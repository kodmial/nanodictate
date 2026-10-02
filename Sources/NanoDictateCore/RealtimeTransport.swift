import Foundation

// MARK: - Transport abstraction (mocked in tests)

/// Minimal WebSocket surface used by the session. Production uses
/// `URLSessionWebSocketTransport`; tests inject `MockRealtimeTransport`.
public protocol RealtimeTransport: AnyObject {
  /// Send one JSON text message.
  func send(text: String) async throws
  /// Receive one JSON text message; nil = transport closed cleanly.
  func receive() async throws -> String?
  /// Deterministic teardown.
  func close() async
}

// MARK: - Receive infrastructure (single long-lived loop per session)

/// Signals that a bounded `withTimeout` wait expired without a result.
/// Distinct from a `nil` operation result (clean transport EOF) so callers
/// keep waiting until their own deadline instead of treating a short
/// per-receive expiry as closure.
enum RealtimeWaitTimeout: Error {
  case timedOut
}

/// One item produced by the single long-lived receive loop.
/// `.text(nil)` is a clean transport EOF; `.failure` preserves the transport
/// error so callers apply the same close-out as a direct `receive()` error.
enum RealtimeReceiveItem: Sendable {
  case text(String?)
  case failure(RealtimeTranscriptionError)
}

/// Thread-safe waiter registry for the receive channel. Held by the channel
/// actor but safe to touch from the non-isolated continuation closures, so
/// timed waits cancel only their own waiter and never the underlying stream.
private final class RealtimeWaiterStore: @unchecked Sendable {
  private let lock = NSLock()
  private var waiters: [UUID: CheckedContinuation<RealtimeReceiveItem?, Never>] = [:]
  private var order: [UUID] = []

  func add(id: UUID, continuation: CheckedContinuation<RealtimeReceiveItem?, Never>) {
    lock.lock()
    waiters[id] = continuation
    order.append(id)
    lock.unlock()
  }

  func popFirst() -> CheckedContinuation<RealtimeReceiveItem?, Never>? {
    lock.lock()
    defer { lock.unlock() }
    guard let id = order.first else { return nil }
    order.removeFirst()
    return waiters.removeValue(forKey: id)
  }

  @discardableResult
  func remove(id: UUID) -> CheckedContinuation<RealtimeReceiveItem?, Never>? {
    lock.lock()
    defer { lock.unlock() }
    order.removeAll { $0 == id }
    return waiters.removeValue(forKey: id)
  }

  func removeAll() -> [CheckedContinuation<RealtimeReceiveItem?, Never>] {
    lock.lock()
    defer { lock.unlock() }
    let all = Array(waiters.values)
    waiters.removeAll()
    order.removeAll()
    return all
  }
}

