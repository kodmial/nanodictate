# -*- coding: utf-8; mode: tcl; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- vim:fenc=utf-8:ft=tcl:et:sw=4:ts=4:sts=4

# NanoDictate — macOS dictation (double-Alt, bilingual EN/RU, 4 STT providers).
# Template: __VERSION__, __SOURCE_SHA256__, __RMD160__, __SOURCE_SIZE__ are
# filled by scripts/release-prep.rb — do not hand-edit the output.

PortSystem          1.0
PortGroup           github 1.0

# Release tag, e.g. v0.1.0; same source tarball as the Homebrew formula
# (https://github.com/kodmial/nanodictate/archive/refs/tags/v0.1.0.tar.gz).
# The tarball URL is derived from the tag v__VERSION__ by PortGroup github
# (no URL placeholder is substituted here; only the Homebrew formula uses
# one); the checksums below are filled by scripts/release-prep.rb.
github.setup        kodmial nanodictate __VERSION__ v
github.tarball_from archive
revision            0

platforms           {darwin >= 21}
categories          audio
license             MIT
maintainers         __MAINTAINERS__ \
                    openmaintainer

description         macOS dictation: double-Alt, bilingual EN/RU, 4 STT providers
long_description    NanoDictate is a macOS dictation tool: tap Alt twice, \
                    speak, and the recognized text is inserted into the \
                    frontmost app. Bilingual EN/RU, 4 STT providers, a \
                    background agent (NanoDictateAgent, runs as a LaunchAgent) \
                    and a control CLI (nanodictate).

# Swift toolchain. There is currently NO "swift" or "swift-lang" macports port
# (both were removed; checked on ports.macports.org, 2026-09). Existing
# SwiftPM-based ports (e.g. swiftlint) build against the Swift compiler shipped
# with Apple's Xcode / Command Line Tools.
# TODO(maintainer): if a self-contained Swift toolchain port ever returns,
# prefer `depends_build port:swift` so Xcode/CLT is not required.
# Package.swift requires swift-tools 5.7 (Xcode 14.3+).
use_xcode           yes

use_configure       no

build.cmd           swift
build.target        build
build.args          --configuration release --disable-sandbox

set builtproductdir ${worksrcpath}/.build/release

destroot {
    xinstall -m 755 ${builtproductdir}/nanodictate ${destroot}${prefix}/bin/
    xinstall -m 755 ${builtproductdir}/NanoDictateAgent ${destroot}${prefix}/bin/
    # Только бинарь + конфиг; службу при установке регистрирует post-destroot
    # (тот же единственный Label com.nanodictate.agent и тот же канонический
    # plist ~/Library/LaunchAgents/com.nanodictate.agent.plist, что у
    # `nanodictate start`) — startupitem НЕ нужен (отдельный startupitem создал
    # бы второй демон).
    # config.example.toml — канон дефолтов: при первом запуске приложение
    # копирует его в юзер-конфиг ~/.config/nanodictate/config.toml (CLI никогда
    # не читает ${prefix}/etc).
    set share_dir ${destroot}${prefix}/share/nanodictate
    xinstall -d -m 755 ${share_dir}
    xinstall -m 644 ${worksrcpath}/config.example.toml ${share_dir}/
}

post-destroot {
    # Гибрид A+B: упаковка сама создаёт канонический plist в LaunchAgents
    # реального пользователя и РАЗОВО активирует службу — после чистой
    # установки (без ручного первого запуска) демон зарегистрирован, стартует
    # при входе в систему (RunAtLoad + KeepAlive) и Alt+Alt работает сразу.
    # post-destroot исполняется от root (sudo port install): дом пользователя —
    # через $SUDO_USER, НЕ $HOME (HOME у root — /var/root). Тот же файл и тот
    # же единственный label, что пишет `nanodictate start`, — один демон при
    # любом способе и порядке установки, второй менеджер подменяет.
    if {[info exists env(SUDO_USER)] && ${env(SUDO_USER)} ne ""} {
        set real_user ${env(SUDO_USER)}
        set user_home /Users/${real_user}
        set launch_dir ${user_home}/Library/LaunchAgents
        set logs_dir ${user_home}/Library/Logs/NanoDictate
        set plist_path ${launch_dir}/com.nanodictate.agent.plist
        set agent_bin ${prefix}/bin/NanoDictateAgent
        set log_path ${logs_dir}/agent.log

        if {[catch {
            exec /bin/mkdir -p ${launch_dir} ${logs_dir}
            exec /usr/sbin/chown ${real_user} ${launch_dir} ${logs_dir}
        }]} {
            ui_warn "nanodictate: could not create ${launch_dir} — the service will register on first 'nanodictate start'"
        } else {
            # Канонический plist, идентичный формату AgentService (CLI):
            # Label/ProgramArguments = реальный путь бинаря + RunAtLoad/
            # KeepAlive. Бинарь — ${prefix}/bin/NanoDictateAgent (настоящий
            # файл, xinstall кладёт его без симлинков — реальный путь).
            set plist_xml {
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.nanodictate.agent</string>
  <key>ProgramArguments</key>
  <array>
    <string>__AGENT_BIN__</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>__LOG_PATH__</string>
  <key>StandardErrorPath</key>
  <string>__LOG_PATH__</string>
</dict>
</plist>
}
            set content [string map [list __AGENT_BIN__ ${agent_bin} __LOG_PATH__ ${log_path}] ${plist_xml}]
            if {[catch {
                set fd [open ${plist_path} w 0600]
                puts -nonewline ${fd} ${content}
                close ${fd}
                exec /usr/sbin/chown ${real_user} ${plist_path}
            }]} {
                ui_warn "nanodictate: could not write ${plist_path} — the service will register on first 'nanodictate start'"
            } else {
                # Разовая активация из-под root: bootstrap в gui-домен другого
                # пользователя требует launchctl asuser (прямой bootstrap из
                # root в чужой gui-домен launchd запрещает). Терпимо: при
                # установке по SSH GUI-сессии нет, и «уже загружено» на
                # повторном install — норма; служба всё равно стартует при
                # входе в систему (RunAtLoad).
                set uid [exec /usr/bin/id -u ${real_user}]
                # Установка поверх УЖЕ работающей службы (например, переустановка
                # вторым менеджером): новый plist уже на диске (записан выше) —
                # сперва терпимо выгружаем старую копию (bootout), и bootstrap
                # ниже применяет замену мгновенно, без перезахода в систему.
                # Симметрия с brew post_install. Службы может не быть — это
                # норма: catch молча пропускает ошибку выгрузки (та же идиома,
                # что у bootstrap ниже), установку не роняет.
                catch {exec /bin/launchctl asuser ${uid} /bin/launchctl bootout gui/${uid}/com.nanodictate.agent}
                catch {exec /bin/launchctl asuser ${uid} /bin/launchctl bootstrap gui/${uid} ${plist_path}}
            }
        }
    } else {
        ui_msg "nanodictate: SUDO_USER unset — not touching user LaunchAgents; run 'nanodictate start' to register the service"
    }
}

checksums           rmd160  __RMD160__ \
                    sha256  __SOURCE_SHA256__ \
                    size    __SOURCE_SIZE__

livecheck.type      github

# Optional smoke test once `nanodictate --version` lands (planned for 0.1.0):
# test.run    yes
# test.cmd    ${prefix}/bin/nanodictate
# test.target --version