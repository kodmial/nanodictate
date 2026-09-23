# Homebrew formula template for NanoDictate (binary install from GitHub Releases).
# Placeholders 0.0.16, 0a3611c376e88a2d8304bb291f946a19ea978456b69beb1283344d5fdc7935e6, 31489b8af3e5bdbddd877bdc2c00fd9cb0f9ea2fd6d00c7bd9a1e8ce8f04af43 are filled by
# scripts/release-prep.rb — do not hand-edit the generated nanodictate.rb.
# This is a binary formula: Homebrew downloads the prebuilt tarball attached
# to the GitHub Release (built by .github/workflows/release.yml) and installs
# it as-is. No Xcode / Swift toolchain is needed on the user's machine.

class Nanodictate < Formula
  desc "macOS dictation via double-Alt: bilingual EN/RU, 4 STT providers"
  homepage "https://github.com/kodmial/nanodictate"
  # Explicit version: the tarball name carries the version but the arch suffix
  # (nanodictate-0.0.16-macos-<arch>.tar.gz) would confuse homebrew's
  # version-from-filename inference.
  version "0.0.16"
  license "MIT"

  depends_on macos: :monterey

  # Release tarballs are attached to the tag v0.0.16 (the tag keeps the
  # "v" prefix; the archive filename does not — see .github/workflows/release.yml).
  if Hardware::CPU.arm?
    url "https://github.com/kodmial/nanodictate/releases/download/v0.0.16/nanodictate-0.0.16-macos-arm64.tar.gz"
    sha256 "0a3611c376e88a2d8304bb291f946a19ea978456b69beb1283344d5fdc7935e6"
  else
    url "https://github.com/kodmial/nanodictate/releases/download/v0.0.16/nanodictate-0.0.16-macos-x86_64.tar.gz"
    sha256 "31489b8af3e5bdbddd877bdc2c00fd9cb0f9ea2fd6d00c7bd9a1e8ce8f04af43"
  end

  def install
    # Каждая релизная тарболка содержит на верхнем уровне два бинаря и
    # config.example.toml (плюс Resources/ для справки — см. release.yml).
    # Только бинарь + конфиг: службу активирует сам пользователь командой
    # `brew services start nanodictate` (service-блок ниже) — тот же
    # единственный Label com.nanodictate.agent, что и `nanodictate start`,
    # без новых label, чтобы не плодить второй демон.
    bin.install "nanodictate", "NanoDictateAgent"

    # config.example.toml — копируемый источник, не живой конфиг: CLI всегда
    # читает ~/.config/nanodictate/config.toml (AppConfig.defaultPath()), никогда
    # файл под etc/. Пример живёт в share/nanodictate/.
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
    # Регистрация службы — service-блок `brew services start nanodictate`
    # либо `nanodictate start` — оба пишут тот же канонический
    # ~/Library/LaunchAgents/com.nanodictate.agent.plist и грузят его через
    # launchctl, повторные запуски идемпотентны. Первый запуск бинаря лишь
    # перезаписывает тот же plist (realpath) при необходимости.
    # config.example.toml копируется в ~/.config/nanodictate/config.toml при
    # первом запуске приложения.
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
      `brew services stop nanodictate` stops it. The CLI `nanodictate start`
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
      (hardened runtime); there is no Developer ID signature and no
      notarization. Homebrew's download does not set the quarantine
      attribute, so Gatekeeper stays quiet; only *browser* downloads get
      com.apple.quarantine (see docs/packaging/homebrew.md for the `xattr -dr`
      workaround).
    EOS
  end

  test do
    # `nanodictate --version` prints the released version — dynamic, must match
    # version.to_s (e.g. "nanodictate 0.0.2" for the 0.0.2 release).
    assert_match version.to_s, shell_output("#{bin}/nanodictate --version")
  end
end