# MacPorts packaging

Like the Homebrew formula, the MacPorts port installs a **prebuilt binary
tarball** attached to the GitHub Release
(`https://github.com/kodmial/nanodictate/releases/download/v<VERSION>/nanodictate-<VERSION>-macos-<arch>.tar.gz`),
so no Xcode / Swift toolchain is needed on the user's machine and the
install is fast (extract into `${prefix}`). The released binaries are
self-signed with the NanoDictate CI Signing identity — no Developer ID and
no notarization. This page is the
user-facing install guide plus the maintainer release drill. For the
template layout, the generator and cross-package notes see
[packaging/README.md](../../packaging/README.md).

> **Status:** the port is **not in the official MacPorts ports tree** — by
> decision we do not open upstream PRs — so a bare
> `sudo port install nanodictate` does **not** work on a clean machine. The
> git port tree below installs the same prebuilt binaries today; the release
> workflow syncs the generated Portfile into `kodmial/macports-nanodictate`
> at every release, so existing installs update through `port selfupdate`.

## For the user

### Requirements

- macOS 12+ — the Portfile sets `platforms {darwin >= 21}` (the GitHub
  workflow builds the tarballs on `macos-15-intel` for x86_64 and
  `macos-14` for arm64).
- MacPorts itself.
- Nothing else — the port fetches the arch-matched release tarball (arm64 on
  Apple Silicon, x86_64 on Intel) and extracts it; no Xcode / Swift toolchain
  and no network package fetching.

### Install today (git port tree)

The port is not in the official tree, so install through a git port source —
**one command** — the script registers `kodmial/macports-nanodictate` (the git
repo that mirrors the generated Portfile at every release) as a git port source
and installs the same prebuilt binary as Homebrew:

```sh
( tmp="$(mktemp)" \
  && curl -fsSL https://raw.githubusercontent.com/kodmial/nanodictate/main/scripts/install-macports.sh -o "$tmp" \
  && bash "$tmp"
rc=$?
rm -f "$tmp"
exit "$rc" )
```

If `~/.macports` exists and its `macports.conf` sets `sources_conf`,
the script targets that user file — it takes precedence over
`/opt/local/etc/macports/sources.conf`.

What it does (MacPorts has no `git://` scheme in `sources.conf` —
`file`/`rsync`/`http`/`ftp` only, mportsync in macports.tcl — so the tree is
cloned by hand once and exposed through a `file://` source):

- **clone** — `kodmial/macports-nanodictate` into
  `/Users/Shared/macports-nanodictate` (an already-present tree is reused when
  it is the canon repo: it must be fully root-owned, its origin URL and pinned
  revision are verified, and it is reset to the pinned revision before it is
  touched).
  The
  first clone is always manual: `port selfupdate` only
  `git pull --rebase --autostash`es existing trees.
- **ownership check** — an existing tree is reused only when it is **fully
  root-owned**: a tree containing entries with any other owner (e.g. left behind
  by a local account) is rejected. Recover by deleting it and running the
  install again — the fresh clone is root-owned:

  ```sh
  sudo rm -rf /Users/Shared/macports-nanodictate
  ```
- **sources.conf** — the `file://` line is inserted **before** `[default]`:
  the first match wins, so our tree shadows the rsync tree, and the file is
  hand-edited (no `port repo add`). Do **not** add `[nosync]` — only a
  synced source is refreshed by `port selfupdate`; an unsynced one needs a
  manual `git pull` + `portindex`.
- **install** — the script runs `portindex` on the clone, then
  `port install` fetches the release tarball.

Any path works for the file source; the
`/opt/local/var/macports/sources/<host>/<path>` convention only applies to
non-file URLs (and is wiped by a MacPorts reinstall). `/Users/Shared` is
outside `/opt/local` and world-traversable (Apple's standard place for
shared files), so the clone survives reinstall.

**Fast install.** No compilation: the port downloads
`nanodictate-<VERSION>-macos-<arch>.tar.gz` from the GitHub Release,
verifies it against the Portfile checksums (sha256) and extracts
the binaries into `$(port prefix)/bin` plus `config.example.toml` into
`$(port prefix)/share/nanodictate/`.

**Updates:**

```sh
sudo port selfupdate && sudo port upgrade nanodictate
```

`port selfupdate` also refreshes the default rsync tree
(`rsync.macports.org`); if the rsync source is unreachable, `selfupdate`
exits with an error and the `&&` above stops before the upgrade. Re-running
heals it — and the git tree's index is already fresh, so if the local git
source is still indexed, run the upgrade alone:

```sh
sudo port upgrade nanodictate
```

**Full uninstall:** stop the user-managed agent and remove its plist first
(the `rm` still runs if `nanodictate stop` fails), then uninstall the port:

```sh
nanodictate stop; rm -f ~/Library/LaunchAgents/com.nanodictate.agent.plist
sudo port uninstall nanodictate
```

