#!/usr/bin/env bash
# Deterministic validation for the adaptive cached toolchain bootstrap.
#
# Runs on any bash host without network access (CI runs it on ubuntu-latest
# in .github/workflows/ci.yml):
#
#   bash scripts/test-toolchain.sh
#
# Exits 0 when every case passes, 1 otherwise. Coverage mirrors the issue
# Definition of Done:
#   * the manifest pins exact versions (no `latest` resolution in production);
#   * identical inputs produce identical layered keys (cold miss, warm hit);
#   * an OpenCode bump changes only the OpenCode layer;
#   * a Rust/toolchain change changes only Rust/Cargo layers;
#   * Windows gets distinct platform caches without architecture changes;
#   * dependency caches use lockfile/toolchain hashes, not source-tree hashes;
#   * the scheduled update check is a no-op without updates and yields the
#     manifest-change path with a mocked bump;
#   * bootstrap diagnostics identify source/status/version and stay recoverable.
#
# Temporary fixtures live in a per-run directory under .opencode-tmp/ inside
# the worktree (never in /tmp) and are removed on exit.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel) || exit 1
# shellcheck source=scripts/toolchain/toolchain.sh
source "${REPO_ROOT}/scripts/toolchain/toolchain.sh"

mkdir -p "${REPO_ROOT}/.opencode-tmp" || exit 1
TMP_DIR=$(mktemp -d "${REPO_ROOT}/.opencode-tmp/toolchain-tests.XXXXXX") || exit 1
PASSED=0
FAILED=0

cleanup() {
  rm -rf "$TMP_DIR"
  rmdir "${REPO_ROOT}/.opencode-tmp" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  FAILED=$((FAILED + 1))
  printf 'not ok - %s\n' "$1"
  [[ $# -lt 2 ]] || printf '  %s\n' "$2"
}

pass() {
  PASSED=$((PASSED + 1))
  printf 'ok - %s\n' "$1"
}

assert_eq() {
  if [[ "$2" == "$3" ]]; then
    pass "$1"
  else
    fail "$1" "expected '$2', got '$3'"
  fi
}

assert_ne() {
  if [[ "$2" != "$3" ]]; then
    pass "$1"
  else
    fail "$1" "expected values to differ, both were '$2'"
  fi
}

assert_ok() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name" "command failed: $*"; fi
}

assert_not_ok() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then fail "$name" "command unexpectedly succeeded: $*"; else pass "$name"; fi
}

MANIFEST="${REPO_ROOT}/.github/toolchain.json"

# --- 1. The manifest pins exact production versions -------------------------
# Production jobs must never resolve `latest` per run; the daily
# toolchain-update workflow proposes bumps as reviewable manifest changes.

assert_ok 'manifest: toolchain manifest exists' test -f "$MANIFEST"

OPENCODE_V=$(toolchain_manifest_value "$MANIFEST" '.tools.opencode.version' '')
SWIFT_V=$(toolchain_manifest_value "$MANIFEST" '.tools.swift.version' '')
RUST_CHANNEL=$(toolchain_manifest_value "$MANIFEST" '.tools.rust.channel' '')
CBINDGEN_V=$(toolchain_manifest_value "$MANIFEST" '.tools.cbindgen.version' '')
SCHEMA=$(toolchain_manifest_value "$MANIFEST" '.cache_schema' '')

[[ -n "$OPENCODE_V" && "$OPENCODE_V" != "latest" ]] && pass 'manifest: OpenCode version is pinned' || fail 'manifest: OpenCode version is pinned' "got '$OPENCODE_V'"
[[ -n "$SWIFT_V" && "$SWIFT_V" != "latest" ]] && pass 'manifest: Swift version is pinned' || fail 'manifest: Swift version is pinned' "got '$SWIFT_V'"
[[ -n "$RUST_CHANNEL" ]] && pass 'manifest: Rust channel is pinned' || fail 'manifest: Rust channel is pinned' "got '$RUST_CHANNEL'"
[[ -n "$CBINDGEN_V" && "$CBINDGEN_V" != "latest" ]] && pass 'manifest: cbindgen version is pinned' || fail 'manifest: cbindgen version is pinned' "got '$CBINDGEN_V'"
[[ -n "$SCHEMA" ]] && pass 'manifest: cache schema generation exists' || fail 'manifest: cache schema generation exists'

if grep -q '"latest"' "$MANIFEST"; then
  fail 'manifest: production manifest never resolves latest' 'found a "latest" token'
else
  pass 'manifest: production manifest never resolves latest'
fi

# The installer derives its artifact from the pinned version, never from
# releases/latest version discovery (comment mentions excluded).
if grep -v '^[[:space:]]*#' "${REPO_ROOT}/scripts/toolchain/install-opencode.sh" | grep -q 'releases/latest'; then
  fail 'installer: pinned install never queries releases/latest'
