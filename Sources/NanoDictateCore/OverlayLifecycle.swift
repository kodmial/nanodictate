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
  /// `isCurrentCycle` ties the delayed hide to the dictation cycle that scheduled
  /// it — if a new cycle began meanwhile, the stale hide is dropped (the new
  /// cycle's own terminal point schedules its hide with its own delay).
  /// Contract: one schedule → at most one `hide()`.
  public static func scheduleHide(
    after delay: TimeInterval,
    stateProvider: @escaping () -> NanoDictateState,
    isCurrentCycle: @escaping () -> Bool = { true },
    hide: @escaping () -> Void
  ) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
      guard isCurrentCycle() else { return }
      if shouldHide(currentState: stateProvider()) {
        hide()
      }
    }
  }
}
