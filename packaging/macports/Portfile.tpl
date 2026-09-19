# -*- coding: utf-8; mode: tcl; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- vim:fenc=utf-8:ft=tcl:et:sw=4:ts=4:sts=4

# NanoDictate — macOS dictation (double-Alt, bilingual EN/RU, 4 STT providers).
# Template: __VERSION__, __SHA256_ARM64__, __SHA256_X86_64__ are filled by
# scripts/release-prep.rb — do not hand-edit the output.

PortSystem          1.0
PortGroup           github 1.0

# Binary port (symmetry with the Homebrew formula): the prebuilt tarball
# attached to the tag is installed as-is — NO Xcode / Swift toolchain needed
# on the user's machine. Tarball name is arch-dependent
# (nanodictate-__VERSION__-macos-<arm64|x86_64>.tar.gz, built by
# .github/workflows/release.yml), so distfile + checksum are chosen by
# ${os.arch}; the download URL is derived from the tag v__VERSION__.
# master_sites points at the GitHub release assets (needed to fetch the
# arch-specific distfile itself, not just for livecheck); livecheck.type
# github walks repo tags. The checksums are filled by scripts/release-prep.rb.
github.setup        kodmial nanodictate __VERSION__ v
revision            0

master_sites        https://github.com/kodmial/nanodictate/releases/download/v__VERSION__

if {${os.arch} eq "arm64"} {
    distfiles       nanodictate-__VERSION__-macos-arm64.tar.gz
    checksums       sha256  __SHA256_ARM64__
} else {
    distfiles       nanodictate-__VERSION__-macos-x86_64.tar.gz
    checksums       sha256  __SHA256_X86_64__
}

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

# Prebuilt tarball ships ad-hoc signed binaries (release.yml signs WITHOUT
# entitlements on purpose: Microphone/Accessibility TCC grants are per-machine,
# each user grants them on their own Mac). No build phase — extract + stage.
use_configure       no

# Binary port: no Makefile in the tarball — the default build phase would
# run `make all` and fail ("No rule to make target 'all'").
build {}

destroot {
    # The tarball is flat (no wrapper): binaries, config + Resources/ land
    # directly in ${workpath} (release.yml: tar -C dist ...). Resources/ ships
    # for reference only (entitlements already applied at codesign) — the port
    # stages binaries + config like the Homebrew formula; the runtime does not
    # need Resources.
    xinstall -m 755 ${workpath}/nanodictate ${destroot}${prefix}/bin/
    xinstall -m 755 ${workpath}/NanoDictateAgent ${destroot}${prefix}/bin/
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
    xinstall -m 644 ${workpath}/config.example.toml ${share_dir}/
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

livecheck.type      github

# Optional smoke test once `nanodictate --version` lands (planned for 0.1.0):
# test.run    yes
# test.cmd    ${prefix}/bin/nanodictate
# test.target --version
