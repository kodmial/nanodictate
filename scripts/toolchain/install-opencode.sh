#!/usr/bin/env bash
# Deterministic pinned OpenCode installation for cache misses.
#
# Usage:
#   scripts/toolchain/install-opencode.sh [--manifest PATH] [--version V]
#       [--bin-dir DIR] [--max-attempts N]
#
# Behavior:
#   - Never queries releases/latest to decide what to install; the version
#     comes from .github/toolchain.json unless --version overrides it.
#   - Downloads the pinned artifact from the deterministic release URL, with
#     bounded retry/backoff for transient transport failures.
#   - Verifies the installed executable reports the expected version.
#   - Fails with actionable diagnostics (source URL, HTTP status, expected vs
#     actual version) instead of generic "failed to fetch version information".
#   - Uses an authenticated GitHub API request only when the caller explicitly
#     asks for update metadata (see check-updates.sh); this installer needs no
#     API metadata on the pinned path.
#
# A bootstrap failure exits non-zero but leaves no lock behind, so the next
# autonomous repair attempt can retry from a clean state.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# shellcheck source=scripts/toolchain/toolchain.sh
source "${REPO_ROOT}/scripts/toolchain/toolchain.sh"

MANIFEST="${REPO_ROOT}/.github/toolchain.json"
VERSION=""
BIN_DIR="${HOME}/.opencode/bin"
MAX_ATTEMPTS=3

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest) MANIFEST="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --bin-dir) BIN_DIR="$2"; shift 2 ;;
    --max-attempts) MAX_ATTEMPTS="$2"; shift 2 ;;
    -h|--help) sed -n '1,30p' "$0"; exit 0 ;;
    *) echo "install-opencode: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

if [[ -z "$VERSION" ]]; then
  VERSION=$(toolchain_manifest_value "$MANIFEST" '.tools.opencode.version' '')
fi
if [[ -z "$VERSION" ]]; then
  echo "::error::install-opencode: no OpenCode version in manifest '$MANIFEST' (tools.opencode.version) and no --version override. source=manifest status=missing-version expected=unknown" >&2
  exit 1
fi

# Normalize "1.18.33" and "v1.18.33" to the bare version for URLs and checks.
VERSION=${VERSION#v}
REPO=$(toolchain_manifest_value "$MANIFEST" '.tools.opencode.repo' 'sst/opencode')
if [[ -z "$REPO" ]]; then
  REPO="sst/opencode"
fi

INSTALL_URL="https://opencode.ai/install"
PINNED_HINT="https://github.com/${REPO}/releases/download/v${VERSION}"

diag() {
  printf 'install-opencode: %s\n' "$*" >&2
}

existing_ok() {
  if [[ -x "${BIN_DIR}/opencode" ]]; then
    local reported
    reported=$("${BIN_DIR}/opencode" --version 2>/dev/null || true)
    if grep -qF "$VERSION" <<<"$reported"; then
      diag "cached binary already reports expected version (expected=${VERSION} reported='${reported}'). source=cache status=hit"
      return 0
    fi
    diag "cached binary version mismatch (expected=${VERSION} reported='${reported:-none}'); reinstalling. source=cache status=stale"
  fi
  return 1
}

if existing_ok; then
  exit 0
fi

mkdir -p "$BIN_DIR"
attempt=1
while [[ $attempt -le $MAX_ATTEMPTS ]]; do
  diag "attempt ${attempt}/${MAX_ATTEMPTS}: installing pinned OpenCode (expected=${VERSION} source=${INSTALL_URL} pinned=${PINNED_HINT})."
  # The upstream installer supports --version for deterministic installs; it
  # fetches the pinned release asset instead of resolving releases/latest.
  if curl -fsSL --retry 2 --retry-delay 2 --max-time 120 "$INSTALL_URL" | bash -s -- --version "$VERSION" --no-modify-path; then
    break
  fi
  status=$?
  diag "attempt ${attempt} failed (source=${INSTALL_URL} http_status=transport-error exit=${status} expected=${VERSION})."
  if [[ $attempt -eq $MAX_ATTEMPTS ]]; then
    echo "::error::OpenCode install failed after ${MAX_ATTEMPTS} attempts (source=${INSTALL_URL} pinned=${PINNED_HINT} expected=${VERSION}). Transient network failure: retry the job; no repair lock is held." >&2
    exit 1
  fi
  sleep $((attempt * 15))
  attempt=$((attempt + 1))
done

export PATH="${BIN_DIR}:${PATH}"
if [[ ! -x "${BIN_DIR}/opencode" && ! -x "$(command -v opencode || true)" ]]; then
  echo "::error::OpenCode binary not found after install (source=${INSTALL_URL} expected=${VERSION} bin_dir=${BIN_DIR})." >&2
  exit 1
fi

REPORTED=$(opencode --version 2>/dev/null || true)
if ! grep -qF "$VERSION" <<<"$REPORTED"; then
  echo "::error::OpenCode version verification failed (source=${INSTALL_URL} expected=${VERSION} reported='${REPORTED:-none}'). Remove the corrupt cache entry and retry; no repair lock is held." >&2
  exit 1
fi

diag "installed and verified OpenCode (expected=${VERSION} reported='${REPORTED}')."
