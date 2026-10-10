#!/usr/bin/env bash
# Shared production build/link contract for Swift products that depend on the
# NanoDictate Rust core. Source this file and call prepare_rust_archive once,
# then pass the returned absolute archive path to swift_build_with_rust.
set -euo pipefail

RUST_SWIFT_CONTRACT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_rust_archive() {
  local archive="${1:-}"
  if [[ -z "$archive" ]]; then
    echo "error: Rust archive path is empty; refusing a Swift-only build" >&2
    return 1
  fi
  if [[ "$(basename "$archive")" != "libnanodictate_core.a" ]]; then
    echo "error: unexpected Rust archive path: $archive" >&2
    return 1
  fi
  if [[ ! -f "$archive" ]]; then
    echo "error: missing Rust archive: $archive" >&2
    return 1
  fi
}

prepare_rust_archive() {
  local path_file archive
  path_file="$(mktemp "${TMPDIR:-/tmp}/nanodictate-rust-archive.XXXXXX")" || {
    echo "error: could not allocate Rust archive path file" >&2
    return 1
  }

  if ! bash "$RUST_SWIFT_CONTRACT_ROOT/scripts/build-rust-core.sh"       --release --archive-path-file "$path_file" 1>&2; then
    rm -f "$path_file"
    echo "error: Rust core preparation failed" >&2
    return 1
  fi

  archive="$(cat "$path_file" 2>/dev/null || true)"
  rm -f "$path_file"
  require_rust_archive "$archive" || return 1
  printf '%s\n' "$archive"
}

swift_build_with_rust() {
  local archive="${1:-}"
  shift || true
  require_rust_archive "$archive" || return 1
  (
    cd "$RUST_SWIFT_CONTRACT_ROOT"
    swift build "$@" -Xlinker "$archive"
  )
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  archive="$(prepare_rust_archive)"
  swift_build_with_rust "$archive" "$@"
fi
