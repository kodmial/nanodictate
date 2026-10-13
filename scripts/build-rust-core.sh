#!/bin/bash
# Builds the shared Rust engine and verifies the generated C ABI header.
#
# Usage:
#   scripts/build-rust-core.sh [--release|--debug] [--skip-header-check]
#       [--archive-path-file PATH]
#
# - Builds nanodictate-core (staticlib for the macOS app, cdylib for the
#   Windows portability check) into <target-dir>/<profile>/, where
#   <target-dir> is the resolved Cargo target directory (see TARGET_DIR
#   below).
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
# when missing and network access is available), python3 (used to read the
# resolved target directory from `cargo metadata`; falls back to rust/target
# when unavailable).
set -euo pipefail

PROFILE="release"
CHECK_HEADER=1
ARCHIVE_PATH_FILE=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --debug) PROFILE="debug"; shift ;;
    --release) PROFILE="release"; shift ;;
    --skip-header-check) CHECK_HEADER=0; shift ;;
    --archive-path-file)
      [[ $# -ge 2 ]] || { echo "missing value for --archive-path-file" >&2; exit 2; }
      ARCHIVE_PATH_FILE="$2"
      shift 2
      ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT/rust"

# Resolve the directory Cargo will use so the build commands and the
# reported Swift link path agree. Precedence: CARGO_TARGET_DIR env, then
# Cargo configuration (e.g. build.target-dir in .cargo/config.toml), then
# the default rust/target. `cargo metadata` already applies the same
# resolution Cargo uses for builds.
if [[ -n "${CARGO_TARGET_DIR:-}" ]]; then
  # Cargo resolves a relative CARGO_TARGET_DIR against the cwd cargo runs in
  # (rust/, after the cd above), so resolve it the same way for reporting.
  if [[ "$CARGO_TARGET_DIR" = /* ]]; then
    TARGET_DIR="$CARGO_TARGET_DIR"
  else
    TARGET_DIR="$REPO_ROOT/rust/$CARGO_TARGET_DIR"
  fi
else
  TARGET_DIR="$(cargo metadata --format-version 1 --no-deps \
    --manifest-path "$REPO_ROOT/rust/Cargo.toml" 2>/dev/null \
    | python3 -c 'import json,sys; print(json.load(sys.stdin).get("target_directory") or "")' 2>/dev/null || true)"
  if [[ -z "${TARGET_DIR:-}" ]]; then
    TARGET_DIR="$REPO_ROOT/rust/target"
  fi
fi

if [[ "$PROFILE" == "release" ]]; then
  cargo build --target-dir "$TARGET_DIR" --release -p nanodictate-core
else
  cargo build --target-dir "$TARGET_DIR" -p nanodictate-core
fi

if [[ "$CHECK_HEADER" == 1 ]]; then
  "$REPO_ROOT/scripts/check-rust-abi.sh"
fi

# Locate the static archive Cargo actually produced. When CARGO_BUILD_TARGET
# or build.target sets a target triple, Cargo places the archive under
# $TARGET_DIR/<triple>/$PROFILE even when the triple matches the host, so
# reconstructing "$TARGET_DIR/$PROFILE/..." would report a stale path. Parse
# the compiler-artifact filenames from a cached `cargo build
# --message-format=json` invocation instead (the real build above keeps
# human-readable output; this second invocation is cached and only discovers
# the path).
ARCHIVE_NAME="libnanodictate_core.a"
ARCHIVE=""
if [[ "$PROFILE" == "release" ]]; then
  BUILD_JSON="$(cargo build --target-dir "$TARGET_DIR" --release -p nanodictate-core --message-format=json 2>/dev/null || true)"
else
  BUILD_JSON="$(cargo build --target-dir "$TARGET_DIR" -p nanodictate-core --message-format=json 2>/dev/null || true)"
fi
if [[ -n "${BUILD_JSON:-}" ]]; then
  ARCHIVE="$(printf '%s' "$BUILD_JSON" | python3 -c 'import json,sys
want = "libnanodictate_core.a"
found = ""
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        msg = json.loads(line)
    except Exception:
        continue
    if msg.get("reason") != "compiler-artifact":
        continue
    if "nanodictate-core" not in str(msg.get("package_id", "")):
        continue
    for f in msg.get("filenames") or []:
        if f.endswith("/" + want):
            found = f
            break
    if found:
        break
print(found)' 2>/dev/null || true)"
  if [[ -z "${ARCHIVE:-}" ]]; then
    # Python-independent extraction for environments without python3: the
    # artifact messages embed the exact archive path Cargo produced,
    # including any <triple> subdirectory.
    ARCHIVE="$(printf '%s' "$BUILD_JSON" | grep -o '"[^"]*libnanodictate_core\.a"' | tr -d '"' | head -n 1 || true)"
  fi
fi
# Fail clearly when artifact discovery fails instead of guessing a path: a
# reconstructed "$TARGET_DIR/$PROFILE/..." fallback or a first-match
# "$TARGET_DIR/*/$PROFILE/..." scan can report a stale archive from an
# unrelated target triple when CARGO_BUILD_TARGET or build.target is set.
if [[ -z "${ARCHIVE:-}" ]]; then
  echo "error: could not locate $ARCHIVE_NAME in cargo build artifact messages (TARGET_DIR=$TARGET_DIR PROFILE=$PROFILE)" >&2
  exit 1
fi
if [[ ! -f "$ARCHIVE" ]]; then
  echo "error: reported Rust archive does not exist: $ARCHIVE (TARGET_DIR=$TARGET_DIR PROFILE=$PROFILE)" >&2
  exit 1
fi

if [[ -n "$ARCHIVE_PATH_FILE" ]]; then
  printf '%s\n' "$ARCHIVE" > "$ARCHIVE_PATH_FILE" || {
    echo "error: could not write Rust archive path to $ARCHIVE_PATH_FILE" >&2
    exit 1
  }
fi

echo "Rust engine built: $ARCHIVE"
echo "Link with: swift build -Xlinker $ARCHIVE"
