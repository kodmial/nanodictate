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
#   * the workflow contract (supported hosted runners only with Node 24
#     actions, isolated macOS 12 execution out-of-band, no secrets),
#   * the --full non-12 refusal (a newer runner is never equivalent),
#   * the source contracts behind the CLI/linkage, audio, Accessibility, and
#     documentation claims so they cannot drift back into over-claiming.
#
# Temporary fixtures live in a per-run directory under .opencode-tmp/ inside
# the worktree (never in /tmp) and are removed on exit.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel) || exit 1
CHECK_SCRIPT="${REPO_ROOT}/scripts/macos12-compat-check.sh"
BUILD_CONTRACT="${REPO_ROOT}/scripts/swift-rust-build-contract.sh"
NORMAL_CI="${REPO_ROOT}/scripts/ci-validation.sh"
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
assert_ok 'Rust/Swift contract: bash -n parses' bash -n "$BUILD_CONTRACT"

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

# --- 3b. Shared Rust/Swift build contract -------------------------------------

assert_grep 'contract: uses the canonical Rust builder' \
  "$BUILD_CONTRACT" 'build-rust-core\.sh'
assert_grep 'contract: requests the exact archive path from the builder' \
  "$BUILD_CONTRACT" 'archive-path-file'
assert_grep 'normal CI: sources the shared Rust/Swift contract' \
  "$NORMAL_CI" 'source scripts/swift-rust-build-contract\.sh'
assert_grep 'normal CI: prepares the canonical Rust archive' \
  "$NORMAL_CI" 'archive="\$\(prepare_rust_archive\)"'
assert_grep 'normal CI: Swift build goes through the shared linker function' \
  "$NORMAL_CI" 'swift_build_with_rust "\$archive"'
assert_grep 'compat: sources the same Rust/Swift contract' \
  "$CHECK_SCRIPT" 'source "\$REPO_ROOT/scripts/swift-rust-build-contract\.sh"'
assert_grep 'compat: prepares the canonical Rust archive' \
  "$CHECK_SCRIPT" 'ARCHIVE="\$\(prepare_rust_archive\)"'
assert_grep 'compat: Swift build goes through the shared linker function' \
  "$CHECK_SCRIPT" 'swift_build_with_rust "\$ARCHIVE"'
assert_not_ok 'compat: no direct Swift-only deployment-target build remains' \
  grep -qE 'MACOSX_DEPLOYMENT_TARGET=12\.0[[:space:]]+swift[[:space:]]+build' "$CHECK_SCRIPT"
assert_grep 'compat: deployment target remains 12.0 for the linked Swift build' \
  "$CHECK_SCRIPT" 'export MACOSX_DEPLOYMENT_TARGET=12\.0'

MISSING_ARCHIVE="$TMP_DIR/missing/libnanodictate_core.a"
MISSING_LOG="$TMP_DIR/missing-archive.log"
if bash -c 'set -euo pipefail; source "$1"; require_rust_archive "$2"' \
    _ "$BUILD_CONTRACT" "$MISSING_ARCHIVE" >"$MISSING_LOG" 2>&1; then
  fail 'contract: missing Rust archive fails explicitly' 'missing archive unexpectedly accepted'
else
  pass 'contract: missing Rust archive fails explicitly'
fi
assert_grep 'contract: missing archive diagnostic names the failure' \
  "$MISSING_LOG" 'missing Rust archive'

FAKE_ARCHIVE="$TMP_DIR/libnanodictate_core.a"
SWIFT_ARGS="$TMP_DIR/swift-args.txt"
EXPECTED_ARGS="$TMP_DIR/expected-swift-args.txt"
touch "$FAKE_ARCHIVE"
assert_ok 'contract: Swift linker arguments are generated by one function' \
  bash -c 'set -euo pipefail
    source "$1"
    ARGS_FILE="$3"
    swift() { printf "%s\\n" "$@" > "$ARGS_FILE"; }
    swift_build_with_rust "$2" --product NanoDictateCoreTests
  ' _ "$BUILD_CONTRACT" "$FAKE_ARCHIVE" "$SWIFT_ARGS"
printf '%s\n' build --product NanoDictateCoreTests -Xlinker "$FAKE_ARCHIVE" > "$EXPECTED_ARGS"
assert_ok 'contract: canonical linker arguments include the exact archive path' \
  cmp "$EXPECTED_ARGS" "$SWIFT_ARGS"

