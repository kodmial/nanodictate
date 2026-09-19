# Packaging

Templates and a generator for distributing NanoDictate through Homebrew and
MacPorts — both install a **prebuilt binary tarball** from GitHub Releases
(the arch-matched `nanodictate-<VERSION>-macos-<arch>.tar.gz` assets published
by the workflow), so no source build happens on the user's machine. Either way
there is **no Developer ID signature and no notarization** — installs are
unsigned/ad-hoc.

## Layout

| Path | Purpose |
| --- | --- |
| `packaging/homebrew/nanodictate.rb.tpl` | Homebrew formula template (binary: `__VERSION__`, `__SHA256_ARM64__`, `__SHA256_X86_64__`) |
| `packaging/homebrew/nanodictate.rb` | Generated formula (do not hand-edit) |
| `packaging/macports/Portfile.tpl` | MacPorts Portfile template (binary: `__VERSION__`, `__SHA256_ARM64__`, `__SHA256_X86_64__`) |
| `packaging/macports/Portfile` | Generated Portfile (do not hand-edit) |
| `scripts/release-prep.rb` | Stdlib-only Ruby generator |

## Usage

Generate the files for a release tag (needs network access to github.com **and**
the published Release — the script downloads the binary tarballs attached to
it, so it can only run after the release workflow finished):

```sh
ruby scripts/release-prep.rb v0.1.0
```

The script downloads the two release binary tarballs
(`.../releases/download/v0.1.0/nanodictate-0.1.0-macos-{arm64,x86_64}.tar.gz`).
It computes `sha256` for each and fills the `__VERSION__`, `__SHA256_ARM64__`,
`__SHA256_X86_64__` placeholders in both templates. Keep the `.tpl`
placeholders in the repo — only the generated files get concrete values.

## Releasing a new version

1. Tag and push: `git tag v0.1.0 && git push origin v0.1.0`
2. Generate: `ruby scripts/release-prep.rb v0.1.0`
3. Publish:
   - **Homebrew**: copy `packaging/homebrew/nanodictate.rb` into the
     `nanodictate-homebrew` tap as `Formula/nanodictate.rb`.
   - **MacPorts**: copy `packaging/macports/Portfile` into a `macports-ports`
     checkout as `audio/nanodictate/Portfile` and open a PR.
4. Verify before release: `brew audit --strict --new nanodictate`, `port lint`,
   and a clean `brew install nanodictate` / `port install` (both binary — no
   build) on a fresh machine.

## Maintainer notes

- **Both Homebrew and MacPorts are binary.** The Homebrew formula and the
  MacPorts port download the same arch-matched ad-hoc signed tarball published
  by the release workflow (`nanodictate-<VERSION>-macos-<arch>.tar.gz`) — no
  compiler on the user's machine. The Portfile sets `use_configure no` and just
  unpacks the binaries into `${prefix}/bin` and ships `config.example.toml`
  into `${prefix}/share/nanodictate/`.
- **Config.** The CLI reads only `~/.config/nanodictate/config.toml`
  (`AppConfig.defaultPath()`), never a file under `etc/`. `config.example.toml`
  therefore ships as a copy source in `share/nanodictate/`.
- **Resources.** Entitlements (`com.nanodictate.agent.entitlements`,
  `com.nanodictate.ctl.entitlements`) are build-time only (code signing in
  `.github/workflows/release.yml`) and no longer ship in the packages: one
  daemon at any install method means the package installs binaries + config
  only.
- **TCC grants.** Microphone + Accessibility are granted manually per binary
  in System Settings (prompted on first use). Both paths install the same
  release binaries — no rebuild per install — so grants only need re-applying
  when a newer release replaces the binary.
- **LaunchAgent — гибрид A+B.** The running binary registers the service
  itself: `nanodictate start` writes the canonical
  `~/Library/LaunchAgents/com.nanodictate.agent.plist` (Label
  `com.nanodictate.agent`) with symlink-resolved binary/log paths and
  bootstraps it via launchctl. In addition, the packages call the same
  registration **once at install**: the Homebrew formula's `post_install`
  (runs as the user) and the MacPorts port's `post-destroot` (runs as root;
  writes into the real user's LaunchAgents via `$SUDO_USER`) write the same
  canonical plist with the same single label and `launchctl bootstrap` it, so
  after a clean install the daemon is registered without a manual first run
  (RunAtLoad starts it at login). No template lookup, no env vars, no
  startupitem/service block and **no second label** anywhere (no
  `homebrew.mxcl.*`) — one daemon regardless of install method or order, the
  second manager takes over. On binary path change (e.g. after an upgrade)
  the CLI prints a TCC re-grant hint.
- **Version flag.** `nanodictate --version` prints `nanodictate 0.1.0` and
  lands together with the 0.1.0 release; the formula `test do` block depends
  on it.

## TODO

- Fill the `maintainers` handle in the generated Portfile (a person's handle
  must not be auto-generated).
- A Homebrew **bottle** (served from Homebrew's CDN) would wrap the same
  release binaries; not needed while the formula downloads them directly from
  GitHub Releases. Developer ID signing remains out of scope for a bottle either
  way.