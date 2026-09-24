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
bash <(curl -fsSL https://raw.githubusercontent.com/kodmial/nanodictate/main/scripts/install-macports.sh)
```

If `~/.macports` exists and its `macports.conf` sets `sources_conf`,
the script targets that user file — it takes precedence over
`/opt/local/etc/macports/sources.conf`.

What it does (MacPorts has no `git://` scheme in `sources.conf` —
`file`/`rsync`/`http`/`ftp` only, mportsync in macports.tcl — so the tree is
cloned by hand once and exposed through a `file://` source):

- **clone** — `kodmial/macports-nanodictate` into
  `/Users/Shared/macports-nanodictate` — into a fresh path (an already-present
  tree is reused only when it is the canon repo: origin URL and pinned
  revision are verified before it is touched).
  The
  first clone is always manual: `port selfupdate` only
  `git pull --rebase --autostash`es existing trees.
- **chown** — (unconditional) hands the tree to root:admin: `port selfupdate`
  pulls as root and git ≥ 2.35.2 refuses an owner-mismatched repo ("dubious
  ownership").
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
(`launchctl bootout gui/$uid/com.nanodictate.agent`), deletes the global
`/Library/LaunchAgents/com.nanodictate.agent.plist` and
`/Library/Logs/NanoDictate`. Only user files (`~/.config/nanodictate`,
`~/Library/Logs/NanoDictate`) survive; the user LaunchAgent plist is removed
only by the manual step above.

**Recovery after a MacPorts reinstall:**

The tree in `/Users/Shared` survives while `sources.conf` is recreated —
remove the stale tree and run the install command again to re-clone it and
re-register the source:

```sh
sudo rm -rf /Users/Shared/macports-nanodictate
```

(the install command clones only into a fresh path, so the stale tree must be
gone first); then repeat the install command — it clones into the fresh path,
re-inserts the `file://` line into the recreated `sources.conf`, indexes it
(`portindex`) and installs the port.

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
   install -m 600 "$(port prefix)/share/nanodictate/config.example.toml" ~/.config/nanodictate/config.toml
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
fetcher, so the installed binaries carry no quarantine attribute and
Gatekeeper does not block them. Only browser downloads of the GitHub
Releases tarballs get `com.apple.quarantine`; clear it once with
`xattr -dr com.apple.quarantine /path/to/binary`. See
[Signing and quarantine in homebrew.md](homebrew.md#signing-and-quarantine) for
the comparison table.

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
   port lint                                    # in the ports checkout
   sudo port -v install nanodictate             # clean-machine test
   nanodictate --version                        # must print "nanodictate 0.1.0"
   ```

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