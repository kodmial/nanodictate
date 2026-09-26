# -*- coding: utf-8; mode: tcl; tab-width: 4; indent-tabs-mode: nil; c-basic-offset: 4 -*- vim:fenc=utf-8:ft=tcl:et:sw=4:ts=4:sts=4

# NanoDictate — macOS dictation (double-Alt, bilingual EN/RU, 4 STT providers).
# Template: __VERSION__, __SHA256_ARM64__, __SHA256_X86_64__, __MAINTAINERS__
# (env MAINTAINERS), __REVISION__ (env REVISION, default 0) are filled by
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
revision            __REVISION__

master_sites        https://github.com/kodmial/nanodictate/releases/download/v__VERSION__

# MacPorts ${os.arch} is NOT the Apple arch string: MacPorts base rewrites
# tcl_platform(machine) to match `uname -p` (macports1.0/macports.tcl,
# "Set os_arch to match `uname -p`"), so Apple Silicon reports "arm" and
# every Intel Mac reports "i386". Testing for "arm64" / "x86_64" here would
# therefore never match and would silently pick the wrong tarball.
#
# Only those two architectures have a release asset. Anything else (e.g. a
# legacy "powerpc" host) is a hard error rather than a fall-back to the Intel
# tarball, which would download a binary that cannot execute there.
switch -- ${os.arch} {
    arm {
        set distfile_arch    arm64
        set distfile_sha256  __SHA256_ARM64__
    }
    i386 {
        set distfile_arch    x86_64
        set distfile_sha256  __SHA256_X86_64__
    }
    default {
        ui_error "nanodictate supports only Apple Silicon (arm64) and Intel (x86_64) macOS; this machine reports os.arch \"${os.arch}\"."
        return -code error "unsupported architecture: ${os.arch}"
    }
}

distfiles           nanodictate-__VERSION__-macos-${distfile_arch}.tar.gz
checksums           sha256  ${distfile_sha256}

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

# Prebuilt tarball ships binaries self-signed with the NanoDictate CI Signing
# identity (hardened runtime); entitlements are applied at CI codesign.
# Microphone/Accessibility TCC grants are still per-machine — each user grants
# them on their own Mac. No build phase — extract + stage.
use_configure       no

# Binary port: no Makefile in the tarball — the default build phase would
# run `make all` and fail ("No rule to make target 'all'").
build {}

destroot {
    # The tarball is flat (no wrapper): binaries, config + Resources/ land
    # directly in ${workpath} (release.yml: tar -C dist ...). Resources/ ships
    # for reference only (entitlements applied at CI codesign) — the port
    # stages binaries + config like the Homebrew formula; the runtime does not
    # need Resources.
    xinstall -m 755 ${workpath}/nanodictate ${destroot}${prefix}/bin/
    xinstall -m 755 ${workpath}/NanoDictateAgent ${destroot}${prefix}/bin/
    # Binaries + config only. Service registration lives in post-activate:
    # it writes the canonical global plist
    # /Library/LaunchAgents/com.nanodictate.agent.plist and bootstraps the
    # console user, so `sudo port install` leaves the daemon live with no
    # manual `nanodictate start`. No startupitem (a separate startupitem would
    # create a second launchd job).
    # config.example.toml — the canonical set of defaults: on first run the
    # application copies it to the per-user config
    # ~/.config/nanodictate/config.toml (the CLI never reads ${prefix}/etc).
    set share_dir ${destroot}${prefix}/share/nanodictate
    xinstall -d -m 755 ${share_dir}
    xinstall -m 644 ${workpath}/config.example.toml ${share_dir}/
}

