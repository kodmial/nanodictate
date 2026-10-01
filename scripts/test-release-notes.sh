#!/usr/bin/env bash
# Regression suite for scripts/release-notes.sh — the canonical release-note
# renderer and publication gate.
#
# Runs on any bash host (no Swift, no network):
#
#   bash scripts/test-release-notes.sh
#
# Exits 0 when every case passes, 1 otherwise. Covers the release pipeline
# contract:
#   1. one releasable PR -> one non-empty version section;
#   2. multiple releasable PRs accumulated into one Release PR;
#   3. Added/Changed/Fixed/Security categorization;
#   4. internal/non-user-facing release plumbing excluded;
#   5. `skip-release` PR excluded;
#   6. Release PR update rerun is idempotent;
#   7. an additional merged PR joins without duplicating prior entries;
#   8. missing/empty canonical notes fail the publication gate;
#   9. the GitHub Release body equals the canonical version section
#      (byte-for-byte or normalization-equivalent);
#   10. a Version.swift / CHANGELOG version mismatch fails;
#   11. historical already-released sections stay unchanged by a new release;
#   12. the v0.1.7 empty-section failure mode cannot recur.
#
# Temporary fixtures live in a per-run directory under .opencode-tmp/ inside
# the worktree (never in /tmp) and are removed on exit.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel) || exit 1
# shellcheck source=scripts/release-notes.sh
source "${REPO_ROOT}/scripts/release-notes.sh"

mkdir -p "${REPO_ROOT}/.opencode-tmp" || exit 1
TMP_DIR=$(mktemp -d "${REPO_ROOT}/.opencode-tmp/release-notes-tests.XXXXXX") || exit 1
PASSED=0
FAILED=0

cleanup() {
  rm -rf "$TMP_DIR"
  rmdir "${REPO_ROOT}/.opencode-tmp" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  FAILED=$(( FAILED + 1 ))
  printf 'not ok - %s\n' "$1"
  [[ $# -lt 2 ]] || printf '  %s\n' "$2"
}

pass() {
  PASSED=$(( PASSED + 1 ))
  printf 'ok - %s\n' "$1"
}

assert_eq() {
  if [[ "$2" == "$3" ]]; then
    pass "$1"
  else
    fail "$1" "expected '$2', got '$3'"
  fi
}

assert_ok() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name" "command failed: $*"; fi
}

assert_not_ok() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then fail "$name" "command unexpectedly succeeded: $*"; else pass "$name"; fi
}

assert_contains() {
  local name=$1 haystack=$2 needle=$3
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name" "did not contain '$needle' in: $haystack"
  fi
}

assert_not_contains() {
  local name=$1 haystack=$2 needle=$3
  if [[ "$haystack" != *"$needle"* ]]; then
    pass "$name"
  else
    fail "$name" "unexpectedly contained '$needle' in: $haystack"
  fi
}

# --- 1. One releasable PR -> one non-empty version section -------------------
# A releasable fix with an explicit human-readable release note renders a
# Fixed section describing the user impact, not the raw commit subject.

ONE=$(printf 'caf7d52|fix(audio): reuse buffers, cut locks|Audio hot path reuses capture buffers and shortens lock hold time|71|')
BODY_ONE=$(printf '%s\n' "$ONE" | release_notes_render)
assert_contains '1: single fix renders a Fixed section' "$BODY_ONE" '### Fixed'
assert_contains '1: explicit release note wins over the subject' \
  "$BODY_ONE" 'Audio hot path reuses capture buffers'
assert_not_contains '1: raw subject is not repeated' \
  "$BODY_ONE" 'fix(audio)'
assert_contains '1: commit reference is kept' "$BODY_ONE" 'caf7d52'
assert_contains '1: PR reference is kept' "$BODY_ONE" '#71'
if printf '%s' "$BODY_ONE" | release_notes_section_is_empty; then
  fail '1: rendered body is non-empty'
else
  pass '1: rendered body is non-empty'
fi