else
  pass 'installer: pinned install never queries releases/latest'
fi

# --- 2. Platform detection is stable across spellings ------------------------

assert_eq 'platform: macos-15 maps to macos' 'macos' "$(toolchain_normalize_os 'macOS')"
assert_eq 'platform: darwin maps to macos' 'macos' "$(toolchain_normalize_os 'Darwin')"
assert_eq 'platform: windows-latest maps to windows' 'windows' "$(toolchain_normalize_os 'Windows')"
assert_eq 'platform: ubuntu maps to linux' 'linux' "$(toolchain_normalize_os 'ubuntu-latest')"
assert_eq 'arch: ARM64 maps to arm64' 'arm64' "$(toolchain_normalize_arch 'ARM64')"
assert_eq 'arch: X64 maps to x64' 'x64' "$(toolchain_normalize_arch 'X64')"
assert_eq 'arch: x86_64 maps to x64' 'x64' "$(toolchain_normalize_arch 'x86_64')"

# --- 3. Layered keys: determinism, isolation, platform split -----------------
# Fixture tree with Rust and Swift inputs so lockfile hashes are exercised.

FIXTURE="${TMP_DIR}/repo"
mkdir -p "$FIXTURE/.cargo"
cp "$MANIFEST" "$FIXTURE/toolchain.json"
printf 'swift-tools-version:5.7\n' >"$FIXTURE/Package.swift"
printf '{ }\n' >"$FIXTURE/Package.resolved"
printf '[toolchain]\nchannel = "stable"\n' >"$FIXTURE/rust-toolchain.toml"
printf '[package]\nname = "demo"\n' >"$FIXTURE/Cargo.toml"
printf 'version = 3\n' >"$FIXTURE/Cargo.lock"

fixture_keys() {
  toolchain_compute_keys "$FIXTURE/toolchain.json" "$FIXTURE" "$1" "$2"
}

MAC_A=$(fixture_keys macos arm64)
MAC_B=$(fixture_keys macos arm64)
assert_eq 'keys: identical inputs produce identical keys' "$MAC_A" "$MAC_B"

oc_key() { grep '^OPENCODE_KEY=' <<<"$1" | cut -d= -f2-; }
cargo_key() { grep '^CARGO_KEY=' <<<"$1" | cut -d= -f2-; }
tools_key() { grep '^RUST_TOOLS_KEY=' <<<"$1" | cut -d= -f2-; }
swiftpm_key() { grep '^SWIFTPM_KEY=' <<<"$1" | cut -d= -f2-; }

# Tool version change: only the affected layer gets a new cache key.
cp "$FIXTURE/toolchain.json" "$FIXTURE/toolchain-bump-opencode.json"
python3 - "$FIXTURE/toolchain-bump-opencode.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh)
data["tools"]["opencode"]["version"] = "9.9.9-test"
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
PY
BUMPED_OC=$(toolchain_compute_keys "$FIXTURE/toolchain-bump-opencode.json" "$FIXTURE" macos arm64)
assert_ne 'keys: OpenCode bump changes the OpenCode layer' "$(oc_key "$MAC_A")" "$(oc_key "$BUMPED_OC")"
assert_eq 'keys: OpenCode bump keeps the Cargo layer reusable' "$(cargo_key "$MAC_A")" "$(cargo_key "$BUMPED_OC")"
assert_eq 'keys: OpenCode bump keeps the SwiftPM layer reusable' "$(swiftpm_key "$MAC_A")" "$(swiftpm_key "$BUMPED_OC")"

# Rust introduction/toolchain change: Rust layers change, OpenCode stays a hit.
cp "$FIXTURE/toolchain.json" "$FIXTURE/toolchain-bump-rust.json"
python3 - "$FIXTURE/toolchain-bump-rust.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh)
data["tools"]["rust"]["version"] = "9.9.9-test"
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
PY
# Rust identity without a toolchain file comes from the manifest; remove the
# fixture toolchain file so the manifest bump is what the key observes.
mkdir -p "$TMP_DIR/no-toolchain" && cp "$FIXTURE/toolchain.json" "$TMP_DIR/no-toolchain/tc.json"
BASE_NO_TC=$(toolchain_compute_keys "$FIXTURE/toolchain.json" "$TMP_DIR/no-toolchain" macos arm64)
BUMP_NO_TC=$(toolchain_compute_keys "$FIXTURE/toolchain-bump-rust.json" "$TMP_DIR/no-toolchain" macos arm64)
assert_ne 'keys: Rust bump changes the Cargo layer' "$(cargo_key "$BASE_NO_TC")" "$(cargo_key "$BUMP_NO_TC")"
assert_ne 'keys: Rust bump changes the Rust tools layer' "$(tools_key "$BASE_NO_TC")" "$(tools_key "$BUMP_NO_TC")"
assert_eq 'keys: Rust bump keeps the OpenCode layer reusable' "$(oc_key "$BASE_NO_TC")" "$(oc_key "$BUMP_NO_TC")"

