import Foundation

// MARK: - EnterSendLatch

/// One-shot latch: post exactly one synthetic Enter after insert ("Enter stops recording").
/// arm() idempotent; consume() once; cancel() no post. Main-thread only by design.
public final class EnterSendLatch {
  private var isArmed = false

  public init() {}

  /// Arm latch; idempotent — Enter posted exactly once.
  public func arm() {
    isArmed = true
  }

  /// One-shot take: true = post Enter, latch cleared; next consume false.
  public func consume() -> Bool {
    guard isArmed else { return false }
    isArmed = false
    return true
  }

  /// Disarm without posting Enter; idempotent.
  public func cancel() {
    isArmed = false
  }

  /// Latch armed?
  public var isPending: Bool {
    isArmed
  }
}
