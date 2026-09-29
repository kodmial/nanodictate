#!/bin/bash
# Builds the shared Rust engine and verifies the generated C ABI header.
#
# Usage:
#   scripts/build-rust-core.sh [--release|--debug] [--skip-header-check]
#
# - Builds nanodictate-core (staticlib for the macOS app, cdylib for the
#   Windows portability check) into rust/target/<profile>/.
# - Regenerates the cbindgen header and fails when the committed header at
#   Sources/NanoDictateRustFFI/include/nanodictate_core.h is stale, so the
#   Swift bridge can never silently drift from the Rust ABI.
# - Prints the SwiftPM link flags needed to link the static library.
#   Link the static archive by absolute path
#   (-Xlinker <root>/rust/target/<profile>/libnanodictate_core.a): using
#   -L/-lnanodictate_core picks the cdylib when both outputs exist and embeds
#   an absolute LC_LOAD_DYLIB path that breaks packaged binaries on any other
#   host ("Library not loaded ... libnanodictate_core.dylib").
#
# Requires: cargo, cbindgen 0.27.0 (scripts/check-rust-abi.sh installs it
# when missing and network access is available).
set -euo pipefail

PROFILE="release"
CHECK_HEADER=1
for arg in "$@"; do
  case "$arg" in
    --debug) PROFILE="debug" ;;
    --release) PROFILE="release" ;;
    --skip-header-check) CHECK_HEADER=0 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/rust"

if [[ "$PROFILE" == "release" ]]; then
  cargo build --release -p nanodictate-core
else
  cargo build -p nanodictate-core
fi

if [[ "$CHECK_HEADER" == 1 ]]; then
  "$REPO_ROOT/scripts/check-rust-abi.sh"
fi

LIB_DIR="$REPO_ROOT/rust/target/$PROFILE"
echo "Rust engine built: $LIB_DIR/libnanodictate_core.a"
echo "Link with: swift build -Xlinker $LIB_DIR/libnanodictate_core.a"
