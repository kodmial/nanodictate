#!/usr/bin/env bash
# Test suite for the Windows distribution contract (issue #195).
#
# Validates, on any bash + python3 host (CI runs it in windows.yml before
# touching a Windows runner):
#   * the Inno Setup script is the one real installer (per-user, x64,
#     stable AppId, silent-capable, preserves user config/logs, HKCU Run
#     autostart with the correct `run --background` verb, no MSIX mislabel),
#   * build-installer.ps1 wires the single Version.swift source, validates
#     required bits fail-closed, never mints a pretend certificate, and
#     supports -RequireSigned,
#   * test-installer.ps1 covers install -> version -> upgrade -> uninstall
#     with user-data preservation and orphan checks,
#   * scripts/make_winget_manifests.py generates and validates the WinGet
#     set for Kodmial.NanoDictate without claiming availability,
#   * windows.yml runs the installer gate and uploads logs,
#     windows-release.yml publishes fail-closed into the same release, and
#     winget-submit.yml automates manifests without fabricating availability,
#   * windows/DISTRIBUTION.md distinguishes Implemented vs Pending and never
#     presents msix-stage/ as an installer or WinGet as available,
#   * the console host exposes a `version` verb backed by HostApp.ProductVersion.
#
# Runs:  bash scripts/test-windows-distribution.sh
# Exits 0 when every case passes, 1 otherwise. Fixtures live under
# .opencode-tmp/ inside the worktree (never in /tmp) and are removed on exit.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel) || exit 1
ISS="${REPO_ROOT}/windows/package/nanodictate.iss"
BUILD_PS1="${REPO_ROOT}/windows/package/build-installer.ps1"
TEST_PS1="${REPO_ROOT}/windows/package/test-installer.ps1"
WINGET_PY="${REPO_ROOT}/scripts/make_winget_manifests.py"
WINDOWS_YML="${REPO_ROOT}/.github/workflows/windows.yml"
RELEASE_YML="${REPO_ROOT}/.github/workflows/windows-release.yml"
WINGET_YML="${REPO_ROOT}/.github/workflows/winget-submit.yml"
DISTRIBUTION_MD="${REPO_ROOT}/windows/DISTRIBUTION.md"
PROGRAM_CS="${REPO_ROOT}/windows/src/NanoDictate.Host/Program.cs"
HOSTAPP_CS="${REPO_ROOT}/windows/src/NanoDictate.Core/HostApp.cs"

mkdir -p "${REPO_ROOT}/.opencode-tmp" || exit 1
TMP_DIR=$(mktemp -d "${REPO_ROOT}/.opencode-tmp/windows-distribution-tests.XXXXXX") || exit 1
PASSED=0
FAILED=0

cleanup() {
  rm -rf "$TMP_DIR"
  rmdir "${REPO_ROOT}/.opencode-tmp" 2>/dev/null || true
}
trap cleanup EXIT

