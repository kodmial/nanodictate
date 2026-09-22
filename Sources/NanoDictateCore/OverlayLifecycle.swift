import CoreGraphics
import Foundation

/// Dictation cycle states; in core so overlay lifecycle stays pure and unit-testable.
public enum NanoDictateState {
  case idle
  case recording
  case transcribing
}

/// Pure overlay hide rules: lives whole cycle, hides only at terminal points
/// (stop/error/insert/cancel/limit); never mid-recording/transcribing.
public enum OverlayLifecycle {
  /// May overlay hide in `currentState`?
  public static func shouldHide(currentState: NanoDictateState) -> Bool {
    switch currentState {
    case .idle:
      return true
    case .recording, .transcribing:
      return false
    }
  }

  /// Hide after delay, re-checking state at fire: new cycle keeps overlay visible.
  /// Contract: one schedule → at most one `hide()`.
  public static func scheduleHide(
    after delay: TimeInterval,
    stateProvider: @escaping () -> NanoDictateState,
    hide: @escaping () -> Void
  ) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      if shouldHide(currentState: stateProvider()) {
        hide()
      }
    }
  }
}
