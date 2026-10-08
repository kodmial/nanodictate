#!/usr/bin/env bash
# macos12-compat-check.sh — repeatable macOS 12 compatibility gate for NanoDictate.
#
# Purpose: validate the declared macOS 12 (Monterey) support floor for the
# release-critical runtime paths without pretending that a newer runner is
# equivalent to macOS 12. The script has two modes:
#
#   --static-only   Compile-time floor checks. Runs on ANY macOS runner
#                   (CI macos-15 included): Package.swift platform, Info.plist
#                   LSMinimumSystemVersion, Homebrew depends_on :monterey,
#                   MACOSX_DEPLOYMENT_TARGET=12.0 build, version-flag sanity.
#                   This mode never claims runtime equivalence with macOS 12.
#
#   --full          Everything in --static-only PLUS live runtime probes that
#                   are only meaningful on an actual macOS 12 machine:
#                   install/startup, LaunchAgent start/stop/restart liveness,
#                   best-effort audio HAL enumeration (no capture, no TCC grant
#                   required; unavailable probe is non-fatal), package min-OS
#                   metadata. Accessibility status is only recorded here:
#                   granting and insertion stay in the manual checklist. On a
#                   non-12 host --full verifies the declared floor and then
#                   FAILS right away, before the build, with a clear message
#                   that runtime validation requires actual macOS 12
#                   execution, unless --allow-non12-runtime is given
#                   (diagnostics only, never a release gate pass).
#
#                   Package installation and Accessibility insertion are
#                   manual-checklist items, never automated phases.
#
# Safety: black-box, low-side-effect. No microphone capture, no TCC prompt
# automation, no STT network calls, no secrets. The LaunchAgent lifecycle uses
# an isolated HOME so the real ~/.config/nanodictate is never touched.
#
# Usage:
#   scripts/macos12-compat-check.sh [--static-only | --full]
#       [--allow-non12-runtime] [--result-dir DIR] [--skip-build]
#
# --skip-build is only accepted with --static-only: --full without the build,
# the CLI probes and the LaunchAgent lifecycle could still print
# result=full-green on release evidence, so the combination is rejected.
#
# Exit 0 on green, non-zero with a failure summary otherwise.
# macOS-only script: exits 2 immediately on other operating systems.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/swift-rust-build-contract.sh
source "$REPO_ROOT/scripts/swift-rust-build-contract.sh"
MODE="full"
ALLOW_NON12_RUNTIME=0
RESULT_DIR="${REPO_ROOT}/.opencode-tmp/macos12-compat-results"
SKIP_BUILD=0

while [ $# -gt 0 ]; do
  case "$1" in
    --static-only) MODE="static-only"; shift ;;
    --full) MODE="full"; shift ;;
    --allow-non12-runtime) ALLOW_NON12_RUNTIME=1; shift ;;
    --result-dir)
      [ $# -ge 2 ] || { echo "missing value for --result-dir" >&2; exit 2; }
      RESULT_DIR="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    -h|--help)
      sed -n '1,43p' "$0"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ "$MODE" = "full" ] && [ "$SKIP_BUILD" = "1" ]; then
  echo "[macos12-compat][FAIL] --skip-build is only valid with --static-only: --full would report full-green without the build, CLI probes or LaunchAgent lifecycle" >&2
  exit 2
fi

case "$(uname -s)" in
  Darwin) ;;
  *) echo "[macos12-compat][FAIL] macOS-only script (uname: $(uname -s))" >&2; exit 2 ;;
esac

mkdir -p "$RESULT_DIR"
# Clear stale markers so a previous green (or failure) cannot survive into
# this run's artifacts and contradict the new outcome.
rm -f "$RESULT_DIR/result.txt" "$RESULT_DIR/failure-summary.txt"
PHASE="init"
CHECK=""

log() { printf '[macos12-compat] %s\n' "$*"; }
phase() { PHASE="$1"; CHECK=""; log "=== phase: $1 ==="; }
set_check() { CHECK="$1"; log "check: $1"; }
fail() {
  printf '[macos12-compat][FAIL] phase=%s check=%s msg=%s\n' "$PHASE" "${CHECK:-<none>}" "$1" >&2
  printf 'phase=%s\ncheck=%s\nmessage=%s\n' "$PHASE" "${CHECK:-<none>}" "$1" > "$RESULT_DIR/failure-summary.txt" 2>/dev/null || true
  exit 1
}

sw_vers_product() { /usr/bin/sw_vers -productVersion 2>/dev/null || echo unknown; }

# compat_macos_major <productVersion> -> major number or empty.
# Pure function, unit-tested in scripts/test-macos12-compat-check.sh.
compat_macos_major() {
  printf '%s' "${1:-}" | grep -oE '^[0-9]+' || true
}

