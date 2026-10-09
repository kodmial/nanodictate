#!/usr/bin/env bash
# Test suite for the packaging-smoke production policy (issue #172).
#
# Guards the two automation invariants that caused the false P0 in run
# 37887269083 (production legs `cancelled`, yet a P0 was filed while the
# product itself was healthy at 0.1.26):
#   1. packaging-smoke.yml concurrency isolates production verification
#      (workflow_run / schedule / workflow_dispatch) per run_id so overlapping
#      Release completions never cancel each other, while PR/push candidate
#      runs still collapse per PR number / ref.
#   2. nanodictate-packaging-smoke-engine.yml production-incident files a P0
#      only on a real leg failure (failure/timed_out), never on
#      cancelled/skipped legs (superseded or infra-cancelled runs carry no
#      product signal; the superseding run reports on its own).
#
# Runs on any bash host (CI runs it on ubuntu-latest):
#
#   bash scripts/test-packaging-smoke-policy.sh
#
# Exits 0 when every case passes, 1 otherwise. Fixtures live under
# .opencode-tmp/ inside the worktree (never in /tmp) and are removed on exit.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel) || exit 1
CALLER="${REPO_ROOT}/.github/workflows/packaging-smoke.yml"
ENGINE="${REPO_ROOT}/.github/workflows/nanodictate-packaging-smoke-engine.yml"

mkdir -p "${REPO_ROOT}/.opencode-tmp" || exit 1
TMP_DIR=$(mktemp -d "${REPO_ROOT}/.opencode-tmp/packaging-smoke-policy-tests.XXXXXX") || exit 1
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

assert_contains() {
  local name=$1 file=$2 needle=$3
  if grep -qF "$needle" "$file" 2>/dev/null; then
    pass "$name"
  else
    fail "$name" "expected '$file' to contain: $needle"
  fi
}

# Mirror of the engine's incident decision (keep in sync with the inline
# github-script in nanodictate-packaging-smoke-engine.yml):
#   green        -> success/success
#   incident     -> any leg failure/timed_out
#   superseded   -> not green but no failure (cancelled/skipped)
smoke_incident_decision() {
  local hb=$1 mp=$2
  local hb_failed=0 mp_failed=0
  [[ "$hb" == "failure" || "$hb" == "timed_out" ]] && hb_failed=1
  [[ "$mp" == "failure" || "$mp" == "timed_out" ]] && mp_failed=1
  if [[ "$hb" == "success" && "$mp" == "success" ]]; then
    printf 'green'
  elif [[ $hb_failed -eq 1 || $mp_failed -eq 1 ]]; then
    printf 'incident'
  else
    printf 'superseded'
  fi
}

assert_decision() {
  local name=$1 hb=$2 mp=$3 expected=$4
  local actual
  actual="$(smoke_incident_decision "$hb" "$mp")"
  if [[ "$actual" == "$expected" ]]; then
    pass "$name"
  else
    fail "$name" "hb=$hb mp=$mp: expected '$expected', got '$actual'"
  fi
}

# --- 1. Caller concurrency isolates production runs -------------------------

assert_contains 'concurrency: caller workflow exists' "$CALLER" 'concurrency:'
assert_contains 'concurrency: collapses PR runs per PR number' \
  "$CALLER" 'github.event.pull_request.number'
assert_contains 'concurrency: isolates workflow_run production runs per run_id' \
  "$CALLER" "github.event_name == 'workflow_run' && github.run_id"
assert_contains 'concurrency: isolates scheduled canary runs per run_id' \
  "$CALLER" "github.event_name == 'schedule' && github.run_id"
assert_contains 'concurrency: isolates manual production runs per run_id' \
  "$CALLER" "github.event_name == 'workflow_dispatch' && github.run_id"
assert_contains 'concurrency: keeps ref collapsing for push/push-like events' \
  "$CALLER" 'github.ref'
assert_contains 'concurrency: still cancels superseded candidate runs' \
  "$CALLER" 'cancel-in-progress: true'

# The production isolation must come before the generic ref fallback so the
# expression short-circuits to run_id for production events. Check ordering:
# the first occurrence of run_id-gated production logic precedes github.ref.
caller_group_line="$(grep -E '^\s*group:' "$CALLER" | head -n1)"
if [[ "$caller_group_line" == *"workflow_run"* && "$caller_group_line" == *"github.ref"* ]]; then
  # Ensure the workflow_run run_id clause appears before github.ref.
  prefix_before_ref="${caller_group_line%%github.ref*}"
  if [[ "$prefix_before_ref" == *"workflow_run"* && "$prefix_before_ref" == *"github.run_id"* ]]; then
    pass 'concurrency: production run_id clause precedes the ref fallback'
  else
    fail 'concurrency: production run_id clause precedes the ref fallback' \
      "group line: $caller_group_line"
  fi
else
  fail 'concurrency: production run_id clause precedes the ref fallback' \
    "group line: $caller_group_line"
fi

# --- 2. Engine incident only pages on real failure ---------------------------

assert_contains 'incident: engine workflow exists' \
  "$ENGINE" 'production-incident:'
assert_contains 'incident: failure predicate covers failure and timed_out' \
  "$ENGINE" "const failed = (r) => r === 'failure' || r === 'timed_out'"
assert_contains 'incident: anyFailed combines both channels' \
  "$ENGINE" 'const anyFailed = failed(hb) || failed(mp)'
assert_contains 'incident: superseded runs return without filing' \
  "$ENGINE" 'if (!allGreen && !anyFailed)'
assert_contains 'incident: superseded path does not call setFailed' \
  "$ENGINE" 'superseded or skipped run carries no product signal'
assert_contains 'incident: real failures still fail the job' \
  "$ENGINE" "core.setFailed('Production packaging smoke failed"
assert_contains 'incident: recovery still closes the issue when green' \
  "$ENGINE" 'Closed recovered incident'

# --- 3. Decision matrix (mirrors the engine JS) ------------------------------

assert_decision 'decision: success/success is green' success success green
assert_decision 'decision: failure/success files an incident' failure success incident
assert_decision 'decision: success/failure files an incident' success failure incident
assert_decision 'decision: failure/failure files an incident' failure failure incident
assert_decision 'decision: timed_out/success files an incident' timed_out success incident
assert_decision 'decision: failure/cancelled still files (a leg really failed)' \
  failure cancelled incident
# Issue #172: both legs cancelled by a superseding run must NOT file.
assert_decision 'decision: cancelled/cancelled is superseded (issue #172)' \
  cancelled cancelled superseded
assert_decision 'decision: cancelled/success is superseded' cancelled success superseded
assert_decision 'decision: success/cancelled is superseded' success cancelled superseded
assert_decision 'decision: skipped/skipped is superseded' skipped skipped superseded
assert_decision 'decision: skipped/cancelled is superseded' skipped cancelled superseded

# --- summary -----------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
