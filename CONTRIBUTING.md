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
```

Тесты — исполняемый таргет `NanoDictateCoreTests`; раннер печатает сводку и возвращает ненулевой код при падениях. CI гоняет те же команды (`.github/workflows/ci.yml`, `swift 5.10.1`, `macos-latest`).

## Стиль коммитов

Conventional Commits с областью: `feat(agent): …`, `fix(agent): …`, `refactor(stt): …`, `docs: …`, `merge(autostop): …`. Сообщения — на русском или английском, как в истории проекта. Один коммит — одна логическая правка.

## Pull Request

- Ветка от `main`, PR в `main`.
- Опиши что и зачем, укажи как проверял (`swift build` / `swift run NanoDictateCoreTests`).
- Не коммить секреты, ключи и `~/.config/nanodictate/`.
- TCC/Accessibility/микрофон затрагиваешь — подписью только через MCP `dictation_deploy` (см. `SECURITY.md`), `codesign` вручную не трогай.

## Issues

Перед созданием проверь открытые issues/PR. Для багов используй шаблон `bug_report.md`.
