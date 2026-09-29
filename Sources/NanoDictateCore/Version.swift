/// App version (semver, no `v` prefix).
///
/// Single source for `nanodictate --version` and CHANGELOG. Updated only
/// through the automated Release PR, never by hand in feature PRs
/// (see release-please-config.json).
public enum NanoDictateVersion {
  public static let string = "0.1.14" // x-release-please-version
}
