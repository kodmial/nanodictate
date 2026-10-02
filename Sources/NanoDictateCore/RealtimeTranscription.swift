import Foundation

// MARK: - Stateful realtime transcription backend (OpenAI realtime transcription)
//
// One stateful WebSocket session per dictation for models whose profile uses
// `.streamingSession` (today: OpenAI `gpt-live-transcribe` family). Audio is
// streamed continuously as raw mono PCM16 at 24 kHz (official realtime
// transcription format: `audio/input/format = {"type": "audio/pcm",
// "rate": 24000}`, base64 bytes without a WAV header) — never as independent
// short WAV batch uploads.
//
// Verified against the official realtime-transcription guide (2026-10-01):
// - client events: `session.update`, `input_audio_buffer.append`,
//   `input_audio_buffer.commit` (+ `input_audio_buffer.clear`);
// - server events: `conversation.item.input_audio_transcription.delta`,
//   `conversation.item.input_audio_transcription.completed`,
//   `conversation.item.input_audio_transcription.failed`,
//   `session.created` / `session.updated`, `input_audio_buffer.committed`,
//   `error`.
// - `gpt-live-transcribe` returns deltas + final transcript; completion
//   ordering across turns is not guaranteed, so `item_id` is the ordering key.
//
// Session lifecycle and error/reconnect policy (written before coding, see
// `docs/realtime-transcription.md`):
// - idle -> connecting (send session.update) -> ready -> streaming (append)
//   -> committing (commit) -> closed (transport close after completion).
// - cancel() from any state -> cancelled: transport closed, pending work
//   dropped, no further callbacks. Never wedges: every wait has a timeout and
//   honors Task cancellation.
// - No automatic reconnect: after a transport drop the session stays
//   `.failed` and never re-uploads already-sent audio silently.
//   Reconnecting or restarting the dictation is the caller's
//   responsibility. A failed session never falls back
//   to repeated batch uploads unless RealtimeFallbackPolicy explicitly allows
//   it (default: fail-closed).

// MARK: - Errors

/// Failures of a realtime transcription session.
public enum RealtimeTranscriptionError: Error, Equatable, Sendable {
  case notConnected
  case alreadyConnected
  case invalidState(String)
  case transport(String)
  case protocolError(String)
  case sessionFailed(String)
  case timeout(String)
  case cancelled
}

// MARK: - Session state

/// Deterministic lifecycle of one dictation session.
public enum RealtimeSessionState: String, Equatable {
  case idle
  case connecting
  case ready
  case streaming
  case committing
  case closed
  case failed
  case cancelled
}

// MARK: - Delay hint

/// Latency/accuracy tradeoff for `gpt-live-transcribe`
/// (`audio.input.transcription.delay`).
public enum RealtimeTranscriptionDelay: String, Equatable {
  case minimal
  case low
  case medium
  case high
  case xhigh
}

// MARK: - Session config

/// Configuration of one realtime transcription session.
public struct RealtimeSessionConfig: Equatable {
  /// Realtime model (e.g. `gpt-live-transcribe`).
  public var model: String
  /// Expected input language hint (e.g. `en`); empty = omitted.
  public var language: String
  /// Free-form context (setting, domain vocabulary).
  public var prompt: String?
  /// Literal keyword hints (product names, codes).
  public var keywords: [String]
  /// Latency/accuracy hint; nil = server default.
  public var delay: RealtimeTranscriptionDelay?
  /// Source sample rate of appended Int16 samples (resampled to 24 kHz).
  public var sourceSampleRate: Int

  public init(
    model: String = "gpt-live-transcribe",
    language: String = "",
    prompt: String? = nil,
    keywords: [String] = [],
    delay: RealtimeTranscriptionDelay? = nil,
    sourceSampleRate: Int = 16000
  ) {
    self.model = model
    self.language = language
    self.prompt = prompt
    self.keywords = keywords
    self.delay = delay
    self.sourceSampleRate = sourceSampleRate
  }
}

