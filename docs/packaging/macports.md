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
**two idempotent commands** — the first registers `kodmial/macports-nanodictate`
(the git repo that mirrors the generated Portfile at every release) as a git
port source, the second installs the same prebuilt binary as Homebrew:

```sh
sudo bash -c '
set -e
P=/Users/Shared/macports-nanodictate
C=/opt/local/etc/macports/sources.conf
U="${SUDO_USER:-$USER}"
H="$(dscl . -read "/Users/$U" NFSHomeDirectory 2>/dev/null | awk -F'"'"': '"'"' '"'"'{print $2}'"'"')"
[ -n "$H" ] || H="$(eval echo "~${U}")"
MC="$H/.macports/macports.conf"
USER_CONF=0
if [ -f "$MC" ] && grep -Eq '"'"'^[[:space:]]*sources_conf([[:space:]]|$)'"'"' "$MC"; then
  SC_VAL="$(grep -E '"'"'^[[:space:]]*sources_conf([[:space:]]|$)'"'"' "$MC" | head -n 1 | awk '"'"'{print $2}'"'"')"
  if [ -n "$SC_VAL" ]; then
    case "$SC_VAL" in
      /*) C="$SC_VAL" ;;
      '"'"'~/'"'"'*) C="$H/${SC_VAL#'"'"'~/"'"'"'}" ;;
      *) C="$H/$SC_VAL" ;;
    esac
    [ "$C" = "/opt/local/etc/macports/sources.conf" ] || USER_CONF=1
  fi
fi
S="file://$P"
[ -d "$P/.git" ] || git clone https://github.com/kodmial/macports-nanodictate "$P"
[ "$(stat -f %u "$P")" = 0 ] || chown -R root:admin "$P"
grep -qxF "$S" "$C" || { grep -qF "[default]" "$C" && sed -i "" "/\[default\]/i\\
$S
" "$C" || echo "$S" >> "$C"; }
if [ "$USER_CONF" = 1 ]; then chown "$U" "$C"; fi
'

sudo port selfupdate && sudo port install nanodictate
```

If `~/.macports` exists and its `macports.conf` sets `sources_conf`,
the command targets that user file — it takes precedence over
`/opt/local/etc/macports/sources.conf`.

What it does (MacPorts has no `git://` scheme in `sources.conf` —
`file`/`rsync`/`http`/`ftp` only, mportsync in macports.tcl — so the tree is
cloned by hand once and exposed through a `file://` source):

- **clone** — `kodmial/macports-nanodictate` into
  `/Users/Shared/macports-nanodictate`, skipped when already present. The
  first clone is always manual: `port selfupdate` only
  `git pull --rebase --autostash`es existing trees.
- **chown** — hands the tree to root:admin: `port selfupdate` pulls as root
  and git ≥ 2.35.2 refuses an owner-mismatched repo ("dubious ownership").
- **sources.conf** — the `file://` line is inserted **before** `[default]`:
  the first match wins, so our tree shadows the rsync tree, and the file is
  hand-edited (no `port repo add`). Do **not** add `[nosync]` — only a
  synced source is refreshed by `port selfupdate`; an unsynced one needs a
  manual `git pull` + `portindex`.
- **install** — `port selfupdate` re-syncs the tree and indexes it, then
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
(`rsync.macports.org`); if it is unreachable the run reports `numfailed` —
re-running heals it, and the git tree's index is already fresh, so the
upgrade still works.

**Full uninstall:**

```sh
sudo port uninstall nanodictate
```

One command: `pre-deactivate` unloads the running agent
(`launchctl bootout gui/$uid/com.nanodictate.agent`), deletes the global
`/Library/LaunchAgents/com.nanodictate.agent.plist` and
`/Library/Logs/NanoDictate`. Only user files (`~/.config/nanodictate`,
`~/Library/Logs/NanoDictate`) survive.

**Recovery after a MacPorts reinstall:**

Run the same first command again — it is idempotent: the clone is skipped
(`/Users/Shared/macports-nanodictate` survives), the `file://` line is
re-inserted into the recreated `sources.conf`, and `port selfupdate`
re-syncs and indexes the tree.

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
at login. The same single label and file are used by `nanodictate start` —
never a second daemon (no `startupitem`). If the install runs without a GUI
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
   cp "$(port prefix)/share/nanodictate/config.example.toml" ~/.config/nanodictate/config.toml
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

1. **Tag and push** — `git tag v0.0.3 && git push origin v0.0.3` (the
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
   MAINTAINERS=@kodmial ruby scripts/release-prep.rb v0.0.3
   ```

   This writes `packaging/macports/Portfile` with the real version, the
   release tarball URL and the sha256 checksums for both arch tarballs
   (arm64 + x86_64). Keep the `Portfile.tpl` in the repo unfilled.

4. **Validate:**

   ```sh
   port lint                                    # in the ports checkout
   sudo port -v install nanodictate             # clean-machine test
   nanodictate --version                        # must print "nanodictate 0.0.3"
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