# A releasable PR without an explicit note falls back to the cleaned subject.
FALLBACK=$(printf '9302009|fix: Backpressure + coalescing for live STT||72|')
BODY_FALLBACK=$(printf '%s\n' "$FALLBACK" | release_notes_render)
assert_contains '1: absent note falls back to the cleaned subject' \
  "$BODY_FALLBACK" 'Backpressure + coalescing for live STT'

# Full PR bodies, review chatter and Co-authored-by lines never enter the
# notes: only the subject and the explicit note footer are rendered.
CHATTER=$(printf '9302009|fix: Backpressure + coalescing for live STT|Coalesced drain loop|72|')
BODY_CHATTER=$(printf '%s\n' "$CHATTER" | release_notes_render)
assert_not_contains '1: Co-authored-by lines cannot leak into notes' \
  "$BODY_CHATTER" 'Co-authored-by'

# --- 2. Multiple releasable PRs accumulate into one Release PR ---------------
# Three releasable changes merged before the pending Release PR is published
# all land in the single canonical body.

THREE=$'caf7d52|fix(audio): reuse buffers, cut locks|Audio hot path reuses capture buffers|71|\n7ab2228|fix(stt): default OpenAI model now gpt-transcribe|Default transcription model is now gpt-transcribe|70|\nc779afd|feat(stt): add live benchmark harness|Live STT benchmark with fixture WAV overlays|69|'
BODY_THREE=$(printf '%s\n' "$THREE" | release_notes_render)
assert_contains '2: first change is present' "$BODY_THREE" 'Audio hot path'
assert_contains '2: second change is present' "$BODY_THREE" 'gpt-transcribe'
assert_contains '2: third change is present' "$BODY_THREE" 'benchmark'
assert_eq '2: one body carries all three changes' \
  '3' "$(printf '%s\n' "$BODY_THREE" | grep -c '^- ')"
assert_contains '2: feature lands under Added' "$BODY_THREE" '### Added'
assert_contains '2: fixes land under Fixed' "$BODY_THREE" '### Fixed'

# --- 3. Added/Changed/Fixed/Security categorization --------------------------
# Sections render in Keep a Changelog order; only non-empty sections appear.

CATEGORIES=$'a1|feat(stt): model capabilities|Model capability negotiation|1|\nb2|perf(audio): cut lock hold time|Shorter audio lock hold time|2|\nc3|fix(mic): wait for live capture|Ready cue waits for live capture|3|\nd4|security(auth): rotate gateway token|Gateway token rotation|4|'
BODY_CAT=$(printf '%s\n' "$CATEGORIES" | release_notes_render)
assert_contains '3: feat renders as Added' "$BODY_CAT" '### Added'
assert_contains '3: perf renders as Changed' "$BODY_CAT" '### Changed'
assert_contains '3: fix renders as Fixed' "$BODY_CAT" '### Fixed'
assert_contains '3: security renders as Security' "$BODY_CAT" '### Security'
assert_not_contains '3: empty Deprecated is omitted' "$BODY_CAT" '### Deprecated'
assert_not_contains '3: empty Removed is omitted' "$BODY_CAT" '### Removed'
# Canonical order: Added < Changed < Fixed < Security.
ORDER=$(printf '%s\n' "$BODY_CAT" | grep '^### ' | tr '\n' ' ')
assert_eq '3: sections follow Keep a Changelog order' \
  '### Added ### Changed ### Fixed ### Security ' "$ORDER"

# --- 4. Internal release plumbing is excluded ---------------------------------
# Manifest syncs, version bumps, CI-only and docs-only commits must not appear
# as user-facing changes.

