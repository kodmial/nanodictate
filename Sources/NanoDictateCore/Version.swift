/// App version (semver, no `v` prefix).
///
/// Single source for `nanodictate --version` and CHANGELOG. Updated only
/// through the automated Release PR, never by hand in feature PRs
/// (see release-please-config.json).
public enum NanoDictateVersion {
  public static let string = "0.1.5" // x-release-please-version

  /// Compact display form for the main window header (for example `v0.1.5`).
  /// Derived from `string` so bumping the version needs no UI change.
  public static var displayString: String { "v\(string)" }
}