# Service registration lives in post-activate, not post-destroot: post-destroot
# runs BEFORE activation, so on a fresh install ${prefix}/bin/NanoDictateAgent
# is not on disk yet; post-activate runs after the new files are in place.
# Port phases run as root and are NOT sandboxed (Homebrew's equivalent runs
# as the user), so we write a GLOBAL LaunchAgent and bootstrap the console
# user directly.
post-activate {
    # Register the LaunchAgent so NanoDictateAgent is alive right after
    # `sudo port install` — no manual `nanodictate start` needed.
    #
    # Canonical plist: /Library/LaunchAgents/com.nanodictate.agent.plist
    # (global LaunchAgents: loaded into every user's GUI session at login,
    # unlike ~/Library/LaunchAgents). Same single Label com.nanodictate.agent
    # and the same plist shape the CLI writes, so there is always exactly one
    # daemon regardless of install method or order.
    #
    # A headless / SSH install (no GUI session for the console user) is NOT
    # fatal: the plist stays on disk and RunAtLoad picks the service up at the
    # next login. But when a GUI session *does* exist and the bootstrap still
    # fails, that is a real problem the user has to know about — so the actual
    # launchctl error is surfaced together with the commands to inspect and
    # recover the job. Each catch is scoped to exactly one command (never a
    # blanket catch around the whole phase), so an unrelated Tcl error cannot
    # be silently reported as "headless install".
    set launch_dir /Library/LaunchAgents
    set plist_path ${launch_dir}/com.nanodictate.agent.plist
    set agent_bin  ${prefix}/bin/NanoDictateAgent
    set label      com.nanodictate.agent

    if {[catch {exec /bin/mkdir -p ${launch_dir}} mkdir_err]} {
        ui_warn "nanodictate: could not create ${launch_dir}: ${mkdir_err}"
        ui_warn "nanodictate: the service will register on the first 'nanodictate start' run by the desktop user."
    } else {
        # Single authoritative XML block (one place to edit).
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
  <!-- StandardOutPath/StandardErrorPath deliberately omitted: the agent logs
       to its own per-user ~/Library/Logs/NanoDictate, and launchd redirection
       would target a root-owned path the console user cannot write. -->
</dict>
</plist>
}
        set content [string map [list __AGENT_BIN__ ${agent_bin}] ${plist_xml}]
        if {[catch {
            set fd [open ${plist_path} w 0644]
            puts -nonewline ${fd} ${content}
            close ${fd}
        } write_err]} {
            ui_warn "nanodictate: could not write ${plist_path}: ${write_err}"
            ui_warn "nanodictate: the service will register on the first 'nanodictate start' run by the desktop user."
        } else {
            # Bootstrap into the CURRENT console user's GUI session so the
            # service is live immediately. uid 0 = no GUI session (SSH/
            # headless install or login screen): nothing to bootstrap now,
            # RunAtLoad covers the next login. This stays non-fatal.
            if {[catch {set uid [exec /usr/bin/stat -f %u /dev/console]} stat_err]} {
                ui_msg "nanodictate: could not determine the console user (${stat_err}) — the service will start at next login (plist: ${plist_path})"
            } elseif {${uid} ne "0"} {
                # Unload a possibly already-loaded job first (re-install over
                # a running service / upgrade): a bootout error when the
                # service is not loaded is normal and expected, so its result
                # is deliberately discarded here.
                catch {exec /bin/launchctl bootout gui/${uid}/${label}}
                if {[catch {exec /bin/launchctl bootstrap gui/${uid} ${plist_path}} boot_err]} {
                    # A GUI session exists but the bootstrap failed: surface
                    # the real reason plus the inspect/recover commands.
                    ui_warn "nanodictate: a GUI session is present (uid ${uid}) but the service failed to bootstrap: ${boot_err}"
                    ui_warn "nanodictate: check the job with:  launchctl print gui/${uid}/${label}"
                    ui_warn "nanodictate: recover with either:  launchctl bootstrap gui/${uid} ${plist_path}   (or, as the logged-in user: nanodictate start)"
                    ui_warn "nanodictate: the plist is in place, so the service will also start at the next login."
                } else {
                    ui_msg "nanodictate: service bootstrapped (gui/${uid}), plist ${plist_path}"
                    # Confirm launchd actually accepted and kept the job —
                    # bootstrap can return 0 while the job immediately dies
                    # (bad path, missing entitlements, ...). 'launchctl print'
                    # on its own only proves the job is REGISTERED: a
                    # repeatedly failing KeepAlive job stays in the domain in
                    # a throttled state, and a job whose process has already
                    # exited is still listed. The live state is therefore read
                    # from the printout — a running job carries
                    # "state = running" together with a "pid = <n>" line, a
                    # dead one reports "state = not running" and has no pid.
                    if {[catch {exec /bin/launchctl print gui/${uid}/${label}} print_result]} {
                        ui_warn "nanodictate: bootstrapped, but 'launchctl print' does not show ${label}: ${print_result}"
                        ui_warn "nanodictate: recover with either:  launchctl bootstrap gui/${uid} ${plist_path}   (or, as the logged-in user: nanodictate start)"
                    } else {
                        set job_state "unknown"
                        set job_pid ""
                        regexp {(?m)^[ \t]*state = ([^\n]+)} ${print_result} -> job_state
                        regexp {(?m)^[ \t]*pid = ([0-9]+)} ${print_result} -> job_pid
                        if {${job_state} eq "running" && ${job_pid} ne ""} {
                            ui_msg "nanodictate: service registered and running (pid ${job_pid}, gui/${uid}), plist ${plist_path}"
                        } else {
                            ui_msg "nanodictate: service registered in launchd (gui/${uid}), plist ${plist_path}"
                            ui_warn "nanodictate: the job is registered but has no live process (state: ${job_state}, pid: ${job_pid}) — a KeepAlive agent that keeps failing stays throttled in the domain like this"
                            ui_warn "nanodictate: check the job with:  launchctl print gui/${uid}/${label}"
                            ui_warn "nanodictate: recover with either:  launchctl bootstrap gui/${uid} ${plist_path}   (or, as the logged-in user: nanodictate start)"
                        }
                    }
                }
            } else {
                ui_msg "nanodictate: no console user (headless) — the service will start at next login (plist: ${plist_path})"
            }
        }
    }
}

