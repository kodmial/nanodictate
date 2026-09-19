# Packaging

Templates and a generator for distributing NanoDictate through Homebrew
(binary install from GitHub Releases) and MacPorts (build from source). The
Homebrew path ships prebuilt ad-hoc signed binaries as-is; MacPorts compiles
the SwiftPM package on the user's machine. Either way there is **no Developer
ID signature and no notarization** — installs are unsigned/ad-hoc.

## Layout

| Path | Purpose |
| --- | --- |
| `packaging/homebrew/nanodictate.rb.tpl` | Homebrew formula template (binary: `__VERSION__`, `__SHA256_ARM64__`, `__SHA256_X86_64__`) |
| `packaging/homebrew/nanodictate.rb` | Generated formula (do not hand-edit) |
| `packaging/macports/Portfile.tpl` | MacPorts Portfile template |
| `packaging/macports/Portfile` | Generated Portfile (do not hand-edit) |
| `scripts/release-prep.rb` | Stdlib-only Ruby generator |

## Usage

Generate the files for a release tag (needs network access to github.com **and**
the published Release — the script downloads the binary tarballs attached to
it, so it can only run after the release workflow finished):

```sh
ruby scripts/release-prep.rb v0.1.0
```

The script downloads the GitHub source tarball
(`.../archive/refs/tags/v0.1.0.tar.gz`) and the two release binary tarballs
(`.../releases/download/v0.1.0/nanodictate-0.1.0-macos-{arm64,x86_64}.tar.gz`).
It computes `sha256` for each binary tarball (plus `sha256`/`rmd160`/`size` for
the source tarball when the local OpenSSL provides them) and fills the
`__VERSION__`, `__SHA256_ARM64__`, `__SHA256_X86_64__`, `__SOURCE_SHA256__`,
`__RMD160__`, `__SOURCE_SIZE__` placeholders in both templates. Keep the
`.tpl` placeholders in the repo — only the generated files get concrete values.

## Releasing a new version

1. Tag and push: `git tag v0.1.0 && git push origin v0.1.0`
2. Generate: `ruby scripts/release-prep.rb v0.1.0`
3. Publish:
   - **Homebrew**: copy `packaging/homebrew/nanodictate.rb` into the
     `nanodictate-homebrew` tap as `Formula/nanodictate.rb`.
   - **MacPorts**: copy `packaging/macports/Portfile` into a `macports-ports`
     checkout as `audio/nanodictate/Portfile` and open a PR.
4. Verify before release: `brew audit --strict --new nanodictate`, `port lint`,
   and a clean `brew install nanodictate` (binary — no build) / `port install`
   on a fresh machine.

## Maintainer notes

- **Homebrew is binary, MacPorts builds from source.** The Homebrew formula
  downloads the ad-hoc signed tarball published by the release workflow — no
  compiler on the user's machine. MacPorts runs `swift build --configuration
  release` via `use_xcode yes` because there is **no `swift` or `swift-lang`
  MacPorts port** (verified against ports.macports.org, 2026-09) — existing
  SwiftPM ports such as `swiftlint` build against Apple's toolchain the same
  way.
- **Sandbox.** The MacPorts build passes `--disable-sandbox` to `swift build`:
  SwiftPM cannot install its own syscall sandbox inside the package manager's
  build sandbox. Note that the build fetches the SwiftLint/SwiftFormat plugin
  packages over the network; the plugins themselves run only when invoked
  explicitly, not during `swift build`.
- **Config.** The CLI reads only `~/.config/nanodictate/config.toml`
  (`AppConfig.defaultPath()`), never a file under `etc/`. `config.example.toml`
  therefore ships as a copy source in `share/nanodictate/`.
- **Resources.** Entitlements (`com.nanodictate.agent.entitlements`,
  `com.nanodictate.ctl.entitlements`) are build-time only (code signing in
  `.github/workflows/release.yml`) and no longer ship in the packages: one
  daemon at any install method means the package installs binaries + config
  only.
- **TCC grants.** Microphone + Accessibility are granted manually per binary
  in System Settings (prompted on first use). Because MacPorts source builds
  produce a new binary on every install/upgrade, grants may need to be
  re-applied after updates (the Homebrew binaries only change on a newer
  release).
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
- `rmd160` may stay a placeholder if the local Ruby cannot compute it
  (`port checksum` can fill it).
- A Homebrew **bottle** (served from Homebrew's CDN) would wrap the same
  release binaries; not needed while the formula downloads them directly from
  GitHub Releases. Developer ID signing remains out of scope for a bottle either
  way.