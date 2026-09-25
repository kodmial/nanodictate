# Homebrew packaging

The NanoDictate Homebrew formula is a **binary formula**: `brew` downloads the
prebuilt tarball attached to the GitHub Release and installs the binaries
as-is. Nothing is compiled on the user's machine — **no Xcode and no Swift
toolchain are required**. The tarballs are built self-signed by
`.github/workflows/release.yml` (NanoDictate CI Signing identity) on every
`v*` tag. This page is the
user-facing install guide plus the maintainer release drill. For the template
layout, the generator and cross-package notes see
[packaging/README.md](../../packaging/README.md).

## For the user

### Requirements

- macOS 12+ (Monterey) — the released binaries target macOS 12+; the formula
  declares `depends_on :macos => :monterey`.
- Homebrew itself.
- **No Xcode, no Command Line Tools** — the formula selects the right tarball
  (`arm64` or `x86_64`) from `Hardware::CPU.arm?` and installs it directly.

### Quick start

```sh
brew tap kodmial/homebrew-nanodictate
brew trust --formula kodmial/nanodictate/nanodictate
brew install nanodictate
brew services start nanodictate
```

> **`brew trust`:** requires **Homebrew 6.0.0+** (macOS) and marks just the
> `kodmial/nanodictate/nanodictate` formula as trusted — not the whole tap —
> so the install below needs no extra confirmation. On an older Homebrew
> without `brew trust`, skip that line and install by the fully qualified
> name instead: `brew install kodmial/nanodictate/nanodictate` taps the
> repository automatically; brew may ask you to confirm the new tap once.

