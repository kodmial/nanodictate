# Homebrew packaging

The NanoDictate Homebrew formula is a **binary formula**: `brew` downloads the
prebuilt tarball attached to the GitHub Release and installs the binaries
as-is. Nothing is compiled on the user's machine — **no Xcode and no Swift
toolchain are required**. The tarballs are built ad-hoc signed by
`.github/workflows/release.yml` on every `v*` tag. This page is the
user-facing install guide plus the maintainer release drill. For the template
layout, the generator and cross-package notes see
[packaging/README.md](../../packaging/README.md).

> **Status (TODO):** the tap repository `nanodictate-homebrew` is **not
> created yet**. Until it is published, install from a local formula file —
> see [Install from a local file](#install-from-a-local-file).

## For the user

### Requirements

- macOS 12+ (Monterey) — the released binaries target macOS 12+; the formula
  declares `depends_on :macos => :monterey`.
- Homebrew itself.
- **No Xcode, no Command Line Tools** — the formula selects the right tarball
  (`arm64` or `x86_64`) from `Hardware::CPU.arm?` and installs it directly.

### Install via the tap (when the tap exists)

```sh
brew install kodmial/nanodictate-homebrew/nanodictate
```

> **Tap repo naming:** Homebrew auto-taps `owner/repo` only when the GitHub
> repository is literally named `homebrew-<repo>` — the mandatory prefix, not a
> convention. So the tap repository must be `kodmial/homebrew-nanodictate-homebrew`
> (with the formula at `Formula/nanodictate.rb`). Any other repo name makes the
> `brew install kodmial/nanodictate-homebrew/nanodictate` command above fail —
> Homebrew cannot find the tap.

The `owner/repo/formula` form fetches the formula from the
`kodmial/nanodictate-homebrew` tap repository without a separate `brew tap`
step. The install is a download of a few megabytes, not a build — no wait for
SwiftPM to compile anything.

### Install from a local formula file (current path)

Until the tap exists, generate the formula for a tag and point `brew`
directly at the file:

```sh
ruby scripts/release-prep.rb v0.1.0     # fills checksums into the template
brew install /path/to/nanodictate/packaging/homebrew/nanodictate.rb
```

This is still a **binary** install — the formula downloads the release tarball
for the machine's architecture, it does not build from source.

Use the **generated** `packaging/homebrew/nanodictate.rb`, never the
`.tpl` template — its `__VERSION__` / `__SHA256_ARM64__` / `__SHA256_X86_64__`
placeholders are unfilled and the formula will fail.

### Verifying the download

The GitHub Release also carries a `SHA256SUMS.txt` covering both tarballs. You
can verify the asset the formula downloads (or a manual `curl` download) with:

```sh
curl -L -O https://github.com/kodmial/nanodictate/releases/download/v0.1.0/SHA256SUMS.txt
shasum -a 256 -c SHA256SUMS.txt   # run in the directory with the tarball
```

Homebrew performs its own sha256 check against the formula's
`__SHA256_ARM64__` / `__SHA256_X86_64__` values — a corrupted/mismatched
download fails the install.

### After install

The formula installs `nanodictate` and `NanoDictateAgent` into
`$(brew --prefix)/bin` and ships `config.example.toml`, the two entitlements
and the LaunchAgent plist template into `$(brew --prefix)/share/nanodictate/`.

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

3. **Start the agent.** The plist template does **not** sit next to the
   binary in a Homebrew install, so point the CLI at it first (the formula
   caveats document this):

   ```sh
   export NANODICTATE_PLIST_TEMPLATE="$(brew --prefix)/share/nanodictate/nanodictate-agent.plist.template"
   nanodictate start
   ```

   This renders `~/Library/LaunchAgents/com.nanodictate.agent.plist` and
   bootstraps the LaunchAgent (auto-restarts at login). Manage it with:

   ```sh
   nanodictate status   # or: launchctl print gui/$(id -u)/com.nanodictate.agent
   nanodictate stop
   nanodictate logs     # last 50 lines; ~/Library/Logs/NanoDictate/agent.log
   ```

### Signing and quarantine

All packaged paths serve the **same ad-hoc signed release binaries** — there
is no Developer ID signature and no notarization. Whether macOS complains at
first launch depends on how the binaries arrived:

| Install path | Quarantine attribute | Gatekeeper |
| --- | --- | --- |
| Homebrew formula (downloads the release tarball) | none — Homebrew's curl does not set it | no prompt, runs as-is |
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

2. **Generate the formula** (needs network access to github.com **and** the
   published Release — the script downloads the binary tarballs):

   ```sh
   ruby scripts/release-prep.rb v0.1.0
   ```

   This writes `packaging/homebrew/nanodictate.rb` with the real version and
   the per-architecture sha256s (`__SHA256_ARM64__`, `__SHA256_X86_64__`),
   and `packaging/macports/Portfile` with the source-tarball checksums. Keep
   the `.tpl` in the repo unfilled — only the generated files get concrete
   values.

3. **Publish to the tap.** Copy the generated formula into the
   `nanodictate-homebrew` tap repo (TODO: create the tap repo) as
   `Formula/nanodictate.rb` and push it. Also copy
   `packaging/homebrew/nanodictate.rb` over `<tap>/Formula/nanodictate.rb`
   on every future release.

4. **Verify before/after publishing:**

   ```sh
   brew audit --strict --new nanodictate   # in the tap repo
   brew style nanodictate                  # in the tap repo
   brew install nanodictate                # binary download, no build
   nanodictate --version                   # must print "nanodictate 0.1.0"
   ```

The formula `test do` block asserts `nanodictate --version` matches the
released version.

## TODO

- Create the `nanodictate-homebrew` tap repository (the
  `brew install kodmial/nanodictate-homebrew/nanodictate` command above).
- A Homebrew **bottle** (served from Homebrew's own CDN) would wrap these same
  binaries; it is not needed while the formula downloads them straight from
  GitHub Releases — see the note in [packaging/README.md](../../packaging/README.md).