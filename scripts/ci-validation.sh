#!/usr/bin/env bash
set -euo pipefail

selected=""
for xcode in /Applications/Xcode_16.4.app /Applications/Xcode_16.3.app; do
  developer_dir="$xcode/Contents/Developer"
  [[ -d "$developer_dir" ]] || continue
  version="$(DEVELOPER_DIR="$developer_dir" xcrun swift --version 2>&1)"
  echo "$xcode: $version"
  if [[ "$version" == *"Swift version 6.1"* ]]; then
    selected="$developer_dir"
    break
  fi
done
if [[ -z "$selected" ]]; then
  echo "::error::No preinstalled Xcode with Swift 6.1 found on $(sw_vers -productVersion)." >&2
  ls -1d /Applications/Xcode*.app 2>/dev/null || true
  exit 1
fi
export DEVELOPER_DIR="$selected"
echo "::notice::Using preinstalled Swift toolchain from $selected."
xcrun swift --version

# shellcheck source=scripts/swift-rust-build-contract.sh
source scripts/swift-rust-build-contract.sh
archive="$(prepare_rust_archive)"
echo "::notice::Using canonical Rust archive: $archive"

brew install swift-format
swift-format lint --recursive --configuration .swift-format Sources
brew install swiftlint
swiftlint lint Sources

swift_build_with_rust "$archive"

swift_build_with_rust "$archive" \
  -Xswiftc -profile-generate \
  -Xswiftc -profile-coverage-mapping \
  --product NanoDictateCoreTests

export LLVM_PROFILE_FILE=".build/nanodictate-%p.profraw"
.build/debug/NanoDictateCoreTests

xcrun llvm-profdata merge -sparse .build/nanodictate-*.profraw -o .build/nanodictate.profdata
REPORT="$(xcrun llvm-cov report \
  .build/debug/NanoDictateCoreTests \
  -instr-profile=.build/nanodictate.profdata \
  -ignore-filename-regex='(Tests/|Sources/NanoDictateAgent/|Sources/nanodictate/|Sources/AudioEngineGuard/)')"
printf '%s\n' "$REPORT"
COVERAGE="$(printf '%s\n' "$REPORT" | awk '/^TOTAL/ {gsub("%", "", $10); print $10}')"
[[ -n "$COVERAGE" ]] || { echo "::error::Could not determine NanoDictateCoreTests line coverage." >&2; exit 1; }
echo "NanoDictateCoreTests line coverage: ${COVERAGE}%"
awk -v coverage="$COVERAGE" 'BEGIN { exit !(coverage >= 80.0) }' || {
  echo "::error::NanoDictateCoreTests line coverage ${COVERAGE}% is below 80%." >&2
  exit 1
}
