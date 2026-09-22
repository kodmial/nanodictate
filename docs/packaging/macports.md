# MacPorts packaging

Like the Homebrew formula, the MacPorts port installs a **prebuilt binary
tarball** attached to the GitHub Release
(`https://github.com/kodmial/nanodictate/releases/download/v<VERSION>/nanodictate-<VERSION>-macos-<arch>.tar.gz`),
so no Xcode / Swift toolchain is needed on the user's machine and the
install is fast (extract into `${prefix}`). The released binaries are
unsigned/ad-hoc — no Developer ID and no notarization. This page is the
user-facing install guide plus the maintainer release drill. For the
template layout, the generator and cross-package notes see
[packaging/README.md](../../packaging/README.md).

> **Status (TODO):** the port is **not yet in the MacPorts ports tree** — a
> PR to `macports-ports` is pending/planned. You cannot `port install
> nanodictate` today.

## For the user

### Requirements

- macOS 12+ — the Portfile sets `platforms {darwin >= 21}` (the GitHub
  workflow builds the tarballs on `macos-15-intel` for x86_64 and
  `macos-14` for arm64).
- MacPorts itself.
- Nothing else — the port fetches the arch-matched release tarball (arm64 on
  Apple Silicon, x86_64 on Intel) and extracts it; no Xcode / Swift toolchain
  and no network package fetching.

### Install (when the port is accepted)

```sh
sudo port install nanodictate
```

**Fast install.** No compilation: the port downloads
`nanodictate-<VERSION>-macos-<arch>.tar.gz` from the GitHub Release,
verifies it against the Portfile checksums (sha256) and extracts
the binaries into `$(port prefix)/bin` plus `config.example.toml` into
`$(port prefix)/share/nanodictate/`.

### After install

The port installs `nanodictate` and `NanoDictateAgent` into
`$(port prefix)/bin` and ships `config.example.toml` into
`$(port prefix)/share/nanodictate/`. The `post-destroot` step (run as root
after `sudo port install`) then registers the launch service **once**: it
writes the canonical plist into the **real user's** LaunchAgents
(`/Users/$SUDO_USER/Library/LaunchAgents/com.nanodictate.agent.plist` —
not root's `$HOME`), label `com.nanodictate.agent`, ProgramArguments = the
`$(port prefix)/bin/NanoDictateAgent` binary, RunAtLoad + KeepAlive, and
bootstraps it into the user's gui domain via `launchctl asuser`. So after a
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
[Why no Developer ID in homebrew.md](homebrew.md#why-no-developer-id) for
the comparison table.

## For the maintainer

1. **Tag and push** — `git tag v0.1.0 && git push origin v0.1.0` (the
   Release workflow attaches the prebuilt binary tarballs the port
   downloads).

2. **Generate the Portfile** (needs network access to github.com):

   ```sh
   ruby scripts/release-prep.rb v0.1.0
   ```

   This writes `packaging/macports/Portfile` with the real version, the
   release tarball URL and the sha256 checksums for both arch tarballs
   (arm64 + x86_64). Keep the `Portfile.tpl` in the repo unfilled.

3. **Fill the `maintainers` handle** in the generated Portfile — a
   person's handle is never auto-generated.

4. **Validate:**

   ```sh
   port lint                                    # in the ports checkout
   sudo port -v install nanodictate             # clean-machine test
   nanodictate --version                        # must print "nanodictate 0.1.0"
   ```

5. **Open a PR in `macports-ports`** following their
   [CONTRIBUTING](https://github.com/macports/macports-ports/blob/master/CONTRIBUTING.md):
   copy the generated file into a `macports-ports` checkout as
   `audio/nanodictate/Portfile`.

## TODO

- Port not yet accepted into `macports-ports` (PR pending).
- `maintainers` handle in the generated Portfile.