fail() {
  FAILED=$(( FAILED + 1 ))
  printf 'not ok - %s\n' "$1"
  [[ $# -lt 2 ]] || printf '  %s\n' "$2"
}

pass() {
  PASSED=$(( PASSED + 1 ))
  printf 'ok - %s\n' "$1"
}

assert_contains() {
  local name=$1 file=$2 needle=$3
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    pass "$name"
  else
    fail "$name" "expected '$file' to contain: $needle"
  fi
}

assert_not_contains() {
  local name=$1 file=$2 needle=$3
  if grep -qF -- "$needle" "$file" 2>/dev/null; then
    fail "$name" "expected '$file' NOT to contain: $needle"
  else
    pass "$name"
  fi
}

assert_file() {
  if [[ -f "$1" ]]; then pass "$2"; else fail "$2" "missing file: $1"; fi
}

# --- 1. Installer files exist ------------------------------------------------
assert_file "$ISS" "iss: nanodictate.iss exists"
assert_file "$BUILD_PS1" "build: build-installer.ps1 exists"
assert_file "$TEST_PS1" "test: test-installer.ps1 exists"
assert_file "$WINGET_PY" "winget: make_winget_manifests.py exists"
assert_file "$WINDOWS_YML" "ci: windows.yml exists"
assert_file "$RELEASE_YML" "release: windows-release.yml exists"
assert_file "$WINGET_YML" "winget: winget-submit.yml exists"

# --- 2. Inno script: one real per-user installer ------------------------------
assert_contains "iss: per-user privileges" "$ISS" "PrivilegesRequired=lowest"
assert_contains "iss: x64 only" "$ISS" "ArchitecturesAllowed=x64compatible"
assert_contains "iss: stable AppId" "$ISS" "AppId={{7A3B1C9D-4E2F-4A5B-8C6D-1A2B3C4D5E01}"
assert_contains "iss: Win10 22H2 floor" "$ISS" "MinVersion=10.0.19045"
assert_contains "iss: version stamped by build" "$ISS" 'OutputBaseFilename=NanoDictate-Setup-{#MyAppVersion}-x64'
assert_contains "iss: ships Rust DLL via staged files" "$ISS" 'Source: "{#SourceDir}\*"'
assert_contains "iss: autostart task" "$ISS" 'Name: "autostart"'
assert_contains "iss: HKCU Run with background verb" "$ISS" 'run --background'
assert_contains "iss: uninstall removes Run value" "$ISS" "uninsdeletevalue"
# The ISS must not produce or mislabel an MSIX package: no .msix/.appx outputs
# and no AppxManifest payload. (An explanatory comment naming MakeAppx as the
# reason MSIX is not shipped is allowed and required by the contract.)
assert_not_contains "iss: never produces .msix" "$ISS" ".msix"
assert_not_contains "iss: never produces .appx" "$ISS" ".appx"
assert_not_contains "iss: never stages AppxManifest" "$ISS" "AppxManifest"
if grep -q "UninstallDelete" "$ISS" 2>/dev/null; then
  fail "iss: preserves user data" "ISS must not carry [UninstallDelete] for config/logs"
else
  pass "iss: preserves user data"
fi

# --- 3. Build script: single version source + fail-closed + honest signing ----
assert_contains "build: reads Version.swift" "$BUILD_PS1" "Sources/NanoDictateCore/Version.swift"
assert_contains "build: self-contained host" "$BUILD_PS1" "--self-contained true"
assert_contains "build: requires WinUI exe" "$BUILD_PS1" "NanoDictate.App.exe"
assert_contains "build: requires Rust DLL" "$BUILD_PS1" "nanodictate_core.dll"
assert_contains "build: fails on missing bits" "$BUILD_PS1" "Installer stage is missing required file"
assert_contains "build: supports RequireSigned" "$BUILD_PS1" "RequireSigned"
assert_contains "build: no pretend certificate" "$BUILD_PS1" "never generates a pretend"
assert_contains "build: writes SHA sidecar" "$BUILD_PS1" ".sha256"
assert_contains "build: refuses small installer" "$BUILD_PS1" "suspiciously small"

# --- 4. Installer test: full lifecycle -----------------------------------------
assert_contains "test: silent install" "$TEST_PS1" "/VERYSILENT"
assert_contains "test: reads version" "$TEST_PS1" "version"
assert_contains "test: runs doctor" "$TEST_PS1" "doctor"
assert_contains "test: runs providers" "$TEST_PS1" "providers"
assert_contains "test: upgrade preserves config" "$TEST_PS1" "Upgrade preserved user config"
assert_contains "test: uninstall preserves data" "$TEST_PS1" "preserved user config"
assert_contains "test: asserts no orphans" "$TEST_PS1" "Orphaned installation"

# --- 5. WinGet generator: real manifests, no fabricated availability ------------
VERSION_FILE="${REPO_ROOT}/Sources/NanoDictateCore/Version.swift"
FILE_VERSION=$(grep -m1 -oE '[0-9]+\.[0-9]+\.[0-9]+' "$VERSION_FILE" || true)
if [[ -z "$FILE_VERSION" ]]; then
  fail "winget: Version.swift carries a semver" "cannot extract version"
  FILE_VERSION="0.1.32"
else
  pass "winget: Version.swift carries a semver"
fi
SHA_FIXTURE="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
URL_FIXTURE="https://github.com/kodmial/nanodictate/releases/download/v${FILE_VERSION}/NanoDictate-Setup-${FILE_VERSION}-x64.exe"
if python3 "$WINGET_PY" --version "$FILE_VERSION" --url "$URL_FIXTURE" --sha256 "$SHA_FIXTURE" --out "$TMP_DIR/winget" >/dev/null 2>&1; then
  pass "winget: generator succeeds for current Version.swift"
else
  fail "winget: generator succeeds for current Version.swift" "python3 $WINGET_PY failed"
fi
assert_contains "winget: package id" "$TMP_DIR/winget/$FILE_VERSION/Kodmial.NanoDictate.yaml" "PackageIdentifier: Kodmial.NanoDictate"
assert_contains "winget: inno type" "$TMP_DIR/winget/$FILE_VERSION/Kodmial.NanoDictate.installer.yaml" "InstallerType: inno"
assert_contains "winget: silent switch" "$TMP_DIR/winget/$FILE_VERSION/Kodmial.NanoDictate.installer.yaml" "Silent: /SILENT"
assert_contains "winget: user scope" "$TMP_DIR/winget/$FILE_VERSION/Kodmial.NanoDictate.installer.yaml" "Scope: user"
assert_contains "winget: upgrade behavior" "$TMP_DIR/winget/$FILE_VERSION/Kodmial.NanoDictate.installer.yaml" "uninstallPrevious"
# Fail-closed inputs.
if python3 "$WINGET_PY" --version "9.9.9" --url "$URL_FIXTURE" --sha256 "$SHA_FIXTURE" --out "$TMP_DIR/winget-bad" >/dev/null 2>&1; then
  fail "winget: rejects out-of-policy version" "generator accepted 9.9.9"
else
  pass "winget: rejects out-of-policy version"
fi
if python3 "$WINGET_PY" --version "$FILE_VERSION" --url "$URL_FIXTURE" --sha256 "xyz" --out "$TMP_DIR/winget-bad" >/dev/null 2>&1; then
  fail "winget: rejects malformed sha" "generator accepted 'xyz'"
else
  pass "winget: rejects malformed sha"
fi

# --- 6. Workflows ----------------------------------------------------------------
assert_contains "windows.yml: builds installer" "$WINDOWS_YML" "build-installer.ps1"
assert_contains "windows.yml: install smoke" "$WINDOWS_YML" "test-installer.ps1"
assert_contains "windows.yml: uploads install logs" "$WINDOWS_YML" "install-test-logs"
assert_contains "windows.yml: validates manifests" "$WINDOWS_YML" "make_winget_manifests.py"
assert_contains "windows.yml: Inno installed" "$WINDOWS_YML" "innosetup"
assert_contains "release: attaches to same release" "$RELEASE_YML" "gh release upload"
assert_contains "release: never overwrites bytes" "$RELEASE_YML" "no --clobber"
assert_contains "release: require signed" "$RELEASE_YML" "-RequireSigned"
assert_contains "release: fail-closed assets" "$RELEASE_YML" "missing required Windows asset"
assert_contains "winget: validates hash" "$WINGET_YML" "SHA-256"
assert_contains "winget: no false availability" "$WINGET_YML" "NOT available"

# --- 7. Docs distinguish implemented vs pending ------------------------------------
assert_contains "docs: implemented section" "$DISTRIBUTION_MD" "## Implemented"
assert_contains "docs: pending section" "$DISTRIBUTION_MD" "## Pending"
assert_contains "docs: direct download path" "$DISTRIBUTION_MD" "direct GitHub Release download"
assert_contains "docs: silent flags" "$DISTRIBUTION_MD" "/VERYSILENT"
assert_contains "docs: signing provisioning" "$DISTRIBUTION_MD" "WINDOWS_SIGN_PFX_B64"
assert_contains "docs: WinGet tentative" "$DISTRIBUTION_MD" "tentative until approved"
assert_not_contains "docs: never claims MSIX installable" "$DISTRIBUTION_MD" "install the signed MSIX"
if grep -q "winget install --id Kodmial.NanoDictate" "$DISTRIBUTION_MD" 2>/dev/null \
  && grep -q "NOT available" "$DISTRIBUTION_MD" 2>/dev/null; then
  pass "docs: WinGet commands paired with availability guard"
else
  fail "docs: WinGet commands paired with availability guard" "commands must ship with a NOT-available guard"
fi

# --- 8. Host version verb -----------------------------------------------------------
assert_contains "host: version verb" "$PROGRAM_CS" '"version" or "--version"'
assert_contains "host: ProductVersion" "$HOSTAPP_CS" "ProductVersion"
assert_file "${REPO_ROOT}/windows/tests/NanoDictate.Core.Tests/ProductVersionTests.cs" "tests: ProductVersionTests exists"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
