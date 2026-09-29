import Foundation

public enum RuntimeEnvironment {
  private static let testRunEnvironmentKey = "NANODICTATE_TESTS"

  /// True when running under NanoDictateCoreTests.
  public static var isTestRun: Bool {
    ProcessInfo.processInfo.environment[testRunEnvironmentKey] == "1"
  }
}
