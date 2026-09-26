# Homebrew cask template for the NanoDictate .app bundle (binary install from
# GitHub Releases). Placeholders __VERSION__, __ZIP_SHA256_ARM64__,
# __ZIP_SHA256_X86_64__ are filled by scripts/release-prep.rb — do not hand-edit
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
# Signing identity — no Developer ID, no notarization. Homebrew Cask stamps the
# com.apple.quarantine attribute on the downloaded container by default
# (Cask::Installer → Quarantine.propagate copies it from the downloaded zip into
# the staged path), so a plain `brew install --cask` would otherwise put the
# bundle on disk WITH that attribute and Gatekeeper would refuse the first
# launch ("damaged"/"unidentified developer").
#
# The postflight_steps stanza below therefore strips exactly ONE attribute:
# com.apple.quarantine, from the installed bundle. Nothing else is touched —
# no blanket extended-attribute wipe, no other xattr keys, no Gatekeeper
# changes, and no "Open Anyway" click in the user's face. Gatekeeper itself
# stays globally enabled; the code signature is unaffected (quarantine is a
# download-provenance tag, not a signature), so the bundle keeps its
# self-signed identity and the grants it has already earned.
#
# TCC privacy grants (microphone, accessibility) are a SEPARATE mechanism and
# are not touched by the postflight: they are requested from the user by macOS
# on the agent's first run, not cleared by brew. See docs/packaging/homebrew.md
# for the full rationale.

cask "nanodictate" do
  version "__VERSION__"
  sha256 arm:   "__ZIP_SHA256_ARM64__",
         intel: "__ZIP_SHA256_X86_64__"

  # arch must be declared as a DSL stanza BEFORE it is referenced: without a
  # preceding `arch` stanza, the DSL's `arch(arm:intel:)` method returns nil in
  # interpolation and the URL would back the empty suffix
  # (nanodictate-<v>-macos-.zip) → curl 404 on `brew install --cask`.
  arch arm: "arm64", intel: "x86_64"

  # The cask asset is the app-bundle zip; a single URL with the arch
  # interpolated from the DSL's `arch` method (arm64 / x86_64) selects the
  # right asset per machine.
  url "https://github.com/kodmial/nanodictate/releases/download/v__VERSION__/nanodictate-__VERSION__-macos-#{arch}.zip"
  name "NanoDictate"
  desc "macOS dictation via double-Alt: bilingual EN/RU, 4 STT providers"
  homepage "https://github.com/kodmial/nanodictate"

  # macOS-only cask (darwin .app bundles, no Linux build). The `macos` platform
  # requirement is what makes brew skip the Linux stanza validation that
  # otherwise rejects the cask at tap time ("Missing Linux stanzas ... Add
  # `depends_on :macos` ..."); the `:monterey` floor matches the formula's
  # minimum supported macOS version, so the cask and the formula never disagree
  # about which machines they support.
  depends_on macos: :monterey

  app "NanoDictate.app"
  # `app` MOVES the bundle to appdir BEFORE the binary link phase (artifact
  # install order: the App group precedes the Binary group), so the executable
  # source must resolve to the installed location — a staged-relative path
  # would no longer exist when the binary's symlink is created.
  binary "#{appdir}/NanoDictate.app/Contents/MacOS/nanodictate"

  # The bundle is self-signed and NOT notarized, so Homebrew would otherwise
  # leave com.apple.quarantine on it and Gatekeeper would refuse the first
  # launch. Strip exactly that one attribute, from the installed bundle, after
  # all install phases have run. Deliberately narrow: no blanket
  # extended-attribute wipe, no other xattr keys, no Gatekeeper changes —
  # Gatekeeper stays globally enabled and the code signature is untouched.
  postflight_steps do
    run "/usr/bin/xattr",
        args: ["-dr", "com.apple.quarantine", "{{appdir}}/NanoDictate.app"]
  end

  caveats <<~EOS
    Config: your settings live in ~/.config/nanodictate/config.toml, which
    neither install nor uninstall ever touches.

    Service: the running binary registers the background agent itself —
    `nanodictate start` writes the canonical
    ~/Library/LaunchAgents/com.nanodictate.agent.plist and bootstraps it, the
    same single label (com.nanodictate.agent) the Homebrew formula and the
    MacPorts port use — never a second daemon:

      nanodictate start | stop | status

    Privacy grants: NanoDictate needs these macOS permissions (System Settings
    → Privacy & Security), which macOS prompts you for on first use:
      - Microphone:      enable NanoDictateAgent (recording)
      - Accessibility:   enable NanoDictateAgent (the agent inserts recognized text)
      - Input Monitoring: only if you use a device that requires it
    Grants are per-binary, so an upgrade that replaces the app may require
    re-granting.

    Gatekeeper: the install's postflight step removes the
    com.apple.quarantine attribute for you, so the first launch needs no
    manual `xattr` and no "Open Anyway" click. Gatekeeper itself stays
    globally enabled and the code signature is unaffected.

    Uninstall: `brew uninstall --cask nanodictate` removes the app only — it
    does not touch the LaunchAgent or your config. Stop the service first:

      nanodictate stop
      brew uninstall --cask nanodictate

    If it was not stopped beforehand, unload the agent and clean up manually:

      launchctl bootout gui/$(id -u)/com.nanodictate.agent
      rm ~/Library/LaunchAgents/com.nanodictate.agent.plist
  EOS
end