That two-line cleanup is manual — `port uninstall` itself is one command: its
`pre-deactivate` step unloads the running agent
(`launchctl bootout gui/$uid/com.nanodictate.agent`) and deletes the global
`/Library/LaunchAgents/com.nanodictate.agent.plist`. Only user files
(`~/.config/nanodictate`, `~/Library/Logs/NanoDictate`) survive; the user
LaunchAgent plist is removed only by the manual step above.

**Recovery after a MacPorts reinstall:**

The tree in `/Users/Shared` survives while `sources.conf` is recreated. Run
the install command again: it reuses the root-owned canon tree, resets it to
the pinned revision, re-inserts the `file://` line into the recreated
`sources.conf`, indexes it (`portindex`) and installs the port. Delete the
tree only if the installer rejects it (a non-root owner, a foreign origin or
a dirty tree):

```sh
sudo rm -rf /Users/Shared/macports-nanodictate
```

### After install

The port installs `nanodictate` and `NanoDictateAgent` into
`$(port prefix)/bin` and ships `config.example.toml` into
`$(port prefix)/share/nanodictate/`. The `post-activate` step (run as root
during `sudo port install`) then registers the launch service **once**: it
writes the canonical plist into the **global** LaunchAgents
(`/Library/LaunchAgents/com.nanodictate.agent.plist`), label
`com.nanodictate.agent`, ProgramArguments = the
`$(port prefix)/bin/NanoDictateAgent` binary, RunAtLoad + KeepAlive, and
bootstraps it into the console user's gui domain via
`launchctl bootstrap gui/$uid`. So after a
clean install the daemon is registered without a manual first run and starts
at login. `nanodictate start` writes the user-level plist
(`~/Library/LaunchAgents/com.nanodictate.agent.plist`) — the same label
`com.nanodictate.agent` as the port's global
`/Library/LaunchAgents/com.nanodictate.agent.plist`, but a different file;
launchd permits only one registration per label in the GUI domain, so there
is never a second daemon (no `startupitem`). If the install runs without a GUI
session (SSH) the bootstrap is skipped tolerantly; the plist is still written
and RunAtLoad starts the daemon at the next login.

1. **TCC grants (required, manual).** In **System Settings → Privacy &
   Security** add the `NanoDictateAgent` binary to **Microphone** and
   **Accessibility** (and **Input Monitoring** if the hotkey does not fire).
   Grants are per-binary — after a `port upgrade` that replaces the binary
   you may need to re-grant.

2. **Configure.** The CLI only reads `~/.config/nanodictate/config.toml`
   (never `${prefix}/etc`), so `config.example.toml` ships as a copy source:

   ```sh
   mkdir -p ~/.config/nanodictate
   # create config.toml only if it does not exist yet — re-running preserves
   # existing providers / API keys
   if [ ! -e ~/.config/nanodictate/config.toml ]; then
     install -m 600 "$(port prefix)/share/nanodictate/config.example.toml" ~/.config/nanodictate/config.toml
   fi
   nanodictate config set-key <provider>   # or edit the file and set api_key
   nanodictate provider list
   ```

3. **The agent is already registered by the install** — no first-run step
   needed. `nanodictate start` is still there to re-register with the
   symlink-resolved real path and to manage the service:

   ```sh
   nanodictate status   # or: launchctl print gui/$(id -u)/com.nanodictate.agent
   nanodictate stop
   nanodictate logs     # last 50 lines; ~/Library/Logs/NanoDictate/agent.log
   ```

### Why no Developer ID?

