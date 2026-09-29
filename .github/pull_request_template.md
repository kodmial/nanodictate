## Что сделано

-

## Почему

-

## Как проверял

- [ ] `scripts/build-rust-core.sh --release` + `swift build -Xlinker "$(pwd)/rust/target/release/libnanodictate_core.a"` (debug/release)
- [ ] `swift run -Xlinker "$(pwd)/rust/target/release/libnanodictate_core.a" NanoDictateCoreTests`
- [ ] Ручная проверка (опиши):

## Чек-лист

- [ ] Ветка от `main`, цель — `main`
- [ ] Нет секретов/ключей в diff
- [ ] TCC/Accessibility/микрофон не затронуты или подписано через MCP `dictation_deploy`
- [ ] Доки/README обновлены, если менялось поведение
- [ ] Release: this PR does NOT bump the version (the automated Release PR owns `Version.swift`; see `CONTRIBUTING.md` → Releases). If it must merge WITHOUT triggering a Release PR update, add the `skip-release` label before merging.

Связанные issues: Closes #
