# MacPorts packaging

Like the Homebrew formula, the MacPorts port builds NanoDictate **from
source** on the user's machine (`swift build --configuration release
--disable-sandbox`), so the installed binaries are unsigned/ad-hoc — no
Developer ID and no notarization. This page is the user-facing install guide
plus the maintainer release drill. For the template layout, the generator
and cross-package notes see [packaging/README.md](../../packaging/README.md).

> **Status (TODO):** the port is **not yet in the MacPorts ports tree** — a
> PR to `macports-ports` is pending/planned. You cannot `port install
> nanodictate` today.

## For the user

### Requirements

- macOS 12+ — the Portfile sets `platforms {darwin >= 21}` (the GitHub
  workflow builds on `macos-13` / `macos-14`).
- MacPorts itself.
- **Xcode 14.3+** (not just CLT): the Portfile sets `use_xcode yes` because
  there is currently **no `swift` / `swift-lang` port in MacPorts** (both
  were removed; verified against ports.macports.org, 2026-09). The Swift
  compiler ships with Apple's Xcode, so Xcode must be installed.

### Install (when the port is accepted)

```sh
sudo port install nanodictate
```

**Expect a long build.** The port runs SwiftPM, which fetches the
SwiftLint/SwiftFormat plugin packages over the network and compiles the
whole package from source. This is normal for source-built Swift ports
(compare `swiftlint`).

### After install

The port installs `nanodictate` and `NanoDictateAgent` into
`$(port prefix)/bin` and ships `config.example.toml`, the two entitlements
and the LaunchAgent plist template into
`$(port prefix)/share/nanodictate/`.

1. **TCC grants (required, manual).** In **System Settings → Privacy &
   Security** add the `NanoDictateAgent` binary to **Microphone** and
   **Accessibility** (and **Input Monitoring** if the hotkey does not fire).
   Grants are per-binary — after a `port upgrade` that rebuilds the binary
   you may need to re-grant.

2. **Configure.** The CLI only reads `~/.config/nanodictate/config.toml`
   (never `${prefix}/etc`), so `config.example.toml` ships as a copy source:

   ```sh
   cp "$(port prefix)/share/nanodictate/config.example.toml" ~/.config/nanodictate/config.toml
   nanodictate config set-key <provider>   # or edit the file and set api_key
   nanodictate provider list
   ```

3. **Start the agent.** The plist template does **not** sit next to the
   binary in a MacPorts install, so point the CLI at it first:

   ```sh
   export NANODICTATE_PLIST_TEMPLATE="$(port prefix)/share/nanodictate/nanodictate-agent.plist.template"
   nanodictate start
   ```

   This renders `~/Library/LaunchAgents/com.nanodictate.agent.plist` and
   bootstraps the LaunchAgent. Manage it with `nanodictate status`,
   `nanodictate stop`, `nanodictate logs` (or
   `launchctl gui/$(id -u)/com.nanodictate.agent`).

### Why no Developer ID?

Same as Homebrew: the port builds locally, so the produced binaries carry no
quarantine attribute and Gatekeeper does not block them. Only browser
downloads of the GitHub Releases tarballs get `com.apple.quarantine`; clear
it once with `xattr -dr com.apple.quarantine /path/to/binary`. See
[Why no Developer ID in homebrew.md](homebrew.md#why-no-developer-id) for
the comparison table.

## For the maintainer

1. **Tag and push** — `git tag v0.1.0 && git push origin v0.1.0` (the
   Release workflow attaches the prebuilt tarballs; the port is
   source-based and only uses the tag).

2. **Generate the Portfile** (needs network access to github.com):

   ```sh
   ruby scripts/release-prep.rb v0.1.0
   ```

   This writes `packaging/macports/Portfile` with the real version, source
   tarball URL, sha256/rmd160/size. Keep the `Portfile.tpl` in the repo
   unfilled.

3. **Fill the `maintainers` handle** in the generated Portfile — a
   person's handle is never auto-generated.

4. **Validate:**

   ```sh
   port lint                                    # in the ports checkout
   port checksum                                # fills rmd160 if it stayed a placeholder
   sudo port -v install nanodictate             # clean-machine test
   nanodictate --version                        # must print "nanodictate 0.1.0"
   ```

5. **Open a PR in `macports-ports`** following their
   [CONTRIBUTING](https://github.com/macports/macports-ports/blob/master/CONTRIBUTING.md):
   copy the generated file into a `macports-ports` checkout as
   `audio/nanodictate/Portfile`.

## TODO

- **Swift toolchain.** No `swift` / `swift-lang` MacPorts port exists →
  `use_xcode yes` forces the build to use Apple's Swift from Xcode. If a
  self-contained Swift port ever returns, prefer `depends_build port:swift`
  so Xcode is not required (marked in the Portfile template).
- Port not yet accepted into `macports-ports` (PR pending).
- `maintainers` handle in the generated Portfile.
- `rmd160` may stay a placeholder if the local Ruby/OpenSSL cannot compute
  it — `port checksum` fills it.