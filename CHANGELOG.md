# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.0] - 2026-09-22

### Changed

- README: установка через MacPorts — две команды
  (`port selfupdate` + `sudo port selfupdate && sudo port install nanodictate`)
  вместо однострочного curl-скрипта. Поддерживается override
  `sources.conf` (локальный `file://` источник без `[nosync]`), установка
  идемпотентна. Блоки документации в README (установка и «теневая»
  копия источника) приведены к единому описанию.

## [0.0.16] - 2026-09-22

### Fixed

- Homebrew cask — arch объявлен явно (arm/intel): в шаблоне каска
  `packaging/homebrew/Casks/nanodictate.rb.tpl` добавлена stanza
  `arch arm: "arm64", intel: "x86_64"` сразу после sha256. Ранее `#{arch}`
  без объявления возвращал nil в cask DSL, из-за чего URL каска
  формировался как `nanodictate-<v>-macos-.zip` → 404
  (`Download failed: .../nanodictate-0.0.15-macos-.zip`) при
  `brew install --cask nanodictate`. URL каска выбирает живой ассет
  релиза (`-macos-arm64.zip` / `-macos-x86_64.zip`) через объявленную
  переменную arch. Генератор scripts/release-prep.rb не правился: он
  делает только подстановку `__VERSION__`/`__ZIP_SHA256_*__`, строка
  `arch` переносится из шаблона в сгенерированный каск без изменений.

## [0.0.13] - 2026-09-22

### Added

- Дистрибуция вариант D — .app-бандл: CI собирает подписанный
  `NanoDictate.app` и публикует его как детерминированный zip-артефакт
  `nanodictate-<v>-macos-{arm64,x86_64}.zip`, устанавливаемый через Homebrew
  cask (`brew install --cask nanodictate`). В бандле те же два подписанных
  бинаря и стабильный bundle id `com.nanodictate.agent` — TCC-гранты
  (Микрофон/Доступность) не слетают между версиями; postflight каска снимает
  `com.apple.quarantine` с установленного приложения (self-signed бинарь без
  нотаризации Gatekeeper отказывается запускать, пока атрибут на месте).
  MacPorts остаётся чистым CLI (вариант D).

## [0.0.12] - 2026-09-21

### Changed

- E2E release: no code changes. Verifies the Accessibility settings panel opens on a fresh install; the wipe ritual clears the cooldown stamp (`defaults delete com.nanodictate.agent NanoDictate.lastAccessibilityPanelOpenAt`) so the panel is shown on first launch.

## [0.0.11] - 2026-09-21

### Fixed

- Панель Доступности — наблюдаемость `openAccessibilitySettingsIfDue()`: debug-маркер
  входа, суффикс «retry in N s» в кулдаун-ветке, причина сбоя
  `NSWorkspace.shared.open` в error-логе, info-лог успешного открытия после
  `defaults.set`; тесты пинают новые строки и уровни.

## [0.0.10] - 2026-09-21

### Changed

- Релизный бамп версии без функциональных изменений: между v0.0.9 и v0.0.10
  кодовых правок нет, v0.0.9 опубликован (macports-канон установки и фикс
  панели Доступности уже в нём).

## [0.0.9] - 2026-09-21

### Changed

- MacPorts-установка — канон: одна идемпотентная команда
  `bash <(curl -fsSL .../scripts/install-macports.sh)` вместо многострочного
  `sudo bash -c '...'`; файл-источник пишется в эффективный sources.conf
  (`~/.macports/macports.conf` с `sources_conf` имеет приоритет над системным
  `/opt/local/etc/macports/sources.conf`), строка `file://` вставляется перед
  `[default]`; дерево переиндексируется `portindex` вместо `port selfupdate`.

### Fixed

- Панель Доступности: кулдаун 10 мин ставится только при успешном открытии
  (`NSWorkspace.shared.open`), при неудаче — ошибка в логе и повтор при
  следующем start/respawn; подавленное открытие логируется как info, а не
  только в debug.

## [0.0.8] - 2026-09-21

### Fixed

- Access-грант Доступности: явный Alt+Alt без гранта теперь показывает
  системный диалог macOS через `AXIsProcessTrustedWithOptions` +
  `kAXTrustedCheckOptionPrompt` — прямой запрос TCC-гранта, а не тихое
  открытие панели Настроек; панель остаётся для start/respawn (стартовый
  кулдаун 10 мин).

## [0.0.7] - 2026-09-21

### Added

- CI-подпись релизных тарболов теперь вшивает entitlements
  (`--entitlements Resources/com.nanodictate.agent.entitlements` /
  `com.nanodictate.ctl.entitlements`) с hardened runtime — первые тарболы,
  несущие TCC-гранты в самой подписи; DR остаётся лист-пином сертификата.

## [0.0.6] - 2026-09-20

### Added

- Стабильная подпись релизных бинарей в CI самоподписанным сертификатом
  (identity `NanoDictate CI Signing`, p12 из секретов
  `NANODICTATE_SIGNING_P12`/`PASSWORD`, временный keychain); встраивание
  Info.plist как Mach-O секции `__info_plist` через `-Xlinker -sectcreate` —
  CFBundleIdentifier виден tccd, поэтому TCC-грант переживает смену пути в
  brew Cellar/<ver> и работает `tccutil reset` по bundle-id; без секретов —
  ad-hoc fallback.