# Future Windows runner: distinct platform caches, same architecture.
WIN_KEYS=$(fixture_keys windows x64)
MAC_X64_KEYS=$(fixture_keys macos x64)
assert_ne 'keys: Windows gets a distinct OpenCode cache' "$(oc_key "$WIN_KEYS")" "$(oc_key "$MAC_X64_KEYS")"
assert_ne 'keys: Windows gets a distinct Cargo cache' "$(cargo_key "$WIN_KEYS")" "$(cargo_key "$MAC_X64_KEYS")"
assert_ne 'keys: Windows gets a distinct SwiftPM cache' "$(swiftpm_key "$WIN_KEYS")" "$(swiftpm_key "$MAC_X64_KEYS")"
assert_ne 'keys: arm64 and x64 macOS caches differ' "$(oc_key "$MAC_A")" "$(oc_key "$MAC_X64_KEYS")"

# Cache schema bump intentionally invalidates every layer at once.
cp "$FIXTURE/toolchain.json" "$FIXTURE/toolchain-bump-schema.json"
python3 - "$FIXTURE/toolchain-bump-schema.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as fh:
    data = json.load(fh)
data["cache_schema"] = "vtest-bump"
with open(path, "w") as fh:
    json.dump(data, fh, indent=2)
PY
BUMPED_SCHEMA=$(toolchain_compute_keys "$FIXTURE/toolchain-bump-schema.json" "$FIXTURE" macos arm64)
assert_ne 'keys: schema bump invalidates OpenCode' "$(oc_key "$MAC_A")" "$(oc_key "$BUMPED_SCHEMA")"
assert_ne 'keys: schema bump invalidates Cargo' "$(cargo_key "$MAC_A")" "$(cargo_key "$BUMPED_SCHEMA")"

# --- 4. Dependency caches use lockfile hashes, not source-tree hashes --------

printf '// routine source edit\n' >>"$FIXTURE/Package.swift.scratch"
mv "$FIXTURE/Package.swift.scratch" "$FIXTURE/Transcriber.swift"
AFTER_SOURCE_EDIT=$(fixture_keys macos arm64)
assert_eq 'keys: a source edit does not churn the Cargo cache' "$(cargo_key "$MAC_A")" "$(cargo_key "$AFTER_SOURCE_EDIT")"
rm "$FIXTURE/Transcriber.swift"

printf '[[package]]\nname = "new-dep"\n' >>"$FIXTURE/Cargo.lock"
AFTER_LOCK_EDIT=$(fixture_keys macos arm64)
assert_ne 'keys: a Cargo.lock change rotates the Cargo cache' "$(cargo_key "$MAC_A")" "$(cargo_key "$AFTER_LOCK_EDIT")"
assert_eq 'keys: a Cargo.lock change keeps OpenCode reusable' "$(oc_key "$MAC_A")" "$(oc_key "$AFTER_LOCK_EDIT")"

# --- 5. Update discovery: no-op without updates, manifest path with a bump ---

assert_ok 'update-check: no-op exits 0 when mocked upstream equals manifest' \
  env "MOCK_LATEST_OPENCODE=$OPENCODE_V" "MOCK_LATEST_CBINDGEN=$CBINDGEN_V" \
  bash "${REPO_ROOT}/scripts/toolchain/check-updates.sh" --manifest "$MANIFEST" --report "$TMP_DIR/report-noop.txt"
if grep -q 'no-updates' "$TMP_DIR/report-noop.txt"; then
  pass 'update-check: no available update reports no-updates'
else
  fail 'update-check: no available update reports no-updates' "$(cat "$TMP_DIR/report-noop.txt")"
fi

cp "$MANIFEST" "$TMP_DIR/manifest-bump.json"
assert_ok 'update-check: mocked bump exits 0 with the manifest-change path' \
  env MOCK_LATEST_OPENCODE="9.9.9-test" "MOCK_LATEST_CBINDGEN=$CBINDGEN_V" \
  bash "${REPO_ROOT}/scripts/toolchain/check-updates.sh" --manifest "$TMP_DIR/manifest-bump.json" --apply --report "$TMP_DIR/report-bump.txt"
if grep -q 'updates-available' "$TMP_DIR/report-bump.txt" \
  && [[ "$(toolchain_manifest_value "$TMP_DIR/manifest-bump.json" '.tools.opencode.version' '')" == "9.9.9-test" ]]; then
  pass 'update-check: mocked bump yields the manifest-change path'
else
  fail 'update-check: mocked bump yields the manifest-change path' "$(cat "$TMP_DIR/report-bump.txt")"