// MARK: - Policies

/// Timeouts and reconnect bounds for a realtime session.
/// Every wait is bounded so cancellation/timeout/provider errors cannot wedge
/// AudioService or the UI.
public struct RealtimeSessionPolicy: Equatable {
  /// Seconds to wait for `session.created`/`session.updated` after connect.
  public var connectTimeout: TimeInterval
  /// Seconds to wait for the final completion after `commit`.
  public var commitTimeout: TimeInterval
  /// Seconds to wait for transport close to settle.
  public var closeTimeout: TimeInterval
  /// Reconnect attempts after a transport drop (0 = no auto reconnect).
  public var maxReconnectAttempts: Int
  /// Base delay between reconnect attempts (exponential: base * 2^n).
  public var reconnectBaseDelay: TimeInterval
  /// Maximum audio samples per `input_audio_buffer.append` message.
  public var maxSamplesPerAppend: Int

  public init(
    connectTimeout: TimeInterval = 10,
    commitTimeout: TimeInterval = 20,
    closeTimeout: TimeInterval = 5,
    maxReconnectAttempts: Int = 2,
    reconnectBaseDelay: TimeInterval = 0.5,
    maxSamplesPerAppend: Int = 4800
  ) {
    self.connectTimeout = connectTimeout
    self.commitTimeout = commitTimeout
    self.closeTimeout = closeTimeout
    self.maxReconnectAttempts = maxReconnectAttempts
    self.reconnectBaseDelay = reconnectBaseDelay
    self.maxSamplesPerAppend = maxSamplesPerAppend
  }

  /// Delay before reconnect attempt number `attempt` (0-based).
  public func reconnectDelay(forAttempt attempt: Int) -> TimeInterval {
    reconnectBaseDelay * pow(2.0, Double(max(0, attempt)))
  }
}

/// Explicit fallback policy when a realtime session fails.
/// Default is fail-closed: a failed realtime session surfaces an error and
/// NEVER silently degrades into repeated batch uploads (which would duplicate
/// audio and cost). Batch fallback happens only when the caller explicitly
/// selects `.allowBatch` for that dictation.
public enum RealtimeFallbackPolicy: String, Equatable {
  /// Surface the realtime error; do not start batch uploads.
  case failClosed
  /// Caller explicitly opts into one batch transcription of the full audio.
  case allowBatch
}

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

// MARK: - Server events

/// Parsed realtime transcription server event (official schema).
public enum RealtimeServerEvent: Equatable {
  case delta(itemID: String, contentIndex: Int, delta: String)
  case completed(itemID: String, contentIndex: Int, transcript: String, languages: [String])
  case failed(itemID: String, message: String)
  case committed(itemID: String)
  case sessionCreated
  case sessionUpdated
  case errorMessage(String)
  case unknown(String)
}

/// Pure parser for server JSON text (no I/O; fully unit-tested).
public enum RealtimeEventParser {
  /// Parse one server text message. Invalid JSON -> `.unknown` (never throws:
  /// one malformed message must not kill the session).
  public static func parse(_ text: String) -> RealtimeServerEvent {
    guard let data = text.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let type = json["type"] as? String
    else {
      return .unknown(text)
    }
    switch type {
    case "conversation.item.input_audio_transcription.delta":
      return .delta(
        itemID: json["item_id"] as? String ?? "",
        contentIndex: (json["content_index"] as? NSNumber)?.intValue ?? 0,
        delta: json["delta"] as? String ?? "")
    case "conversation.item.input_audio_transcription.completed":
      var languages: [String] = []
      if let items = json["languages"] as? [[String: Any]] {
        for item in items {
          if let code = item["code"] as? String, !code.isEmpty {
            languages.append(code)
          }
        }
      }
      return .completed(
        itemID: json["item_id"] as? String ?? "",
        contentIndex: (json["content_index"] as? NSNumber)?.intValue ?? 0,
        transcript: json["transcript"] as? String ?? "",
        languages: languages)
    case "conversation.item.input_audio_transcription.failed":
      let message: String
      if let error = json["error"] as? [String: Any] {
        message = error["message"] as? String ?? error["code"] as? String ?? "transcription failed"
      } else {
        message = json["message"] as? String ?? "transcription failed"
      }
      return .failed(itemID: json["item_id"] as? String ?? "", message: message)
    case "input_audio_buffer.committed":
      return .committed(itemID: json["item_id"] as? String ?? "")
    case "session.created":
      return .sessionCreated
    case "session.updated":
      return .sessionUpdated
    case "error":
      if let error = json["error"] as? [String: Any] {
        return .errorMessage(error["message"] as? String ?? error["code"] as? String ?? "error")
      }
      return .errorMessage(json["message"] as? String ?? "error")
    default:
      return .unknown(type)
    }
  }
}

