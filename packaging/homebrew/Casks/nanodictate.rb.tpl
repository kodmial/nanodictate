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
# com.nanodictate.agent.plist that `nanodictate start`, the formula's
# post_install and the MacPorts port's post-activate write. Installing the
# cask over the formula is safe (idempotent re-registration, never a second
# daemon); the last installer simply re-writes the same canonical file.
#
# postflight_steps + quarantine: the release binaries are self-signed with the
# NanoDictate CI Signing identity — no Developer ID, no notarization. A .app
# carrying the com.apple.quarantine attribute is refused by Gatekeeper
# ("damaged"/"unidentified developer"). Homebrew's own curl does not set the
# attribute, but a browser-downloaded zip (or a brew that stamps it) would
# break first launch, so the postflight_steps strips it from the installed bundle.
# Homebrew expands the `{{staged_path}}` template token (install_steps.rb) to the
# staged source: after the `app` artifact moved the bundle into /Applications, it
# is a symlink to it (FileUtils.ln_sf); xattr follows the link and clears the
# attribute on the REAL installed app. `xattr -dr` exits 0 even when nothing is
# quarantined (verified on macOS), so the step is a safe no-op on a clean
# brew-cached download. `postflight_steps` is the current brew DSL stanza; the
# deprecated `postflight` alias warns on every tap.

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

  # macOS-only cask (darwin .app bundles, no Linux build). `depends_on :macos`
  # makes brew skip the Linux stanza validation that otherwise rejects the
  # cask at tap time ("Missing Linux stanzas ... Add `depends_on :macos` ...").
  depends_on :macos

  app "NanoDictate.app"
  binary "NanoDictate.app/Contents/MacOS/nanodictate"

  postflight_steps do
    # The {{staged_path}} token is dereferenced by Homebrew at install time to
    # the staged source — after the `app` artifact moved the bundle into
    # /Applications, it is a symlink to it (FileUtils.ln_sf), so xattr follows
    # the link and clears the attribute on the REAL installed app. Exit 0 on a
    # clean tree, so this never fails a cask install.
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{staged_path}}/NanoDictate.app"]
  end

  caveats <<~EOS
    NanoDictate needs manual macOS privacy grants (System Settings → Privacy & Security):
      - Microphone:     enable NanoDictateAgent (recording)
      - Accessibility:  enable NanoDictateAgent (the agent inserts recognized text)
    macOS prompts on first use; grants are per-binary, so an upgrade that
    replaces the app may require re-granting.

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