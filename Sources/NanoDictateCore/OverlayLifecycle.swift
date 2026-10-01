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

  /// Deferred "starting" UI: fast successful starts (ready within the UX
  /// threshold) transition directly to recording without visibly flashing the
  /// transient starting state. Slow starts still show it so the user knows
  /// the microphone is not ready yet. Pure and unit-testable.
  public enum StartingUIDefer {
    /// Grace window before the starting phase becomes visible (seconds).
    /// 0.12 s: below the ~100-150 ms perceptual flash boundary, above
    /// typical armed fast-path bring-up.
    public static let graceInterval: TimeInterval = 0.12

    /// True when the starting phase should be shown: still starting after
    /// the grace interval and not yet recording-ready.
    public static func shouldShowStarting(
      elapsed: TimeInterval,
      threshold: TimeInterval = graceInterval
    ) -> Bool {
      elapsed >= threshold
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