// MARK: - Transcript accumulator (no duplication)

/// Accumulates deltas and final transcripts keyed by `item_id`.
/// - delta text is appended incrementally (never re-emitted);
/// - a `completed` transcript is authoritative for its item and replaces that
///   item's pending delta buffer (partials never duplicate committed text);
/// - final transcript is deterministic: completed items joined in first-seen
///   order with single spaces.
public struct RealtimeTranscriptAccumulator: Equatable {
  private var pending: [String: String] = [:]
  private var completed: [String: String] = [:]
  private var order: [String] = []

  public init() {}

  private mutating func noteOrder(_ itemID: String) {
    if !order.contains(itemID) {
      order.append(itemID)
    }
  }

  /// Apply one parsed server event.
  /// - Returns: current partial text after applying (for overlay display).
  @discardableResult
  public mutating func apply(_ event: RealtimeServerEvent) -> String {
    switch event {
    case let .delta(itemID, _, delta):
      noteOrder(itemID)
      // A completed item never accepts more deltas (late/duplicate guard).
      if completed[itemID] == nil, !delta.isEmpty {
        pending[itemID, default: ""] += delta
      }
      return partialText
    case let .completed(itemID, _, transcript, _):
      noteOrder(itemID)
      completed[itemID] = transcript
      pending[itemID] = nil
      return partialText
    case .failed(let itemID, _):
      noteOrder(itemID)
      pending[itemID] = nil
      return partialText
    case .committed(let itemID) where !itemID.isEmpty:
      noteOrder(itemID)
      return partialText
    case .committed, .sessionCreated, .sessionUpdated, .errorMessage, .unknown:
      return partialText
    }
  }

  /// Current display text: completed items (authoritative) plus pending deltas
  /// of uncompleted items, in first-seen order. No committed text is repeated.
  public var partialText: String {
    var parts: [String] = []
    for itemID in order {
      if let done = completed[itemID] {
        if !done.isEmpty {
          parts.append(done)
        }
      } else if let text = pending[itemID], !text.isEmpty {
        parts.append(text)
      }
    }
    return parts.joined(separator: " ")
  }

  /// Deterministic final transcript after stop/session completion: joined
  /// completed items, or nil when nothing completed.
  public var finalText: String? {
    let parts = order.compactMap { completed[$0] }.filter { !$0.isEmpty }
    guard !parts.isEmpty else { return nil }
    return parts.joined(separator: " ")
  }

  /// Whether at least one item completed.
  public var hasCompleted: Bool {
    completed.values.contains { !$0.isEmpty }
  }
}

// MARK: - PCM conversion and resampling

/// Raw PCM16 helpers for the realtime path (no WAV headers anywhere here).
public enum RealtimePCMConverter {
  /// Int16 samples -> little-endian bytes.
  public static func pcmData(from samples: [Int16]) -> Data {
    var data = Data()
    data.reserveCapacity(samples.count * 2)
    if !samples.isEmpty {
      samples.withUnsafeBytes { raw in
        data.append(contentsOf: raw)
      }
    }
    return data
  }

