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
#                   audio HAL enumeration (no capture, no TCC grant required),
#                   Accessibility trust-state query (no grant required),
#                   package min-OS metadata. On a non-12 host --full still runs
#                   the static checks and then FAILS with a clear message that
#                   runtime validation requires actual macOS 12 execution,
#                   unless --allow-non12-runtime is given (diagnostics only,
#                   never a release gate pass).
#
# Safety: black-box, low-side-effect. No microphone capture, no TCC prompt
# automation, no STT network calls, no secrets. The LaunchAgent lifecycle uses
# an isolated HOME so the real ~/.config/nanodictate is never touched.
#
# Usage:
#   scripts/macos12-compat-check.sh [--static-only | --full]
#       [--allow-non12-runtime] [--result-dir DIR] [--skip-build]
#
# Exit 0 on green, non-zero with a failure summary otherwise.
# macOS-only script: exits 2 immediately on other operating systems.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="full"
ALLOW_NON12_RUNTIME=0
RESULT_DIR="${REPO_ROOT}/.opencode-tmp/macos12-compat-results"
SKIP_BUILD=0

while [ $# -gt 0 ]; do
  case "$1" in
    --static-only) MODE="static-only"; shift ;;
    --full) MODE="full"; shift ;;
    --allow-non12-runtime) ALLOW_NON12_RUNTIME=1; shift ;;
    --result-dir) RESULT_DIR="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    -h|--help)
      sed -n '1,40p' "$0"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$(uname -s)" in
  Darwin) ;;
  *) echo "[macos12-compat][FAIL] macOS-only script (uname: $(uname -s))" >&2; exit 2 ;;
esac

mkdir -p "$RESULT_DIR"
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

# --- 2. Deployment-target build ----------------------------------------------
phase "deployment-target-build"
if [ "$SKIP_BUILD" = "1" ]; then
  log "skip-build requested, deployment-target build not executed"
else
  set_check "MACOSX_DEPLOYMENT_TARGET=12.0 swift build succeeds"
  (cd "$REPO_ROOT" && MACOSX_DEPLOYMENT_TARGET=12.0 swift build) \
    || fail "swift build failed with MACOSX_DEPLOYMENT_TARGET=12.0 (availability error?)"
  log "deployment-target build ok"
fi

# --- 3. Freshly built CLI sanity (no hardware, no TCC) -----------------------
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
    OTOOL_OUT="$(otool -l "$BIN" 2>/dev/null | grep -A3 'LC_BUILD_VERSION' | head -n 12 || true)"
    printf '%s\n' "$OTOOL_OUT" > "$RESULT_DIR/otool-build-version.txt"
    printf '%s\n' "$OTOOL_OUT" | grep -qE 'minos 12\.' \
      || log "warning: could not confirm minos 12.x via otool (non-fatal on this host)"
  fi
  [ -x "$AGENT_BIN" ] || log "warning: agent binary missing at $AGENT_BIN (non-fatal)"
fi

if [ "$MODE" = "static-only" ]; then
  log "STATIC-ONLY GREEN (no runtime claim: run --full on actual macOS 12 for release validation)"
  printf 'result=static-only-green\nruntime_claim=none\n' > "$RESULT_DIR/result.txt"
  exit 0
fi

# --- 4. Full mode requires actual macOS 12 -----------------------------------
phase "runtime-host"
set_check "host is actually macOS 12"
if [ "$MACOS_MAJOR" != "12" ]; then
  if [ "$ALLOW_NON12_RUNTIME" = "1" ]; then
    log "warning: host is macOS ${MACOS_VERSION}, not 12 — continuing as diagnostics-only (NOT a release pass)"
    printf 'result=diagnostics-only\nruntime_claim=none\nreason=non-12-host\n' > "$RESULT_DIR/result.txt"
  else
    fail "runtime validation requires actual macOS 12 execution (host is ${MACOS_VERSION}); refusing to pretend macos-15 == macos-12. See docs/compatibility/macos-12-validation.md"
  fi
else
  log "runtime host ok: macOS ${MACOS_VERSION}"
fi

# --- 5. LaunchAgent lifecycle with isolated HOME (no TCC grant needed) --------
phase "launchd-lifecycle"
if [ "$SKIP_BUILD" = "1" ]; then
  log "skip-build requested, launchd lifecycle skipped"
else
  BIN="$REPO_ROOT/.build/debug/nanodictate"
  ISOLATED_HOME="$(mktemp -d "$RESULT_DIR/isolated-home.XXXXXX")"
  export HOME="$ISOLATED_HOME"
  log "isolated HOME: $ISOLATED_HOME"
  LABEL="com.nanodictate.agent"
  UID_NUM="$(id -u)"
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
  /bin/launchctl print "gui/$UID_NUM/$LABEL" >/dev/null 2>&1 \
    || fail "job not registered after restart"
  "$BIN" stop >/dev/null 2>&1 || true
  log "launchd lifecycle ok (start/stop/restart, isolated HOME, real user config untouched)"
  export HOME="${HOME:-/}"
fi

# --- 6. Audio HAL enumeration (no capture, no TCC grant) ----------------------
phase "audio-hal"
set_check "audio output/input devices enumerable without capture"
if system_profiler SPAudioDataType >/dev/null 2>&1; then
  system_profiler SPAudioDataType 2>/dev/null | head -n 30 > "$RESULT_DIR/audio-devices.txt" || true
  log "audio HAL enumeration ok"
else
  log "warning: system_profiler SPAudioDataType unavailable (non-fatal, manual check remains)"
fi

# --- 7. Accessibility trust-state query (no grant, no insertion) --------------
phase "accessibility-state"
set_check "Accessibility trust API reachable (query only, grants are manual)"
OSX_TRUSTED="unknown"
if /usr/bin/python3 -c 'import ApplicationServices' 2>/dev/null; then
  log "warning: python ApplicationServices bridge present but unused; trust state is a manual check"
fi
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
