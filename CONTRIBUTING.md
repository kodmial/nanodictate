# Contributing

## Сборка

```sh
swift build                 # debug
swift build -c release      # release
```

Требуется Swift 5.7+, macOS 12+. Если `swift build` не парсит `Package.swift` (сломан CLT) — задай `SWIFT_TOOLCHAIN` (см. раздел `SWIFT_TOOLCHAIN` в README).

MCP-сервер деплоя (опционально, Node 22+):

```sh
cd mcp/nanodictate-deploy-mcp-server
npm ci && npm run build
npm test   # build + node --test
```

## Тесты

```sh
swift run NanoDictateCoreTests   # не `swift test` — таргет исполняемый
bash scripts/test-release-policy.sh   # политика релизов bump-version.yml (чистый bash, где угодно)
```

Тесты — исполняемый таргет `NanoDictateCoreTests`; раннер печатает сводку и возвращает ненулевой код при падениях. CI гоняет те же команды (`.github/workflows/ci.yml`, Swift 6.1, `macos-15`).

## Стиль коммитов

Conventional Commits с областью: `feat(agent): …`, `fix(agent): …`, `refactor(stt): …`, `docs: …`, `merge(autostop): …`. Сообщения — на русском или английском, как в истории проекта. Один коммит — одна логическая правка.

## Pull Request

- Ветка от `main`, PR в `main`.
- Опиши что и зачем, укажи как проверял (`swift build` / `swift run NanoDictateCoreTests`).
- Не коммить секреты, ключи и `~/.config/nanodictate/`.
- TCC/Accessibility/микрофон затрагиваешь — подписью только через MCP `dictation_deploy` (см. `SECURITY.md`), `codesign` вручную не трогай.

## Releases

Every merge into `main` is evaluated by `.github/workflows/bump-version.yml` ("Bump version"), which decides whether the merge publishes a new NanoDictate version. The decision logic lives in `scripts/release-policy.sh` and is covered by `scripts/test-release-policy.sh`.

- **Automatic bump** — a merge with real code changes that did not bump `Sources/NanoDictateCore/Version.swift` gets the patch version bumped (`0.0.N` → `0.0.(N+1)`) and the Release workflow is dispatched for the new version. Automatic bumps stop at `0.0.100`; the `0.1.x` series may grow past that. The same commit also cuts the matching `## [<version>]` section in `CHANGELOG.md` (reopening an empty `## [Unreleased]` above it and refreshing the compare links), because `VersionTests.testVersionStringEqualsCurrentRelease` requires the two files to agree: a PR that bumps `Version.swift` by hand must add the release section to `CHANGELOG.md` in the same change, or CI stays red.
- **Path-based exclusions** — a diff limited to `Version.swift`, `CHANGELOG.md`, `README.md`, `SECURITY.md`, `LICENSE`, `docs/`, `.github/`, `.githooks/`, the root meta-dotfiles and packaging files is classified as non-releasable: no bump, no release. Such a merge would otherwise publish an empty release.
- **`skip-release` label** — a PR that must merge without publishing a version gets the `skip-release` label ("Merge this PR without bumping or publishing a NanoDictate version."). It is an explicit override, checked before anything else: a labeled PR is never bumped, never committed to, and never dispatched to the Release workflow, whatever its file paths contain. Add the label **before** merging — it is read from the merge event payload, so removing it afterwards changes nothing.

Every no-release outcome finishes the workflow successfully (a green no-op, with the reason in the job summary). Only a broken version fails it: a `Version.swift` that cannot be parsed, or a version outside `0.0.x` / `0.1.x`. Unrelated labels (`chore`, `documentation`, `ci`, ...) never skip a release implicitly — the release decision stays explicit.

One caveat: the merge itself also triggers the Release workflow through its own `push` trigger. That is harmless for a normal `skip-release` PR (the version is unchanged, so the Release workflow sees an already-published version and no-ops), but a PR that both bumps `Version.swift` and carries `skip-release` would still publish its own version. Use the label for merges that do not bump the version.

## Issues

Перед созданием проверь открытые issues/PR. Для багов используй шаблон `bug_report.md`.
