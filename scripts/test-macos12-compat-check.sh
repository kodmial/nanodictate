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
#   * the runtime host gate that only a macOS 12 host may pass (pure function),
#   * --skip-build rejection in --full mode (no result file, non-zero exit),
#   * the declared-floor assertions against the real repository files,
#   * the workflow contract (self-hosted macos-12 only, no secrets, fork
#     PRs never reach the self-hosted runner),
#   * the --full non-12 refusal (a newer runner is never equivalent),
#   * the source contracts behind the CLI/linkage, audio, Accessibility, and
#     documentation claims so they cannot drift back into over-claiming.
#
# Temporary fixtures live in a per-run directory under .opencode-tmp/ inside
# the worktree (never in /tmp) and are removed on exit.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel) || exit 1
CHECK_SCRIPT="${REPO_ROOT}/scripts/macos12-compat-check.sh"
WORKFLOW="${REPO_ROOT}/.github/workflows/macos-12-compat.yml"
COMPAT_DOC="${REPO_ROOT}/docs/compatibility/macos-12-validation.md"

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

# --- 2b. compat_runtime_gate: only macOS 12 may produce a full-green pass -----

compat_runtime_gate() {
  eval "$(sed -n '/^compat_runtime_gate() {/,/^}/p' "$CHECK_SCRIPT")"
  compat_runtime_gate "$@"
}

assert_eq 'host-gate: macOS 12 -> run' 'run' "$(compat_runtime_gate 12 0)"
assert_eq 'host-gate: macOS 12 + diagnostics flag -> run' 'run' "$(compat_runtime_gate 12 1)"
assert_eq 'host-gate: macOS 15 -> refuse' 'refuse' "$(compat_runtime_gate 15 0)"
assert_eq 'host-gate: macOS 15 + diagnostics flag -> diagnostics' \
  'diagnostics' "$(compat_runtime_gate 15 1)"
assert_eq 'host-gate: macOS 13 -> refuse' 'refuse' "$(compat_runtime_gate 13 0)"
assert_eq 'host-gate: unknown version -> refuse' 'refuse' "$(compat_runtime_gate '' 0)"

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
# `secrets:` catches both a secrets block and `secrets: inherit`;
# `secrets.` additionally catches direct references like `${{ secrets.TOKEN }}`.
assert_not_ok 'workflow: requests no secrets' \
  grep -qE 'secrets:|secrets\.' "$WORKFLOW"
SECRET_REF_FIXTURE="$TMP_DIR/workflow-with-secret-ref.yml"
printf '%s\n' 'jobs:' '  build:' '    steps:' \
  '      - run: echo ${{ secrets.NANODICTATE_RUNTIME_TOKEN }}' \
  > "$SECRET_REF_FIXTURE"
assert_ok 'workflow: the assertion catches a direct secret reference' \
  grep -qE 'secrets:|secrets\.' "$SECRET_REF_FIXTURE"
assert_not_ok 'workflow: the secrets: pattern alone would miss that reference' \
  grep -qE 'secrets:' "$SECRET_REF_FIXTURE"
assert_grep 'workflow: never equates a newer runner with macOS 12' \
  "$CHECK_SCRIPT" 'refusing to pretend macos-15 == macos-12'

# --- 5. Mode validation: --skip-build never yields a full-green ---------------
# Host-independent: the check runs before the macOS-only platform gate.

FULL_SKIP_DIR="$TMP_DIR/full-skip-build"
FULL_SKIP_LOG="$TMP_DIR/full-skip-build.log"
bash "$CHECK_SCRIPT" --full --skip-build --result-dir "$FULL_SKIP_DIR" \
  > "$FULL_SKIP_LOG" 2>&1
FULL_SKIP_STATUS=$?
assert_eq 'mode: --full --skip-build exits with a usage error' '2' "$FULL_SKIP_STATUS"
assert_grep 'mode: rejection names the static-only requirement' \
  "$FULL_SKIP_LOG" 'only valid with --static-only'
assert_not_ok 'mode: rejection writes no result file' \
  test -e "$FULL_SKIP_DIR/result.txt"
assert_not_ok 'mode: rejection writes no failure summary' \
  test -e "$FULL_SKIP_DIR/failure-summary.txt"

# --- 6. CLI/linkage, audio, and Accessibility claims stay accurate ------------
# Source contracts: these phases are hardware- or TCC-bound, so the wording
# (and the strictness) of the script itself is what must not drift back into
# over-claiming or into a warning-only path.

assert_grep 'linkage: otool fallback widens the LC_BUILD_VERSION window' \
  "$CHECK_SCRIPT" "grep -A5 'LC_BUILD_VERSION'"
assert_grep 'linkage: otool fallback fails the gate instead of warning' \
  "$CHECK_SCRIPT" 'fail "otool minos is not 12\.x'