# compat_runtime_gate <macosMajor> <allowNon12Runtime> -> run|refuse|diagnostics.
# Pure function, unit-tested in scripts/test-macos12-compat-check.sh.
# Only "run" can ever lead to result=full-green; "diagnostics" records no
# runtime claim and "refuse" fails the gate.
compat_runtime_gate() {
  if [ "${1:-}" = "12" ]; then
    printf 'run'
    return 0
  fi
  if [ "${2:-0}" = "1" ]; then
    printf 'diagnostics'
    return 0
  fi
  printf 'refuse'
}

MACOS_VERSION="$(sw_vers_product)"
MACOS_MAJOR="$(compat_macos_major "$MACOS_VERSION")"
ARCH="$(/usr/bin/arch 2>/dev/null || uname -m)"
{
  echo "macos_version=${MACOS_VERSION}"
  echo "macos_major=${MACOS_MAJOR}"
  echo "arch=${ARCH}"
  echo "mode=${MODE}"
} > "$RESULT_DIR/environment.txt"
log "host: macOS ${MACOS_VERSION} (${ARCH}), mode=${MODE}"

# --- 1. Declared floor: Package.swift ---------------------------------------
phase "declared-floor"
set_check "Package.swift declares .macOS(.v12)"
grep -q '\.macOS(\.v12)' "$REPO_ROOT/Package.swift" \
  || fail "Package.swift no longer declares .macOS(.v12)"
set_check "Info.NanoDictateApp.plist LSMinimumSystemVersion is 12.0"
grep -A1 'LSMinimumSystemVersion' "$REPO_ROOT/packaging/Info.NanoDictateApp.plist" | grep -q '12\.0' \
  || fail "packaging/Info.NanoDictateApp.plist LSMinimumSystemVersion is not 12.0"
set_check "Homebrew formula and cask keep the :monterey floor"
grep -q 'depends_on macos: :monterey' "$REPO_ROOT/packaging/homebrew/nanodictate.rb.tpl" \
  || fail "packaging/homebrew/nanodictate.rb.tpl lost depends_on macos: :monterey"
grep -q 'depends_on macos: :monterey' "$REPO_ROOT/packaging/homebrew/Casks/nanodictate.rb.tpl" \
  || fail "packaging/homebrew/Casks/nanodictate.rb.tpl lost depends_on macos: :monterey"
log "declared floor ok (Package.swift .v12, Info.plist 12.0, brew :monterey)"

# --- 2. Full mode requires actual macOS 12 -----------------------------------
# Evaluated before the build: a newer host is refused immediately instead of
# after a multi-minute deployment-target build, and the refusal never depends
# on the build succeeding. --static-only is skipped here on purpose: the
# compile-time floor gate must run on any macOS runner, including macos-15.
if [ "$MODE" != "static-only" ]; then
  phase "runtime-host"
  set_check "host is actually macOS 12"
  case "$(compat_runtime_gate "$MACOS_MAJOR" "$ALLOW_NON12_RUNTIME")" in
    run)
      log "runtime host ok: macOS ${MACOS_VERSION}"
      ;;
    diagnostics)
      log "warning: host is macOS ${MACOS_VERSION}, not 12 — continuing as diagnostics-only (NOT a release pass)"
      printf 'result=diagnostics-only\nruntime_claim=none\nreason=non-12-host\n' > "$RESULT_DIR/result.txt"
      ;;
    *)
      fail "runtime validation requires actual macOS 12 execution (host is ${MACOS_VERSION}); refusing to pretend macos-15 == macos-12. See docs/compatibility/macos-12-validation.md"
      ;;
  esac
fi

# --- 3. Deployment-target build ----------------------------------------------
phase "deployment-target-build"
if [ "$SKIP_BUILD" = "1" ]; then
  log "skip-build requested, deployment-target build not executed"
else
  set_check "canonical production Rust archive is prepared"
  ARCHIVE="$(prepare_rust_archive)" \
    || fail "failed to prepare the production Rust archive"
  [ -f "$ARCHIVE" ] || fail "missing Rust archive after preparation: $ARCHIVE"
  log "Rust archive: $ARCHIVE"

  set_check "MACOSX_DEPLOYMENT_TARGET=12.0 Swift build links the canonical Rust archive"
  (
    export MACOSX_DEPLOYMENT_TARGET=12.0
    swift_build_with_rust "$ARCHIVE"
  ) || fail "Swift/Rust build failed with MACOSX_DEPLOYMENT_TARGET=12.0 (availability or link error?)"
  log "deployment-target Swift/Rust build ok"