# --- 4. Workflow contract -----------------------------------------------------
# No JavaScript action can execute on macOS 12 after the Node 24 migration
# (Node 20 removed September 23, 2026; Node 24 incompatible with macOS 13.4
# and earlier), so every Actions job must run on a supported hosted runner
# and the --full probe must run on an isolated host out-of-band.

assert_ok 'workflow: file exists' test -f "$WORKFLOW"
assert_not_ok 'workflow: no self-hosted execution (unsupported for JS actions on macOS 12)' \
  grep -qE 'runs-on:.*self-hosted' "$WORKFLOW"
assert_not_ok 'workflow: no hosted macos-12 fallback' \
  grep -qE 'runs-on: macos-12' "$WORKFLOW"
assert_grep 'workflow: runtime handoff runs on supported macos-15' \
  "$WORKFLOW" 'runs-on: macos-15'
assert_grep 'workflow: checkout uses Node 24 (v5)' \
  "$WORKFLOW" 'actions/checkout@v5'
assert_not_ok 'workflow: checkout no longer uses Node 20 (v4 removed)' \
  grep -qE 'actions/checkout@v4' "$WORKFLOW"
assert_grep 'workflow: artifacts use Node 24 (v6)' \
  "$WORKFLOW" 'actions/upload-artifact@v6'
assert_not_ok 'workflow: artifacts no longer use Node 20 (v4 removed)' \
  grep -qE 'actions/upload-artifact@v4' "$WORKFLOW"
assert_grep 'workflow: checkout does not persist credentials' \
  "$WORKFLOW" 'persist-credentials: false'
assert_grep 'workflow: runtime records an isolated-host handoff instead of claiming a pass' \
  "$WORKFLOW" 'needs-macos12-host'
assert_grep 'workflow: Rust core changes trigger the compatibility gate' \
  "$WORKFLOW" "rust/\*\*"

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

# --- 6b. Lifecycle safety: stale evidence, existing agent, restart liveness, teardown ---
assert_grep 'lifecycle: stale result markers cleared during init' \
  "$CHECK_SCRIPT" 'rm -f "\$RESULT_DIR/result\.txt" "\$RESULT_DIR/failure-summary\.txt"'
assert_grep 'lifecycle: probe refuses when an agent is already loaded' \
  "$CHECK_SCRIPT" 'existing .* already loaded in gui/'
assert_grep 'lifecycle: exit trap installed before the probe job starts' \
  "$CHECK_SCRIPT" 'trap lifecycle_cleanup EXIT'
assert_grep 'lifecycle: exit trap removed after verified final stop' \
  "$CHECK_SCRIPT" 'trap - EXIT'
assert_grep 'lifecycle: restart repeats the live-pid check' \
  "$CHECK_SCRIPT" 'restarted job has no live pid'
assert_grep 'lifecycle: restart repeats the process-liveness check' \
  "$CHECK_SCRIPT" 'restarted pid .* has no process'
assert_grep 'lifecycle: final stop fails the gate instead of suppressing' \
  "$CHECK_SCRIPT" 'fail "nanodictate final stop failed"'
assert_grep 'lifecycle: final stop verifies job removal' \
  "$CHECK_SCRIPT" 'service still registered 30s after final stop'
assert_grep 'lifecycle: original HOME saved before isolation' \
  "$CHECK_SCRIPT" 'ORIGINAL_HOME="\$\{HOME:-/\}"'
assert_grep 'lifecycle: original HOME restored after the probe' \
  "$CHECK_SCRIPT" 'export HOME="\$ORIGINAL_HOME"'
assert_not_ok 'lifecycle: probe no longer retains the isolated HOME' \
  grep -qF 'export HOME="${HOME:-/}"' "$CHECK_SCRIPT"

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
assert_grep 'docs: Node 24 host constraint documented' \
  "$COMPAT_DOC" 'Node 24'
assert_grep 'docs: isolated macOS 12 execution documented' \
  "$COMPAT_DOC" 'isolated macOS 12'
assert_not_ok 'docs: no self-hosted macOS 12 runner strategy remains' \
  grep -qE 'self-hosted, macos-12' "$COMPAT_DOC"
assert_grep 'docs: results collected back on a supported machine' \
  "$COMPAT_DOC" 'collect the results back on a supported'

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
