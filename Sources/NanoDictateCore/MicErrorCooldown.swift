import Foundation

// MARK: - Cooldown микрофонных ошибок

/// Cooldown for terminal mic errors: repeated Alt+Alt must not replay error sound/flash;
/// message shown at most once per `interval`. Pure — timestamps only, no AppKit.
public struct MicErrorCooldown {
  /// Min seconds between two error shows.
  public let interval: TimeInterval

  /// Time of last allowed show; -.infinity = never fired (tap at 0.0 must not eat next).
  private var lastFiredAt: TimeInterval = -.infinity

  public init(interval: TimeInterval) {
    self.interval = interval
  }

  /// True when ≥ interval since last show; records now. False — suppressed, state unchanged.
  public mutating func allow(at now: TimeInterval) -> Bool {
    guard now - lastFiredAt >= interval else { return false }
    lastFiredAt = now
    return true
  }
}
