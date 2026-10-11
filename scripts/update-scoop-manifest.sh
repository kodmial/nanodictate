#!/usr/bin/env bash
# Publish a SHA256-pinned first-party Scoop manifest from a completed release.
set -euo pipefail
VERSION="$1"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Invalid release version" >&2; exit 2; }
[[ -n "$GH_TOKEN" ]] || { echo "GH_TOKEN is required" >&2; exit 2; }
REPO="kodmial/nanodictate"
TAG="v$VERSION"
ZIP="nanodictate-$VERSION-windows-x64.zip"
SETUP="nanodictate-$VERSION-windows-x64-setup.exe"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
gh release download "$TAG" -R "$REPO" -p "$ZIP" -p "$SETUP" -p SHA256SUMS.txt -D "$WORK" --clobber
for name in "$ZIP" "$SETUP"; do
  published="$(awk -v name="$name" '$2==name {print $1}' "$WORK/SHA256SUMS.txt")"
  [[ "$published" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "Missing checksum for $name" >&2; exit 1; }
  actual="$(sha256sum "$WORK/$name" | awk '{print $1}')"
  [[ "$(printf %s "$published" | tr '[:upper:]' '[:lower:]')" == "$actual" ]] || { echo "Checksum mismatch for $name" >&2; exit 1; }
done
SHA="$(sha256sum "$WORK/$ZIP" | awk '{print $1}')"
URL="https://github.com/$REPO/releases/download/$TAG/$ZIP"
jq -n --arg version "$VERSION" --arg url "$URL" --arg hash "$SHA" \
  -f scripts/scoop-manifest.jq > "$WORK/nanodictate.json"
jq -e '.version and .architecture["64bit"].hash and .shortcuts and (.post_install | length >= 2) and (.pre_uninstall | length > 0)' "$WORK/nanodictate.json" >/dev/null
CONTENTS="repos/$REPO/contents/bucket/nanodictate.json"
CURRENT_SHA="$(gh api "$CONTENTS" --jq '.sha' 2>/dev/null || true)"
ENCODED="$(base64 -w0 "$WORK/nanodictate.json")"
if [[ -n "$CURRENT_SHA" ]]; then
  gh api -X PUT "$CONTENTS" \
    -f message="chore(scoop): pin NanoDictate $TAG to verified SHA256 [skip ci]" \
    -f branch=main -f sha="$CURRENT_SHA" -f content="$ENCODED" > /dev/null
else
  gh api -X PUT "$CONTENTS" \
    -f message="chore(scoop): publish NanoDictate $TAG [skip ci]" \
    -f branch=main -f content="$ENCODED" > /dev/null
fi
EXPECTED="$(jq -cS . "$WORK/nanodictate.json")"
ACTUAL="$(gh api "$CONTENTS" --jq .content | base64 -d | jq -cS .)"
[[ "$EXPECTED" == "$ACTUAL" ]] || { echo "Scoop manifest readback mismatch" >&2; exit 1; }
echo "Published first-party Scoop manifest for $TAG (SHA256 $SHA)"