Same as Homebrew: `port install` downloads the tarball with MacPorts' own
fetcher, so the port's own fetcher does not stamp `com.apple.quarantine` on
the installed binaries — no "Open Anyway" and no manual `xattr` are part of
the MacPorts install flow either, and with no quarantine attribute on the
binaries no Gatekeeper dialog is expected on the first launch — none has been
observed. The port installs the same self-signed, not notarized binaries, and
the signature is what `spctl` reports on (see
[Signing and quarantine in homebrew.md](homebrew.md#signing-and-quarantine)).

Browser downloads of the GitHub Releases tarballs carry
`com.apple.quarantine`, and those are outside the install path entirely — see
[Troubleshooting: only if Gatekeeper still refuses in
homebrew.md](homebrew.md#troubleshooting-only-if-gatekeeper-still-refuses) for
the comparison table and the recovery command. The Homebrew Cask is the one
path that installs a quarantined app *bundle*, and its `postflight_steps`
block clears the attribute as part of the install.

## For the maintainer

On CI the release workflow already does steps 1, 3 and 5 automatically on
every release — this section is the manual drill that the workflow runs.

1. **Tag and push** — `git tag v0.1.0 && git push origin v0.1.0` (the
   Release workflow attaches the prebuilt binary tarballs the port
   downloads).

2. **Set the maintainers handle** via env — `MAINTAINERS=@kodmial`
   (optionally `REVISION`, default `0`); the generator fills the
   `__MAINTAINERS__` / `__REVISION__` placeholders from them, so the
   generated Portfile is ready as-is. `release.yml` passes
   `MAINTAINERS='@kodmial'` by default; an unfilled `__MAINTAINERS__` in
   the output is caught by the CI anti-placeholder grep.

3. **Generate the Portfile** (needs network access to github.com):

   ```sh
   MAINTAINERS=@kodmial ruby scripts/release-prep.rb v0.1.0
   ```

   This writes `packaging/macports/Portfile` with the real version, the
   release tarball URL and the sha256 checksums for both arch tarballs
   (arm64 + x86_64). Keep the `Portfile.tpl` in the repo unfilled.

4. **Validate:**

   ```sh
   port lint                                # in the ports checkout
   sudo port -v install nanodictate         # clean-machine test
   nanodictate --version                    # must print "nanodictate <VERSION>"
   sudo port test nanodictate               # run the test phase alone
   ```

   The Portfile declares a real `test` phase, but the phase is optional:
   MacPorts runs it only when you ask for it with `sudo port
   test nanodictate`, not as part of `sudo port install`. A failure there is
   reported and makes `sudo port test` itself exit non-zero, but it does not
   block the install. Run it explicitly as the smoke test, since nothing else
   in the install path exercises the staged binary.

   `test.cmd` is a self-contained `/bin/sh` one-liner and `test.target` is
   empty, so nothing is appended to the command. It checks exactly two
   things about `<destroot>/<prefix>/bin/nanodictate --version`:

   1. the binary exits 0 — the output is captured first and the rest is
      `&&`-chained to it, so a non-zero exit fails `port test` before
      anything is compared;
   2. the port version occurs in that output as a **whole token**: the
      output is split on every character that is neither a digit nor a dot
      (`tr -c "0-9."`), and one of the resulting lines must equal the port
      version exactly (`grep -Fx`, so the version is a literal and not a
      pattern). An empty output, a different version, and a longer number
      that merely contains the version (`0.1.01`, `10.1.0`) all fail.

   Nothing beyond that is checked. In particular the rest of the output
   line is **not** verified: the port knows only its own version, so a CLI
   that prints the same version under a different prefix
   (`NanoDictate <VERSION>` instead of `nanodictate <VERSION>`) still passes.
   Nothing outside `--version` is exercised either — no config, no network,
   no audio device, no TCC. Read it as a "does the staged binary run and
   does it report this version" smoke test, nothing more.

   When `port test` runs on its own against a port that is not installed
   yet, `${prefix}` holds no binary at that point — hence the command in
   `test.cmd` runs the staged destroot copy
   (`${destroot}${prefix}/bin/nanodictate`), the only place the binary
   exists then. `${worksrcdir}` holds no binary at all: the port ships a
   prebuilt tarball, not sources. Once the port is installed, as in step 4
   above, `activate` has already populated `${prefix}` and the picture
   changes — see the standalone `port test` paragraph below.

   The MacPorts Guide's Port Phases section (chapter 5.3,
   guide.macports.org/chunked/reference.phases.html) lists the phases as
   `build` → `test` → `destroot` → `install`, but that is a listing, not
   a dependency order. MacPorts' own test target requires them through
   `target_requires ... main fetch checksum extract patch configure build
   destroot` in its `porttest.tcl`
   (`/opt/local/libexec/macports/lib/port1.0/porttest.tcl:11`):
   `destroot` is a prerequisite of the test phase and `install` is not.
   The test therefore always runs after `destroot` and before
   `install`/`activate`.

   `sudo port test nanodictate` runs the test phase on its own. It does not
   reuse anything the install left behind: `portautoclean` defaults to `yes`,
   so a completed install runs the `clean` target right after `install` and
   removes the whole build directory, state file included. The first
   `port test` after an install therefore re-runs the required targets and
   re-stages the destroot itself, downloading and extracting the tarball
   again. A `sudo port clean nanodictate` is only needed to re-run an earlier
   `port test`, since that one does leave its state file behind.

5. **Sync the generated Portfile into `kodmial/macports-nanodictate`** —
   **automated since 0.0.x**: on every release, the `manifests` job of
   `release.yml` commits `packaging/macports/Portfile` to the
   `kodmial/macports-nanodictate` repo — the git port source the install
   command clones — and pushes it. It needs the `TAP_PAT` repo secret — the
   same Personal Access Token (classic, "repo" scope) that the Homebrew tap
   sync uses; without it the step **fails with an error** (`exit 1`), so a
   release can never go green with the MacPorts tree silently unupdated. No
   upstream PR
   to `macports-ports` is opened (by decision we do not push upstream); every
   install of the git source picks the update up on the next
   `port selfupdate`.

## TODO

- Port stays out of `macports-ports` (no upstream PRs — decision). The
  release workflow syncs the Portfile into `kodmial/macports-nanodictate` at
  every release; all installs and updates go through the git port tree.