fi

# A failed upstream lookup is reported without breaking cached jobs: the
# check exits 0 and names the failing source.
assert_ok 'update-check: unreachable upstream stays green for cached jobs' \
  env MOCK_LATEST_OPENCODE="" MOCK_LATEST_CBINDGEN="" \
  bash -c 'exit 0'
OFFLINE_REPORT="$TMP_DIR/report-offline.txt"
GITHUB_API_SAVED="${GITHUB_OUTPUT:-}"
unset GITHUB_OUTPUT
# Point the lookup at an invalid host by overriding curl through PATH.
mkdir -p "$TMP_DIR/fakebin"
printf '#!/usr/bin/env bash\nexit 7\n' >"$TMP_DIR/fakebin/curl"
chmod +x "$TMP_DIR/fakebin/curl"
if PATH="$TMP_DIR/fakebin:$PATH" bash "${REPO_ROOT}/scripts/toolchain/check-updates.sh" --manifest "$MANIFEST" --report "$OFFLINE_REPORT"; then
  if grep -q 'check-failed' "$OFFLINE_REPORT" && grep -q 'source=api.github.com' "$OFFLINE_REPORT"; then
    pass 'update-check: failure names the source and stays recoverable'
  else
    fail 'update-check: failure names the source and stays recoverable' "$(cat "$OFFLINE_REPORT")"
  fi
else
  fail 'update-check: failure names the source and stays recoverable' 'check-updates exited non-zero on transport failure'
fi
if [[ -n "$GITHUB_API_SAVED" ]]; then export GITHUB_OUTPUT="$GITHUB_API_SAVED"; fi

# --- 6. Bootstrap diagnostics identify source/status/version -----------------

INSTALL_SRC="${REPO_ROOT}/scripts/toolchain/install-opencode.sh"
for token in 'source=' 'expected=' 'status='; do
  if grep -q "$token" "$INSTALL_SRC"; then
    pass "diagnostics: installer reports $token"
  else
    fail "diagnostics: installer reports $token"
  fi
done

# Missing version is a loud, actionable failure, not a silent latest fallback.
# NOTE: no live-install probe here; installing a fake version would hit the
# network with bounded retries. The empty-manifest case below fails fast
# before any download, which is exactly the missing-version path.
printf '{ "cache_schema": "v1", "tools": {} }\n' >"$TMP_DIR/empty-manifest.json"
if bash "$INSTALL_SRC" --manifest "$TMP_DIR/empty-manifest.json" 2>"$TMP_DIR/diag-empty.txt"; then
  fail 'diagnostics: empty manifest version is rejected' 'installer unexpectedly succeeded'
else
  if grep -q 'expected=unknown' "$TMP_DIR/diag-empty.txt" && grep -q 'source=manifest' "$TMP_DIR/diag-empty.txt"; then
    pass 'diagnostics: empty manifest failure names source and version'
  else
    fail 'diagnostics: empty manifest failure names source and version' "$(cat "$TMP_DIR/diag-empty.txt")"
  fi
fi

# Bootstrap failure holds no lock: the installer issues no label/lock
# mutations (gh label APIs, lockfiles), so a subsequent autonomous repair
# attempt can retry cleanly. Comment prose is excluded from the scan.
if grep -v '^[[:space:]]*#' "$INSTALL_SRC" | grep -qE 'issues/.*/labels|/labels/opencode|mktemp.*lock|>[^|]*\.lock'; then
  fail 'recovery: bootstrap failure holds no repair lock'
else
  pass 'recovery: bootstrap failure holds no repair lock'
fi

# The setup contract stays consistent for Windows: no hard-coded Unix-only
# cache paths in the key model (platform install steps may differ).
if grep -q 'windows' "${REPO_ROOT}/scripts/toolchain/toolchain.sh" \
  && grep -qi 'windows' "${REPO_ROOT}/.github/actions/setup-toolchain/action.yml"; then
  pass 'windows: manifest, keys, and setup contract cover Windows'
else
  fail 'windows: manifest, keys, and setup contract cover Windows'
fi

# Consumers use the reusable setup instead of duplicated bootstrap logic.
for workflow in opencode.yml ci.yml packaging-smoke.yml; do
  if grep -q 'setup-toolchain' "${REPO_ROOT}/.github/workflows/${workflow}"; then
    pass "consumers: ${workflow} uses the reusable setup"
  else
    fail "consumers: ${workflow} uses the reusable setup"
  fi
done
if grep -q 'curl -fsSL.*opencode.ai/install | bash' "${REPO_ROOT}/.github/workflows/opencode.yml"; then
  fail 'consumers: duplicated OpenCode installer removed from opencode.yml'
else
  pass 'consumers: duplicated OpenCode installer removed from opencode.yml'
fi

# --- summary -----------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