fi

# --- 4. Freshly built CLI sanity (no hardware, no TCC) -----------------------
phase "cli-sanity"
if [ "$SKIP_BUILD" = "1" ]; then
  log "skip-build requested, CLI sanity probes skipped"
else
  BIN="$REPO_ROOT/.build/debug/nanodictate"
  AGENT_BIN="$REPO_ROOT/.build/debug/NanoDictateAgent"
  set_check "built nanodictate --version exits 0"
  [ -x "$BIN" ] || fail "built binary missing: $BIN (run without --skip-build first)"
  VERSION_OUT="$("$BIN" --version 2>&1)" || fail "--version exited non-zero: $VERSION_OUT"
  log "version ok: $VERSION_OUT"
  printf '%s\n' "$VERSION_OUT" > "$RESULT_DIR/nanodictate-version.txt"
  set_check "built nanodictate --help exits 0"
  "$BIN" --help >/dev/null 2>&1 || fail "--help exited non-zero"
  set_check "linked minimum OS is 12.x (LC_BUILD_VERSION minos)"
  if command -v vtool >/dev/null 2>&1; then
    VTOOL_OUT="$(vtool -show-build "$BIN" 2>/dev/null || true)"
    printf '%s\n' "$VTOOL_OUT" > "$RESULT_DIR/vtool-show-build.txt"
    printf '%s\n' "$VTOOL_OUT" | grep -qE 'minos 12\.' \
      || fail "vtool minos is not 12.x: $(printf '%s' "$VTOOL_OUT" | head -n 5)"
  else
    OTOOL_OUT="$(otool -l "$BIN" 2>/dev/null | grep -A5 'LC_BUILD_VERSION' | head -n 12 || true)"
    printf '%s\n' "$OTOOL_OUT" > "$RESULT_DIR/otool-build-version.txt"
    printf '%s\n' "$OTOOL_OUT" | grep -qE 'minos 12\.' \
      || fail "otool minos is not 12.x: $(printf '%s' "$OTOOL_OUT" | head -n 5)"
  fi
  [ -x "$AGENT_BIN" ] || fail "agent binary missing at $AGENT_BIN"
  export NANODICTATE_AGENT_BIN="$AGENT_BIN"
fi

if [ "$MODE" = "static-only" ]; then
  log "STATIC-ONLY GREEN (no runtime claim: run --full on actual macOS 12 for release validation)"
  printf 'result=static-only-green\nruntime_claim=none\n' > "$RESULT_DIR/result.txt"
  exit 0
fi

# --- 5. LaunchAgent lifecycle with isolated HOME (no TCC grant needed) --------
phase "launchd-lifecycle"
if [ "$SKIP_BUILD" = "1" ]; then
  log "skip-build requested, launchd lifecycle skipped"
