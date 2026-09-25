# Packaging

Templates and a generator for distributing NanoDictate through Homebrew and
MacPorts — all install **prebuilt binaries** from GitHub Releases, so no
source build happens on the user's machine. The release workflow publishes
four arch-matched assets per version: the two CLI **tarballs**
(`nanodictate-<VERSION>-macos-<arch>.tar.gz` — Homebrew formula + MacPorts
port) and the two app-bundle **zips**
(`nanodictate-<VERSION>-macos-<arch>.zip` — Homebrew cask). Either way there
is **no Developer ID signature and no notarization** — the release binaries
are self-signed with the NanoDictate CI Signing identity.

## Layout

| Path | Purpose |
| --- | --- |
| `packaging/homebrew/nanodictate.rb.tpl` | Homebrew formula template (binary: `__VERSION__`, `__SHA256_ARM64__`, `__SHA256_X86_64__`) |
| `packaging/homebrew/nanodictate.rb` | Generated formula (do not hand-edit) |
| `packaging/homebrew/Casks/nanodictate.rb.tpl` | Homebrew cask template (app bundle: `__VERSION__`, `__ZIP_SHA256_ARM64__`, `__ZIP_SHA256_X86_64__`) |
| `packaging/homebrew/Casks/nanodictate.rb` | Generated cask (do not hand-edit) |
| `packaging/macports/Portfile.tpl` | MacPorts Portfile template (binary: `__VERSION__`, `__SHA256_ARM64__`, `__SHA256_X86_64__`, `__MAINTAINERS__` (env `MAINTAINERS`), `__REVISION__` (env `REVISION`, default `0`)) |
| `packaging/macports/Portfile` | Generated Portfile (do not hand-edit) |
| `packaging/Info.NanoDictateApp.plist` | Info.plist source for `NanoDictate.app` (CFBundleIdentifier `com.nanodictate.agent`, CFBundleExecutable `NanoDictateAgent`, LSUIElement, usage descriptions; version placeholders injected by the workflow before codesign seals the bundle) |
| `scripts/release-prep.rb` | Stdlib-only Ruby generator |

## Usage

Generate the files for a release tag (needs network access to github.com **and**
the published Release — the script downloads the binary tarballs and the
app-bundle zips attached to it, so it can only run after the release workflow
finished):

```sh
MAINTAINERS=@kodmial ruby scripts/release-prep.rb v0.1.0
```

The script downloads the two release binary tarballs
(`.../releases/download/v0.1.0/nanodictate-0.1.0-macos-{arm64,x86_64}.tar.gz`)
and the two app-bundle zips (`...-0.1.0-macos-{arm64,x86_64}.zip`). It
computes `sha256` for each and fills the `__VERSION__`, `__SHA256_ARM64__`,
`__SHA256_X86_64__` placeholders in the formula + Portfile templates, the
`__ZIP_SHA256_ARM64__` / `__ZIP_SHA256_X86_64__` placeholders in the cask
template (distinct tokens on purpose — the formula pins the tarballs, the
cask pins the zips, and the two can never cross-contaminate), plus the
Portfile's `__MAINTAINERS__` (env `MAINTAINERS`) and `__REVISION__` (env
`REVISION`, default `0`). Keep the `.tpl` placeholders in the repo — only the
generated files get concrete values.

## Releasing a new version

1. Tag and push: `git tag v0.1.0 && git push origin v0.1.0`
2. Generate: `MAINTAINERS=@kodmial ruby scripts/release-prep.rb v0.1.0`
3. Publish:
   - **Homebrew**: the release workflow's `manifests` job copies
     `packaging/homebrew/nanodictate.rb` into the `kodmial/homebrew-nanodictate`
     tap as `nanodictate.rb` (repo root) and
     `packaging/homebrew/Casks/nanodictate.rb` as `Casks/nanodictate.rb` when
     `TAP_PAT` is set; manually, the same copies + push.
   - **MacPorts**: the release workflow's `manifests` job syncs
     `packaging/macports/Portfile` into the `kodmial/macports-nanodictate`
     repo — the git port source users clone — when `TAP_PAT` is set;
     manually, the same commit + push.
