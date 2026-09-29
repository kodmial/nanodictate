#!/bin/bash
# Fails when the committed C ABI header is stale relative to the Rust core.
#
# Regenerates the header with cbindgen into a scratch directory inside the
# worktree and diffs it against
# Sources/NanoDictateRustFFI/include/nanodictate_core.h. Any difference
# means the Rust ABI changed without regenerating the header: commit the
# regenerated file (see rust/nanodictate-core/cbindgen.toml).
#
# Requires cbindgen 0.27.0; when it is missing and cargo is available, an
# install is attempted (CI installs it explicitly instead).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HEADER="$REPO_ROOT/Sources/NanoDictateRustFFI/include/nanodictate_core.h"
PINNED_CBINDGEN="0.27.0"

if command -v cbindgen >/dev/null 2>&1; then
  INSTALLED_CBINDGEN="$(cbindgen --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -n 1)"
  if [[ "$INSTALLED_CBINDGEN" != "$PINNED_CBINDGEN" ]]; then
    echo "cbindgen version mismatch (found ${INSTALLED_CBINDGEN:-unknown}, want $PINNED_CBINDGEN); installing pinned version..." >&2
    cargo install cbindgen --version "$PINNED_CBINDGEN" --locked
  fi
else
  echo "cbindgen not found; attempting cargo install cbindgen $PINNED_CBINDGEN..." >&2
  cargo install cbindgen --version "$PINNED_CBINDGEN" --locked
fi

mkdir -p "$REPO_ROOT/.opencode-tmp"
SCRATCH="$(mktemp -d "$REPO_ROOT/.opencode-tmp/abi-check.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

(
  cd "$REPO_ROOT/rust"
  cbindgen --config nanodictate-core/cbindgen.toml --crate nanodictate-core \
    --output "$SCRATCH/nanodictate_core.h"
)

if ! diff -u "$HEADER" "$SCRATCH/nanodictate_core.h"; then
  echo "::error::Committed C ABI header is stale. Regenerate and commit:" >&2
  echo "  cbindgen --config rust/nanodictate-core/cbindgen.toml --crate nanodictate-core \\" >&2
  echo "    --output Sources/NanoDictateRustFFI/include/nanodictate_core.h \\" >&2
  echo "    rust/nanodictate-core" >&2
  exit 1
fi
echo "C ABI header is fresh."
