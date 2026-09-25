# Homebrew cask template for the NanoDictate .app bundle (binary install from
# GitHub Releases). Placeholders 0.0.16, efb9b4846cf1c93593b999d60f207be0fd70068fd057aa9d767f54b9979a5dbf,
# b29e0536b9d24c10d4162646810cfb2cea86c526d1a7cef98e6531a20e32b503 are filled by scripts/release-prep.rb — do not hand-edit
# the generated Casks/nanodictate.rb.
#
# ZIP placeholders are distinct from the formula's __SHA256_*__ on purpose:
# the formula pins the TARBALL hashes, the cask pins the APP-BUNDLE ZIP hashes
# — a shared token would silently bake the wrong checksum into one of them.
#
# Relationship to the formula (packaging/homebrew/nanodictate.rb.tpl): both
# serve the SAME release binaries. The formula installs the bare nanodictate
# CLI + NanoDictateAgent from the .tar.gz; this cask installs the
# NanoDictate.app bundle from the .zip (Contents/MacOS/ holds the same two
# binaries plus config.example.toml, the bundled config source). Either way
# there is exactly ONE daemon behind one canonical LaunchAgent plist with the
# single label com.nanodictate.agent — the same ~/Library/LaunchAgents/
# com.nanodictate.agent.plist that `nanodictate start`, `brew services start`
# and the MacPorts port's post-activate write. Install either the formula or
# the cask, not both — each links `nanodictate` into $(brew --prefix)/bin, and
# the second installer fails on the existing symlink. Uninstall one before
# installing the other.
#
# quarantine: the release binaries are self-signed with the NanoDictate CI
# Signing identity — no Developer ID, no notarization. A .app carrying the
# com.apple.quarantine attribute is refused by Gatekeeper on first launch
# ("damaged"/"unidentified developer"). Homebrew Cask stamps the quarantine
# attribute on the downloaded container by default (Cask::Installer →
# Quarantine.propagate copies it from the downloaded zip into the staged
# path), so a plain `brew install --cask` puts the bundle on disk WITH the
# attribute — and this cask has NO postflight step that would clear it.
# Gatekeeper may therefore refuse the first launch of the self-signed,
# non-notarized bundle. On macOS 15 (Sequoia) and later, launch the app once
# (it is refused), then approve it in System Settings → Privacy & Security →
# "Open Anyway"; on macOS 14 and older, Right-click → Open still works. As an
# alternative, clear the attribute by hand with `xattr -dr
# com.apple.quarantine /Applications/NanoDictate.app` (see the "Signing and
# quarantine" section in docs/packaging/homebrew.md for the rationale).

cask "nanodictate" do
  version "0.0.16"
  sha256 arm:   "efb9b4846cf1c93593b999d60f207be0fd70068fd057aa9d767f54b9979a5dbf",
         intel: "b29e0536b9d24c10d4162646810cfb2cea86c526d1a7cef98e6531a20e32b503"

  # arch must be declared as a DSL stanza BEFORE it is referenced: without a
  # preceding `arch` stanza, the DSL's `arch(arm:intel:)` method returns nil in
  # interpolation and the URL would back the empty suffix
  # (nanodictate-<v>-macos-.zip) → curl 404 on `brew install --cask`.
  arch arm: "arm64", intel: "x86_64"

  # The cask asset is the app-bundle zip; a single URL with the arch
  # interpolated from the DSL's `arch` method (arm64 / x86_64) selects the
  # right asset per machine.
  url "https://github.com/kodmial/nanodictate/releases/download/v0.0.16/nanodictate-0.0.16-macos-#{arch}.zip"
  name "NanoDictate"
  desc "macOS dictation via double-Alt: bilingual EN/RU, 4 STT providers"
  homepage "https://github.com/kodmial/nanodictate"

  # macOS-only cask (darwin .app bundles, no Linux build). `depends_on :macos`
  # makes brew skip the Linux stanza validation that otherwise rejects the
  # cask at tap time ("Missing Linux stanzas ... Add `depends_on :macos` ...").
  depends_on :macos

  app "NanoDictate.app"
  # `app` MOVES the bundle to appdir BEFORE the binary link phase (artifact
  # install order: the App group precedes the Binary group), so the executable
  # source must resolve to the installed location — a staged-relative path
  # would no longer exist when the binary's symlink is created.
  binary "#{appdir}/NanoDictate.app/Contents/MacOS/nanodictate"

  caveats <<~EOS
    NanoDictate needs manual macOS privacy grants (System Settings → Privacy & Security):
      - Microphone:     enable NanoDictateAgent (recording)
      - Accessibility:  enable NanoDictateAgent (the agent inserts recognized text)
    macOS prompts on first use; grants are per-binary, so an upgrade that
    replaces the app may require re-granting.

    Gatekeeper approval: Homebrew Cask keeps the com.apple.quarantine
    attribute on the downloaded bundle, and the app is self-signed and not
    notarized — so macOS may refuse the first launch. On macOS 15 (Sequoia)
    and later, Control-click/Right-click → Open is no longer available:
    launch the app once (it is refused), then approve it in System Settings
    → Privacy & Security → "Open Anyway". On macOS 14 and older,
    Right-click → Open still works. Either way you can clear the attribute
    by hand with `xattr -dr com.apple.quarantine
    /Applications/NanoDictate.app`.

    The running binary registers the background agent itself — `nanodictate start`
    writes the canonical ~/Library/LaunchAgents/com.nanodictate.agent.plist and
    bootstraps it, the same single label (com.nanodictate.agent) the Homebrew
    formula and the MacPorts port use — never a second daemon:

      nanodictate start | stop | status

    Uninstall: `brew uninstall --cask nanodictate` removes the app only — it
    does not touch the LaunchAgent or your config. Stop the service first:

      nanodictate stop
      brew uninstall --cask nanodictate

    If it was not stopped beforehand, unload the agent and clean up manually:

      launchctl bootout gui/$(id -u)/com.nanodictate.agent
      rm ~/Library/LaunchAgents/com.nanodictate.agent.plist

    Your config (~/.config/nanodictate/config.toml) is never touched by
    install or uninstall.
  EOS
end