## [0.0.5] - 2026-09-20

### Added

- Homebrew formula service block: `brew services start nanodictate` registers
  the background agent (single canonical label `com.nanodictate.agent`)
  outside the Homebrew ≥ 7 sandbox — README/docs and the formula `opoo` hint
  point to it as the primary registration path.

### Fixed

- VersionTests compares `NanoDictateVersion.string` to the current release
  header in CHANGELOG.md instead of a hardcoded version — CI no longer breaks
  on every version bump.

## [0.0.4] - 2026-09-20

### Fixed

- Release automation (ЦЕЛЬ Б): deterministic tarballs (SOURCE_DATE_EPOCH +
  BSD `touch -t` 12-digit + uid/gid 0 + sorted member list + `gzip -n`), the
  version-exists guard via `gh api releases/tags/v<VERSION>` (200/404) instead
  of `gh release view` (the old probe mis-detected the draft window 5/5 times),
  the GH_TOKEN conflict in the MacPorts sync step, and `--clobber`-free asset
  uploads (existing bytes are never overwritten).
- MacPorts uninstall leaves no trace: `pre-deactivate` now deletes
  `/Library/Logs/NanoDictate` (root-owned log dir from `post-activate`) on
  `sudo port uninstall` — no manual `sudo rm` step.

## [0.0.3] - 2026-09-20

### Fixed

- `resolveAgentBinaryPath` finds the agent binary via `PATH` on a bare
  invocation (`nanodictate start`) — a clean Homebrew ≥7 install now works.
- Homebrew formula `post_install` sandbox guard (brew ≥7 runs post_install in
  a sandbox with a temp HOME; registration is deferred to `nanodictate start`
  with a printed hint instead of failing).

## [0.0.2] - 2026-09-20

### Added

- Dictation started/stopped by a double **Alt** press; **Esc** cancels.
- Overlay panel with live input level and recording/progress/status phases.
- Bilingual UI (English and Russian), switchable from the TUI menu.
- Text insertion via CGEvent keyboard events (default) or clipboard + Cmd+V
  (previous clipboard restored).
- Undo window: a double-**Alt** shortly after an insertion removes the text.
- Silence auto-stop (~3 s of quiet) with configurable duration and RMS
  threshold (`NANODICTATE_AUTOSTOP_DURATION`, `NANODICTATE_AUTOSTOP_RMS`).
- Multi-provider STT via OpenAI-compatible `/audio/transcriptions` adapters:
  OpenAI, Groq, GigaAM/Airubiz (default), Cloudflare Workers AI, and any
  generic `openai-compatible` endpoint.
- Transport options: `direct`, HTTP proxy (`http`), gateway (`proxy_key`
  header relay), and `cookie-relay` (JS-challenge with computed `__test`
  cookie).
- Batch file transcription: chunked segments, parallel workers, pause cutting,
  checkpoint/resume, and a progress bar.
- Optional review gate (`review_before_insert`) — confirm text before typing.
- Auto-failover between providers and manual `nanodictate retry <provider>`.
- Interactive TUI status menu (`nanodictate`) with agent state, provider list,
  log viewer, and language toggle.
- Background LaunchAgent (`com.nanodictate.agent`) with
  `nanodictate start|stop|status`.
- TOML configuration at `~/.config/nanodictate/config.toml`
  (chmod 600, atomic writes).
- Code signing workflow with a stable identity + fixed entitlements to preserve
  macOS TCC grants (Microphone/Accessibility) across rebuilds.
- `nanodictate --version` / `-v` prints the current version.

[Unreleased]: https://github.com/kodmial/nanodictate/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/kodmial/nanodictate/compare/v0.0.16...v0.1.0
[0.0.16]: https://github.com/kodmial/nanodictate/compare/v0.0.13...v0.0.16
[0.0.13]: https://github.com/kodmial/nanodictate/compare/v0.0.12...v0.0.13
[0.0.12]: https://github.com/kodmial/nanodictate/compare/v0.0.11...v0.0.12
[0.0.11]: https://github.com/kodmial/nanodictate/compare/v0.0.10...v0.0.11
[0.0.10]: https://github.com/kodmial/nanodictate/compare/v0.0.9...v0.0.10
[0.0.9]: https://github.com/kodmial/nanodictate/compare/v0.0.8...v0.0.9
[0.0.8]: https://github.com/kodmial/nanodictate/compare/v0.0.7...v0.0.8
[0.0.7]: https://github.com/kodmial/nanodictate/compare/v0.0.6...v0.0.7
[0.0.6]: https://github.com/kodmial/nanodictate/compare/v0.0.5...v0.0.6
[0.0.5]: https://github.com/kodmial/nanodictate/compare/v0.0.4...v0.0.5
[0.0.4]: https://github.com/kodmial/nanodictate/compare/v0.0.3...v0.0.4
[0.0.3]: https://github.com/kodmial/nanodictate/releases/tag/v0.0.3
[0.0.2]: https://github.com/kodmial/nanodictate/releases/tag/v0.0.2