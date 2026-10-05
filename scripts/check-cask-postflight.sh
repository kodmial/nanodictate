#!/usr/bin/env bash
# check-cask-postflight.sh — static smoke gate for the Homebrew Cask
# quarantine postflight (issue #156: literal `{{appdir}}` regression).
#
# Proves, without macOS/Homebrew, that the cask postflight:
#   1. resolves the REAL installed app path via the Cask DSL interpolation
#      (`#{appdir}/NanoDictate.app`), never a literal `{{appdir}}` placeholder
#      or a hardcoded /Applications path;
#   2. removes ONLY `com.apple.quarantine` (`xattr -dr com.apple.quarantine`),
#      with no blanket attribute wipe (`-c`), no other xattr keys, no
#      Gatekeeper changes (`spctl`, `gatekeeper`).
# Checks both the template (packaging/homebrew/Casks/nanodictate.rb.tpl,
# the source of truth consumed by scripts/release-prep.rb and the candidate
# smoke gate) and the generated cask, and requires them to agree on the
# postflight stanza modulo version/SHA placeholders.
#
# Usage: bash scripts/check-cask-postflight.sh
# Exit 0 when the contract holds, non-zero with a reason otherwise.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL="$ROOT/packaging/homebrew/Casks/nanodictate.rb.tpl"
GEN="$ROOT/packaging/homebrew/Casks/nanodictate.rb"

fail() {
  echo "check-cask-postflight: FAIL: $1" >&2
  exit 1
}

[ -f "$TPL" ] || fail "template missing: $TPL"
[ -f "$GEN" ] || fail "generated cask missing: $GEN"

# --- 1. Ruby syntax of the generated cask -------------------------------------
if command -v ruby >/dev/null 2>&1; then
  ruby -c "$GEN" >/dev/null || fail "ruby -c rejects $GEN"
  echo "check-cask-postflight: ruby -c ok ($GEN)"
else
  echo "check-cask-postflight: ruby absent, skipping ruby -c" >&2
fi

for file in "$TPL" "$GEN"; do
  # --- 2. No literal placeholder ------------------------------------------------
  if grep -q "{{appdir}}" "$file"; then
    fail "$file contains a literal {{appdir}} placeholder (postflight would target a nonexistent path)"
  fi
  # --- 3. DSL interpolation resolves the installed app path ---------------------
  if ! grep -q '#{appdir}/NanoDictate\.app' "$file"; then
    fail "$file does not resolve the installed app path via #{appdir}/NanoDictate.app"
  fi
  # --- 4. Only com.apple.quarantine is removed ----------------------------------
  if ! grep -q '"-dr", "com\.apple\.quarantine"' "$file"; then
    fail "$file postflight must strip exactly com.apple.quarantine via xattr -dr"
  fi
  if grep -Eq '"-c"|\bcom\.apple\.(FinderInfo|ResourceFork|metadata|birthtime)\b' "$file"; then
    fail "$file touches extended attributes beyond com.apple.quarantine"
  fi
  if grep -Eq '\bspctl\b|\bgatekeeper\b' "$file"; then
    fail "$file must not change Gatekeeper state"
  fi
done

# --- 5. Template and generated cask agree on the postflight stanza -------------
# (modulo release-prep.rb placeholders: __VERSION__, __ZIP_SHA256_*__).
normalize() {
  sed -e 's/__VERSION__//g' \
      -e 's/__ZIP_SHA256_ARM64__//g' \
      -e 's/__ZIP_SHA256_X86_64__//g' \
      -e 's/[0-9]\+\.[0-9]\+\.[0-9]\+//g' \
      -e 's/[0-9a-f]\{64\}//g' "$1" \
    | grep -A4 "postflight_steps"
}
if [ "$(normalize "$TPL")" != "$(normalize "$GEN")" ]; then
  fail "postflight stanza drift between template and generated cask"
fi

echo "check-cask-postflight: PASS (postflight resolves #{appdir}/NanoDictate.app, removes only com.apple.quarantine)"
