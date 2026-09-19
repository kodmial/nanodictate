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
    # Только бинарь + конфиг. LaunchAgent порт НЕ регистрирует: destroot/
    # staging не должен мутировать хомяк пользователя и бустраппить агента
    # при обычной установке (для юзер-агентов у MacPorts механизма нет —
    # startupitem создал бы второй, системный, демон). Службу поднимает
    # пользователь ПОСЛЕ установки: `nanodictate start` — тот же единственный
    # Label com.nanodictate.agent и тот же канонический plist
    # ~/Library/LaunchAgents/com.nanodictate.agent.plist.
    # config.example.toml — канон дефолтов: при первом запуске приложение
    # копирует его в юзер-конфиг ~/.config/nanodictate/config.toml (CLI никогда
    # не читает ${prefix}/etc).
    set share_dir ${destroot}${prefix}/share/nanodictate
    xinstall -d -m 755 ${share_dir}
    xinstall -m 644 ${worksrcpath}/config.example.toml ${share_dir}/
    ui_msg "nanodictate: installed. To register and start the background agent, run 'nanodictate start'"
}

checksums           rmd160  __RMD160__ \
                    sha256  __SOURCE_SHA256__ \
                    size    __SOURCE_SIZE__

livecheck.type      github

# Optional smoke test once `nanodictate --version` lands (planned for 0.1.0):
# test.run    yes
# test.cmd    ${prefix}/bin/nanodictate
# test.target --version