# Release notes pipeline

One canonical release-note document per version, generated before publication
and reused everywhere. This is the contract behind the `CHANGELOG.md` version
sections and the GitHub Release bodies.

## Flow (single source of truth)

```text
merged PR metadata (conventional subject + `Release note:` footer)
  -> canonical version notes (rendered once, reviewed on the Release PR)
  -> CHANGELOG.md `## [<version>]` section
  -> GitHub Release body (same bytes, or whitespace-normalized equal)
```

Rules:

1. Release notes are visible on the Release PR **before** it is merged. A release
   is never published first and documented afterward.
2. `release-please-config.json` keeps the `changelog-sections` mapping prepared
   (conventional types to Keep a Changelog sections), but native changelog
   updates stay disabled (`skip-changelog: true`) until the Release PR
   producer integrates the footer-aware renderer (`scripts/release-notes.sh`):
   it must apply explicit `Release note:` text and honor `Release note: None`
   suppression. No scraping of free-form PR prose at publication time.
3. The GitHub Release body must be the already-reviewed canonical section
   extracted from the release commit — never an independently generated text.
   A link to the full changelog or comparison may be appended after the
   notes, never instead of them. The `gate --body-file` check enforces this
   equivalence when wired, but publication wiring is a pending follow-up:
   the external Continuum workflow does not yet consume the canonical
   section, and this repository does not publish a real release body through
   `release_notes_gate_publish` with `--body-file`, so the fail-closed
   guarantee does not yet apply at publication time.
4. Re-running the pipeline over the same merged history produces byte-identical
   notes: entries deduplicate by commit SHA, prior entries keep their order,
   and already-released sections are never rewritten.

## Canonical renderer and gate

`scripts/release-notes.sh` is the single canonical implementation (sourceable
library plus CLI). `scripts/test-release-notes.sh` is its regression suite —
run it for any pipeline change:

```sh
bash scripts/test-release-notes.sh
```

Key commands:

```sh
# Render a canonical body from merged-PR entries (see input contract below):
bash scripts/release-notes.sh render < entries.txt

# Extract the canonical section for a version (this is the release body):
bash scripts/release-notes.sh extract 0.1.15 < CHANGELOG.md

# Fail-closed publication gate (missing/empty section, version mismatch,
# body divergence all fail):
bash scripts/release-notes.sh gate --version 0.1.15 --swift-version "$(grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+' Sources/NanoDictateCore/Version.swift)" \
  --releasable 1 --body-file release-body.md < CHANGELOG.md
```

## PR input contract

For every releasable PR, the pipeline needs a deterministic, human-readable
description of the user/developer impact — not a repeated commit subject and
never a dump of the PR body, review threads, or `Co-authored-by` lines.

Add a footer to the PR description (and keep it in the squash-merge commit
message so it survives as repository evidence):

```text
Release note: <one or two sentences describing the user/developer impact>
```

Semantics:

- `Release note: <text>` — explicit user/developer-facing description. This is
  required whenever the PR changes behavior, defaults, performance, UI, CLI,
  packaging installation, or the release process in a user-visible way.
- `Release note: None` — intentionally no user-facing note (pure refactor with
  no behavior change, test-only, CI-only, docs-only). The entry is excluded
  from the rendered notes.
- Footer absent — controlled fallback to the cleaned conventional-commit
  subject (the `type(scope):` prefix is stripped). Acceptable only when the
  subject already describes the impact; prefer an explicit note.

Categorization follows Keep a Changelog and is derived from the conventional
type (aligned with `changelog-sections` in `release-please-config.json`):

| Conventional type | Section    |
| ----------------- | ---------- |
| `feat`            | Added      |
| `fix`             | Fixed      |
| `perf`, `refactor`, `revert` | Changed |
| `security`        | Security   |
| `deprecate`       | Deprecated |
| `remove`          | Removed    |
| `docs`, `style`, `test`, `build`, `ci`, `chore` | hidden (never rendered) |

Only sections with entries are rendered, in canonical Keep a Changelog order.
Internal release plumbing, manifest synchronization, pure formatting and
generated-version commits never appear as user-facing changes unless they
materially affect users (for example, a fix for a stale distribution
channel). A PR that must merge without touching the release flow uses the
`skip-release` label instead — such entries are always excluded from notes.

## Publication gate (fail closed)

Publication refuses to proceed when:

- the `## [<version>]` section is missing from `CHANGELOG.md`;
- the section is empty (header-only, the v0.1.7 failure mode) while releasable
  changes exist;
- the section version disagrees with `Sources/NanoDictateCore/Version.swift`;
- the would-be GitHub Release body differs from the canonical section beyond
  whitespace normalization.

## History repair policy

Releases v0.1.7 through v0.1.15 were backfilled from merged-PR and commit
evidence after the Release PR migration reduced them to one-line summaries.
Backfilled notes describe only impact present in that evidence — no invented
rationale. Tags, release assets and artifact checksums are never rewritten;
only `CHANGELOG.md` sections and (where supported) release descriptions are
repaired to match the canonical text.

## Preserved release-policy semantics

This pipeline does not change: `skip-release`, no direct automated push to
protected `main`, Release PR ownership of version changes, patch-only
automatic versioning, the release-manifests PR flow, the candidate packaging
smoke gate, post-publish production smoke, or rerun safety. The release
decision itself still lives in `scripts/release-policy.sh` (tested by
`scripts/test-release-policy.sh`); release notes only describe what that
policy already classified as releasable.