PLUMBING=$'p1|chore(release): update v0.1.15 manifests||| \np2|fix(packaging): restore v0.1.14 post-release state||81| \np3|docs: clarify local verification||| \np4|ci: enforce 80 percent core coverage||| \nr1|fix(audio): reuse buffers, cut locks|Audio hot path|71|'
BODY_PLUMB=$(printf '%s\n' "$PLUMBING" | release_notes_render)
assert_contains '4: user-facing change survives' "$BODY_PLUMB" 'Audio hot path'
assert_not_contains '4: manifest sync is excluded' "$BODY_PLUMB" 'manifests'
assert_not_contains '4: docs change is excluded' "$BODY_PLUMB" 'clarify local'
assert_not_contains '4: ci change is excluded' "$BODY_PLUMB" '80 percent'
# A docs/ci-only set renders no user-facing notes at all.
NOTHING=$(printf 'p1|chore(release): update manifests|||\n' | release_notes_render)
assert_eq '4: plumbing-only input renders nothing' '' "$NOTHING"

# An explicit `Release note: None` marks an intentionally note-free change.
NONE_ENTRY=$(printf 'n1|fix(build): quiet xyz warning|None|90|')
BODY_NONE=$(printf '%s\n' "$NONE_ENTRY" | release_notes_render)
assert_eq '4: explicit None renders nothing' '' "$BODY_NONE"
NONE_MIXED=$'n1|fix(build): quiet xyz warning|None|90|\nr1|fix(audio): reuse buffers|Audio hot path|71|'
BODY_NONE_MIXED=$(printf '%s\n' "$NONE_MIXED" | release_notes_render)
assert_not_contains '4: None entry stays out of mixed notes' \
  "$BODY_NONE_MIXED" 'quiet xyz'
assert_contains '4: real entry still renders alongside None' \
  "$BODY_NONE_MIXED" 'Audio hot path'

# --- 5. skip-release PR excluded ----------------------------------------------
SKIP=$'s1|feat(stt): experimental flag|Experimental flag|91|skip-release\nr1|fix(audio): reuse buffers|Audio hot path|71|'
BODY_SKIP=$(printf '%s\n' "$SKIP" | release_notes_render)
assert_not_contains '5: skip-release change is excluded' \
  "$BODY_SKIP" 'Experimental flag'
assert_contains '5: ordinary change still renders' "$BODY_SKIP" 'Audio hot path'
# (The near-miss entry must render: a non-empty body proves the label did not skip.)
assert_contains '5: near-miss label keeps the entry' \
  "$(printf 's1|feat(stt): x|Visible||no-skip-release\n' | release_notes_render)" \
  'Visible'

# --- 6. Release PR update rerun is idempotent ---------------------------------
# Re-running the renderer over the same merged history yields byte-identical
# notes: no duplicated entries, sections, or bullets.

RERUN_A=$(printf '%s\n' "$THREE" | release_notes_render)
RERUN_B=$(printf '%s\n' "$THREE" | release_notes_render)
assert_eq '6: rerun over the same history is byte-identical' "$RERUN_A" "$RERUN_B"
# A repeated sha inside one run renders once.
DUP=$'caf7d52|fix(audio): reuse buffers|Audio hot path|71|\ncaf7d52|fix(audio): reuse buffers|Audio hot path|71|'
assert_eq '6: a duplicated sha renders one bullet' \
  '1' "$(printf '%s\n' "$DUP" | release_notes_render | grep -c '^- ')"

# --- 7. A new merged PR joins without duplicating prior entries --------------
# The Release PR update path re-renders the accumulated set; prior entries
# keep their text and order, the newcomer is added exactly once.

BEFORE=$'caf7d52|fix(audio): reuse buffers|Audio hot path|71|\n7ab2228|fix(stt): default model|Default model gpt-transcribe|70|'
AFTER=${BEFORE}$'\nc779afd|feat(stt): benchmark|Live benchmark|69|'
BODY_BEFORE=$(printf '%s\n' "$BEFORE" | release_notes_render)
BODY_AFTER=$(printf '%s\n' "$AFTER" | release_notes_render)
assert_contains '7: prior entry text is unchanged' "$BODY_AFTER" 'Audio hot path'
assert_contains '7: newcomer is added' "$BODY_AFTER" 'Live benchmark'
assert_eq '7: three entries render three bullets' \
  '3' "$(printf '%s\n' "$BODY_AFTER" | grep -c '^- ')"
assert_eq '7: prior bullets are not duplicated' \
  '1' "$(printf '%s\n' "$BODY_AFTER" | grep -c 'Audio hot path')"

