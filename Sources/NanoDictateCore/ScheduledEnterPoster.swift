import Foundation

/// Cancellable post of one synthetic Enter after Enter-stop insert.
/// Esc must cancel a scheduled post; asyncAfter alone can't — DispatchWorkItem + generation.
public final class ScheduledEnterPoster {
  /// Runs when fired, unless cancelled.
  public var action: (() -> Void)?

  /// Schedule→fire delay (0.25 s): target app processes inserted text first.
  public var delay: TimeInterval = 0.25

  /// Bumped on schedule/cancel; invalidates stale work items.
  private var generation: UInt64 = 0
  private var workItem: DispatchWorkItem?

  public init() {}

  /// Fire action after delay; re-schedule cancels previous (last wins).
  public func schedule() {
    cancelScheduled()
    generation &+= 1
    let myGeneration = generation
    let item = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.workItem = nil
      // Stale if cancelled (cancelScheduled) or re-scheduled?
      guard self.generation == myGeneration else { return }
      self.action?()
    }
    workItem = item
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
  }

  /// Cancel scheduled action (Esc). Idempotent; pending fire won't run.
  public func cancelScheduled() {
    workItem?.cancel()
    workItem = nil
    generation &+= 1
  }
}