  /// Int16 samples -> base64 PCM16 string for `input_audio_buffer.append`.
  public static func base64PCM(from samples: [Int16]) -> String {
    pcmData(from: samples).base64EncodedString()
  }

  /// Linear resample between integer rates (used for 16 kHz mic -> 24 kHz
  /// realtime). Identity when rates match; empty in -> empty out.
  public static func resample(_ samples: [Int16], fromRate: Int, toRate: Int) -> [Int16] {
    guard !samples.isEmpty, fromRate > 0, toRate > 0, fromRate != toRate else {
      return samples
    }
    let ratio = Double(toRate) / Double(fromRate)
    let outCount = max(1, Int((Double(samples.count) * ratio).rounded()))
    var out: [Int16] = []
    out.reserveCapacity(outCount)
    for i in 0..<outCount {
      let pos = Double(i) / ratio
      let lo = Int(pos)
      let hi = min(lo + 1, samples.count - 1)
      let frac = pos - Double(lo)
      let interpolated = Double(samples[lo]) * (1.0 - frac) + Double(samples[hi]) * frac
      out.append(Int16(clamping: Int(interpolated.rounded())))
    }
    return out
  }

  /// Resample to the model-required realtime rate (24 kHz PCM).
  public static func resampleToRealtime(_ samples: [Int16], sourceRate: Int) -> [Int16] {
    resample(samples, fromRate: sourceRate, toRate: 24000)
  }

  /// Split samples into chunks of at most `maxSamples` (preserves order).
  public static func chunk(_ samples: [Int16], maxSamples: Int) -> [[Int16]] {
    guard maxSamples > 0, samples.count > maxSamples else {
      return samples.isEmpty ? [] : [samples]
    }
    var out: [[Int16]] = []
    var start = 0
    while start < samples.count {
      let end = min(start + maxSamples, samples.count)
      out.append(Array(samples[start..<end]))
      start = end
    }
    return out
  }
}

// MARK: - Client event builders (pure JSON)