# --- 8. Missing/empty canonical notes fail the publication gate ---------------
# Fixture changelog: released 0.9.0 plus an Unreleased block.

FIXTURE_CHANGELOG=$'# Changelog\n\n## [Unreleased]\n\n## [0.9.0] - 2026-09-26\n\n### Fixed\n\n- Old entry ([`abc`](https://github.com/kodmial/nanodictate/commit/abc))\n'
assert_not_ok '8: missing version section fails the gate' \
  release_notes_gate_publish 0.9.1 0.9.1 1 <<< "$FIXTURE_CHANGELOG"
# An empty section with releasable changes fails (the v0.1.7 failure mode).
EMPTY_CHANGELOG=$'# Changelog\n\n## [Unreleased]\n\n## [0.9.1] - 2026-09-27\n\n## [0.9.0] - 2026-09-26\n\n### Fixed\n\n- Old entry\n'
assert_not_ok '8: empty section with releasable changes fails the gate' \
  release_notes_gate_publish 0.9.1 0.9.1 1 <<< "$EMPTY_CHANGELOG"
# The same empty section with zero releasable changes is a legitimate no-op.
assert_ok '8: empty section with no releasable changes passes' \
  release_notes_gate_publish 0.9.1 0.9.1 0 <<< "$EMPTY_CHANGELOG"
# A populated section passes.
FULL_CHANGELOG=$'# Changelog\n\n## [Unreleased]\n\n## [0.9.1] - 2026-09-27\n\n### Fixed\n\n- Audio hot path\n\n## [0.9.0] - 2026-09-26\n\n### Fixed\n\n- Old entry\n'
assert_ok '8: populated section passes the gate' \
  release_notes_gate_publish 0.9.1 0.9.1 1 <<< "$FULL_CHANGELOG"

# --- 9. Release body equals the canonical section -----------------------------
SECTION_FILE="${TMP_DIR}/section.md"
BODY_FILE="${TMP_DIR}/body.md"
printf '%s' "$FULL_CHANGELOG" | release_notes_extract_section 0.9.1 > "$SECTION_FILE"
cp "$SECTION_FILE" "$BODY_FILE"
assert_ok '9: byte-identical body passes' \
  release_notes_gate_publish 0.9.1 0.9.1 1 "$BODY_FILE" <<< "$FULL_CHANGELOG"
# Normalization-equivalent (trailing whitespace, trailing blank lines) passes.
printf '%s   \n\n\n' "$(cat "$SECTION_FILE")" > "$BODY_FILE"
assert_ok '9: normalization-equivalent body passes' \
  release_notes_gate_publish 0.9.1 0.9.1 1 "$BODY_FILE" <<< "$FULL_CHANGELOG"
# A divergent body (the old static placeholder) fails.
printf 'Release v0.9.1. See CHANGELOG.md for the full release notes.\n' > "$BODY_FILE"
assert_not_ok '9: placeholder body fails' \
  release_notes_gate_publish 0.9.1 0.9.1 1 "$BODY_FILE" <<< "$FULL_CHANGELOG"
printf '## [0.9.1] - 2026-09-27\n\n### Fixed\n\n- Something else entirely\n' > "$BODY_FILE"
assert_not_ok '9: divergent body fails' \
  release_notes_gate_publish 0.9.1 0.9.1 1 "$BODY_FILE" <<< "$FULL_CHANGELOG"

# --- 10. Version.swift / CHANGELOG mismatch fails ------------------------------
assert_not_ok '10: version mismatch fails the gate' \
  release_notes_gate_publish 0.9.1 0.9.2 1 <<< "$FULL_CHANGELOG"
assert_ok '10: matching versions pass' \
  release_notes_gate_publish 0.9.1 0.9.1 1 <<< "$FULL_CHANGELOG"
# first-version agrees with the Swift test's header selection.
assert_eq '10: first-version selects the header after Unreleased' \
  '0.9.1' "$(printf '%s' "$FULL_CHANGELOG" | release_notes_first_version)"

