#!/usr/bin/env bash
# Test suite for scripts/release-policy.sh — the release policy used by
# .github/workflows/bump-version.yml to decide whether a merge into main
# publishes a NanoDictate version.
#
# Runs on any bash + git host (CI runs it on ubuntu-latest in .github/workflows/ci.yml):
#
#   bash scripts/test-release-policy.sh
#
# Exits 0 when every case passes, 1 otherwise. The suite covers both halves of
# the policy that the workflow depends on:
#   * the explicit `skip-release` label (present -> green no-op, absent -> the
#     existing automatic policy applies), and
#   * the path-based guard, asserted against REAL `git diff` output from a
#     throwaway repository so a broken grep cannot pass the pure-function cases.
#
# Temporary fixtures live in a per-run directory under .opencode-tmp/ inside the
# worktree (never in /tmp) and are removed on exit.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel) || exit 1
# shellcheck source=scripts/release-policy.sh
source "${REPO_ROOT}/scripts/release-policy.sh"

# `mktemp -d` gives every run its own fixture repository, so two concurrent runs
# in the same worktree cannot delete each other's fixtures, and `cleanup` below
# only ever removes what this run created.
mkdir -p "${REPO_ROOT}/.opencode-tmp" || exit 1
TMP_DIR=$(mktemp -d "${REPO_ROOT}/.opencode-tmp/release-policy-tests.XXXXXX") || exit 1
PASSED=0
FAILED=0

cleanup() {
  rm -rf "$TMP_DIR"
  # Leave no trace in the worktree: drop the scratch parent too, but only when
  # nothing else is using it (rmdir refuses a non-empty directory).
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

# assert_eq <name> <expected> <actual>
assert_eq() {
  if [[ "$2" == "$3" ]]; then
    pass "$1"
  else
    fail "$1" "expected '$2', got '$3'"
  fi
}

# assert_ok <name> <command...> — the command must exit 0
assert_ok() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then pass "$name"; else fail "$name" "command failed: $*"; fi
}

# assert_not_ok <name> <command...> — the command must exit non-zero
assert_not_ok() {
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then fail "$name" "command unexpectedly succeeded: $*"; else pass "$name"; fi
}

# --- 1. The `skip-release` label is an explicit, exact-match override ------
# A label array as GitHub sends it in `pull_request.labels`.

LABELED='[{"id":1,"name":"skip-release","color":"5319e7","description":"Merge this PR without bumping or publishing a NanoDictate version."}]'
LABELED_WITH_OTHERS='[{"name":"documentation"},{"name":"skip-release"},{"name":"review-ready"}]'
UNLABELED='[{"name":"documentation"},{"name":"chore"}]'
EMPTY='[]'
ABSENT='null'
NEAR_MISS='[{"name":"skip-release-please"}]'
PREFIXED='[{"name":"no-skip-release"}]'
DESCRIPTION_ONLY='[{"name":"docs","description":"use skip-release for release PRs"}]'

assert_ok 'label: skip-release is detected' \
  policy_pr_has_label "$LABELED" skip-release
assert_ok 'label: detected alongside other labels' \
  policy_pr_has_label "$LABELED_WITH_OTHERS" skip-release
assert_not_ok 'label: absent -> no skip' \
  policy_pr_has_label "$UNLABELED" skip-release
assert_not_ok 'label: empty array -> no skip' \
  policy_pr_has_label "$EMPTY" skip-release
assert_not_ok 'label: null payload -> no skip' \
  policy_pr_has_label "$ABSENT" skip-release
assert_not_ok 'label: empty payload -> no skip' \
  policy_pr_has_label '' skip-release
assert_not_ok 'label: skip-release-please is not skip-release' \
  policy_pr_has_label "$NEAR_MISS" skip-release
assert_not_ok 'label: no-skip-release is not skip-release' \
  policy_pr_has_label "$PREFIXED" skip-release
assert_not_ok 'label: a description mentioning skip-release does not skip' \
  policy_pr_has_label "$DESCRIPTION_ONLY" skip-release
assert_not_ok 'label: unrelated labels are not overloaded' \
  policy_pr_has_label "$UNLABELED" skip-release

assert_eq 'label names: one per line' \
  $'bug\ndocumentation' \
  "$(policy_label_names '[{"name":"bug"},{"name":"documentation"}]')"
