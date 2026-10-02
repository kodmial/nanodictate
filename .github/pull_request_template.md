## Что сделано

-

## Почему

-

## Как проверял

- [ ] `scripts/build-rust-core.sh --release` (use the absolute archive path it prints; default `rust/target/release/libnanodictate_core.a` when `CARGO_TARGET_DIR` is unset) + `swift build -Xlinker "$ARCHIVE"` (debug/release)
- [ ] `swift run -Xlinker "$ARCHIVE" NanoDictateCoreTests`
- [ ] Ручная проверка (опиши):

## Release note

<!-- One or two sentences describing the user/developer impact, or `None` for
     intentionally note-free changes (pure refactor, tests, CI, docs). Without
     this footer the cleaned commit subject is used as a fallback.
     See docs/release-notes.md for the contract. -->

Release note:

## Чек-лист

- [ ] Ветка от `main`, цель — `main`
- [ ] Нет секретов/ключей в diff
- [ ] TCC/Accessibility/микрофон не затронуты или подписано через MCP `dictation_deploy`
- [ ] Доки/README обновлены, если менялось поведение
- [ ] Release: this PR does NOT bump the version (the automated Release PR owns `Version.swift`; see `CONTRIBUTING.md` → Releases). If it must merge WITHOUT triggering a Release PR update, add the `skip-release` label before merging.

Связанные issues: Closes #
