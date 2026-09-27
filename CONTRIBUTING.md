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
bash scripts/test-release-policy.sh   # политика релизов release-pr.yml (чистый bash, где угодно)
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

Every merge into `main` is evaluated by `.github/workflows/release-pr.yml` ("Release PR"), which maintains the single automated Release PR from what has actually landed in `main`. The decision logic lives in `scripts/release-policy.sh` and is covered by `scripts/test-release-policy.sh`.

- **No version bumps in feature PRs** — ordinary PRs never touch `Sources/NanoDictateCore/Version.swift` or `.release-please-manifest.json`. The `version-ownership` CI job fails such PRs. The next version is chosen once, at release time, so concurrent PRs can merge in any order without racing or picking duplicate versions.
- **Automatic Release PR** — a merge with real code changes makes release-please create or update the one Release PR (`release-please--branches--main`) with the next patch version (`0.0.N` → `0.0.(N+1)`, `0.1.x` likewise; `feat:` bumps the patch too, never the minor). The workflow then cuts the matching `## [<version>]` section in `CHANGELOG.md` on that branch (reopening an empty `## [Unreleased]` above it and refreshing the compare links), because `VersionTests.testVersionStringEqualsCurrentRelease` requires the two files to agree. Merging the Release PR publishes the release through `release.yml` (tag + GitHub Release + binaries); the post-release job opens a `chore/release-manifests-v<version>` PR with the regenerated Homebrew/MacPorts manifests and the installer pin. Nothing is ever pushed to `main` directly — every change arrives through a pull request.
- **Path-based exclusions** — a diff limited to `Version.swift`, the release-please config/manifest, `CHANGELOG.md`, `README.md`, `SECURITY.md`, `LICENSE`, `docs/`, `.github/`, `.githooks/`, the root meta-dotfiles and packaging files is classified as non-releasable: no Release PR update. Such a merge would otherwise publish an empty release.
- **`skip-release` label** — a PR that must merge without triggering a Release PR update gets the `skip-release` label ("Merge this PR without bumping or publishing a NanoDictate version."). It is an explicit override, checked before anything else: a labeled PR never triggers a Release PR update, whatever its file paths contain. Its changes still ride along with the next Release PR. Add the label **before** merging — it is read from the merge event payload, so removing it afterwards changes nothing.
- **Automatic bump limit** — automatic bumps in the `0.0.x` series stop at `0.0.100`; the `0.1.x` series may grow past that. A future series (e.g. `0.1.x`) is started through the Release PR, not through a feature PR.

Every no-release outcome finishes the workflow successfully (a green no-op, with the reason in the job summary). Only a broken version fails it: a `Version.swift` that cannot be parsed, or a version outside `0.0.x` / `0.1.x`. Unrelated labels (`chore`, `documentation`, `ci`, ...) never skip a release implicitly — the release decision stays explicit.

Conventional Commits matter for versioning: release-please proposes the next version from the conventional commits (`feat:`, `fix:`, ...) merged since the last release, so keep the `type(scope): …` style. A merge with no conventional commits is a green no-op (no Release PR proposed).

Branch protection: `main` requires a pull request before merging, and no automation needs a direct-push bypass. The Release PR and the manifests PR are ordinary PAT-authored PRs (`RELEASE_PR_TOKEN`, falling back to the existing `TAP_PAT` repo secret), so required CI runs on them before merge. Without either secret the automation falls back to `GITHUB_TOKEN` with a warning — the PRs are still created, but CI will not trigger on them.

## Issues

Перед созданием проверь открытые issues/PR. Для багов используй шаблон `bug_report.md`.
