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
    # Только бинарь + конфиг: службу формула регистрирует в post_install
    # (тот же единственный Label com.nanodictate.agent, что и `nanodictate
    # start`, — никаких service-блоков/startupitem и НИКАКИХ новых label,
    # чтобы не плодить второй демон homebrew.mxcl.*).
    bin.install "nanodictate", "NanoDictateAgent"

    # config.example.toml — копируемый источник, не живой конфиг: CLI всегда
    # читает ~/.config/nanodictate/config.toml (AppConfig.defaultPath()), никогда
    # файл под etc/. Пример живёт в share/nanodictate/.
    (share/"nanodictate").install "config.example.toml"
  end

  def post_install
    # Гибрид A+B: упаковка сама создаёт канонический plist и РАЗОВО активирует
    # службу — после чистой установки (без ручного первого запуска) демон уже
    # зарегистрирован, RunAtLoad + KeepAlive: стартует при входе в систему и
    # Alt+Alt работает сразу. Тот же канонический файл
    # ~/Library/LaunchAgents/com.nanodictate.agent.plist и тот же единственный
    # Label com.nanodictate.agent, что у `nanodictate start`, — второй менеджер
    # подменяет, повторный запуск идемпотентен.
    # post_install исполняется от пользователя (brew), HOME — реальный дом.
    home = Pathname.new(ENV.fetch("HOME"))
    launch_agents = home + "Library" + "LaunchAgents"
    launch_agents.mkpath
    logs = home + "Library" + "Logs" + "NanoDictate"
    logs.mkpath
    plist = launch_agents + "com.nanodictate.agent.plist"

    # Путь бинаря: $(brew --prefix)/bin/NanoDictateAgent — симлинк Homebrew на
    # текущий Cellar (brew перенаправляет его при апгрейде), поэтому пути не
    # протухают между релизами (launchd разрешает симлинк в момент старта).
    agent = "#{HOMEBREW_PREFIX}/bin/NanoDictateAgent"
    log_path = (logs + "agent.log").to_s
    plist.write(<<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Label</key>
        <string>com.nanodictate.agent</string>
        <key>ProgramArguments</key>
        <array>
          <string>#{agent}</string>
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>StandardOutPath</key>
        <string>#{log_path}</string>
        <key>StandardErrorPath</key>
        <string>#{log_path}</string>
      </dict>
      </plist>
    PLIST
    plist.chmod(0o600)

    # Takeover: выгрузить прежнего (терпимо — при первой установке службы
    # нет), затем загрузить новый план. Ошибки НЕ роняют `brew install`:
    # например, установка по SSH без GUI-сессии — служба всё равно стартует
    # при следующем входе в систему (RunAtLoad) либо её поднимет
    # `nanodictate start`.
    target = "gui/#{Process.uid}/com.nanodictate.agent"
    system "/bin/launchctl", "bootout", target
    system "/bin/launchctl", "bootstrap", "gui/#{Process.uid}", plist.to_s
  end

  def caveats
    # Регистрация службы — работа post_install (запускается от пользователя,
    # HOME — реальный дом), а не первого запуска бинаря: post_install сам
    # пишет канонический ~/Library/LaunchAgents/com.nanodictate.agent.plist и
    # грузит службу через launchctl. Первый запуск бинаря лишь перезаписывает
    # тот же plist (realpath) при необходимости. config.example.toml копируется
    # в ~/.config/nanodictate/config.toml при первом запуске приложения.
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

      The install registers the background agent as a user LaunchAgent
      (auto-restarts at login): the canonical
      ~/Library/LaunchAgents/com.nanodictate.agent.plist is written by
      post_install with the brew binary path and bootstrapped into launchd —
      no manual `nanodictate start` is required after a clean install. Run it
      anyway to re-register with the symlink-resolved real path (e.g. after
      moving things around), or to print the current state:

        nanodictate start
        nanodictate status
        nanodictate stop

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