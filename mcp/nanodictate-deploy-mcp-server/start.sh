#!/usr/bin/env bash
#
# Wrapper for the nanodictate-deploy MCP server (stdio transport).
#
# A fresh clone has no dist/ (and possibly no node_modules/) because both are
# gitignored — running dist/index.js directly would fail with ENOENT and the
# server would silently not register. This wrapper builds on first run, then
# execs the compiled server so the MCP stdio transport keeps the same process.
#
# Never writes to stdout (that would corrupt the JSON-RPC protocol); build
# logs go to .start-build.log (gitignored via *.log) and errors to stderr.

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
DIST="$DIR/dist/index.js"
LOG="$DIR/.start-build.log"

# Rebuild not only when dist/index.js is missing, but also when the sources it
# was compiled from are newer: a git pull can update src/ or the package files
# while leaving an old dist/ index.js in place, and launching it would run a
# stale bundle. Dependency installation likewise runs when node_modules is
# missing or the package manifests are newer than DIST — not only when DIST is
# missing — and any such install is followed by a rebuild.
NEEDS_BUILD=false
NEEDS_INSTALL=false
BUILD_REASON=""

# package-lock.json may be absent (e.g. a pruned checkout); pass `find` only
# existing inputs, because a missing path operand makes find exit non-zero and
# under `set -o pipefail` that would turn the `find ... | grep -q .` freshness
# probes below into false negatives even when a match was found.
FIND_INPUTS=("$DIR/src" "$DIR/package.json")
MANIFEST_INPUTS=("$DIR/package.json")
if [[ -f "$DIR/package-lock.json" ]]; then
  FIND_INPUTS+=("$DIR/package-lock.json")
  MANIFEST_INPUTS+=("$DIR/package-lock.json")
fi

if [[ ! -f "$DIST" ]]; then
  NEEDS_BUILD=true
  NEEDS_INSTALL=true
  BUILD_REASON="$DIST missing"
elif find "${FIND_INPUTS[@]}" \
    -newer "$DIST" -print -quit 2>/dev/null | grep -q .; then
  NEEDS_BUILD=true
  BUILD_REASON="$DIST older than src/ or package files (stale bundle)"
fi

if [[ ! -d "$DIR/node_modules" ]]; then
  NEEDS_INSTALL=true
  NEEDS_BUILD=true
  [[ -n "$BUILD_REASON" ]] || BUILD_REASON="node_modules missing"
elif [[ -f "$DIST" ]] && find "${MANIFEST_INPUTS[@]}" \
    -newer "$DIST" -print -quit 2>/dev/null | grep -q .; then
  NEEDS_INSTALL=true
fi

if [[ "$NEEDS_BUILD" == "true" ]]; then
  echo "start.sh: $BUILD_REASON — building" >&2

  if [[ "$NEEDS_INSTALL" == "true" ]]; then
    if [[ -f "$DIR/package-lock.json" ]]; then
      if ! npm ci --prefix "$DIR" >"$LOG" 2>&1; then
        echo "start.sh: npm ci failed, falling back to npm install" >&2
        if ! npm install --prefix "$DIR" >"$LOG" 2>&1; then
          echo "start.sh: npm install failed — cannot build the MCP server (log: $LOG)" >&2
          exit 1
        fi
      fi
    else
      if ! npm install --prefix "$DIR" >"$LOG" 2>&1; then
        echo "start.sh: npm install failed — cannot build the MCP server (log: $LOG)" >&2
        exit 1
      fi
    fi
  fi

  if ! npm run build --prefix "$DIR" >"$LOG" 2>&1; then
    echo "start.sh: npm run build failed — dist/index.js not produced (log: $LOG)" >&2
    tail -n 40 "$LOG" >&2 || true
    exit 1
  fi

  rm -f "$LOG"
fi

if [[ ! -f "$DIST" ]]; then
  echo "start.sh: build completed but $DIST is still missing" >&2
  exit 1
fi

# Swift toolchain for the `swift build` the server runs: the Command Line Tools
# ManifestAPI has no PackageDescription.swiftmodule, so plain `swift build`
# cannot compile Package.swift. Mirror the removed build.sh — prefer SWIFT_TOOLCHAIN
# (the one inherited from ~/.claude.json) and export the SwiftPM manifest vars
# so spawn'd builds inherit them.
if [[ -n "${SWIFT_TOOLCHAIN:-}" && ! -x "$SWIFT_TOOLCHAIN/usr/bin/swift" ]]; then
  echo "start.sh: SWIFT_TOOLCHAIN=$SWIFT_TOOLCHAIN has no executable swift" >&2
  exit 1
fi
if [[ -z "${SWIFT_TOOLCHAIN:-}" ]]; then
  # Auto-detect: derive the toolchain dir from `xcrun --find swift`.
  SWIFT_BIN="$(xcrun --find swift 2>/dev/null || true)"
  if [[ -n "$SWIFT_BIN" ]]; then
    # …/<toolchain>/usr/bin/swift → …/<toolchain>/usr/bin → …/<toolchain>/usr → …/<toolchain>
    AUTO_TOOLCHAIN="$(cd "$(dirname "$(dirname "$(dirname "$SWIFT_BIN")")")" && pwd)"
    if [[ -n "$AUTO_TOOLCHAIN" && -x "$AUTO_TOOLCHAIN/usr/bin/swift" ]]; then
      export SWIFT_TOOLCHAIN="$AUTO_TOOLCHAIN"
      echo "start.sh: SWIFT_TOOLCHAIN unset — auto-detected $SWIFT_TOOLCHAIN" >&2
    fi
  fi
fi
if [[ -z "${SWIFT_TOOLCHAIN:-}" ]]; then
  echo "start.sh: cannot locate a Swift toolchain. Install Xcode Command Line Tools, " >&2
  echo "          or set SWIFT_TOOLCHAIN to the toolchain directory (e.g. the one containing usr/bin/swift)." >&2
  exit 1
fi
if [[ -n "${SWIFT_TOOLCHAIN:-}" ]]; then
  export SWIFT_EXEC_MANIFEST="$SWIFT_TOOLCHAIN/usr/bin/swiftc"
  export SWIFTPM_CUSTOM_LIBS_DIR="$SWIFT_TOOLCHAIN/usr/lib/swift/pm"
fi

exec node "$DIST" "$@"
