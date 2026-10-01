# Contributing

Thanks for contributing to NanoDictate. Keep changes focused, verifiable, and easy to review.

## Requirements

- macOS 12 or later.
- Swift 5.7 or later for local development.
- CI currently validates with Swift 6.1 on `macos-15`.
- Follow the repository instructions in `AGENTS.md` when using a coding agent.

## Build and test

For every production-code change, run:

```sh
scripts/build-rust-core.sh --release   # builds rust/target/release/libnanodictate_core.a first
swift build -Xlinker "$(pwd)/rust/target/release/libnanodictate_core.a"                 # debug
swift build -c release -Xlinker "$(pwd)/rust/target/release/libnanodictate_core.a"     # release
swift run -Xlinker "$(pwd)/rust/target/release/libnanodictate_core.a" NanoDictateCoreTests   # not `swift test` — executable target
```

`NanoDictateCoreTests` is an executable test runner, so do not use `swift test`. It exits non-zero when a test fails.

CI additionally runs formatting and lint checks, release-policy validation, version-ownership checks, and enforces at least 80% line coverage for `NanoDictateCore`. New or changed behavior must include focused automated tests. Do not weaken tests or coverage checks to make CI pass.

For release-policy changes, also run:

```sh
bash scripts/test-release-policy.sh
```

If a required check cannot run in your environment, state exactly which check was not run and why.

## Optional deployment MCP server

Changes under `mcp/nanodictate-deploy-mcp-server` require Node.js 22 or later:

```sh
cd mcp/nanodictate-deploy-mcp-server
npm ci
npm run build
npm test
```

## Commits

Use Conventional Commits and write commit messages in English. Prefer one logical change per commit.

Examples:

```text
feat(agent): add status reporting
fix(stt): handle empty transcription response
refactor(audio): simplify buffer lifecycle
docs: clarify local verification
```

## Pull requests

- Branch from `main` and target `main`.
- Keep the PR scoped to one coherent change.
- Explain what changed, why it changed, and how it was verified (for example, `swift build -Xlinker "$(pwd)/rust/target/release/libnanodictate_core.a"` / `swift run -Xlinker "$(pwd)/rust/target/release/libnanodictate_core.a" NanoDictateCoreTests`).
- Add or update focused tests for changed behavior.
- Never commit secrets, credentials, or local configuration such as `~/.config/nanodictate/`.
- Do not change `Sources/NanoDictateCore/Version.swift` or `.release-please-manifest.json` in ordinary feature or fix PRs; release automation owns version changes.
- For TCC, Accessibility, microphone, signing, or deployment changes, follow `SECURITY.md` and the relevant project documentation.

## Releases

Release automation is owned by `.github/workflows/continuum-tech-swift-release-pr.yml` and `scripts/release-policy.sh`.

Ordinary feature and fix PRs do not bump versions. After releasable changes land in `main`, release-please creates or updates the automated Release PR. Merging that Release PR publishes the release through `release.yml`; post-release automation then prepares packaging-manifest updates.

A PR whose changes must merge without updating the Release PR can use the `skip-release` label. Apply it before merge. Path-only documentation, repository metadata, and packaging changes may also be classified as non-releasable by the release policy.

Do not bypass the release workflow with manual version bumps or direct pushes to `main`.

## Issues

Before opening a new issue, check existing issues and pull requests for duplicates. Use the bug-report template for defects and include enough information to reproduce the problem.
