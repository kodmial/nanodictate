/// Pure decision for the retry-insertion drop guard in the agent CLI.
/// Extracted into NanoDictateCore so the drop logic is unit-testable
/// (the Agent executable itself is not importable by the test target).
public enum RetryInsertionGate {
  /// A retry result is dropped when a newer agent cycle owns the session,
  /// or the agent is not idle (recording/transcribing in flight).
  public static func shouldDropRetry(
    state: NanoDictateState,
    processingSession: Int,
    session: Int
  ) -> Bool {
    state != .idle || processingSession != session
  }
}