Installs the prebuilt binary; the final command activates the background agent:
`brew services start nanodictate` uses the formula's `service do` block to
write the canonical `~/Library/LaunchAgents/com.nanodictate.agent.plist` and
bootstrap it into launchd. `brew install` itself does not register the
LaunchAgent — `nanodictate start` is the equivalent, idempotent alternative
(see [After install](#after-install)).

Prefer a proper app bundle? `brew install --cask kodmial/nanodictate/nanodictate` installs
**NanoDictate.app** — the same two release binaries inside a `.app` bundle,
the same `com.nanodictate.agent` service (one daemon either way), and the
quarantine attribute is kept until you approve the app (see
[Install the app bundle via cask](#install-the-app-bundle-via-cask)).

### Install via the tap

```sh
brew install kodmial/nanodictate/nanodictate
```

> **Tap repo naming:** Homebrew auto-taps `owner/repo` only when the GitHub
> repository is literally named `homebrew-<repo>` — the mandatory prefix, not a
> convention. The tap repository is `kodmial/homebrew-nanodictate` (with the
> formula `nanodictate.rb` at the repo root). The `brew install
> kodmial/nanodictate/nanodictate` command above maps to that repo: owner
> `kodmial`, tap repo `homebrew-nanodictate`, formula `nanodictate`.

The `owner/repo/formula` form fetches the formula from the
`kodmial/homebrew-nanodictate` tap repository without a separate `brew tap`
step. The install is a download of a few megabytes, not a build — no wait for
SwiftPM to compile anything.

### Install from a local formula file

Alternatively, generate the formula for a tag and point `brew` directly at the
file (the same file the tap serves, after `scripts/release-prep.rb`
fills it in):

```sh
MAINTAINERS=@kodmial ruby scripts/release-prep.rb v0.1.0     # fills checksums into the template
HOMEBREW_DEVELOPER=1 brew install /path/to/nanodictate/packaging/homebrew/nanodictate.rb
```

`HOMEBREW_DEVELOPER=1` is scoped to this call so Homebrew accepts a formula
installed from a local file path rather than a tap or the formula API. This
is still a **binary** install — the formula downloads the release tarball
for the machine's architecture, it does not build from source.

Use the **generated** `packaging/homebrew/nanodictate.rb`, never the
`.tpl` template — its `__VERSION__` / `__SHA256_ARM64__` / `__SHA256_X86_64__`
placeholders are unfilled and the formula will fail.

### Install the app bundle via cask

```sh
brew install --cask kodmial/nanodictate/nanodictate
```

Builds nothing: the cask downloads the **app-bundle zip**
(`nanodictate-<VER>-macos-<arch>.zip` — a second, distinct release asset; the
formula pins the tarball sha256s, the cask pins the zip sha256s) and moves
**NanoDictate.app** into `/Applications`. `Contents/MacOS/` holds only the
same `NanoDictateAgent` and `nanodictate` binaries; `Contents/Resources/`
ships `config.example.toml` and the entitlements for reference. `LSUIElement` is
set, so the app runs as a background agent — no Dock icon, no menu bar.

Same canonical service, never a second daemon: the app registers the same
`~/Library/LaunchAgents/com.nanodictate.agent.plist` via `nanodictate start`
(label `com.nanodictate.agent`). Install **either** the formula **or** the
cask — **not both**: both link the `nanodictate` binary into
`$(brew --prefix)/bin`, so the second install fails on the conflicting file.
Uninstall one before installing the other.

**Quarantine stays until you approve the app.** Nothing in this guide clears
the `com.apple.quarantine` attribute for you, and the self-signed bundle is
not notarized — so Gatekeeper may refuse it on first launch until you approve
it deliberately (Right-click → Open, or System Settings → Privacy & Security).
To run it unattended, clear the attribute by hand — a Gatekeeper workaround:
`xattr -dr com.apple.quarantine /Applications/NanoDictate.app`.

**Uninstall:** `brew uninstall --cask nanodictate` removes the app only — not
the LaunchAgent, not your config. Stop the service first:

```sh
nanodictate stop
brew uninstall --cask nanodictate
```

If it was not stopped, unload the agent and remove the plist by hand
(`launchctl bootout gui/$(id -u)/com.nanodictate.agent` + `rm
~/Library/LaunchAgents/com.nanodictate.agent.plist`); config is never
touched.

### Verifying the download

The GitHub Release also carries a `SHA256SUMS.txt` covering both tarballs. You
can verify the asset the formula downloads (or a manual `curl` download) with:

```sh
curl -L -O https://github.com/kodmial/nanodictate/releases/download/v0.1.0/SHA256SUMS.txt
# run in the directory with the tarball; SHA256SUMS.txt lists both arch
# tarballs, so check only the entry for the one you downloaded
grep "nanodictate-0.1.0-macos-$(uname -m)\.tar\.gz$" SHA256SUMS.txt | shasum -a 256 -c -
```

Homebrew performs its own sha256 check against the formula's
`__SHA256_ARM64__` / `__SHA256_X86_64__` values — a corrupted/mismatched
download fails the install.

### After install

The formula installs `nanodictate` and `NanoDictateAgent` into
`$(brew --prefix)/bin` and ships `config.example.toml` into
`$(brew --prefix)/share/nanodictate/`. The launch service lives in the
canonical `~/Library/LaunchAgents/com.nanodictate.agent.plist` (label
`com.nanodictate.agent`, ProgramArguments = the brew binary path, RunAtLoad +
KeepAlive) and is bootstrapped into launchd — the same single label and file
used by every registration path, never a second daemon (no `homebrew.mxcl.*`).
Registration is explicit: `brew install` does not write the LaunchAgent;
activate the service once with `brew services start nanodictate` — it runs as
the user, writes the same canonical plist and loads gui/<uid> (`nanodictate
start` is the equivalent, idempotent alternative). If the activation runs
without a GUI session (e.g. over SSH) and the SSH user does not own
/dev/console, Homebrew selects the user/<uid> launchd domain instead of
gui/<uid> — the service is still bootstrapped, but into the wrong domain.
Activate the agent from your GUI session (re-run `brew services start
nanodictate` or `nanodictate start` there) so the service loads into
gui/<uid> as expected.

1. **TCC grants (required, manual).** In **System Settings → Privacy &
   Security** add the `NanoDictateAgent` binary to **Microphone** (recording)
   and **Accessibility** (text insertion); add it to **Input Monitoring**
   too if the hotkey does not fire. Grants are per-binary — after a
   `brew upgrade` that replaces the binary you may need to re-grant.

2. **Configure.** Create `~/.config/nanodictate/config.toml` (from
   `config.example.toml` under `$(brew --prefix)/share/nanodictate/`, or
   via `nanodictate config init`) and set STT providers / API keys:

   ```sh
   nanodictate config init                # writes default config.toml
   nanodictate config set-key <provider>  # API key interactively
   nanodictate provider list
   ```

3. **Start the service.** `brew install` does not register the LaunchAgent —
   start the service once with `brew services start nanodictate`: it uses the
   formula's `service do` block, writes the same canonical
   `~/Library/LaunchAgents/com.nanodictate.agent.plist` (label
   `com.nanodictate.agent`) and bootstraps it into launchd — `nanodictate
   start` is the equivalent, idempotent alternative. Running one after the
   other just re-registers with the symlink-resolved real path; a binary path
   change prints a note that macOS may ask again for Microphone/Accessibility:

   ```sh
   nanodictate status   # or: launchctl print gui/$(id -u)/com.nanodictate.agent
   nanodictate stop
   nanodictate logs     # last 50 lines; ~/Library/Logs/NanoDictate/agent.log
   ```

### Signing and quarantine

All packaged paths serve the **same self-signed release binaries** — there is
no Developer ID signature and no notarization. Whether macOS complains at
first launch depends on how the binaries arrived:

| Install path | Quarantine attribute | Gatekeeper |
| --- | --- | --- |
| Homebrew formula (downloads the release tarball) | none — Homebrew's curl does not set it | no prompt, runs as-is |
| Homebrew cask (downloads the app-bundle zip) | kept until you approve the app (approve via Right-click → Open, or clear it manually — a Gatekeeper workaround) | prompts on first launch; approve once |
| `curl` download from GitHub Releases | none | no prompt, runs as-is |
| Browser download from GitHub Releases | `com.apple.quarantine` set | **blocked** — "developer cannot be verified" |

If you downloaded the release binaries with a browser, clear the quarantine
attribute once (or Right-click → Open):

```sh
xattr -dr com.apple.quarantine /path/to/NanoDictateAgent /path/to/nanodictate
```

## For the maintainer

Release drill for a new version (details in
[packaging/README.md](../../packaging/README.md)):

1. **Tag and push** — the GitHub Release workflow (`v*`) builds both tarballs
   and attaches them to the Release automatically:

   ```sh
   git tag v0.1.0 && git push origin v0.1.0
   ```

2. **Generate the manifests** (needs network access to github.com **and** the
   published Release — the script downloads the two binary tarballs and the
   two app-bundle zips):

   ```sh
   MAINTAINERS=@kodmial ruby scripts/release-prep.rb v0.1.0
   ```

   This writes `packaging/homebrew/nanodictate.rb` (version + tarball
   sha256s), `packaging/homebrew/Casks/nanodictate.rb` (version + zip sha256s
   — distinct `__ZIP_SHA256_ARM64__` / `__ZIP_SHA256_X86_64__` placeholders,
   so the tarball hashes can never come to pin the zips) and
   `packaging/macports/Portfile`. Keep the `.tpl` files in the repo unfilled —
   only the generated files get concrete values.

3. **Publish to the tap** (`kodmial/homebrew-nanodictate`). The release
   workflow's `manifests` job does this automatically — it regenerates
   `packaging/homebrew/nanodictate.rb` and the cask
   `packaging/homebrew/Casks/nanodictate.rb`, commits them to main and copies
   them into the tap repo as `nanodictate.rb` (repo root, not `Formula/`) and
   `Casks/nanodictate.rb` when the `TAP_PAT` secret is configured. Manually,
   copy the generated files over `<tap>/nanodictate.rb` and
   `<tap>/Casks/nanodictate.rb` and push.

4. **Verify before/after publishing:**

   ```sh
   brew audit --strict --new nanodictate    # in the tap repo (formula)
   brew audit --cask --strict nanodictate   # in the tap repo (cask)
   brew style nanodictate                   # in the tap repo
   brew install kodmial/nanodictate/nanodictate # binary download, no build
   brew uninstall nanodictate # release the formula link so the cask can link
   brew install --cask kodmial/nanodictate/nanodictate # app bundle, no build
   nanodictate --version                    # must print "nanodictate 0.1.0"
   ```

The formula `test do` block asserts `nanodictate --version` matches the
released version.

## TODO

- A Homebrew **bottle** (served from Homebrew's own CDN) would wrap these same
  binaries; it is not needed while the formula downloads them straight from
  GitHub Releases — see the note in [packaging/README.md](../../packaging/README.md).