# --- 11. Historical sections stay unchanged by a new release ------------------
# Cutting a new release section must not rewrite already-released history:
# the bytes of every older section are identical before and after.

OLD_SECTION_BEFORE=$(printf '%s' "$FULL_CHANGELOG" | release_notes_extract_section 0.9.0)
NEW_CHANGELOG=$'# Changelog\n\n## [Unreleased]\n\n## [0.9.2] - 2026-09-28\n\n### Added\n\n- Brand new thing\n\n## [0.9.1] - 2026-09-27\n\n### Fixed\n\n- Audio hot path\n\n## [0.9.0] - 2026-09-26\n\n### Fixed\n\n- Old entry\n'
OLD_SECTION_AFTER=$(printf '%s' "$NEW_CHANGELOG" | release_notes_extract_section 0.9.0)
assert_eq '11: older section bytes are unchanged by a new release' \
  "$OLD_SECTION_BEFORE" "$OLD_SECTION_AFTER"
MID_BEFORE=$(printf '%s' "$FULL_CHANGELOG" | release_notes_extract_section 0.9.1)
MID_AFTER=$(printf '%s' "$NEW_CHANGELOG" | release_notes_extract_section 0.9.1)
assert_eq '11: intermediate section bytes are unchanged by a newer release' \
  "$MID_BEFORE" "$MID_AFTER"

# --- 12. No recurrence of the v0.1.7 empty-section failure mode ---------------
# v0.1.7 shipped as a bare header with no notes. The gate must refuse such a
# section whenever releasable changes exist, and the section-emptiness probe
# must flag header-only sections.

V017_SHAPE=$'# Changelog\n\n## [Unreleased]\n\n## [0.1.7] - 2026-09-27\n\n## [0.1.6] - 2026-09-27\n\n### Changed\n\n- Something\n'
if printf '%s' "$V017_SHAPE" | release_notes_extract_section 0.1.7 | release_notes_section_is_empty; then
  pass '12: header-only section is detected as empty'
else
  fail '12: header-only section is detected as empty'
fi
assert_not_ok '12: header-only section fails the gate with releasable changes' \
  release_notes_gate_publish 0.1.7 0.1.7 1 <<< "$V017_SHAPE"
# A repaired section (real entries) passes.
REPAIRED=$'# Changelog\n\n## [Unreleased]\n\n## [0.1.7] - 2026-09-27\n\n### Added\n\n- Model-aware STT capabilities\n\n## [0.1.6] - 2026-09-27\n\n### Changed\n\n- Something\n'
if printf '%s' "$REPAIRED" | release_notes_extract_section 0.1.7 | release_notes_section_is_empty; then
  fail '12: repaired section is detected as non-empty'
else
  pass '12: repaired section is detected as non-empty'
fi
assert_ok '12: repaired section passes the gate' \
  release_notes_gate_publish 0.1.7 0.1.7 1 <<< "$REPAIRED"

# --- Repository self-checks ----------------------------------------------------
# The repository's own CHANGELOG must satisfy the same invariants: the first
# release header matches Version.swift, and the current version section is
# non-empty (a release with releasable changes is never header-only).

REPO_SWIFT=$(grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+' "${REPO_ROOT}/Sources/NanoDictateCore/Version.swift")
REPO_FIRST=$(release_notes_first_version < "${REPO_ROOT}/CHANGELOG.md")
assert_eq 'repo: CHANGELOG first header matches Version.swift' \
  "$REPO_SWIFT" "$REPO_FIRST"
if release_notes_extract_section "$REPO_SWIFT" < "${REPO_ROOT}/CHANGELOG.md" | release_notes_section_is_empty; then
  fail 'repo: current version section is non-empty' "## [$REPO_SWIFT] has no notes"
else
  pass 'repo: current version section is non-empty'
fi
assert_ok 'repo: current version passes the publication gate' \
  release_notes_gate_publish "$REPO_SWIFT" "$REPO_SWIFT" 1 < "${REPO_ROOT}/CHANGELOG.md"

# --- summary -----------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
