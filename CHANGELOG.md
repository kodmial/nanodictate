# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.1.15] - 2026-10-01

### Changed

- Release automation now runs through versioned Continuum reusable workflows invoked by thin caller workflows in this repository, replacing the previous inline release implementation. Version ownership (the Release PR owns `Version.swift`), `skip-release`, patch-only versioning, packaging smoke gates and manifest synchronization behave as before ([1894142](https://github.com/kodmial/nanodictate/commit/189414260997346fe98332404dd090a8b6d7314d)).
- Fixed MacPorts distribution serving a stale tree and added a packaging-manifest sync test so generated manifests cannot lag `Version.swift` again ([5b596c2](https://github.com/kodmial/nanodictate/commit/5b596c2a53e9b7ad2c19a021dcc7d1ce8b2564c0)).
- Packaging manifests resynced to the v0.1.14 post-release state (Homebrew formula/cask, MacPorts Portfile, installer PIN) ([72f6bac](https://github.com/kodmial/nanodictate/commit/72f6bac96e8ee832096cde76d8a6a0bd83afbde4)).

## [0.1.14] - 2026-09-29

### Changed

- No user-facing changes. Test coverage for `NanoDictateCore` reached 90.01% with 1027 tests passing ([e7e3c50](https://github.com/kodmial/nanodictate/commit/e7e3c50364e8d388d89911ed29e079ad309ddf79)).

## [0.1.13] - 2026-09-29

### Changed

- Audio hot path reuses capture buffers and shortens lock hold time, lowering CPU cost during dictation ([caf7d52](https://github.com/kodmial/nanodictate/commit/caf7d528d23abc0a12e80c765b7b39e7e25529a2)).

### Fixed

- Capture callbacks are isolated per tap generation, so a stale audio tap can no longer corrupt samples after an engine wedge swap ([caf7d52](https://github.com/kodmial/nanodictate/commit/caf7d528d23abc0a12e80c765b7b39e7e25529a2)).

## [0.1.12] - 2026-09-29

### Fixed

- Live STT now applies backpressure with a coalesced drain: a single drain task serves buffered segments, recording and delivery stop after cancellation, and the completion watchdog accounts for buffered plus in-flight batches ([9302009](https://github.com/kodmial/nanodictate/commit/93020099f68474f9193e8a1fb44ae4ff956e34f8)).

## [0.1.11] - 2026-09-29

### Changed

- The default OpenAI transcription model is now `gpt-transcribe` (explicit `whisper-1` remains a compatibility path; empty config resolves to the new default). Language-hint routing follows per-model capabilities (`gpt-transcribe` receives a `languages[]` array) ([7ab2228](https://github.com/kodmial/nanodictate/commit/7ab2228f8bbaddb928268875aaccd29ec721fccb)).

## [0.1.10] - 2026-09-29

### Added

- STT benchmark harness (`benchmark` subcommand, `STTBenchmark`) with synthetic-tone latency runs, transcript-bearing WAV overlays for live scoring, and `docs/stt-benchmark.md` ([c779afd](https://github.com/kodmial/nanodictate/commit/c779afd6c58360006cebcaf56456502836f6bfa6)).

## [0.1.9] - 2026-09-29

### Changed

- Tag releases are gated on the macOS packaging smoke suite (Homebrew and MacPorts lifecycles) and only smoke-tested candidate artifacts are published ([640cb97](https://github.com/kodmial/nanodictate/commit/640cb97cce452b86fe35839662fa9ad35a460d0a)).

## [0.1.8] - 2026-09-28

### Added

- Overlay header shows a version badge derived from `NanoDictateVersion` (`OverlayVersion.displayString`), staying fully visible during processing. Tag releases are rejected when the tag disagrees with `Version.swift` ([7b4f3d7](https://github.com/kodmial/nanodictate/commit/7b4f3d7762c1c2d2da046b0e4b6307e8862f5f6f)).

### Fixed

- The recording-ready cue is emitted only after the audio engine starts successfully; a first buffer arriving while start is pending is held and discarded on failure, cancellation, device change or watchdog timeout. The warmed-converter cache is reset on reuse so resample state cannot leak between sessions ([9a183f5](https://github.com/kodmial/nanodictate/commit/9a183f56288e2630a47b26dfc83964e2a499f279)).

## [0.1.7] - 2026-09-27

### Added

- Model-aware STT capabilities: per-model capability negotiation for STT adapters, with batch long-form gating and WAV encoding following declared capabilities. Documented in `docs/stt-capabilities.md` ([883e723](https://github.com/kodmial/nanodictate/commit/883e723c52316f9ca1d1482dff60828a59899e04)).

## [0.1.6] - 2026-09-27

### Changed

- Release automation follows the Release PR model: merges into `main` no
  longer bump the version with a direct push. `release-pr.yml` (release-please
  with `always-bump-patch`, `Version.swift` via the generic `extra-files`
  updater) maintains the single Release PR from the merged history, cuts the
  matching `CHANGELOG.md` section on that branch, and merging it publishes the
  release through the unchanged `release.yml` pipeline. The post-release
  manifests and the installer pin arrive through a
  `chore/release-manifests-v<version>` PR instead of a direct push, so `main`
  can require pull requests with no automation bypass. Feature PRs never touch
  `Version.swift` or `.release-please-manifest.json` (enforced by the
  `version-ownership` CI job); the `skip-release` label, the path-based guard
  and the `0.0.100` automatic-bump cap keep working as before. Release PR
  writes use `RELEASE_PR_TOKEN` (falling back to the existing `TAP_PAT`) so
  required CI runs on them.

## [0.1.5] - 2026-09-27

## [0.1.4] - 2026-09-27

## [0.1.3] - 2026-09-27

### Added

- `skip-release` PR label — the explicit opt-out from release automation. A
  merged PR carrying the label is a green no-op in `bump-version.yml`:
  `Sources/NanoDictateCore/Version.swift` stays untouched, nothing is committed
  or pushed, and `release.yml` is not dispatched, even when the PR's file paths
  would count as releasable. The label is read straight from the
  `pull_request` event payload (no extra API call) and checked before the
  version comparison, the diff classification and any write. Documented in
  `CONTRIBUTING.md` and in the PR template.
- `scripts/release-policy.sh` — the release policy (`skip-release` gate,
  path-based exclusions, macports `PIN_REV`-only installer diff, version shape
  and the 0.0.x automatic-bump cap) extracted from the workflow so it can be
  unit-tested, plus `scripts/test-release-policy.sh`, run by `ci.yml` on
  `ubuntu-latest` against real `git diff` output.

### Fixed

- The automatic bump no longer leaves `CHANGELOG.md` behind `Version.swift`.
  `bump-version.yml` bumped the version constant on every releasable merge but
  never cut a matching release section, so the very first automatic bump
  (v0.1.2) turned `VersionTests.testVersionStringEqualsCurrentRelease` red on
  `main` and on every open PR. The bump step now cuts the `## [<version>]`
  section, reopens an empty `## [Unreleased]` above it and refreshes the compare
  links, through the tested `policy_changelog_cut_release` in
  `scripts/release-policy.sh`. The missing v0.1.2 section is added below.
- `bump-version.yml` no longer fails the run when a merge is correctly
  classified as not releasable. The "no code changes" guard (docs-only,
  `.github/`-only, packaging-only, `PIN_REV`-only changes) used to `exit 1`
  after already refusing the bump, turning a green no-op into a red check on
  the merge; it now finishes successfully, records the reason in the job
  summary and leaves the version and the release workflow alone. Only a genuine
  policy error — an unparsable `Version.swift` or a version outside
  `0.0.x` / `0.1.x` — still fails the workflow.

## [0.1.2] - 2026-09-26

### Added

- Added the OpenCode GitHub Actions agent and automatic repair paths for
  CodeRabbit findings, merge conflicts, and failed pull-request CI.
- Added scheduled retry of CodeRabbit reviews after included-review rate limits.

### Changed

- CodeRabbit review requests are now gated on successful CI for the exact current
  pull-request head, with per-head readiness/request locks reset on every new
  commit so the review/fix loop is idempotent.
- CI can skip the macOS build for documentation-only changes, and CodeRabbit
  linked-issue assessment is enforced as a pre-merge check.

## [0.1.1] - 2026-09-26

### Changed

- Homebrew Cask: `depends_on macos: :monterey` replaces `depends_on :macos`, so
  the cask sets the same macOS floor as the formula and brew refuses an install
  on an older system. The platform requirement itself stays, or brew rejects
  the cask at tap validation.
- Release workflow: the negative check "the cask must not clear quarantine"
  becomes a positive one — the release fails unless the generated cask still
  has exactly one `postflight_steps` block running `/usr/bin/xattr` with
  `args: ["-dr", "com.apple.quarantine", "{{appdir}}/NanoDictate.app"]` and
  still declares `depends_on macos: :monterey`. The "did not become clearing
  all attributes / does not poke spctl" check is kept, but now runs against a
  comment-stripped copy of the cask, so that future prose in the template
  legitimately mentioning those tokens cannot break the guard.
- MacPorts: the architecture test is now a `switch -- ${os.arch}` with an
  explicit `default` branch, so an unsupported architecture reports a clear
  error instead of silently falling back to the Intel tarball. A real smoke
  test replaces the stub commented out as "for a future release" —
  `test.run yes` running `nanodictate --version` against the staged destroot
  copy — and `test.ignore_archs yes` disables MacPorts' own architecture check,
  which compares the `arm`/`i386` vocabulary against the `arm64`/`x86_64`
  binaries and would warn on every install.
- Release workflow: the git identity for the automated commits in this repo was
  `dima <dima@users.noreply.github.com>` and is now
  `kodmial <kodmial@gmail.com>` — the manifest-sync steps, the MacPorts tree,
  `scripts/install-macports.sh` and the tap. `bump-version.yml` now sets the
  same identity.
- Packaging docs: `docs/packaging/homebrew.md`, `docs/packaging/macports.md`
  and `packaging/README.md` are aligned with the templates. The Homebrew guide
  documents the cask postflight and its macOS 12 floor and demotes the manual
  "Open Anyway" / `xattr` steps to troubleshooting; the MacPorts guide drops
  the claim that `port uninstall` removes `/Library/Logs/NanoDictate` and
  explains the `test` phase; `packaging/README.md` records that both packages
  declare a version test which neither runs during install. Documentation only.
- README restructured around a "Quick start" that installs the app bundle via
  `brew install --cask kodmial/nanodictate/nanodictate`, with dedicated upgrade
  and uninstall sections, an "Alternative installation: MacPorts" section, and
  the macOS 12 Monterey-or-newer requirement stated with the other platform
  requirements at the top.

### Fixed

- Homebrew Cask — Gatekeeper no longer blocks the first launch: the
  `postflight_steps` block runs `/usr/bin/xattr` with
  `args: ["-dr", "com.apple.quarantine", "{{appdir}}/NanoDictate.app"]`,
  removing exactly one attribute from the installed bundle, so a plain
  `brew install --cask` needs neither an "Open Anyway" click nor a manual
  `xattr`. The removal is deliberately narrow: not `xattr -cr`, no other xattr
  keys, no `spctl --master-disable` — Gatekeeper stays globally enabled and the
  code signature is untouched, so the bundle keeps its self-signed identity
  and the grants it already has. TCC permissions are separate: macOS asks for
  Microphone and Accessibility on the agent's first run.
- Homebrew Formula: the overreaching `caveats` wording is retired and reworded
  rather than deleted. The two misleading sentences are gone — the blanket
  claim that "Homebrew's download does not set the quarantine attribute, so
  Gatekeeper stays quiet", and the "only *browser* downloads get
  com.apple.quarantine" pointer at a manual `xattr -dr` workaround. What
  survives is scoped to this install path and hedged with an observation: no
  quarantine attribute is set here, so no Gatekeeper dialog is expected on the
  first launch of the binaries in `#{opt_prefix}/bin`, and none has been
  observed. The caveats mention no manual `xattr` or "Open Anyway".
- MacPorts: a LaunchAgent bootstrap failure is now diagnosed — with a GUI
  session present, the concrete launchctl error is printed with the commands to
  inspect and recover the job instead of a generic "it will start at next
  login" message, while a headless or SSH install stays non-fatal and each
  `catch` is scoped to one command. After a successful bootstrap the port runs
  `launchctl print` to confirm launchd really kept the job, since bootstrap can
  return 0 while the job dies at once. The dead `/Library/Logs/NanoDictate`
  cleanup in `pre-deactivate` was removed: the port never creates that
  directory, so it could only ever print a misleading "logs ... removed".

## [0.1.0] - 2026-09-22

### Changed

- README: установка через MacPorts — две команды
  (блок `sudo bash -c '...'`, регистрирующий локальный `file://`-порт, затем
  `sudo port selfupdate && sudo port install nanodictate`)
  вместо однострочного curl-скрипта. Поддерживается override
  `sources.conf` (локальный `file://` источник без `[nosync]`), первая
  команда отказывается работать с уже существующим путём дерева.
  Блоки документации в README (установка и «теневая»
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

[Unreleased]: https://github.com/kodmial/nanodictate/compare/v0.1.15...HEAD
[0.1.15]: https://github.com/kodmial/nanodictate/compare/v0.1.14...v0.1.15
[0.1.14]: https://github.com/kodmial/nanodictate/compare/v0.1.13...v0.1.14
[0.1.13]: https://github.com/kodmial/nanodictate/compare/v0.1.12...v0.1.13
[0.1.12]: https://github.com/kodmial/nanodictate/compare/v0.1.11...v0.1.12
[0.1.11]: https://github.com/kodmial/nanodictate/compare/v0.1.10...v0.1.11
[0.1.10]: https://github.com/kodmial/nanodictate/compare/v0.1.9...v0.1.10
[0.1.9]: https://github.com/kodmial/nanodictate/compare/v0.1.8...v0.1.9
[0.1.8]: https://github.com/kodmial/nanodictate/compare/v0.1.7...v0.1.8
[0.1.7]: https://github.com/kodmial/nanodictate/compare/v0.1.6...v0.1.7
[0.1.6]: https://github.com/kodmial/nanodictate/compare/v0.1.5...v0.1.6
[0.1.5]: https://github.com/kodmial/nanodictate/compare/v0.1.4...v0.1.5
[0.1.4]: https://github.com/kodmial/nanodictate/compare/v0.1.3...v0.1.4
[0.1.3]: https://github.com/kodmial/nanodictate/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/kodmial/nanodictate/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/kodmial/nanodictate/compare/v0.1.0...v0.1.1
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