assert_eq 'label names: an empty array yields nothing' \
  '' "$(policy_label_names '[]')"
assert_eq 'label names: a null payload yields nothing' \
  '' "$(policy_label_names 'null')"

# The runner image ships jq, but the fallback must not rot: a PATH whose jq is
# a directory (so `command -v jq` fails) still has to detect the label, because
# the workflow must not break on a runner without jq.
NOJQ_BIN="${TMP_DIR}/nojq-bin"
mkdir -p "${NOJQ_BIN}/jq"
for tool in bash grep sed; do ln -sf "$(command -v "$tool")" "${NOJQ_BIN}/${tool}"; done
FALLBACK_LABELS=$(PATH="$NOJQ_BIN" bash -c \
  'source "$1"; policy_label_names "$2"' _ "${REPO_ROOT}/scripts/release-policy.sh" "$LABELED")
assert_eq 'label names: jq-less fallback still extracts names' \
  'skip-release' "$FALLBACK_LABELS"
if PATH="$NOJQ_BIN" bash -c \
  'source "$1"; policy_pr_has_label "$2" skip-release' \
  _ "${REPO_ROOT}/scripts/release-policy.sh" "$LABELED"; then
  pass 'label: jq-less fallback detects skip-release'
else
  fail 'label: jq-less fallback detects skip-release'
fi

# --- 2. The label decides BEFORE any path classification ---------------------
# The label must win even when the diff is unambiguously releasable.

RELEASABLE_DIFF=$'Sources/NanoDictateCore/VAD.swift\nSources/NanoDictateCore/Version.swift'
assert_eq 'decide: labeled PR skips even with real code changes' \
  'skip-release' \
  "$(policy_decide "$LABELED" "$RELEASABLE_DIFF" '')"
assert_eq 'decide: unlabeled PR with real code changes is releasable' \
  'releasable' \
  "$(policy_decide "$UNLABELED" "$RELEASABLE_DIFF" '')"
assert_eq 'decide: labeled PR skips before looking at an empty diff' \
  'skip-release' \
  "$(policy_decide "$LABELED" '' '')"
assert_eq 'decide: unlabeled PR with an empty diff is no-changes' \
  'no-changes' \
  "$(policy_decide "$UNLABELED" '' '')"
assert_eq 'decide: null labels fall through to the automatic policy' \
  'releasable' \
  "$(policy_decide "$ABSENT" "$RELEASABLE_DIFF" '')"

# --- 3. Path-based exclusions still work without the label -------------------

assert_eq 'paths: only excluded paths are non-releasable' \
  'non-releasable' \
  "$(policy_decide "$EMPTY" $'CHANGELOG.md\nREADME.md\ndocs/packaging/homebrew.md\n.github/workflows/ci.yml\n.githooks/pre-commit\npackaging/homebrew/nanodictate.rb\nnanodictate.rb\nconfig.example.toml\nSECURITY.md\nCODE_OF_CONDUCT.md\nCONTRIBUTING.md\nLICENSE\n.gitignore\n.swift-format\n.swiftlint.yml\n.coderabbit.yaml\nSources/NanoDictateCore/Version.swift' '')"
assert_eq 'paths: a single source change is releasable' \
  'releasable' \
  "$(policy_decide "$EMPTY" 'Sources/NanoDictateCore/Transcriber.swift' '')"
assert_eq 'paths: a source change among excluded files is still releasable' \
  'releasable' \
  "$(policy_decide "$EMPTY" $'CHANGELOG.md\nscripts/release-prep.rb\nREADME.md' '')"
assert_eq 'paths: the new policy script itself counts as a code change' \
  'releasable' \
  "$(policy_decide "$EMPTY" $'scripts/release-policy.sh\nscripts/test-release-policy.sh' '')"
assert_eq 'paths: .github is excluded, not a prefix-free match' \
  'non-releasable' \
  "$(policy_decide "$EMPTY" '.github/workflows/bump-version.yml' '')"
assert_eq 'paths: an unrelated nested file is not excluded' \
  'releasable' \
  "$(policy_decide "$EMPTY" 'Sources/NanoDictateCoreSupport/Helper.swift' '')"