4. Verify before release: `brew audit --strict --new nanodictate`,
   `brew audit --cask --strict nanodictate`, `port lint`, and a clean
   `brew install nanodictate` / `brew install --cask nanodictate` /
   `port install` (all binary — no build) on a fresh machine.

## Maintainer notes

- **Both Homebrew and MacPorts are binary.** The Homebrew formula and the
  MacPorts port download the same arch-matched tarball (self-signed) published
  by the release workflow (`nanodictate-<VERSION>-macos-<arch>.tar.gz`) — no
  compiler on the user's machine. The Portfile sets `use_configure no` and just
  unpacks the binaries into `${prefix}/bin` and ships `config.example.toml`
  into `${prefix}/share/nanodictate/`.
- **Config.** The CLI reads only `~/.config/nanodictate/config.toml`
  (`AppConfig.defaultPath()`), never a file under `etc/`. `config.example.toml`
  therefore ships as a copy source in `share/nanodictate/`.
- **Resources.** Entitlements (`com.nanodictate.agent.entitlements`,
  `com.nanodictate.ctl.entitlements`) are applied at CI codesign (code signing
  in `.github/workflows/release.yml`). The CLI tarballs and the port ship
  binaries + config only; the app bundle carries `Contents/Resources/` copies
  for reference.
- **The cask ships the app bundle.** `brew install --cask nanodictate`
  installs `NanoDictate.app` (assembled and signed in the release workflow's
  code-sign step: the same CI identity, identifier `com.nanodictate.agent`,
  entitlements from `Resources/com.nanodictate.agent.entitlements`, release
  version injected into `Contents/Info.plist` before the signature seals the
  bundle). `Contents/MacOS/` holds the SAME two binaries as the tarball — one
  daemon, one canonical `com.nanodictate.agent` label whether the user
  installed the formula, the cask or the port. The cask has NO postflight
  step that would clear the bundle's quarantine attribute: Homebrew Cask
  keeps the `com.apple.quarantine` attribute on the downloaded container
  (Cask::Installer → Quarantine.propagate copies it from the downloaded zip
  into the staged path), so a plain `brew install --cask` puts the bundle on
  disk with the attribute — and Gatekeeper prompts on first launch of this
  self-signed, non-notarized bundle. On macOS 15 and later, launch it once
  (it is refused), then approve it in System Settings → Privacy & Security →
  "Open Anyway"; on macOS 14 and older, Right-click → Open still works. You
  can also clear the attribute by hand with
  `xattr -dr com.apple.quarantine /Applications/NanoDictate.app`.
- **TCC grants.** Microphone + Accessibility are granted manually per binary
  in System Settings (prompted on first use). Both paths install the same
  release binaries — no rebuild per install — so grants only need re-applying
  when a newer release replaces the binary.
- **LaunchAgent — гибрид A+B.** The running binary registers the service
  itself: `nanodictate start` writes the canonical
  `~/Library/LaunchAgents/com.nanodictate.agent.plist` (Label
  `com.nanodictate.agent`) with symlink-resolved binary/log paths and
  bootstraps it via launchctl. On Homebrew the formula ships a `service do`
  block (canonical label `com.nanodictate.agent`) and the user activates the
  service explicitly once after install with `brew services start
  nanodictate` — it writes the same canonical plist and bootstraps gui/<uid>;
  `brew install` itself does not register the LaunchAgent. The MacPorts port
  still auto-registers at install (`post-activate` runs as root; writes the
  global `/Library/LaunchAgents/com.nanodictate.agent.plist` and bootstraps
  the console user). No template lookup, no env vars, no
  startupitem block and **no second label** anywhere (no
  `homebrew.mxcl.*`) — one daemon regardless of install method or order, the
  second manager takes over. On binary path change (e.g. after an upgrade)
  the CLI prints a TCC re-grant hint.
- **Version flag.** `nanodictate --version` prints `nanodictate <VERSION>`;
  the formula `test do` block depends on it.

## TODO

- A Homebrew **bottle** (served from Homebrew's CDN) would wrap the same
  release binaries; not needed while the formula downloads them directly from
  GitHub Releases. Developer ID signing remains out of scope for a bottle either
  way.