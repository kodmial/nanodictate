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

1. Merge the feature PRs normally — never bump the version in them. The
   Release PR workflow proposes the next version on
   `release-please--branches--main` (see `CONTRIBUTING.md` → Releases).
2. Merge the Release PR: the release workflow builds both tarballs and both
   app-bundle zips and attaches them to the GitHub Release automatically.
   (Manual equivalent: `git tag v0.1.0 && git push origin v0.1.0`.)
3. Generate (manual equivalent only — the workflow does this itself):
   `MAINTAINERS=@kodmial ruby scripts/release-prep.rb v0.1.0`
4. Publish:
   - **Homebrew**: the release workflow's `manifests` job opens a
     `chore/release-manifests-v<version>` PR with
     `packaging/homebrew/nanodictate.rb` and
     `packaging/homebrew/Casks/nanodictate.rb` and, in the same job, pushes them into
     the `kodmial/homebrew-nanodictate` tap as `nanodictate.rb` (repo root) and
     `Casks/nanodictate.rb` when `TAP_PAT` is set; manually, the same copies +
     push.
   - **MacPorts**: the release workflow's `manifests` job syncs
     `packaging/macports/Portfile` into the `kodmial/macports-nanodictate`
     repo — the git port source users clone — when `TAP_PAT` is set;
     manually, the same commit + push. The installer pin (`PIN_REV` in
     `scripts/install-macports.sh`) rides along in the same manifests PR.
5. Verify before release: `brew audit --strict --new nanodictate`,
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
  in `.github/workflows/continuum-release.yml`). The CLI tarballs and the port ship
  binaries + config only; the app bundle carries `Contents/Resources/` copies
  for reference.
- **The cask ships the app bundle.** `brew install --cask nanodictate`
  installs `NanoDictate.app` (assembled and signed in the release workflow's
  code-sign step: the same CI identity, identifier `com.nanodictate.agent`,
  entitlements from `Resources/com.nanodictate.agent.entitlements`, release
  version injected into `Contents/Info.plist` before the signature seals the
  bundle). `Contents/MacOS/` holds the SAME two binaries as the tarball — one
  daemon, one canonical `com.nanodictate.agent` label whether the user
  installed the formula, the cask or the port. The cask declares
  `depends_on macos: :monterey` — the same floor as the formula, so the two
  packages never disagree about supported machines — and its
  `postflight_steps` block removes `com.apple.quarantine` from
  `/Applications/NanoDictate.app` after the install, so a plain
  `brew install --cask` leaves no quarantine prompt and the user never needs
  "Open Anyway" or a manual `xattr` (a first-launch signing warning is still
  possible — the bundle is self-signed and not notarized, so clearing the
  attribute will not silence it). The removal is deliberately narrow: it
  strips that ONE attribute, not the whole extended-attribute set (no
  `xattr -cr`), it never touches other xattr keys, it never runs
  `spctl --master-disable`, and Gatekeeper stays globally enabled. The code
  signature is unaffected — quarantine is a download-provenance tag, not a
  signature — so the bundle keeps its self-signed identity and the TCC grants
  it has already earned. Privacy grants (Microphone, Accessibility) are a
  separate mechanism and are untouched by the postflight: macOS asks for them
  on the agent's first run.
- **TCC grants.** Microphone + Accessibility are granted manually per binary
  in System Settings (prompted on first use). Both paths install the same
  release binaries — no rebuild per install — so grants only need re-applying
  when a newer release replaces the binary.
- **LaunchAgent — hybrid A+B.** The running binary registers the service
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
  both packages declare a test that asserts the version. The formula's
  `test do` block compares the output against `version.to_s`, and it runs
  only on an explicit `brew test nanodictate`. The Portfile runs it as a
  real `test` phase against the staged destroot binary, with an empty
  `test.target` and a self-contained `test.cmd` shell pipeline that
  asserts two things: the command exits 0, and the port version occurs
  in the output as a whole token (`grep -Fx` over `tr -c "0-9." "\n"`,
  so a longer number that merely contains it, like `0.1.01` or `10.1.0`,
  does not match). The rest of the output line is not checked, and
  nothing outside `--version` is exercised. It runs only on an explicit
  `sudo port test nanodictate`. Neither test phase runs as part of the
  install, and a failure in either is reported without blocking the install.

## Packaging lifecycle smoke

`.github/workflows/continuum-packaging-smoke.yml` runs one reusable black-box macOS
lifecycle smoke (`scripts/packaging-smoke/*-lifecycle.sh`) in three modes
sharing the same assertions:

1. **Candidate gate (blocking):** the workflow builds/signs the final
   artifacts once per architecture, derives a temporary Cask and a temporary
   local ports tree from the production templates (only version/source/SHA
   adapted to those exact bytes) and runs the full
   install → verify → start/post-activate → live launchd job → stop →
   uninstall → cleanup lifecycle on fresh VMs (`macos-15`, `macos-15-intel`).
   A red gate must block publication of those bytes.
2. **Post-publish verification:** after the Release workflow completes, the
   same lifecycle runs against the real public paths only —
   `brew install --cask kodmial/nanodictate/nanodictate` and the documented
   `curl .../scripts/install-macports.sh` installer covering the real
   `kodmial/macports-nanodictate` tree. A failure opens or updates one
   `priority:p0` `Production packaging smoke failure` incident issue
   (marker `<!-- nanodictate-production-packaging-smoke-incident -->`)
   and never mutates the published release.
3. **Daily canary (03:17 UTC) + `workflow_dispatch`:** the latest stable
   release through the same real channels, additionally exercising
   `macos-latest` so runner-image drift is caught early. Recovery to full
   green closes the incident issue with a recovery comment.

Homebrew asserts the explicit `nanodictate start` path; MacPorts asserts the
`post-activate` auto-start with no prior manual start. Liveness is proven via
`launchctl print gui/$UID/com.nanodictate.agent` plus a real
`NanoDictateAgent` PID, never by plist existence alone. User config/logs are
preserved, never deleted. See the workflow header for the full contract.

## TODO

- A Homebrew **bottle** (served from Homebrew's CDN) would wrap the same
  release binaries; not needed while the formula downloads them directly from
  GitHub Releases. Developer ID signing remains out of scope for a bottle either
  way.