assert_eq 'paths: whitespace-only diff list is no-changes' \
  'no-changes' \
  "$(policy_decide "$EMPTY" $'  \n' '')"

# The macports installer: a PIN_REV-only edit is generated, not a user change.
assert_eq 'installer: PIN_REV-only edit is non-releasable' \
  'non-releasable' \
  "$(policy_decide "$EMPTY" 'scripts/install-macports.sh' '')"
assert_eq 'installer: a real installer edit is releasable' \
  'releasable' \
  "$(policy_decide "$EMPTY" 'scripts/install-macports.sh' $'+-  local url="https://example.com"')"
assert_eq 'installer: PIN_REV-only plus a source change is releasable' \
  'releasable' \
  "$(policy_decide "$EMPTY" $'scripts/install-macports.sh\nSources/NanoDictateCore/Transcriber.swift' '')"

PIN_REV_ONLY_DIFF=$'--- a/scripts/install-macports.sh\n+++ b/scripts/install-macports.sh\n-PIN_REV=old\n+PIN_REV=new'
assert_eq 'installer: PIN_REV lines are filtered out of the diff' \
  '' \
  "$(printf '%s\n' "$PIN_REV_ONLY_DIFF" | policy_installer_diff_wo_pinrev)"
assert_eq 'installer: a real line survives the PIN_REV filter' \
  '-OLD_URL=x' \
  "$(printf '%s\n' $'--- a/scripts/install-macports.sh\n+++ b/scripts/install-macports.sh\n@@ -1 +1 @@\n-PIN_REV=old\n+PIN_REV=new\n-OLD_URL=x' | policy_installer_diff_wo_pinrev)"

# Hunk-aware filtering: diff/hunk headers carry no content, but a content line
# that itself starts with `++`/`--` is a real change and must survive.
assert_eq 'installer: diff and hunk headers are not mistaken for changes' \
  $'-OLD_URL=x\n-#-- a separator\n++ a leading plus' \
  "$(printf '%s\n' $'diff --git a/scripts/install-macports.sh b/scripts/install-macports.sh\nindex 1234567..89abcde 100755\n--- a/scripts/install-macports.sh\n+++ b/scripts/install-macports.sh\n@@ -1,2 +1,2 @@\n-OLD_URL=x\n-#-- a separator\n+PIN_REV=new\n++ a leading plus' | policy_installer_diff_wo_pinrev)"
assert_eq 'installer: a file-mode change counts as a real installer edit' \
  $'old mode 100644\nnew mode 100755' \
  "$(printf '%s\n' $'diff --git a/scripts/install-macports.sh b/scripts/install-macports.sh\nold mode 100644\nnew mode 100755' | policy_installer_diff_wo_pinrev)"
assert_eq 'installer: a mode-only change makes the installer releasable' \
  'releasable' \
  "$(policy_decide "$EMPTY" 'scripts/install-macports.sh' "$(printf '%s\n' $'old mode 100644\nnew mode 100755' | policy_installer_diff_wo_pinrev)")"

# --- 4. Version policy -------------------------------------------------------

assert_ok 'version: 0.0.1 is allowed' policy_version_is_allowed '0.0.1'
assert_ok 'version: 0.1.12 is allowed' policy_version_is_allowed '0.1.12'
assert_not_ok 'version: 1.0.0 is a policy error' policy_version_is_allowed '1.0.0'
assert_not_ok 'version: 0.2.0 is a policy error' policy_version_is_allowed '0.2.0'
assert_not_ok 'version: 0.0.08 (leading zero) is a policy error' policy_version_is_allowed '0.0.08'
assert_not_ok 'version: an empty version is a policy error' policy_version_is_allowed ''
assert_not_ok 'version: a non-semver string is a policy error' policy_version_is_allowed 'main'

assert_not_ok 'bump: 0.0.99 is below the cap' policy_automatic_bump_blocked '0.0.99'
assert_ok 'bump: 0.0.100 is at the 0.0.x cap' policy_automatic_bump_blocked '0.0.100'
assert_not_ok 'bump: 0.1.100 is not capped (0.1.x may grow)' policy_automatic_bump_blocked '0.1.100'
assert_not_ok 'bump: 0.1.101 is not capped' policy_automatic_bump_blocked '0.1.101'