/// Pure builders for realtime client JSON (unit-tested, no transport).
public enum RealtimeClientEvents {
  /// `session.update` for a transcription session (official schema).
  public static func sessionUpdate(
    model: String,
    language: String = "",
    prompt: String? = nil,
    keywords: [String] = [],
    delay: RealtimeTranscriptionDelay? = nil
  ) -> String {
    var transcription: [String: Any] = ["model": model]
    if let prompt, !prompt.isEmpty {
      transcription["prompt"] = prompt
    }
    let cleanKeywords = keywords.filter { !$0.isEmpty }
    if !cleanKeywords.isEmpty {
      transcription["keywords"] = cleanKeywords
    }
    if !language.isEmpty {
      transcription["languages"] = [language]
    }
    if let delay {
      transcription["delay"] = delay.rawValue
    }
    let session: [String: Any] = [
      "type": "transcription",
      "audio": [
        "input": [
          "format": ["type": "audio/pcm", "rate": 24000],
          "transcription": transcription,
          // Client-side VAD: server VAD unsupported for gpt-live-transcribe.
          "turn_detection": NSNull(),
        ] as [String: Any],
      ] as [String: Any],
    ]
    let event: [String: Any] = ["type": "session.update", "session": session]
    let data =
      (try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{\"type\":\"session.update\"}"
  }

  /// `input_audio_buffer.append` with base64 PCM16.
  public static func appendAudio(base64PCM: String) -> String {
    let event: [String: Any] = ["type": "input_audio_buffer.append", "audio": base64PCM]
    let data = (try? JSONSerialization.data(withJSONObject: event)) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{\"type\":\"input_audio_buffer.append\"}"
  }

  /// `input_audio_buffer.commit` (end of turn -> final transcript).
  public static func commit() -> String {
    "{\"type\":\"input_audio_buffer.commit\"}"
  }

  /// `input_audio_buffer.clear` (discard buffered audio).
  public static func clear() -> String {
    "{\"type\":\"input_audio_buffer.clear\"}"
  }
}

// MARK: - Endpoint

/// WebSocket endpoint for realtime transcription sessions.
public enum RealtimeEndpoint {
  /// Base URL for OpenAI realtime WebSocket sessions.
  public static let baseURL = "wss://api.openai.com/v1/realtime"
  /// Session URL: transcription intent keeps model selection inside
  /// `session.update` (official transcription flow).
  public static func transcriptionURL() -> URL? {
    URL(string: "\(baseURL)?intent=transcription")
  }
  /// Model-scoped URL (conversational realtime sessions).
  public static func modelURL(model: String) -> URL? {
    URL(string: "\(baseURL)?model=\(model)")
  }
}

// MARK: - Model helpers

extension STTModelRegistry {
  /// Whether a concrete (adapterID, model) profile uses a stateful realtime
  /// session instead of batch uploads.
  public static func isRealtime(adapterID: String, model: String) -> Bool {
    resolve(adapterID: adapterID, model: model).capabilities.transport == .streamingSession
  }
}

extension ProviderRequestBuilder {
  /// Whether a concrete (adapterID, model) pair streams via realtime.
  public static func isRealtime(adapterID: String, model: String) -> Bool {
    STTModelRegistry.isRealtime(adapterID: adapterID, model: model)
  }
}

// MARK: - Stateful session (one per dictation)

/// Signals that a bounded `withTimeout` wait expired without a result.
/// Distinct from a `nil` operation result (clean transport EOF) so callers
/// keep waiting until their own deadline instead of treating a short
/// per-receive expiry as closure.
private enum RealtimeWaitTimeout: Error {
  case timedOut
}

/// One item produced by the single long-lived receive loop.
/// `.text(nil)` is a clean transport EOF; `.failure` preserves the transport
/// error so callers apply the same close-out as a direct `receive()` error.
private enum RealtimeReceiveItem: Sendable {
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
private actor RealtimeReceiveChannel {
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
  func deliver(_ item: RealtimeReceiveItem) {
    guard !stopped else { return }
    if let waiter = waiterStore.popFirst() {
      waiter.resume(returning: item)
    } else {
      pending.append(item)
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

/// One stateful realtime transcription session per dictation.
///
/// Usage:
/// ```
/// let session = RealtimeTranscriptionSession(
///   transport: ws, config: RealtimeSessionConfig(model: "gpt-live-transcribe"),
///   policy: RealtimeSessionPolicy())
/// try await session.connect()
/// try await session.appendAudio(samples16k, sourceSampleRate: 16000)
/// try await session.commit()
/// let final = try await session.waitForFinal()
/// await session.close()
/// ```
/// Cancellation: call `cancel()` (or cancel the surrounding Task); pending
/// waits throw `RealtimeTranscriptionError.cancelled` and the transport is
/// closed exactly once.
public actor RealtimeTranscriptionSession {
  private let transport: RealtimeTransport
  private let config: RealtimeSessionConfig
  private let policy: RealtimeSessionPolicy
  private let fallback: RealtimeFallbackPolicy

  private var state: RealtimeSessionState = .idle
  private var accumulator = RealtimeTranscriptAccumulator()
  private var lastError: String?
  private var closedTransport = false
  private var connectAttempts = 0
  /// Single long-lived receive loop for this session. The pump is the only
  /// caller of `transport.receive()`; waits consume the stream with a short
  /// per-poll timeout so no wait ever cancels a pending WebSocket receive.
  private var receiveChannel: RealtimeReceiveChannel?

  /// Latest display text (committed + pending deltas, no duplication).
  public var partialText: String { accumulator.partialText }
  /// Deterministic final transcript once a completion arrived.
  public var completedText: String? { accumulator.finalText }
  /// Current lifecycle state.
  public var currentState: RealtimeSessionState { state }
  /// Last provider/transport error message, if any.
  public var lastErrorMessage: String? { lastError }

  public init(
    transport: RealtimeTransport,
    config: RealtimeSessionConfig,
    policy: RealtimeSessionPolicy = RealtimeSessionPolicy(),
    fallback: RealtimeFallbackPolicy = .failClosed
  ) {
    self.transport = transport
    self.config = config
    self.policy = policy
    self.fallback = fallback
  }

  // MARK: - Lifecycle

  /// Open the session: send `session.update` and wait for
  /// `session.created`/`session.updated` within `policy.connectTimeout`.
  public func connect() async throws {
    guard state == .idle else {
      throw RealtimeTranscriptionError.alreadyConnected
    }
    try Task.checkCancellation()
    state = .connecting
    let update = RealtimeClientEvents.sessionUpdate(
      model: config.model,
      language: config.language,
      prompt: config.prompt,
      keywords: config.keywords,
      delay: config.delay)
    do {
      try await transport.send(text: update)
    } catch {
      state = .failed
      lastError = error.localizedDescription
      throw RealtimeTranscriptionError.transport(error.localizedDescription)
    }
    // Wait for session acknowledgement (created or updated).
    let acknowledged = await waitForAck(timeout: policy.connectTimeout)
    if state == .failed {
      throw RealtimeTranscriptionError.sessionFailed(lastError ?? "session rejected")
    }
    if !acknowledged {
      state = .failed
      lastError = "no session ack"
      throw RealtimeTranscriptionError.timeout("no session ack")
    }
    state = .ready
    connectAttempts += 1
  }

  /// Stream microphone audio continuously. Samples are resampled from
  /// `sourceSampleRate` to the model-required 24 kHz and sent as ordered
  /// base64 PCM16 appends (no WAV chunks are written).
  public func appendAudio(_ samples: [Int16], sourceSampleRate: Int) async throws {
    try Task.checkCancellation()
    guard state == .ready || state == .streaming else {
      throw RealtimeTranscriptionError.notConnected
    }
    if Task.isCancelled {
      throw RealtimeTranscriptionError.cancelled
    }
    let realtime = RealtimePCMConverter.resample(samples, fromRate: sourceSampleRate, toRate: 24000)
    let chunks = RealtimePCMConverter.chunk(realtime, maxSamples: policy.maxSamplesPerAppend)
    state = .streaming
    for chunk in chunks {
      try Task.checkCancellation()
      let payload = RealtimeClientEvents.appendAudio(
        base64PCM: RealtimePCMConverter.base64PCM(from: chunk))
      do {
        try await transport.send(text: payload)
      } catch {
        state = .failed
        lastError = error.localizedDescription
        throw RealtimeTranscriptionError.transport(error.localizedDescription)
      }
    }
  }

  /// End the audio turn: the provider emits the final completion event.
  public func commit() async throws {
    try Task.checkCancellation()
    guard state == .ready || state == .streaming else {
      throw RealtimeTranscriptionError.notConnected
    }
    state = .committing
    do {
      try await transport.send(text: RealtimeClientEvents.commit())
    } catch {
      state = .failed
      lastError = error.localizedDescription
      throw RealtimeTranscriptionError.transport(error.localizedDescription)
    }
  }

  /// Handle one received server text message: updates the accumulator and
  /// lifecycle state. Returns the parsed event (pure aside from state).
  @discardableResult
  public func handleMessage(_ text: String) -> RealtimeServerEvent {
    let event = RealtimeEventParser.parse(text)
    switch event {
    case .delta, .committed, .sessionCreated, .sessionUpdated, .unknown:
      _ = accumulator.apply(event)
    case .completed:
      _ = accumulator.apply(event)
      if state == .committing {
        state = .closed
      }
    case let .failed(_, message):
      _ = accumulator.apply(event)
      state = .failed
      lastError = message
    case let .errorMessage(message):
      state = .failed
      lastError = message
    }
    return event
  }

  /// Wait for the deterministic final transcript after `commit()`.
  /// Returns the completed text, or throws on timeout/cancel/failure.
  /// When no completion arrives but deltas did, the partial text is returned
  /// as a deterministic fallback (documented, not a silent batch upload).
  public func waitForFinal() async throws -> String {
    let deadline = Date().addingTimeInterval(policy.commitTimeout)
    await ensureReceiveChannel()
    while true {
      try Task.checkCancellation()
      if state == .cancelled {
        throw RealtimeTranscriptionError.cancelled
      }
      if state == .failed {
        throw RealtimeTranscriptionError.sessionFailed(lastError ?? "session failed")
      }
      if let final = accumulator.finalText {
        return final
      }
      if Date() >= deadline {
        // Deterministic close-out: prefer completed text; else expose the
        // accumulated partial so the caller never hangs. Batch fallback is
        // NOT triggered here (see RealtimeFallbackPolicy).
        let partial = accumulator.partialText
        if !partial.isEmpty {
          return partial
        }
        throw RealtimeTranscriptionError.timeout("no completion within commit timeout")
      }
      do {
        guard let item = try await receiveChannel?.next(timeout: 0.2) else {
          // Stream finished before completion: same close-out as clean EOF.
          if let final = self.accumulator.finalText {
            return final
          }
          let partial = self.accumulator.partialText
          if !partial.isEmpty {
            return partial
          }
          state = .failed
          lastError = "transport closed before completion"
          throw RealtimeTranscriptionError.transport("transport closed before completion")
        }
        switch item {
        case .text(let text):
          guard let text else {
            // Clean EOF before completion: deterministic close-out. When a
            // final or partial transcript is already available it is returned
            // (no failure); otherwise the drop fails the session closed.
            if let final = self.accumulator.finalText {
              return final
            }
            let partial = self.accumulator.partialText
            if !partial.isEmpty {
              return partial
            }
            state = .failed
            lastError = "transport closed before completion"
            throw RealtimeTranscriptionError.transport("transport closed before completion")
          }
          _ = handleMessage(text)
        case .failure(let transportError):
          throw transportError
        }
      } catch is CancellationError {
        throw RealtimeTranscriptionError.cancelled
      } catch is RealtimeWaitTimeout {
        // Per-poll expiry (not EOF): keep waiting until the commit deadline.
        continue
      } catch let error as RealtimeTranscriptionError {
        // Transport drop during receive fails the session closed so a later
        // `lastErrorMessage` reflects the drop. When a final or partial
        // transcript is already buffered it is returned instead of throwing
        // (same close-out as clean EOF below).
        if case .transport(let message) = error {
          if let final = self.accumulator.finalText {
            return final
          }
          let partial = self.accumulator.partialText
          if !partial.isEmpty {
            return partial
          }
          state = .failed
          lastError = message
        }
        throw error
      } catch {
        // Unknown receive errors are transport drops, not per-poll
        // expiries: return buffered text when available, otherwise fail
        // closed so `lastErrorMessage` reflects the drop.
        if let final = self.accumulator.finalText {
          return final
        }
        let partial = self.accumulator.partialText
        if !partial.isEmpty {
          return partial
        }
        state = .failed
        lastError = error.localizedDescription
        throw RealtimeTranscriptionError.transport(error.localizedDescription)
      }
    }
  }

  /// Pump server messages until the final transcript arrives (convenience for
  /// tests and simple callers that committed exactly one turn).
  public func runToCompletion(
    onPartial: ((String) -> Void)? = nil
  ) async throws -> String {
    await ensureReceiveChannel()
    while true {
      try Task.checkCancellation()
      if state == .cancelled {
        throw RealtimeTranscriptionError.cancelled
      }
      if state == .failed {
        throw RealtimeTranscriptionError.sessionFailed(lastError ?? "session failed")
      }
      if let final = accumulator.finalText {
        return final
      }
      let item = await receiveChannel?.dequeue()
      guard let item else {
        // Stream finished before completion: return buffered transcript when
        // available; otherwise fail the session closed.
        if let final = accumulator.finalText {
          return final
        }
        let partial = accumulator.partialText
        if !partial.isEmpty {
          return partial
        }
        state = .failed
        lastError = "transport closed before completion"
        throw RealtimeTranscriptionError.transport("transport closed before completion")
      }
      switch item {
      case .text(let text):
        guard let text else {
          // Clean EOF before completion: return buffered transcript when
          // available; otherwise fail the session closed.
          if let final = accumulator.finalText {
            return final
          }
          let partial = accumulator.partialText
          if !partial.isEmpty {
            return partial
          }
          state = .failed
          lastError = "transport closed before completion"
          throw RealtimeTranscriptionError.transport("transport closed before completion")
        }
        _ = handleMessage(text)
        onPartial?(accumulator.partialText)
      case .failure(let transportError):
        if case .transport(let message) = transportError {
          if let final = accumulator.finalText {
            return final
          }
          let partial = accumulator.partialText
          if !partial.isEmpty {
            return partial
          }
          state = .failed
          lastError = message
        }
        throw transportError
      }
    }
  }

  /// Deterministic teardown: closes the transport exactly once and moves to
  /// `.closed` (or `.cancelled` when `cancelled == true`).
  public func close(cancelled: Bool = false) async {
    state = cancelled ? .cancelled : .closed
    await closeTransportOnce()
  }

  /// Deterministic cancellation from any state: drops pending work, closes
  /// the transport, blocks further append/commit.
  public func cancel() async {
    state = .cancelled
    await closeTransportOnce()
  }

  /// Explicit fallback decision after a failure (never implicit).
  public var fallbackPolicy: RealtimeFallbackPolicy { fallback }

  // MARK: - Private

  /// Start the single long-lived receive loop (idempotent).
  private func ensureReceiveChannel() async {
    if receiveChannel == nil {
      receiveChannel = RealtimeReceiveChannel(transport: transport)
    }
    await receiveChannel?.start()
  }

  private func closeTransportOnce() async {
    if let receiveChannel {
      await receiveChannel.stop()
    }
    guard !closedTransport else { return }
    closedTransport = true
    await transport.close()
  }

  /// Wait up to `timeout` for a session ack message. Returns true when
  /// `session.created`/`session.updated` arrived; false on timeout/EOF.
  /// A per-poll stream expiry keeps waiting until the deadline; only a `nil`
  /// stream result (clean EOF) returns `false` early. Timeouts apply to the
  /// stream, never to a pending `transport.receive()`.
  private func waitForAck(timeout: TimeInterval) async -> Bool {
    await ensureReceiveChannel()
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if Task.isCancelled { return false }
      do {
        guard let item = try await receiveChannel?.next(timeout: 0.2) else {
          return false
        }
        let text: String?
        switch item {
        case .text(let message):
          text = message
        case .failure:
          // Transport noise while waiting for ack: keep waiting until the
          // ack deadline (same as unknown messages below).
          continue
        }
        guard let text else {
          return false
        }
        let event = RealtimeEventParser.parse(text)
        switch event {
        case .sessionCreated, .sessionUpdated:
          return true
        case .delta, .completed, .committed:
          // Early transcript before ack: keep it, treat as acknowledged.
          _ = accumulator.apply(event)
          return true
        case .failed(_, let message):
          _ = accumulator.apply(event)
          state = .failed
          lastError = message
          return false
        case .errorMessage(let message):
          state = .failed
          lastError = message
          return false
        case .unknown:
          continue
        }
      } catch is RealtimeWaitTimeout {
        // Per-poll stream expiry: keep waiting until the ack deadline.
        continue
      } catch {
        continue
      }
    }
    return false
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
