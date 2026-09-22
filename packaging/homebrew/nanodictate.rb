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
    # Только бинарь + конфиг: службу формула регистрирует в post_install
    # (Homebrew < 7) либо через service-блок `brew services start` (brew >= 7)
    # — всегда тот же единственный Label com.nanodictate.agent, что и
    # `nanodictate start`, без новых label, чтобы не плодить второй демон.
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
    # `brew services start nanodictate` runs OUTSIDE the Homebrew sandbox and
    # writes ~/Library/LaunchAgents/com.nanodictate.agent.plist + bootstraps
    # gui/<uid> — the only way to get the service live on brew>=7, where the
    # post_install sandbox blocks launchctl (EIO) and cardinal writes (EPERM).
    name macos: "com.nanodictate.agent"
    run opt_bin/"NanoDictateAgent"
    keep_alive true
    run_at_load true
    log_path "#{Dir.home}/Library/Logs/NanoDictate/agent.log"
    error_log_path "#{Dir.home}/Library/Logs/NanoDictate/agent.log"
  end

  def post_install
    # homebrew >= 7 исполняет post_install в sandbox (HOME = временный /private/tmp,
    # запись в реальный дом -> EPERM, launchctl -> EIO). Тогда авторегистрацию
    # службы из post_install сделать нельзя: печатаем предупреждение с командой и
    # выходим. На старых версиях brew HOME — реальный дом: гибрид A+B работает.
    real_home = Etc.getpwuid(Process.uid).dir
    if ENV.fetch("HOME") != real_home
      opoo "Homebrew sandbox: LaunchAgent registration skipped. Run `brew services start nanodictate` to register the background agent — it writes the same canonical ~/Library/LaunchAgents/com.nanodictate.agent.plist and loads gui/<uid> outside the sandbox; `nanodictate start` is the equivalent, idempotent alternative."
      return
    end
    # Гибрид A+B: упаковка сама создаёт канонический plist и РАЗОВО активирует
    # службу — после чистой установки (без ручного первого запуска) демон уже
    # зарегистрирован, RunAtLoad + KeepAlive: стартует при входе в систему и
    # Alt+Alt работает сразу. Тот же канонический файл
    # ~/Library/LaunchAgents/com.nanodictate.agent.plist и тот же единственный
    # Label com.nanodictate.agent, что у `nanodictate start`, — второй менеджер
    # подменяет, повторный запуск идемпотентен.
    # post_install исполняется от пользователя (brew), HOME — реальный дом.
    home = Pathname.new(real_home)
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
    # ещё нет, bootout выходит с «Boot-out failed: No such process»), затем
    # загрузить новый план. Kernel.system (многоаргументная форма, без шелла)
    # возвращает false вместо throw — в отличие от Formula#system, который
    # кидает BuildError на любом ненулевом exit и ронял бы `brew install` на
    # чистой установке. Оба вызова терпимы: провал bootstrap (например,
    # установка по SSH без GUI-сессии) не роняет установку — служба всё равно
    # стартует при следующем входе в систему (RunAtLoad) либо её поднимет
    # `nanodictate start`.
    target = "gui/#{Process.uid}/com.nanodictate.agent"
    Kernel.system "/bin/launchctl", "bootout", target
    Kernel.system "/bin/launchctl", "bootstrap", "gui/#{Process.uid}", plist.to_s
  end

  def caveats
    # Регистрация службы — post_install (Homebrew < 7, HOME — реальный дом),
    # service-блок `brew services start` (brew >= 7, вне sandbox) либо
    # `nanodictate start` — все пути пишут тот же канонический
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
      login) under the canonical single label com.nanodictate.agent. The
      Homebrew post_install sandbox (brew >= 7) cannot register the
      LaunchAgent during `brew install` — start the background agent with:

        brew services start nanodictate

      This writes ~/Library/LaunchAgents/com.nanodictate.agent.plist (single
      canonical label com.nanodictate.agent) and loads it outside the
      sandbox; `brew services stop nanodictate` stops it. The CLI
      `nanodictate start` is the same registration — idempotent, never a
      second daemon — and on Homebrew < 7 post_install already registered the
      service, so it is a safe no-op. Run it anyway to re-register with the
      symlink-resolved real path (e.g. after moving things around), or to
      print the current state:

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