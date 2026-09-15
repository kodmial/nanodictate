#!/usr/bin/env bash
#
# Wrapper for the dictation-deploy MCP server (stdio transport).
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

if [[ ! -f "$DIST" ]]; then
  echo "start.sh: $DIST missing — installing dependencies and building" >&2

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
# cannot compile Package.swift. Mirror build.sh — prefer SWIFT_TOOLCHAIN (the
# one inherited from ~/.claude.json, or the full toolchain at ~/.swift-toolchain)
# and export the SwiftPM manifest vars so spawn'd builds inherit them.
if [[ -n "${SWIFT_TOOLCHAIN:-}" && ! -x "$SWIFT_TOOLCHAIN/usr/bin/swift" ]]; then
  echo "start.sh: SWIFT_TOOLCHAIN=$SWIFT_TOOLCHAIN has no executable swift" >&2
  exit 1
fi
if [[ -z "${SWIFT_TOOLCHAIN:-}" && -x /Users/dima/.swift-toolchain/usr/bin/swift ]]; then
  export SWIFT_TOOLCHAIN=/Users/dima/.swift-toolchain
  echo "start.sh: SWIFT_TOOLCHAIN unset — using $SWIFT_TOOLCHAIN" >&2
fi
if [[ -n "${SWIFT_TOOLCHAIN:-}" ]]; then
  export SWIFT_EXEC_MANIFEST="$SWIFT_TOOLCHAIN/usr/bin/swiftc"
  export SWIFTPM_CUSTOM_LIBS_DIR="$SWIFT_TOOLCHAIN/usr/lib/swift/pm"
fi

exec node "$DIST" "$@"