/// Single long-lived receive loop per session.
///
/// The pump task calls `transport.receive()` continuously for the session
/// lifetime and delivers every outcome to the channel. Waiters suspend on
/// per-waiter continuations (never on `transport.receive()` or on a shared
/// `AsyncStream.Iterator`, whose cancellation would terminate the stream per
/// SE-0314), so expiring a wait cancels only that waiter. A message that
/// arrives after a timeout is appended to `pending` and returned by the next
/// wait instead of being discarded.
actor RealtimeReceiveChannel {
  private let transport: RealtimeTransport
  private let waiterStore = RealtimeWaiterStore()
  private var pending: [RealtimeReceiveItem] = []
  private var pump: Task<Void, Never>?
  private var stopped = false

  init(transport: RealtimeTransport) {
    self.transport = transport
  }

  /// Start the background pump (idempotent; one loop per session).
  func start() {
    guard pump == nil, !stopped else { return }
    pump = Task { [transport, channel = self] in
      await Self.runPump(transport: transport, channel: channel)
    }
  }

  /// Stop the pump and resume pending waiters with nil (idempotent).
  func stop() {
    stopped = true
    pump?.cancel()
    pump = nil
    for waiter in waiterStore.removeAll() {
      waiter.resume(returning: nil)
    }
  }

  /// Deliver one pump outcome: resume the oldest waiter or buffer it.
  /// FIFO is preserved: when items are already buffered, a newly arrived
  /// item never jumps ahead of them to a waiter. The waiter receives the
  /// oldest buffered item instead, so back-to-back deliveries (for example
  /// a session ack immediately followed by EOF) keep receive order.
  func deliver(_ item: RealtimeReceiveItem) {
    guard !stopped else { return }
    pending.append(item)
    if let waiter = waiterStore.popFirst() {
      let oldest = pending.removeFirst()
      waiter.resume(returning: oldest)
    }
  }

  /// Resume and drop one waiter without delivering (timeout/cancel path).
  func cancelWaiter(id: UUID) {
    if let waiter = waiterStore.remove(id: id) {
      waiter.resume(returning: nil)
    }
  }

  /// Next buffered item without a timeout (nil = stopped/finished).
  func dequeue() async -> RealtimeReceiveItem? {
    if !pending.isEmpty {
      return pending.removeFirst()
    }
    if stopped { return nil }
    let id = UUID()
    let store = waiterStore
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<RealtimeReceiveItem?, Never>) in
        store.add(id: id, continuation: continuation)
      }
    } onCancel: {
      Task { await self.cancelWaiter(id: id) }
    }
  }

  /// Next item with a bounded wait. Throws `RealtimeWaitTimeout.timedOut`
  /// when no item arrives first. Cancelling the timeout waiter never cancels
  /// the pump or terminates a shared stream; a late arrival is buffered in
  /// `pending` (via `deliver` or via requeue of a won race) for the next call.
  func next(timeout: TimeInterval) async throws -> RealtimeReceiveItem? {
    if !pending.isEmpty {
      return pending.removeFirst()
    }
    if stopped { return nil }
    if timeout <= 0 {
      return await dequeue()
    }
    return try await withThrowingTaskGroup(of: RealtimeReceiveItem?.self) { group in
      group.addTask {
        await self.dequeue()
      }
      group.addTask {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        throw RealtimeWaitTimeout.timedOut
      }
      do {
        guard let first = try await group.next() else {
          group.cancelAll()
          _ = try? await group.next()
          return nil
        }
        group.cancelAll()
        _ = try? await group.next()
        return first
      } catch is RealtimeWaitTimeout {
        group.cancelAll()
        var late: RealtimeReceiveItem?? = nil
        do {
          if let other = try await group.next() {
            late = other
          }
        } catch {
          // Sleeper cancellation noise; the dequeue child reports values only.
        }
        // If the dequeue waiter won the race just as the timeout fired, its
        // item was consumed by this call and must be requeued, not discarded.
        // If delivery happened after cancel, `deliver` already buffered it in
        // `pending`, so there is nothing extra to do here.
        // Requeue at the front: the recovered item arrived before anything
        // buffered in `pending` while draining the race (e.g. a `.completed`
        // followed by EOF), so appending would invert receive order and let
        // EOF be processed before the completion.
        if let item = late ?? nil {
          pending.insert(item, at: 0)
        }
        throw RealtimeWaitTimeout.timedOut
      }
    }
  }

  /// Background pump: the only place that calls `transport.receive()`.
  /// Never cancelled by a wait timeout; only by `stop()` / task cancellation.
  private static func runPump(
    transport: RealtimeTransport,
    channel: RealtimeReceiveChannel
  ) async {
    while true {
      if Task.isCancelled { break }
      do {
        let text = try await transport.receive()
        await channel.deliver(.text(text))
        if text == nil {
          // Clean EOF: pause so a closed transport does not hot-spin.
          try? await Task.sleep(nanoseconds: 5_000_000)
        }
      } catch is CancellationError {
        await channel.deliver(.failure(.cancelled))
        break
      } catch let error as RealtimeTranscriptionError {
        await channel.deliver(.failure(error))
        try? await Task.sleep(nanoseconds: 5_000_000)
      } catch {
        await channel.deliver(.failure(.transport(error.localizedDescription)))
        try? await Task.sleep(nanoseconds: 5_000_000)
      }
    }
  }
}

// MARK: - URLSession WebSocket transport (production)

/// Production WebSocket transport over `URLSessionWebSocketTask`.
/// Kept separate from the session state machine so tests inject a mock.
public final class URLSessionWebSocketTransport: RealtimeTransport {
  private let url: URL
  private let apiKey: String
  private var task: URLSessionWebSocketTask?
  private let session: URLSession

  public init(url: URL, apiKey: String, session: URLSession = .shared) {
    self.url = url
    self.apiKey = apiKey
    self.session = session
  }

  /// Connect lazily on first send/receive.
  private func ensureTask() {
    guard task == nil else { return }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
    task = session.webSocketTask(with: request)
    task?.resume()
  }

  public func send(text: String) async throws {
    ensureTask()
    guard let task else {
      throw RealtimeTranscriptionError.transport("websocket unavailable")
    }
    do {
      try await task.send(.string(text))
    } catch {
      throw RealtimeTranscriptionError.transport(error.localizedDescription)
    }
  }

  public func receive() async throws -> String? {
    ensureTask()
    guard let task else {
      throw RealtimeTranscriptionError.transport("websocket unavailable")
    }
    do {
      let message = try await task.receive()
      switch message {
      case .string(let text):
        return text
      case .data(let data):
        return String(data: data, encoding: .utf8)
      @unknown default:
        return nil
      }
    } catch {
      // Cancelled receive surfaces as an error; map to clean EOF when the
      // task is already cancelled/closed so teardown stays deterministic.
      if (error as NSError).code == NSURLErrorCancelled {
        return nil
      }
      throw RealtimeTranscriptionError.transport(error.localizedDescription)
    }
  }

  public func close() async {
    task?.cancel(with: .normalClosure, reason: nil)
    task = nil
  }
}