else
  BIN="$REPO_ROOT/.build/debug/nanodictate"
  ORIGINAL_HOME="${HOME:-/}"
  ISOLATED_HOME="$(mktemp -d "$RESULT_DIR/isolated-home.XXXXXX")"
  export HOME="$ISOLATED_HOME"
  log "isolated HOME: $ISOLATED_HOME"
  LABEL="com.nanodictate.agent"
  UID_NUM="$(id -u)"
  # Never disturb a real agent: `start` boots out the canonical target before
  # bootstrapping the probe plist, and `stop` unloads the same target, so the
  # probe only runs when nothing is currently loaded in this gui domain.
  if /bin/launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
    fail "existing $LABEL job already loaded in gui/$UID_NUM — unload it before running the lifecycle probe so the probe cannot boot out or replace the real agent"
  fi
  # Tear down the test-owned job on failure paths after it starts. The guard
  # above guarantees any job registered from here on is probe-owned, so the
  # cleanup stop cannot harm a pre-existing agent.
  LIFECYCLE_STARTED=0
  lifecycle_cleanup() {
    if [ "${LIFECYCLE_STARTED:-0}" = "1" ]; then
      "$BIN" stop >/dev/null 2>&1 || true
    fi
  }
  trap lifecycle_cleanup EXIT
  LIFECYCLE_STARTED=1
  set_check "config path resolves inside isolated HOME"
  EXPECTED_CONFIG_PATH="$ISOLATED_HOME/.config/nanodictate/config.toml"
  CONFIG_PATH="$("$BIN" config path 2>/dev/null)" \
    || fail "could not resolve the config path under isolated HOME"
  [ "$CONFIG_PATH" = "$EXPECTED_CONFIG_PATH" ] \
    || fail "config path is not isolated: $CONFIG_PATH"
  set_check "nanodictate config init in isolated HOME"
  "$BIN" config init >/dev/null 2>&1 || fail "config init failed in isolated HOME"
  [ -f "$ISOLATED_HOME/.config/nanodictate/config.toml" ] \
    || fail "config.toml not created in isolated HOME"
  set_check "nanodictate start registers the canonical job"
  "$BIN" start >/dev/null 2>&1 || fail "nanodictate start failed on macOS ${MACOS_VERSION}"
  sleep 3
  PRINTOUT="$(/bin/launchctl print "gui/$UID_NUM/$LABEL" 2>&1)" \
    || fail "launchctl print gui/$UID_NUM/$LABEL failed after start: $PRINTOUT"
  PID="$(printf '%s\n' "$PRINTOUT" | sed -n 's/^[[:space:]]*pid = //p' | head -n1)"
  [ -n "$PID" ] && [ "$PID" != "0" ] || fail "job registered but has no live pid: $PRINTOUT"
  ps -p "$PID" -o pid=,comm= >/dev/null 2>&1 || fail "reported pid $PID has no process"
  log "live job ok: pid=$PID"
  set_check "nanodictate status exits 0 while running"
  "$BIN" status >/dev/null 2>&1 || fail "nanodictate status failed while job live"
  set_check "nanodictate stop removes the gui-domain job"
  "$BIN" stop >/dev/null 2>&1 || fail "nanodictate stop failed"
  STOPPED=0
  for _ in $(seq 1 15); do
    if ! /bin/launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
      STOPPED=1
      break
    fi
    sleep 2
  done
  [ "$STOPPED" = "1" ] || fail "service still registered 30s after stop"
  set_check "restart: start again after stop"
  "$BIN" start >/dev/null 2>&1 || fail "restart start failed"
  sleep 3
  RESTART_PRINTOUT="$(/bin/launchctl print "gui/$UID_NUM/$LABEL" 2>&1)" \
    || fail "launchctl print gui/$UID_NUM/$LABEL failed after restart: $RESTART_PRINTOUT"
  RESTART_PID="$(printf '%s\n' "$RESTART_PRINTOUT" | sed -n 's/^[[:space:]]*pid = //p' | head -n1)"
  [ -n "$RESTART_PID" ] && [ "$RESTART_PID" != "0" ] || fail "restarted job has no live pid: $RESTART_PRINTOUT"
  ps -p "$RESTART_PID" -o pid=,comm= >/dev/null 2>&1 || fail "restarted pid $RESTART_PID has no process"
  log "restarted job ok: pid=$RESTART_PID"
  set_check "nanodictate stop removes the gui-domain job after restart"
  "$BIN" stop >/dev/null 2>&1 || fail "nanodictate final stop failed"
  FINAL_STOPPED=0
  for _ in $(seq 1 15); do
    if ! /bin/launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1; then
      FINAL_STOPPED=1
      break
    fi
    sleep 2
  done
  [ "$FINAL_STOPPED" = "1" ] || fail "service still registered 30s after final stop"
  LIFECYCLE_STARTED=0
  trap - EXIT
  log "launchd lifecycle ok (start/stop/restart, isolated HOME, real user config untouched)"
  export HOME="$ORIGINAL_HOME"
fi

# --- 6. Audio HAL enumeration (no capture, no TCC grant, best-effort) ---------
phase "audio-hal"
if system_profiler SPAudioDataType >/dev/null 2>&1; then
  set_check "audio output/input devices enumerable without capture"
  system_profiler SPAudioDataType 2>/dev/null | head -n 30 > "$RESULT_DIR/audio-devices.txt" || true
  log "audio HAL enumeration ok (enumeration only: no capture, no engine start/stop)"
else
  log "warning: system_profiler SPAudioDataType unavailable (non-fatal, manual capture check remains)"
fi

# --- 7. Accessibility manual check (no grant, no insertion) -------------------
phase "accessibility-state"
set_check "Accessibility insertion readiness recorded for manual checklist"
log "accessibility trust query skipped by design: granting requires manual TCC approval; see manual checklist"
printf 'accessibility=manual-check-required\n' >> "$RESULT_DIR/environment.txt"

# --- 8. Result -----------------------------------------------------------------
phase "result"
if [ "$MACOS_MAJOR" = "12" ]; then
  log "FULL GREEN on actual macOS ${MACOS_VERSION} (${ARCH})"
  printf 'result=full-green\nruntime_claim=macos-12\nmacos=%s\narch=%s\n' "$MACOS_VERSION" "$ARCH" > "$RESULT_DIR/result.txt"
else
  log "DIAGNOSTICS-ONLY complete on macOS ${MACOS_VERSION} (not a release pass)"
fi
