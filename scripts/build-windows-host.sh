#!/bin/bash
# Builds the Windows bootstrap inputs: the shared Rust engine (cdylib/DLL
# on Windows, shared library elsewhere for local verification) and the
# .NET host. Used by CI (.github/workflows/windows.yml) and developers.
#
# Usage:
#   scripts/build-windows-host.sh [--config Release|Debug]
set -euo pipefail

CONFIG="Release"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config=*) CONFIG="${1#--config=}"; shift ;;
    --config) CONFIG="${2:?missing value for --config}"; shift 2 ;;
    Release|Debug) CONFIG="$1"; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/rust"

cargo build --release -p nanodictate-core
cd "$REPO_ROOT"

DLL_SRC=""
if [[ -f rust/target/release/nanodictate_core.dll ]]; then
  DLL_SRC="rust/target/release/nanodictate_core.dll"
elif [[ -f rust/target/release/libnanodictate_core.so ]]; then
  DLL_SRC="rust/target/release/libnanodictate_core.so"
elif [[ -f rust/target/release/libnanodictate_core.dylib ]]; then
  DLL_SRC="rust/target/release/libnanodictate_core.dylib"
fi

dotnet build windows/NanoDictate.sln -c "$CONFIG"

if [[ -n "$DLL_SRC" ]]; then
  for dir in \
    "windows/src/NanoDictate.Core/bin/$CONFIG/net8.0" \
    "windows/src/NanoDictate.Smoke/bin/$CONFIG/net8.0" \
    "windows/tests/NanoDictate.Core.Tests/bin/$CONFIG/net8.0"; do
    if [[ -d "$dir" ]]; then
      cp "$DLL_SRC" "$dir/"
    fi
  done
fi

echo "Windows host built ($CONFIG). Engine: ${DLL_SRC:-(resolved at runtime)}"
