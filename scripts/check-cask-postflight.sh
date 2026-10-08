#!/usr/bin/env bash
# check-cask-postflight.sh — static smoke gate for the Homebrew Cask
# quarantine postflight.
#
# Homebrew's structured postflight_steps DSL expands template tokens such as
# {{appdir}}. Ruby interpolation (#{appdir}) is not available inside that DSL.
#
# Proves that both the template and generated cask:
#   1. target {{appdir}}/NanoDictate.app;
#   2. do not use Ruby #{appdir} interpolation in postflight_steps;
#   3. remove only com.apple.quarantine;
#   4. keep the template and generated postflight stanzas in sync.

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

if command -v ruby >/dev/null 2>&1; then
  ruby -c "$GEN" >/dev/null || fail "ruby -c rejects $GEN"
fi

for file in "$TPL" "$GEN"; do
  postflight="$(
    awk '
      /postflight_steps do/ { capture=1 }
      capture { print }
      capture && /^[[:space:]]*end[[:space:]]*$/ { exit }
    ' "$file"
  )"

  [ -n "$postflight" ] || fail "$file has no postflight_steps stanza"

  if ! grep -q '{{appdir}}/NanoDictate\.app' <<<"$postflight"; then
    fail "$file must target {{appdir}}/NanoDictate.app inside postflight_steps"
  fi

  if grep -q '#{appdir}/NanoDictate\.app' <<<"$postflight"; then
    fail "$file must not use Ruby #{appdir} interpolation inside postflight_steps"
  fi
  if ! grep -q 'run "/usr/bin/xattr"' <<<"$postflight"; then
    fail "$file must invoke run \"/usr/bin/xattr\" inside postflight_steps"
  fi
  if ! grep -q '"-dr", "com\.apple\.quarantine"' <<<"$postflight"; then
    fail "$file must strip exactly com.apple.quarantine via xattr -dr"
  fi
  if grep -Eq '"-c"|\bcom\.apple\.(FinderInfo|ResourceFork|metadata|birthtime)\b' <<<"$postflight"; then
    fail "$file touches extended attributes beyond com.apple.quarantine"
  fi
  if grep -Eqi '\bspctl\b|\bgatekeeper\b' <<<"$postflight"; then
    fail "$file must not change Gatekeeper state"
  fi
done

normalize() {
  sed -e 's/__VERSION__//g' \
      -e 's/__ZIP_SHA256_ARM64__//g' \
      -e 's/__ZIP_SHA256_X86_64__//g' \
      -e 's/[0-9]\+\.[0-9]\+\.[0-9]\+//g' \
      -e 's/[0-9a-f]\{64\}//g' "$1" \
    | awk '
        /postflight_steps do/ { capture=1 }
        capture { print }
        capture && /^[[:space:]]*end[[:space:]]*$/ { exit }
      '
}

if [ "$(normalize "$TPL")" != "$(normalize "$GEN")" ]; then
  fail "postflight stanza drift between template and generated cask"
fi

echo "check-cask-postflight: PASS"
