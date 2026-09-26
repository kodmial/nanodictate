# Homebrew formula template for NanoDictate (binary install from GitHub Releases).
# Placeholders 0.1.1, d412de86f63ea2a6666ce6af930dc14f5a8f98a62b3d21ce9c226a61b07bda22, 73b1eafa2f2b7137b3ba57e6f4fe9ce45d478a00f8bab17f4b9f8f23c301a628 are filled by
# scripts/release-prep.rb — do not hand-edit the generated nanodictate.rb.
# This is a binary formula: Homebrew downloads the prebuilt tarball attached
# to the GitHub Release (built by .github/workflows/release.yml) and installs
# it as-is. No Xcode / Swift toolchain is needed on the user's machine.

class Nanodictate < Formula
  desc "macOS dictation via double-Alt: bilingual EN/RU, 4 STT providers"
  homepage "https://github.com/kodmial/nanodictate"
  # Explicit version: the tarball name carries the version but the arch suffix
  # (nanodictate-0.1.1-macos-<arch>.tar.gz) would confuse homebrew's
  # version-from-filename inference.
  version "0.1.1"
  license "MIT"

  depends_on macos: :monterey

  # Release tarballs are attached to the tag v0.1.1 (the tag keeps the
  # "v" prefix; the archive filename does not — see .github/workflows/release.yml).
  if Hardware::CPU.arm?
    url "https://github.com/kodmial/nanodictate/releases/download/v0.1.1/nanodictate-0.1.1-macos-arm64.tar.gz"
    sha256 "d412de86f63ea2a6666ce6af930dc14f5a8f98a62b3d21ce9c226a61b07bda22"
  else
    url "https://github.com/kodmial/nanodictate/releases/download/v0.1.1/nanodictate-0.1.1-macos-x86_64.tar.gz"
    sha256 "73b1eafa2f2b7137b3ba57e6f4fe9ce45d478a00f8bab17f4b9f8f23c301a628"
  end

  def install
    # Every release tarball has two binaries and config.example.toml at the
    # top level (plus Resources/ for reference — see release.yml).
    # Only the binaries + config are installed: the user activates the service
    # with `brew services start nanodictate` (the service block below) — the
    # same single Label com.nanodictate.agent as `nanodictate start`, with no
    # extra labels, so a second daemon is never spawned.
    bin.install "nanodictate", "NanoDictateAgent"

    # config.example.toml is a copyable source, not the live config: the CLI
    # always reads ~/.config/nanodictate/config.toml (AppConfig.defaultPath()),
    # never a file under etc/. The example lives in share/nanodictate/.
    (share/"nanodictate").install "config.example.toml"
  end

  service do
    # Canonical single LaunchAgent label com.nanodictate.agent — the same
    # plist the CLI (`nanodictate start`) and the MacPorts port write, so there
    # is always exactly one daemon regardless of install method or order.
    # `brew services start nanodictate` runs as the user (no sandbox), writes
    # ~/Library/LaunchAgents/com.nanodictate.agent.plist and bootstraps
    # gui/<uid> — that explicit activation registers the service after install.
    name macos: "com.nanodictate.agent"
    run opt_bin/"NanoDictateAgent"
    keep_alive true
    run_at_load true
    log_path "#{Dir.home}/Library/Logs/NanoDictate/agent.log"
    error_log_path "#{Dir.home}/Library/Logs/NanoDictate/agent.log"
  end

  def caveats
    # Service registration — the service block (`brew services start
    # nanodictate`) or `nanodictate start` — both write the same canonical
    # ~/Library/LaunchAgents/com.nanodictate.agent.plist and load it via
    # launchctl; repeat runs are idempotent. The first run of the binary only
    # rewrites that same plist (realpath) if needed.
    # config.example.toml is copied to ~/.config/nanodictate/config.toml on the
    # app's first launch.
    <<~EOS
      NanoDictate needs manual macOS privacy grants (System Settings → Privacy & Security):
        - Microphone:     enable NanoDictateAgent (recording)
        - Accessibility:  enable NanoDictateAgent (the agent inserts recognized text)
      macOS prompts on first use; grants are per-binary, so a binary change
      (e.g. after `brew upgrade`) may require re-granting.

      The config is created automatically on first launch: the app copies
      #{opt_share}/nanodictate/config.example.toml to
      ~/.config/nanodictate/config.toml (the file the app reads). No manual
      `config init` step is required; `nanodictate config init` writes the
      same canon explicitly.

        nanodictate provider list
        nanodictate config set-key <provider>

      The tool runs as a background user LaunchAgent (auto-restarts at
      login) under the canonical single label com.nanodictate.agent. `brew
      install` does not register the LaunchAgent — activate it once with:

        brew services start nanodictate

      This writes ~/Library/LaunchAgents/com.nanodictate.agent.plist (single
      canonical label com.nanodictate.agent) and loads it into launchd;
      `brew services stop nanodictate` stops it.

      Homebrew 5.1.15 or newer is required for the `brew services start
      nanodictate` workflow: older versions do not create parent directories
      for explicit service log paths, so on a fresh account the service can
      fail to start because ~/Library/Logs/NanoDictate is absent (cmdStart()
      creates it only for `nanodictate start`).

      The CLI `nanodictate start`
      is the same registration — idempotent, never a second daemon. Run it
      anyway to re-register with the symlink-resolved real path (e.g. after
      moving things around), or to print the current state:

        nanodictate start
        nanodictate status
        nanodictate stop

      Stop the registered service BEFORE uninstalling — the CLI is needed to
      stop the daemon and is gone after `brew uninstall`:

        nanodictate stop
        brew uninstall nanodictate

      `brew uninstall` removes the binaries only: it does not unload the
      LaunchAgent and the canonical plist
      (~/Library/LaunchAgents/com.nanodictate.agent.plist) survives. If the
      service was not stopped beforehand, unload it and remove the plist
      manually:

        launchctl bootout gui/$(id -u)/com.nanodictate.agent
        rm ~/Library/LaunchAgents/com.nanodictate.agent.plist

      Your config (~/.config/nanodictate/config.toml) is never touched by
      install or uninstall.

      Release binaries are self-signed with the NanoDictate CI Signing identity
      (hardened runtime); there is no Developer ID signature and they are not
      notarized by Apple. This install path sets no quarantine attribute, so
      no Gatekeeper dialog is expected on the first launch of the binaries in
      #{opt_prefix}/bin, and none has been observed.
    EOS
  end

  test do
    # `nanodictate --version` prints the released version — dynamic, must match
    # version.to_s (e.g. "nanodictate 0.0.2" for the 0.0.2 release).
    assert_match version.to_s, shell_output("#{bin}/nanodictate --version")
  end
end