assert_eq 'next version: 0.0.8 -> 0.0.9 (no octal)' \
  '0.0.9' "$(policy_next_version '0.0.8')"
assert_eq 'next version: 0.0.9 -> 0.0.10' \
  '0.0.10' "$(policy_next_version '0.0.9')"
assert_eq 'next version: 0.1.12 keeps its minor series' \
  '0.1.13' "$(policy_next_version '0.1.12')"

# --- 5. End-to-end against a real git diff ----------------------------------
# Replays exactly the shell the workflow runs, against a throwaway repository
# tagged like a published release, so a change in the grep patterns or in the
# git invocation itself cannot pass unnoticed.

FIXTURE="${TMP_DIR}/repo"
mkdir -p "$FIXTURE"
git -C "$FIXTURE" init -q -b main
git -C "$FIXTURE" config user.email 'test@example.com'
git -C "$FIXTURE" config user.name 'Release Policy Test'
mkdir -p "$FIXTURE/Sources/NanoDictateCore" "$FIXTURE/docs" "$FIXTURE/.github/workflows" "$FIXTURE/scripts"
printf 'let string = "0.0.1"\n' > "$FIXTURE/Sources/NanoDictateCore/Version.swift"
printf 'source\n' > "$FIXTURE/Sources/NanoDictateCore/Transcriber.swift"
printf 'PIN_REV=deadbeef\n' > "$FIXTURE/scripts/install-macports.sh"
git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit -q -m 'base'
git -C "$FIXTURE" tag v0.0.1

# Classify the fixture the way the workflow does.
fixture_decide() {
  local labels_json=$1
  local all_changed installer_diff
  all_changed=$(git -C "$FIXTURE" diff --name-only v0.0.1..HEAD)
  installer_diff=$(git -C "$FIXTURE" diff v0.0.1..HEAD -- scripts/install-macports.sh \
    | policy_installer_diff_wo_pinrev)
  policy_decide "$labels_json" "$all_changed" "$installer_diff"
}

assert_eq 'fixture: an unchanged tree is no-changes' \
  'no-changes' "$(fixture_decide "$EMPTY")"

printf 'guide\n' > "$FIXTURE/docs/packaging.md"
printf 'name: CI\n' > "$FIXTURE/.github/workflows/ci.yml"
git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit -q -m 'docs only'
assert_eq 'fixture: docs + .github only is non-releasable' \
  'non-releasable' "$(fixture_decide "$EMPTY")"
assert_eq 'fixture: the same docs-only diff is skipped when labeled' \
  'skip-release' "$(fixture_decide "$LABELED")"

printf 'more source\n' >> "$FIXTURE/Sources/NanoDictateCore/Transcriber.swift"
git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit -q -m 'real code change'
assert_eq 'fixture: a real code change is releasable' \
  'releasable' "$(fixture_decide "$EMPTY")"
assert_eq 'fixture: a real code change is skipped when labeled' \
  'skip-release' "$(fixture_decide "$LABELED")"

# A PIN_REV-only refresh, on its own branch so no real code change is in range.
git -C "$FIXTURE" checkout -q -B pin-only v0.0.1
printf 'PIN_REV=cafebabe\n' > "$FIXTURE/scripts/install-macports.sh"
git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit -q -m 'pin refresh only'
assert_eq 'fixture: a PIN_REV-only installer refresh is non-releasable' \
  'non-releasable' "$(fixture_decide "$EMPTY")"

printf 'https://example.com/real\n' >> "$FIXTURE/scripts/install-macports.sh"
git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit -q -m 'real installer edit'
assert_eq 'fixture: a real installer edit is releasable' \
  'releasable' "$(fixture_decide "$EMPTY")"

# A chmod of the installer produces a mode-only diff (no +/- lines at all); it
# is still a real installer edit, so it must not be swallowed as PIN_REV-only.
git -C "$FIXTURE" checkout -q -B mode-only v0.0.1
chmod +x "$FIXTURE/scripts/install-macports.sh"
git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit -q -m 'installer mode change only'
assert_eq 'fixture: a mode-only installer change is releasable' \
  'releasable' "$(fixture_decide "$EMPTY")"

# --- summary -----------------------------------------------------------------

printf '\n%s passed, %s failed\n' "$PASSED" "$FAILED"
[[ "$FAILED" -eq 0 ]]
