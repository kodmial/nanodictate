#!/usr/bin/env bash
# Daily upstream update discovery for managed toolchain versions.
#
# Usage:
#   scripts/toolchain/check-updates.sh [--manifest PATH] [--apply] [--report PATH]
#
# Behavior:
#   - Compares pinned manifest versions against current stable upstream
#     versions (OpenCode via authenticated GitHub API, cbindgen via
#     authenticated GitHub API, Rust via the manifest channel).
#   - Never mutates a running job: without --apply it only reports.
#   - With --apply it rewrites the manifest versions in place; the caller
#     (toolchain-update.yml) turns that diff into a reviewable PR, and the
#     changed manifest naturally generates new cache keys after merge.
#   - No-op (exit 0, "no updates") when nothing changed, so the schedule
#     creates no noise.
#   - Update-check failures are reported as actionable diagnostics and exit 0
#     with status=check-failed, so a transient API outage never breaks normal
#     cached jobs.
#
# Test hooks (no network):
#   MOCK_LATEST_OPENCODE, MOCK_LATEST_CBINDGEN — pretend upstream versions.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
# shellcheck source=scripts/toolchain/toolchain.sh
source "${REPO_ROOT}/scripts/toolchain/toolchain.sh"

MANIFEST="${REPO_ROOT}/.github/toolchain.json"
APPLY=0
REPORT=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --manifest) MANIFEST="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --report) REPORT="$2"; shift 2 ;;
    -h|--help) sed -n '1,32p' "$0"; exit 0 ;;
    *) echo "check-updates: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

CURRENT_OPENCODE=$(toolchain_manifest_value "$MANIFEST" '.tools.opencode.version' '')
CURRENT_CBINDGEN=$(toolchain_manifest_value "$MANIFEST" '.tools.cbindgen.version' '')
OPENCODE_REPO=$(toolchain_manifest_value "$MANIFEST" '.tools.opencode.repo' 'sst/opencode')

github_latest_tag() {
  local repo=$1 mock=${2:-}
  if [[ -n "$mock" ]]; then
    printf '%s' "$mock"
    return 0
  fi
  local auth=()
  if [[ -n "${GH_TOKEN:-${GITHUB_TOKEN:-}}" ]]; then
    auth=(-H "Authorization: Bearer ${GH_TOKEN:-${GITHUB_TOKEN:-}}")
  fi
  local tag
  if ! tag=$(curl -fsSL --max-time 30 "${auth[@]}" -H "Accept: application/vnd.github+json" \
      "https://api.github.com/repos/${repo}/releases/latest" 2>/dev/null \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('tag_name',''))" 2>/dev/null); then
    return 1
  fi
  [[ -n "$tag" ]] || return 1
  printf '%s' "${tag#v}"
}

STATUS="ok"
NOTES=()
LATEST_OPENCODE=""
LATEST_CBINDGEN=""

if LATEST_OPENCODE=$(github_latest_tag "$OPENCODE_REPO" "${MOCK_LATEST_OPENCODE:-}"); then
  :
else
  STATUS="check-failed"
  NOTES+=("opencode: upstream lookup failed (source=api.github.com/repos/${OPENCODE_REPO}/releases/latest); normal cached jobs are unaffected.")
  LATEST_OPENCODE="$CURRENT_OPENCODE"
fi

if LATEST_CBINDGEN=$(github_latest_tag "mozilla/cbindgen" "${MOCK_LATEST_CBINDGEN:-}"); then
  :
else
  STATUS="check-failed"
  NOTES+=("cbindgen: upstream lookup failed (source=api.github.com/repos/mozilla/cbindgen/releases/latest); normal cached jobs are unaffected.")
  LATEST_CBINDGEN="$CURRENT_CBINDGEN"
fi

CHANGES=()
if [[ -n "$LATEST_OPENCODE" && -n "$CURRENT_OPENCODE" && "$LATEST_OPENCODE" != "$CURRENT_OPENCODE" ]]; then
  CHANGES+=("opencode: ${CURRENT_OPENCODE} -> ${LATEST_OPENCODE}")
fi
if [[ -n "$LATEST_CBINDGEN" && -n "$CURRENT_CBINDGEN" && "$LATEST_CBINDGEN" != "$CURRENT_CBINDGEN" ]]; then
  CHANGES+=("cbindgen: ${CURRENT_CBINDGEN} -> ${LATEST_CBINDGEN}")
fi

if [[ $APPLY -eq 1 && ${#CHANGES[@]} -gt 0 ]]; then
  if command -v python3 >/dev/null 2>&1; then
    MANIFEST_PATH="$MANIFEST" OPENCODE_V="$LATEST_OPENCODE" CBINDGEN_V="$LATEST_CBINDGEN" python3 - <<'PY'
import json, os
path = os.environ["MANIFEST_PATH"]
with open(path) as fh:
    data = json.load(fh)
tools = data.setdefault("tools", {})
op = tools.setdefault("opencode", {})
cb = tools.setdefault("cbindgen", {})
new_oc = os.environ.get("OPENCODE_V", "")
new_cb = os.environ.get("CBINDGEN_V", "")
if new_oc:
    op["version"] = new_oc
    repo = op.get("repo", "sst/opencode")
    op["asset_url"] = f"https://github.com/{repo}/releases/download/v{new_oc}"
    op["install"] = f"curl -fsSL https://opencode.ai/install | bash -s -- --version {new_oc} --no-modify-path"
if new_cb:
    cb["version"] = new_cb
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
  else
    echo "check-updates: python3 is required for --apply" >&2
    exit 1
  fi
fi

if [[ ${#CHANGES[@]} -eq 0 && "$STATUS" == "ok" ]]; then
  RESULT="no-updates"
elif [[ ${#CHANGES[@]} -eq 0 ]]; then
  RESULT="check-failed"
else
  RESULT="updates-available"
fi

SUMMARY="toolchain update check: ${RESULT} (opencode current=${CURRENT_OPENCODE} latest=${LATEST_OPENCODE}; cbindgen current=${CURRENT_CBINDGEN} latest=${LATEST_CBINDGEN})"
for note in ${NOTES[@]+"${NOTES[@]}"}; do SUMMARY+=$'\n'"$note"; done
for change in ${CHANGES[@]+"${CHANGES[@]}"}; do SUMMARY+=$'\n'"pending manifest change: $change"; done

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    printf 'result=%s\n' "$RESULT"
    printf 'latest_opencode=%s\n' "$LATEST_OPENCODE"
    printf 'latest_cbindgen=%s\n' "$LATEST_CBINDGEN"
    printf 'changes=%s\n' "${CHANGES[*]:-}"
  } >>"$GITHUB_OUTPUT"
fi

if [[ -n "$REPORT" ]]; then
  printf '%s\n' "$SUMMARY" >"$REPORT"
fi
printf '%s\n' "$SUMMARY"

# No-op stays green and quiet; failures in discovery never fail cached jobs.
exit 0
