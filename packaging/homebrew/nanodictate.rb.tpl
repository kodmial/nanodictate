# Homebrew formula template for NanoDictate (binary install from GitHub Releases).
# Placeholders __VERSION__, __SHA256_ARM64__, __SHA256_X86_64__ are filled by
# scripts/release-prep.rb — do not hand-edit the generated nanodictate.rb.
# This is a binary formula: Homebrew downloads the prebuilt tarball attached
# to the GitHub Release (built by .github/workflows/release.yml) and installs
# it as-is. No Xcode / Swift toolchain is needed on the user's machine.

class NanoDictate < Formula
  desc "macOS dictation via double-Alt: bilingual EN/RU, 4 STT providers"
  homepage "https://github.com/kodmial/nanodictate"
  # Explicit version: the tarball name carries the version but the arch suffix
  # (nanodictate-__VERSION__-macos-<arch>.tar.gz) would confuse homebrew's
  # version-from-filename inference.
  version "__VERSION__"
  license "MIT"

  depends_on macos: :monterey

  # Release tarballs are attached to the tag v__VERSION__ (the tag keeps the
  # "v" prefix; the archive filename does not — see .github/workflows/release.yml).
  if Hardware::CPU.arm?
    url "https://github.com/kodmial/nanodictate/releases/download/v__VERSION__/nanodictate-__VERSION__-macos-arm64.tar.gz"
    sha256 "__SHA256_ARM64__"
  else
    url "https://github.com/kodmial/nanodictate/releases/download/v__VERSION__/nanodictate-__VERSION__-macos-x86_64.tar.gz"
    sha256 "__SHA256_X86_64__"
  end

  def install
    # Каждая релизная тарболка содержит на верхнем уровне два бинаря и
    # config.example.toml (плюс Resources/ для справки — см. release.yml).
    # Только бинарь + конфиг: СЛУЖБУ регистрирует сам запущенный бинарь
    # (`nanodictate start` пишет канонический plist в ~/Library/LaunchAgents),
    # формула службу НЕ ставит — никаких service-блоков/startupitem, чтобы
    # не плодить второй демон (homebrew.mxcl.*).
    bin.install "nanodictate", "NanoDictateAgent"

    # config.example.toml — копируемый источник, не живой конфиг: CLI всегда
    # читает ~/.config/nanodictate/config.toml (AppConfig.defaultPath()), никогда
    # файл под etc/. Пример живёт в share/nanodictate/.
    (share/"nanodictate").install "config.example.toml"
  end

  def caveats
    # NB: post_install нет намеренно — Homebrew запускает его с root-овым HOME
    # и не может надёжно писать в ~/.config пользователя. Механизм первого
    # запуска в коде (автокопия config.example.toml в ~/.config/nanodictate/
    # config.toml) покрывает это; регистрация службы — тоже работа запущенного
    # бинаря, а не формулы.
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

      Start the background agent as a user LaunchAgent (auto-restarts at login).
      The running binary registers the service itself — it writes the canonical
      plist ~/Library/LaunchAgents/com.nanodictate.agent.plist with the real
      (symlink-resolved) binary path, so the path never goes stale after updates:
        nanodictate start

      Manage it with `nanodictate status`, `nanodictate stop`, `nanodictate logs`.

      Release binaries are ad-hoc signed — there is no Developer ID signature
      and no notarization. Homebrew's download does not set the quarantine
      attribute, so Gatekeeper stays quiet; only *browser* downloads get
      com.apple.quarantine (see docs/packaging/homebrew.md for the `xattr -dr`
      workaround).
    EOS
  end

  test do
    # `nanodictate --version` prints "nanodictate 0.1.0" (flag lands with 0.1.0).
    assert_match version.to_s, shell_output("#{bin}/nanodictate --version")
  end
end