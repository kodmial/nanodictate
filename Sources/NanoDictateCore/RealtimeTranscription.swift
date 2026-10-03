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
  /// Extra expected language hints besides `language` (code-switching).
  /// Normalized codes; merged with `language` into `languages[]` by
  /// `session.update` (capped at the shared total-languages budget).
  public var extraLanguages: [String]
  /// Latency/accuracy hint; nil = server default.
  public var delay: RealtimeTranscriptionDelay?
  /// Source sample rate of appended Int16 samples (resampled to 24 kHz).
  public var sourceSampleRate: Int

  public init(
    model: String = "gpt-live-transcribe",
    language: String = "",
    prompt: String? = nil,
    keywords: [String] = [],
    extraLanguages: [String] = [],
    delay: RealtimeTranscriptionDelay? = nil,
    sourceSampleRate: Int = 16000
  ) {
    self.model = model
    self.language = language
    self.prompt = prompt
    self.keywords = keywords
    self.extraLanguages = extraLanguages
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
  /// Per-phase budget for audio sends. `appendAudio` chunks share one
  /// `appendTimeout` budget, and the `commit` send gets its own separate
  /// `appendTimeout` budget. Bounds otherwise unbounded WebSocket sends so a
  /// stalled upload cannot outlive the caller's watchdog (which must cover
  /// both phases: connect + 2 x append + final wait + close + margin).
  public var appendTimeout: TimeInterval
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
    appendTimeout: TimeInterval = 15,
    closeTimeout: TimeInterval = 5,
    maxReconnectAttempts: Int = 2,
    reconnectBaseDelay: TimeInterval = 0.5,
    maxSamplesPerAppend: Int = 4800
  ) {
    self.connectTimeout = connectTimeout
    self.commitTimeout = commitTimeout
    self.appendTimeout = appendTimeout
    self.closeTimeout = closeTimeout
    self.maxReconnectAttempts = maxReconnectAttempts
    self.reconnectBaseDelay = reconnectBaseDelay
    self.maxSamplesPerAppend = maxSamplesPerAppend
  }

  /// Delay before reconnect attempt number `attempt` (0-based).
  public func reconnectDelay(forAttempt attempt: Int) -> TimeInterval {
    reconnectBaseDelay * pow(2.0, Double(max(0, attempt)))
  }

  /// Worst-case session duration the Agent watchdog must cover: connect, one
  /// `appendTimeout` for the append phase, a second `appendTimeout` for the
  /// commit send, the final-wait budget, close, plus `margin`.
  public func watchdogDuration(margin: TimeInterval = 5) -> TimeInterval {
    connectTimeout + (2 * appendTimeout) + commitTimeout + closeTimeout + margin
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

  /// Whether any item completed, including an empty (silent) transcript.
  public var hasAnyCompletion: Bool { !completed.isEmpty }
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
  /// The timeout is a total budget: the initial send (including lazy
  /// WebSocket setup) is bounded by `connectTimeout`, and the acknowledgement
  /// wait receives only the unspent remainder.
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
      extraLanguages: config.extraLanguages,
      delay: config.delay)
    let connectStart = Date()
    do {
      try await sendWithTimeout(text: update, timeout: policy.connectTimeout)
    } catch is RealtimeWaitTimeout {
      state = .failed
      lastError = "no session ack"
      await closeTransportOnce()
      throw RealtimeTranscriptionError.timeout("no session ack")
    } catch {
      state = .failed
      lastError = error.localizedDescription
      throw RealtimeTranscriptionError.transport(error.localizedDescription)
    }
    let remaining = policy.connectTimeout - Date().timeIntervalSince(connectStart)
    if remaining <= 0 {
      state = .failed
      lastError = "no session ack"
      throw RealtimeTranscriptionError.timeout("no session ack")
    }
    // Wait for session acknowledgement (created or updated).
    let acknowledged = await waitForAck(timeout: remaining)
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
  /// base64 PCM16 appends (no WAV chunks are written). The append phase
  /// is bounded by its own `policy.appendTimeout` budget (separate from the
  /// commit send budget): each chunk send receives only the
  /// unspent remainder, so a stalled upload fails fast instead of outliving
  /// the caller's watchdog. Timeout/cancellation closes the transport before
  /// returning (a suspended WebSocket send unblocks only on close).
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
    let deadline = Date().addingTimeInterval(policy.appendTimeout)
    for chunk in chunks {
      try Task.checkCancellation()
      let remaining = deadline.timeIntervalSinceNow
      guard remaining > 0 else {
        state = .failed
        lastError = "audio append timed out"
        await closeTransportOnce()
        throw RealtimeTranscriptionError.timeout("audio append timed out")
      }
      let payload = RealtimeClientEvents.appendAudio(
        base64PCM: RealtimePCMConverter.base64PCM(from: chunk))
      do {
        try await sendWithTimeout(text: payload, timeout: remaining)
      } catch is RealtimeWaitTimeout {
        state = .failed
        lastError = "audio append timed out"
        await closeTransportOnce()
        throw RealtimeTranscriptionError.timeout("audio append timed out")
      } catch {
        if error is CancellationError {
          state = .cancelled
          await closeTransportOnce()
          throw RealtimeTranscriptionError.cancelled
        }
        state = .failed
        lastError = error.localizedDescription
        throw RealtimeTranscriptionError.transport(error.localizedDescription)
      }
    }
  }

  /// End the audio turn: the provider emits the final completion event.
  /// The `commit` send gets its own `policy.appendTimeout` budget (separate
  /// from the `appendAudio` budget) and closes the transport on
  /// timeout/cancellation, like the append phase above.
  public func commit() async throws {
    try Task.checkCancellation()
    guard state == .ready || state == .streaming else {
      throw RealtimeTranscriptionError.notConnected
    }
    state = .committing
    do {
      try await sendWithTimeout(text: RealtimeClientEvents.commit(), timeout: policy.appendTimeout)
    } catch is RealtimeWaitTimeout {
      state = .failed
      lastError = "commit timed out"
      await closeTransportOnce()
      throw RealtimeTranscriptionError.timeout("commit timed out")
    } catch {
      if error is CancellationError {
        state = .cancelled
        await closeTransportOnce()
        throw RealtimeTranscriptionError.cancelled
      }
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
      try throwIfWaitTerminal()
      if accumulator.hasAnyCompletion {
        return accumulator.finalText ?? ""
      }
      if let done = try transcriptIfPastDeadline(deadline) {
        return done
      }
      do {
        guard let item = try await receiveChannel?.next(timeout: 0.2) else {
          try throwIfWaitTerminal()
          return try closeOutOrFail(message: "transport closed before completion")
        }
        if let done = try handleWaitItem(item) {
          return done
        }
      } catch is CancellationError {
        throw RealtimeTranscriptionError.cancelled
      } catch is RealtimeWaitTimeout {
        // Per-poll expiry (not EOF): keep waiting until the commit deadline.
        continue
      } catch let error as RealtimeTranscriptionError {
        return try resolveWaitError(error)
      } catch {
        return try closeOutOrFail(message: error.localizedDescription)
      }
    }
  }

  /// Throw when the wait loop reached a terminal session state.
  private func throwIfWaitTerminal() throws {
    try Task.checkCancellation()
    if state == .cancelled {
      throw RealtimeTranscriptionError.cancelled
    }
    if state == .failed {
      throw RealtimeTranscriptionError.sessionFailed(lastError ?? "session failed")
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
      if accumulator.hasAnyCompletion {
        return accumulator.finalText ?? ""
      }
      let item = await receiveChannel?.dequeue()
      guard let item else {
        if state == .cancelled {
          throw RealtimeTranscriptionError.cancelled
        }
        // Stream finished before completion: return buffered transcript when
        // available; otherwise fail the session closed. Tear down the pump
        // and transport so an unclosed session cannot leave runPump
        // appending outcomes indefinitely.
        if accumulator.hasAnyCompletion {
          await closeTransportOnce()
          return accumulator.finalText ?? ""
        }
        let partial = accumulator.partialText
        if !partial.isEmpty {
          await closeTransportOnce()
          return partial
        }
        state = .failed
        lastError = "transport closed before completion"
        await closeTransportOnce()
        throw RealtimeTranscriptionError.transport("transport closed before completion")
      }
      switch item {
      case .text(let text):
        guard let text else {
          if state == .cancelled {
            throw RealtimeTranscriptionError.cancelled
          }
          // Clean EOF before completion: return buffered transcript when
          // available; otherwise fail the session closed. Tear down the
          // pump and transport (see above); runPump itself keeps running
          // on EOF so waitForAck can read until its deadline.
          if accumulator.hasAnyCompletion {
            await closeTransportOnce()
            return accumulator.finalText ?? ""
          }
          let partial = accumulator.partialText
          if !partial.isEmpty {
            await closeTransportOnce()
            return partial
          }
          state = .failed
          lastError = "transport closed before completion"
          await closeTransportOnce()
          throw RealtimeTranscriptionError.transport("transport closed before completion")
        }
        _ = handleMessage(text)
        onPartial?(accumulator.partialText)
      case .failure(let transportError):
        if case .transport(let message) = transportError {
          // Terminal transport failure: same teardown as EOF above.
          if accumulator.hasAnyCompletion {
            await closeTransportOnce()
            return accumulator.finalText ?? ""
          }
          let partial = accumulator.partialText
          if !partial.isEmpty {
            await closeTransportOnce()
            return partial
          }
          state = .failed
          lastError = message
          await closeTransportOnce()
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
}

// MARK: - waitForFinal helpers (kept out of the session body for lint)

extension RealtimeTranscriptionSession {
  /// Bounded initial send: lazy WebSocket setup inside `transport.send`
  /// must not keep `connect()` pending past `timeout`. Expiring the wait
  /// closes the transport *before* waiting for the send task to finish: send
  /// cancellation is cooperative, and a production send can stay suspended
  /// until the WebSocket closes, so draining the task group first would block
  /// the very close that unblocks it. The caller marks the session failed.
  /// Transport errors propagate unchanged so `connect()` preserves its
  /// existing error mapping.
  private func sendWithTimeout(text: String, timeout: TimeInterval) async throws {
    let transport = self.transport
    let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
    try await withThrowingTaskGroup(of: Void.self) { group in
      group.addTask {
        try await transport.send(text: text)
      }
      group.addTask {
        try await Task.sleep(nanoseconds: nanoseconds)
        throw RealtimeWaitTimeout.timedOut
      }
      do {
        _ = try await group.next()
        group.cancelAll()
        _ = try? await group.next()
      } catch is RealtimeWaitTimeout {
        // Unblock a non-cooperative send first: closing the transport lets a
        // suspended WebSocket send finish instead of blocking group exit.
        await closeTransportOnce()
        group.cancelAll()
        _ = try? await group.next()
        throw RealtimeWaitTimeout.timedOut
      } catch {
        if error is CancellationError {
          // Same ordering for outer cancellation: close before draining so a
          // suspended send cannot block task-group exit.
          await closeTransportOnce()
        }
        group.cancelAll()
        _ = try? await group.next()
        throw error
      }
    }
  }

  /// Wait up to `timeout` for a session ack message. Returns true when
  /// `session.created`/`session.updated` arrived; false on timeout.
  /// A per-poll stream expiry keeps waiting until the deadline, as does a
  /// clean EOF or transport noise observed before the ack: the ack and the
  /// EOF are delivered back-to-back by the single pump, so an EOF surfacing
  /// first around a poll expiry must not fail fast while the ack may still
  /// be buffered right behind it. Timeouts apply to the
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
          // Clean EOF before the ack: keep waiting until the ack deadline
          // (same as transport noise above). Failing fast here loses a
          // back-to-back ack buffered right behind the EOF around a
          // per-poll stream expiry.
          continue
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

  /// Deterministic close-out at the commit deadline: prefer completed text,
  /// else expose the accumulated partial so the caller never hangs. Batch
  /// fallback is NOT triggered here (see RealtimeFallbackPolicy).
  /// Returns nil when still before the deadline.
  fileprivate func transcriptIfPastDeadline(_ deadline: Date) throws -> String? {
    guard Date() >= deadline else { return nil }
    if accumulator.hasAnyCompletion {
      return accumulator.finalText ?? ""
    }
    let partial = accumulator.partialText
    if !partial.isEmpty {
      return partial
    }
    throw RealtimeTranscriptionError.timeout("no completion within commit timeout")
  }

  /// Buffered transcript when available (completed preferred, else partial).
  fileprivate func bufferedTranscript() -> String? {
    if accumulator.hasAnyCompletion {
      return accumulator.finalText ?? ""
    }
    let partial = accumulator.partialText
    return partial.isEmpty ? nil : partial
  }

  /// Deterministic close-out: return buffered text when available, otherwise
  /// fail the session closed with `message`.
  fileprivate func closeOutOrFail(message: String) throws -> String {
    if let buffered = bufferedTranscript() {
      return buffered
    }
    state = .failed
    lastError = message
    throw RealtimeTranscriptionError.transport(message)
  }

  /// Handle one receive-channel item during `waitForFinal`.
  /// Returns a transcript when close-out is satisfied, nil to keep waiting.
  fileprivate func handleWaitItem(_ item: RealtimeReceiveItem) throws -> String? {
    switch item {
    case .text(let text):
      guard let text else {
        try throwIfWaitTerminal()
        return try closeOutOrFail(message: "transport closed before completion")
      }
      _ = handleMessage(text)
      return nil
    case .failure(let transportError):
      throw transportError
    }
  }

  /// Map a realtime error during the wait into return-or-throw.
  /// A transport drop fails the session closed so a later `lastErrorMessage`
  /// reflects the drop; when buffered text exists it is returned instead.
  fileprivate func resolveWaitError(_ error: RealtimeTranscriptionError) throws -> String {
    if case .transport(let message) = error {
      return try closeOutOrFail(message: message)
    }
    throw error
  }
}
