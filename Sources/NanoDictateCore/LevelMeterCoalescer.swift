import Foundation

// MARK: - Coalesced level-meter delivery

/// Collapses rapid audio-thread level updates into at most one pending
/// main-queue delivery holding the latest RMS. Stale levels never queue as an
/// unbounded backlog when the main thread stalls under load.
public final class LevelMeterCoalescer {
  private let lock = NSLock()
  private var latest: Float = 0
  private var pending = false

  public init() {}

  /// Records a new level. Returns true when the caller must schedule a flush
  /// (no delivery pending); false when a flush is already scheduled and will
  /// pick up this latest value.
  @discardableResult
  public func submit(_ rms: Float) -> Bool {
    lock.lock()
    latest = rms
    let shouldSchedule = !pending
    pending = true
    lock.unlock()
    return shouldSchedule
  }

  /// Takes the latest level for delivery, clearing the pending flag.
  public func takePending() -> Float {
    lock.lock()
    defer {
      pending = false
      lock.unlock()
    }
    return latest
  }

  public var hasPending: Bool {
    lock.lock()
    defer { lock.unlock() }
    return pending
  }
}
