import Foundation

/// Test-runner flag: NanoDictateCoreTests sets NANODICTATE_TESTS=1 at process start.
/// Gates real sounds, overlay panel, prod agent.log writes.
/// Read live (not cached) so tests can override.
public enum RuntimeEnvironment {
  /// True when running under NanoDictateCoreTests.
  public static var isTestRun: Bool {
    ProcessInfo.processInfo.environment["NANODICTATE_TESTS"] == "1"
  }
}
