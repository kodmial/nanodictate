#!/usr/bin/env bash
# Test suite for scripts/macos12-compat-check.sh.
#
# Runs on any bash + git host (Linux included):
#
#   bash scripts/test-macos12-compat-check.sh
#
# Exits 0 when every case passes, 1 otherwise. Covers the parts of the
# compat gate that must not rot on hosts without macOS 12 hardware:
#   * the macOS major-version parser (pure function),
#   * the declared-floor assertions against the real repository files,
#   * the workflow contract (self-hosted macos-12 only, no secrets, fork
#     PRs never reach the self-hosted runner),
#   * the --full non-12 refusal (a newer runner is never equivalent).
#
# Temporary fixtures live in a per-run directory under .opencode-tmp/ inside
# the worktree (never in /tmp) and are removed on exit.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel) || exit 1
CHECK_SCRIPT="${REPO_ROOT}/scripts/macos12-compat-check.sh"
WORKFLOW="${REPO_ROOT}/.github/workflows/macos-12-compat.yml"

mkdir -p "${REPO_ROOT}/.opencode-tmp" || exit 1
TMP_DIR=$(mktemp -d "${REPO_ROOT}/.opencode-tmp/macos12-compat-tests.XXXXXX") || exit 1
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

assert_grep() {
  local name=$1 file=$2 pattern=$3
  if grep -qE "$pattern" "$file"; then
    pass "$name"
  else
    fail "$name" "pattern '$pattern' not found in $file"
  fi
}

# --- 1. The script exists, is executable, parses -----------------------------

assert_ok 'script: bash -n parses' bash -n "$CHECK_SCRIPT"
assert_ok 'script: is executable' test -x "$CHECK_SCRIPT"

# --- 2. compat_macos_major: pure version parser ------------------------------
# Sourced in a subshell so the helper (and only the helper) is tested: the
# script exits early on non-Darwin, so extract the function definition and
# evaluate it in isolation.

compat_macos_major() {
  eval "$(sed -n '/^compat_macos_major() {/,/^}/p' "$CHECK_SCRIPT")"
  compat_macos_major "$@"
}

assert_eq 'parser: 12.7.6 -> 12' '12' "$(compat_macos_major '12.7.6')"
assert_eq 'parser: 12.0 -> 12' '12' "$(compat_macos_major '12.0')"
assert_eq 'parser: 15.7.9 -> 15' '15' "$(compat_macos_major '15.7.9')"
assert_eq 'parser: 13.6 -> 13' '13' "$(compat_macos_major '13.6')"
assert_eq 'parser: empty -> empty' '' "$(compat_macos_major '')"
assert_eq 'parser: unknown -> empty' '' "$(compat_macos_major 'unknown')"

# --- 3. Declared floor matches the real repository files ---------------------

assert_grep 'floor: Package.swift declares .v12' \
  "${REPO_ROOT}/Package.swift" '\.macOS\(\.v12\)'
assert_grep 'floor: Info plist pins 12.0' \
  "${REPO_ROOT}/packaging/Info.NanoDictateApp.plist" '12\.0'
assert_grep 'floor: formula template keeps :monterey' \
  "${REPO_ROOT}/packaging/homebrew/nanodictate.rb.tpl" 'depends_on macos: :monterey'
assert_grep 'floor: cask template keeps :monterey' \
  "${REPO_ROOT}/packaging/homebrew/Casks/nanodictate.rb.tpl" 'depends_on macos: :monterey'

# --- 4. Workflow contract -----------------------------------------------------

assert_ok 'workflow: file exists' test -f "$WORKFLOW"
assert_grep 'workflow: runtime uses self-hosted macos-12' \
  "$WORKFLOW" 'self-hosted, macos-12'
assert_not_ok 'workflow: no hosted macos-12 fallback' \
  grep -qE 'runs-on: macos-12' "$WORKFLOW"
assert_grep 'workflow: fork PRs are excluded from the self-hosted runner' \
  "$WORKFLOW" 'head\.repo\.full_name'
assert_not_ok 'workflow: requests no secrets' \
  grep -qE 'secrets:' "$WORKFLOW"
assert_grep 'workflow: never equates a newer runner with macOS 12' \
  "$CHECK_SCRIPT" 'refusing to pretend macos-15 == macos-12'

# --- 5. --full on a non-12 host refuses (never a silent pass) -----------------
# Only meaningful on macOS; on Linux the script exits 2 (macOS-only), which
# still proves it never claims a pass off-host.

if [[ "$(uname -s)" == "Darwin" ]]; then
  MAJOR="$(/usr/bin/sw_vers -productVersion 2>/dev/null | grep -oE '^[0-9]+' || true)"
  if [[ "$MAJOR" != "12" ]]; then
    assert_not_ok 'runtime: --full refuses a non-12 host' \
      bash "$CHECK_SCRIPT" --full --skip-build --result-dir "$TMP_DIR/refuse"
    assert_grep 'runtime: refusal names actual execution' \
      "$TMP_DIR/refuse/failure-summary.txt" 'actual macOS 12'
    assert_ok 'runtime: diagnostics-only flag exists for triage' \
      bash "$CHECK_SCRIPT" --full --allow-non12-runtime --skip-build --result-dir "$TMP_DIR/diag"
    assert_grep 'runtime: diagnostics-only claims no release pass' \
      "$TMP_DIR/diag/result.txt" 'diagnostics-only'
  else
    pass 'runtime: host IS macOS 12, refusal cases skipped (full gate applies)'
  fi
else
  assert_not_ok 'runtime: macOS-only script exits non-zero on Linux' \
    bash "$CHECK_SCRIPT" --static-only --skip-build --result-dir "$TMP_DIR/linux"
fi

# --- summary -----------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
