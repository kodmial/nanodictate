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

exec node "$DIST" "$@"