pre-deactivate {
    # Teardown on uninstall/deactivate: unload the running service and remove
    # the global plist so a single `sudo port uninstall` leaves no trace — no
    # manual `sudo rm` step. deactivate also runs on `port upgrade`; the plist
    # is deleted here, but post-activate recreates it and re-bootstraps the
    # service, so the gap is a brief service break at worst. Idempotent:
    # bootout of a service that is not loaded is normal (catch).
    set plist_path "/Library/LaunchAgents/com.nanodictate.agent.plist"
    # plist removal is not tied to the console user — do it first so it also
    # happens when stat fails below.
    if {[catch {file delete -force ${plist_path}}]} {
        ui_warn "nanodictate: could not remove ${plist_path}"
    } else {
        ui_msg "nanodictate: plist ${plist_path} removed"
    }
    # NOTE: no /Library/Logs/NanoDictate cleanup here. This port never creates
    # that directory — the agent writes to the per-user ~/Library/Logs/
    # NanoDictate (Sources: logDirectory = "~/Library/Logs/NanoDictate"), and
    # the plist deliberately omits StandardOutPath/StandardErrorPath so launchd
    # creates no root-owned log dir. The previous cleanup was therefore dead
    # code that could only ever print a misleading "logs ... removed". User
    # logs under ~ are left alone on uninstall on purpose.
    if {[catch {set uid [exec /usr/bin/stat -f %u /dev/console]} stat_err]} {
        ui_msg "nanodictate: could not determine the console user (${stat_err}) — skipping service unload"
    } elseif {${uid} ne "0"} {
        catch {exec /bin/launchctl bootout gui/${uid}/com.nanodictate.agent}
        ui_msg "nanodictate: service unloaded (gui/${uid})"
    } else {
        ui_msg "nanodictate: no console user — nothing to unload"
    }
}

livecheck.type      github

# Smoke test: run the freshly staged binary and check it starts and prints its
# version. `nanodictate --version` is a pure, non-interactive query — it prints
# one line and exits 0, so it is safe under `port test` (no TTY, no TCC prompt,
# no config/network access).
#
# The command must point at the DESTROOT, not ${prefix}: the test phase runs
# after destroot but before install/activate, so nothing has been copied into
# ${prefix} yet. This matches the documented default test.dir of ${build.dir}
# (a command is run as `cd ${test.dir} && ${test.cmd} ${test.target}`).
#
# MacPorts' own test target (libexec/macports/lib/port1.0/porttest.tcl:11)
# requires the test phase via `target_requires ${org.macports.test} main fetch
# checksum extract patch configure build destroot`: the test phase requires
# destroot but not install, so at test time the binary does not exist under
# ${prefix}/bin yet and ${destroot}${prefix}/bin/<tool> is the only working form.
test.run            yes
test.cmd            ${destroot}${prefix}/bin/nanodictate
test.target         --version