assert_not_ok 'linkage: otool fallback no longer only warns' \
  grep -q 'could not confirm minos 12.x via otool' "$CHECK_SCRIPT"

assert_grep 'audio: probe documented as best-effort and non-fatal' \
  "$CHECK_SCRIPT" 'best-effort audio HAL enumeration'
assert_grep 'audio: unavailable probe keeps the run non-fatal' \
  "$CHECK_SCRIPT" 'SPAudioDataType unavailable \(non-fatal'

assert_grep 'accessibility: manual insertion readiness recorded' \
  "$CHECK_SCRIPT" 'Accessibility insertion readiness recorded for manual checklist'
assert_grep 'accessibility: manual-check status written to environment.txt' \
  "$CHECK_SCRIPT" 'accessibility=manual-check-required'
assert_not_ok 'accessibility: no unused Python ApplicationServices probe' \
  grep -q 'import ApplicationServices' "$CHECK_SCRIPT"
assert_not_ok 'accessibility: script no longer claims a trust-state query' \
  grep -q 'Accessibility trust-state query' "$CHECK_SCRIPT"

# --- 7. Documentation must not claim more than the gate automates ------------

assert_ok 'docs: file exists' test -f "$COMPAT_DOC"
assert_grep 'docs: audio probe described as best-effort' \
  "$COMPAT_DOC" 'Best-effort'
assert_not_ok 'docs: automated list no longer claims microphone engine lifecycle' \
  grep -qE 'Microphone engine \| Audio HAL' "$COMPAT_DOC"
assert_not_ok 'docs: automated list no longer claims package install lifecycle' \
  grep -qE 'Package install \| Homebrew/MacPorts lifecycle smoke' "$COMPAT_DOC"
assert_not_ok 'docs: runtime gate no longer claims microphone engine start/stop' \
  grep -q 'microphone engine start/stop/restart' "$COMPAT_DOC"
assert_not_ok 'docs: runtime gate no longer claims package installation' \
  grep -q 'Accessibility insertion readiness, and package' "$COMPAT_DOC"
assert_grep 'docs: package lifecycle lives in the manual checklist' \
  "$COMPAT_DOC" 'MacPorts install on macOS 12'
assert_grep 'docs: Accessibility insertion is stated as manual' \
  "$COMPAT_DOC" 'Accessibility insertion are deliberately \*\*not\*\* automated'
assert_grep 'docs: --skip-build documented as static-only only' \
  "$COMPAT_DOC" '\-\-static-only` only'

# --- 8. --full on a non-12 host refuses (never a silent pass) -----------------
# Only meaningful on macOS; on Linux the script exits 2 (macOS-only), which
# still proves it never claims a pass off-host.

if [[ "$(uname -s)" == "Darwin" ]]; then
  MAJOR="$(/usr/bin/sw_vers -productVersion 2>/dev/null | grep -oE '^[0-9]+' || true)"
  if [[ "$MAJOR" != "12" ]]; then
    assert_not_ok 'runtime: --full refuses a non-12 host' \
      bash "$CHECK_SCRIPT" --full --result-dir "$TMP_DIR/refuse"
    assert_grep 'runtime: refusal names actual execution' \
      "$TMP_DIR/refuse/failure-summary.txt" 'actual macOS 12'
    # `--full --allow-non12-runtime` is not invoked here: --skip-build is
    # rejected in --full mode, so on this host it would build and drive the
    # LaunchAgent lifecycle, stopping the developer's own
    # com.nanodictate.agent job. Its decision is unit tested through
    # compat_runtime_gate above; the recorded result strings are asserted here.
    assert_grep 'runtime: diagnostics-only result never claims a pass' \
      "$CHECK_SCRIPT" 'result=diagnostics-only'
    assert_grep 'runtime: diagnostics-only records no runtime claim' \
      "$CHECK_SCRIPT" 'runtime_claim=none'
    assert_grep 'runtime: only a macOS 12 host records a runtime claim' \
      "$CHECK_SCRIPT" 'runtime_claim=macos-12'
  else
    pass 'runtime: host IS macOS 12, refusal cases skipped (full gate applies)'
  fi
  assert_ok 'mode: --static-only --skip-build stays accepted' \
    bash "$CHECK_SCRIPT" --static-only --skip-build --result-dir "$TMP_DIR/static-skip"
  assert_grep 'mode: static-only result claims no runtime pass' \
    "$TMP_DIR/static-skip/result.txt" 'result=static-only-green'
  assert_grep 'mode: static-only records no runtime claim' \
    "$TMP_DIR/static-skip/result.txt" 'runtime_claim=none'
else
  assert_not_ok 'runtime: macOS-only script exits non-zero on Linux' \
    bash "$CHECK_SCRIPT" --static-only --skip-build --result-dir "$TMP_DIR/linux"
fi

# --- summary -----------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
