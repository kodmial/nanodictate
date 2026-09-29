import Foundation

// MARK: - Stateful realtime transcription session (OpenAI realtime API)
//
// One stateful WebSocket session per dictation for streaming-capable
// profiles (see STTModelRegistry `gpt-live-transcribe` family). The batch
// path (Transcriber / BatchTranscriber) is untouched and remains the
// regression-safe fallback for non-streaming providers.
//
// Session lifecycle and error/reconnect policy (written before coding, see
// docs/realtime-transcription.md):
// - Exactly one session per dictation: start() -> stream appends -> stop()
//   (commit + wait for completion + close). A failed session is never reused;
//   the next dictation opens a fresh session (fresh item IDs, no stitching).
// - No silent fallback: a realtime transport/provider failure surfaces as
//   RealtimeSessionError. Automatic downgrade to repeated batch uploads is
//   forbidden; callers opt in explicitly via RealtimeFallbackPolicy.batchOnce
//   (single batch request, not a retry loop).
// - No automatic reconnect inside a dictation: reconnecting mid-stream would
//   duplicate or reorder committed turns. On failure the session moves to
//   .failed and must be discarded.
// - Deterministic teardown: stop()/cancel()/close() are idempotent, never
//   block the audio tap thread, and never wedge the UI: the receive loop ends
//   on close, waiters wake with timeout or cancellation.
// - Audio format is model-driven (STTAudioProfile.realtimeMono24k: 24 kHz
//   mono raw PCM16 little-endian, base64 inside input_audio_buffer.append),
//   never the 16 kHz batch WAV profile.
//
// Wire schema verified against the official realtime transcription guide
// (2026-09): session.update with type=transcription, audio.input.format
// {type audio/pcm, rate 24000}, manual commit (turn_detection null),
// input_audio_buffer.append/commit/clear, server events
// conversation.item.input_audio_transcription.delta/completed/failed.

// MARK: - Fallback policy

/// Explicit policy for what happens when a realtime session fails.
/// There is no implicit batch retry: callers choose.
public enum RealtimeFallbackPolicy: Equatable {
  /// Surface the realtime error; no batch request is issued.
  case fail
  /// Issue exactly one batch transcription request as a fallback
  /// (caller-owned; never a repeated upload loop).
  case batchOnce
}

// MARK: - Session state

/// Lifecycle state of one realtime transcription session.
public enum RealtimeSessionState: Equatable {
  case idle
  case connecting
  case ready
  case streaming
  case committing
  case closed
  case failed(String)
  case cancelled
}

// MARK: - Session errors

public enum RealtimeSessionError: Error, Equatable {
  case invalidState(String)
  case network(String)
  case provider(String)
  case timeout(String)
  case cancelled
  case invalidMessage(String)
}

// MARK: - Session config

/// Configuration for one realtime transcription session.
public struct RealtimeSessionConfig: Equatable {
  /// Transcription model, e.g. "gpt-live-transcribe".
  public var model: String
  /// API key for the Authorization header.
  public var apiKey: String
  /// Single language hint ("" = auto-detect, omitted). Mapped to the
  /// session `languages` array for multi-hint realtime models.
  public var language: String
  /// Optional transcription context (specialized vocabulary, setting).
  public var prompt: String?
  /// Optional keyword biasing list (product names, acronyms).
  public var keywords: [String]
  /// WebSocket endpoint. Default is the official transcription intent URL.
  public var urlString: String
  /// Seconds to wait for session readiness and for the final completion.
  public var timeoutSeconds: TimeInterval

  public static let defaultURLString = "wss://api.openai.com/v1/realtime?intent=transcription"

  public init(
    model: String = "gpt-live-transcribe",
    apiKey: String = "",
    language: String = "",
    prompt: String? = nil,
    keywords: [String] = [],
    urlString: String = RealtimeSessionConfig.defaultURLString,
    timeoutSeconds: TimeInterval = 15
  ) {
    self.model = model
    self.apiKey = apiKey
    self.language = language
    self.prompt = prompt
    self.keywords = keywords
    self.urlString = urlString
    self.timeoutSeconds = timeoutSeconds
  }
}

// MARK: - Audio conversion (16 kHz mic -> 24 kHz realtime)

/// Pure PCM helpers for the realtime path. The microphone delivers 16 kHz
/// Int16; realtime transcription requires 24 kHz mono PCM16 little-endian.
public enum RealtimeAudioConverter {
  /// Upsample 16 kHz Int16 to 24 kHz Int16 (factor 3/2) with linear
  /// interpolation. Empty in, empty out. Deterministic, no allocation
  /// beyond the output array.
  public static func upscale16kTo24k(_ samples: [Int16]) -> [Int16] {
    guard !samples.isEmpty else { return [] }
    let outCount = samples.count * 3 / 2
    var out: [Int16] = []
    out.reserveCapacity(outCount)
    for j in 0..<outCount {
      let pos = Double(j) * 2.0 / 3.0
      let i = Int(pos)
      let frac = pos - Double(i)
      let a = Int(samples[min(i, samples.count - 1)])
      let b = Int(samples[min(i + 1, samples.count - 1)])
      let value = Int((Double(a) * (1.0 - frac) + Double(b) * frac).rounded())
      out.append(Int16(clamping: value))
    }
    return out
  }

  /// Raw PCM16 little-endian bytes (no WAV header) for realtime appends.
  public static func pcm16LEBytes(_ samples: [Int16]) -> Data {
    var data = Data()
    data.reserveCapacity(samples.count * 2)
    for sample in samples {
      var value = sample.littleEndian
      withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
    }
    return data
  }

  /// Base64 of raw PCM16 bytes for `input_audio_buffer.append`.
  public static func base64PCM16(_ samples: [Int16]) -> String {
    pcm16LEBytes(samples).base64EncodedString()
  }

  /// Split samples into append-sized chunks (default ~128 ms at 24 kHz).
  public static func chunked(_ samples: [Int16], chunkSamples: Int = 3072) -> [[Int16]] {
    guard chunkSamples > 0, !samples.isEmpty else { return [] }
    var chunks: [[Int16]] = []
    var index = 0
    while index < samples.count {
      let end = min(index + chunkSamples, samples.count)
      chunks.append(Array(samples[index..<end]))
      index = end
    }
    return chunks
  }
}

// MARK: - Client events

/// JSON text builders for realtime client events.
public enum RealtimeClientEvent {
  /// session.update enabling transcription with 24 kHz PCM input and manual
  /// commit (turn_detection null for push-to-talk dictation).
  public static func sessionUpdate(config: RealtimeSessionConfig) -> String {
    var transcription: [String: Any] = ["model": config.model]
    if let prompt = config.prompt, !prompt.isEmpty {
      transcription["prompt"] = prompt
    }
    if !config.keywords.isEmpty {
      transcription["keywords"] = config.keywords
    }
    if !config.language.isEmpty {
      transcription["languages"] = [config.language]
    }
    let session: [String: Any] = [
      "type": "transcription",
      "audio": [
        "input": [
          "format": ["type": "audio/pcm", "rate": 24000],
          "transcription": transcription,
          "turn_detection": NSNull(),
        ]
      ],
    ]
    let event: [String: Any] = ["type": "session.update", "session": session]
    let data = (try? JSONSerialization.data(withJSONObject: event, options: [.sortedKeys])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{\"type\":\"session.update\"}"
  }

  /// input_audio_buffer.append with base64 PCM16 audio.
  public static func appendAudio(base64PCM: String) -> String {
    let event: [String: Any] = ["type": "input_audio_buffer.append", "audio": base64PCM]
    let data = (try? JSONSerialization.data(withJSONObject: event, options: [])) ?? Data()
    return String(data: data, encoding: .utf8) ?? "{\"type\":\"input_audio_buffer.append\"}"
  }

  /// input_audio_buffer.commit: close the turn, request final transcript.
  public static func commit() -> String {
    "{\"type\":\"input_audio_buffer.commit\"}"
  }

  /// input_audio_buffer.clear: drop buffered audio without transcribing.
  public static func clear() -> String {
    "{\"type\":\"input_audio_buffer.clear\"}"
  }
}

// MARK: - Server events

/// Parsed realtime server event (transcription-relevant subset).
public enum RealtimeServerEvent: Equatable {
  case delta(itemID: String, text: String)
  case completed(itemID: String, transcript: String)
  case failed(itemID: String, message: String)
  case sessionReady
  case error(message: String)
  case ignored(type: String)
  case invalid(message: String)

  /// Event type names from the official realtime API.
  public static let deltaType = "conversation.item.input_audio_transcription.delta"
  public static let completedType = "conversation.item.input_audio_transcription.completed"
  public static let failedType = "conversation.item.input_audio_transcription.failed"

  /// Parse one server text message. Unknown types map to .ignored (robust
  /// against future server events); non-JSON maps to .invalid.
  public static func parse(_ text: String) -> RealtimeServerEvent {
    guard let data = text.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data),
      let dict = json as? [String: Any],
      let type = dict["type"] as? String
    else {
      return .invalid(message: "Response is not a JSON object")
    }
    switch type {
    case deltaType:
      let itemID = dict["item_id"] as? String ?? ""
      let delta = dict["delta"] as? String ?? ""
      return .delta(itemID: itemID, text: delta)
    case completedType:
      let itemID = dict["item_id"] as? String ?? ""
      let transcript = dict["transcript"] as? String ?? ""
      return .completed(itemID: itemID, transcript: transcript)
    case failedType:
      let itemID = dict["item_id"] as? String ?? ""
      let message = (dict["error"] as? [String: Any])?["message"] as? String
        ?? dict["message"] as? String ?? "transcription failed"
      return .failed(itemID: itemID, message: message)
    case "session.created", "session.updated",
      "transcription_session.created", "transcription_session.updated":
      return .sessionReady
    case "error":
      let message = (dict["error"] as? [String: Any])?["message"] as? String
        ?? dict["message"] as? String ?? "realtime error"
      return .error(message: message)
    default:
      return .ignored(type: type)
    }
  }
}

// MARK: - Transcript accumulator

/// Deterministic transcript state: committed turns plus open delta buffers.
/// The completed transcript for an item is authoritative and REPLACES its
/// pending deltas (never appended after them), so partial updates cannot
/// duplicate committed text.
public struct RealtimeTranscriptAccumulator: Equatable {
  /// Committed transcripts in completion order.
  public var committed: [String]
  /// Open delta buffers by item ID.
  public var pending: [String: String]
  /// Item IDs already completed (late duplicates ignored).
  public var completedIDs: Set<String>

  public init(committed: [String] = [], pending: [String: String] = [:]) {
    self.committed = committed
    self.pending = pending
    self.completedIDs = Set<String>()
  }

  public static func == (lhs: RealtimeTranscriptAccumulator, rhs: RealtimeTranscriptAccumulator) -> Bool {
    lhs.committed == rhs.committed && lhs.pending == rhs.pending
  }

  /// Apply one parsed server event. Returns the live text (committed plus
  /// open partials) for UI preview, or nil when the event carries no text.
  @discardableResult
  public mutating func apply(_ event: RealtimeServerEvent) -> String? {
    switch event {
    case let .delta(itemID, text):
      guard !completedIDs.contains(itemID), !text.isEmpty else { return liveText() }
      pending[itemID, default: ""] += text
      return liveText()
    case let .completed(itemID, transcript):
      guard !completedIDs.contains(itemID) else { return liveText() }
      completedIDs.insert(itemID)
      pending.removeValue(forKey: itemID)
      let clean = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
      if !clean.isEmpty {
        committed.append(clean)
      }
      return liveText()
    case let .failed(itemID, _):
      pending.removeValue(forKey: itemID)
      completedIDs.insert(itemID)
      return liveText()
    case .sessionReady, .error, .ignored, .invalid:
      return nil
    }
  }

  /// Committed text plus open partials (for live UI preview).
  public func liveText() -> String {
    let partials = pending.keys.sorted().compactMap { pending[$0] }.filter { !$0.isEmpty }
    let parts = committed + partials
    guard !parts.isEmpty else { return "" }
    return parts.joined(separator: " ")
  }

  /// Deterministic final transcript after stop/session completion:
  /// committed turns only, whitespace-collapsed.
  public func finalTranscript() -> String {
    let joined = committed.joined(separator: " ")
    return joined.split { $0.isWhitespace }.joined(separator: " ")
  }
}

// MARK: - WebSocket transport (mockable)

/// Minimal realtime WebSocket contract. The URLSession implementation is
/// production; tests inject a mock scripted transport.
public protocol RealtimeWebSocketTransport: AnyObject {
  func connect(url: URL, headers: [String: String]) async throws
  func sendText(_ text: String) async throws
  /// Next server text message; nil means the peer closed the connection.
  func receiveText() async throws -> String?
  func close() async
}

/// Production transport over URLSessionWebSocketTask (macOS 12+).
public final class URLSessionRealtimeTransport: RealtimeWebSocketTransport {
  private var task: URLSessionWebSocketTask?
  private let lock = NSLock()

  public init() {}

  public func connect(url: URL, headers: [String: String]) async throws {
    var request = URLRequest(url: url)
    for (name, value) in headers {
      request.setValue(value, forHTTPHeaderField: name)
    }
    let created = URLSession.shared.webSocketTask(with: request)
    lock.lock()
    task = created
    lock.unlock()
    created.resume()
  }

  public func sendText(_ text: String) async throws {
    guard let current = currentTask() else {
      throw RealtimeSessionError.invalidState("not connected")
    }
    try await current.send(.string(text))
  }

  public func receiveText() async throws -> String? {
    guard let current = currentTask() else { return nil }
    do {
      let message = try await current.receive()
      switch message {
      case let .string(text):
        return text
      case let .data(data):
        return String(data: data, encoding: .utf8)
      @unknown default:
        return nil
      }
    } catch {
      if (error as? URLError)?.code == .cancelled {
        return nil
      }
      throw RealtimeSessionError.network(error.localizedDescription)
    }
  }

  public func close() async {
    currentTask()?.cancel(with: .goingAway, reason: nil)
    lock.lock()
    task = nil
    lock.unlock()
  }

  private func currentTask() -> URLSessionWebSocketTask? {
    lock.lock()
    defer { lock.unlock() }
    return task
  }
}

// MARK: - Session (one per dictation)

/// Stateful realtime transcription session: exactly one per dictation.
/// Thread-safe via NSLock; teardown is idempotent and never blocks the
/// audio tap thread (stream appends from a background task, never from the
/// realtime tap callback directly).
public final class RealtimeTranscriptionSession {
  /// Live preview callback (committed + open partials). Called on the
  /// receive-loop task; handlers must be light (no blocking).
  public var onPartial: ((String) -> Void)?

  private let config: RealtimeSessionConfig
  private let transport: RealtimeWebSocketTransport
  private let lock = NSLock()
  private var state: RealtimeSessionState = .idle
  private var accumulator = RealtimeTranscriptAccumulator()
  private var receiveTask: Task<Void, Never>?
  private var sentSamples = 0
  private var commitSent = false

  /// Sleep hook for timeout waits (tests inject an instant sleeper).
  private let sleeper: (TimeInterval) async -> Void

  public init(
    config: RealtimeSessionConfig,
    transport: RealtimeWebSocketTransport,
    sleeper: ((TimeInterval) async -> Void)? = nil
  ) {
    self.config = config
    self.transport = transport
    // swiftlint:disable:next multiline_arguments
    self.sleeper = sleeper ?? { seconds in
      guard seconds > 0 else { return }
      try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
  }

  /// Current lifecycle state (lock-guarded snapshot).
  public var currentState: RealtimeSessionState {
    lock.lock()
    defer { lock.unlock() }
    return state
  }

  /// Samples successfully handed to the transport (24 kHz domain count).
  public var appendedSampleCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return sentSamples
  }

  /// Open one session: connect, send session.update, start the receive loop.
  /// Exactly one session per dictation; calling start() twice throws.
  public func start() async throws {
    lock.lock()
    guard state == .idle else {
      let current = state
      lock.unlock()
      throw RealtimeSessionError.invalidState("start in \(current)")
    }
    state = .connecting
    lock.unlock()

    guard let url = URL(string: config.urlString) else {
      fail(state: "bad realtime URL")
      throw RealtimeSessionError.invalidState("bad realtime URL")
    }
    do {
      var headers: [String: String] = [:]
      if !config.apiKey.isEmpty {
        headers["Authorization"] = "Bearer \(config.apiKey)"
      }
      headers["OpenAI-Beta"] = "realtime=v1"
      try await transport.connect(url: url, headers: headers)
      try await transport.sendText(RealtimeClientEvent.sessionUpdate(config: config))
    } catch is CancellationError {
      cancelSync()
      throw RealtimeSessionError.cancelled
    } catch {
      fail(state: error.localizedDescription)
      throw RealtimeSessionError.network(error.localizedDescription)
    }
    lock.lock()
    // A concurrent cancel() during connect wins: do not resurrect.
    if state == .cancelled {
      lock.unlock()
      await transport.close()
      throw RealtimeSessionError.cancelled
    }
    state = .ready
    lock.unlock()
    startReceiveLoop()
  }

  /// Stream microphone audio continuously (16 kHz Int16 in; converted to
  /// 24 kHz PCM16). Call from a background task, never from the audio tap
  /// callback directly. No WAV chunks are written.
  public func appendAudio(samples16k: [Int16]) async throws {
    if Task.isCancelled { throw RealtimeSessionError.cancelled }
    lock.lock()
    let current = state
    guard current == .ready || current == .streaming else {
      lock.unlock()
      throw RealtimeSessionError.invalidState("append in \(current)")
    }
    state = .streaming
    lock.unlock()
    let upsampled = RealtimeAudioConverter.upscale16kTo24k(samples16k)
    guard !upsampled.isEmpty else { return }
    for chunk in RealtimeAudioConverter.chunked(upsampled) {
      if Task.isCancelled { throw RealtimeSessionError.cancelled }
      let event = RealtimeClientEvent.appendAudio(
        base64PCM: RealtimeAudioConverter.base64PCM16(chunk))
      do {
        try await transport.sendText(event)
      } catch is CancellationError {
        throw RealtimeSessionError.cancelled
      } catch {
        fail(state: error.localizedDescription)
        throw RealtimeSessionError.network(error.localizedDescription)
      }
      lock.lock()
      sentSamples += chunk.count
      lock.unlock()
    }
  }

  /// Feed one raw server text message into the accumulator. Public for the
  /// receive loop and for mocked-transport integration tests.
  public func processServerMessage(_ text: String) {
    let event = RealtimeServerEvent.parse(text)
    lock.lock()
    switch event {
    case .error(let message):
      state = .failed(message)
      lock.unlock()
      return
    case .invalid:
      lock.unlock()
      return
    default:
      break
    }
    let live = accumulator.apply(event)
    lock.unlock()
    if let live {
      onPartial?(live)
    }
  }

  /// Stop the session deterministically: commit, wait for the final
  /// completion (timeout), close. Returns the deterministic final
  /// transcript (committed turns only).
  public func stop() async throws -> String {
    if Task.isCancelled {
      await cancel()
      throw RealtimeSessionError.cancelled
    }
    lock.lock()
    let current = state
    // A failed session surfaces its provider cause on stop (instead of a
    // generic invalidState) so callers see the real error; the transport
    // still closes deterministically below.
    if case let .failed(message) = current {
      lock.unlock()
      await closeTransport()
      throw RealtimeSessionError.provider(message)
    }
    guard current == .ready || current == .streaming || current == .committing else {
      lock.unlock()
      throw RealtimeSessionError.invalidState("stop in \(current)")
    }
    state = .committing
    commitSent = true
    let deadline = config.timeoutSeconds
    lock.unlock()
    do {
      try await transport.sendText(RealtimeClientEvent.commit())
    } catch is CancellationError {
      await cancel()
      throw RealtimeSessionError.cancelled
    } catch {
      fail(state: error.localizedDescription)
      throw RealtimeSessionError.network(error.localizedDescription)
    }
    // Wait for the committed completion: the accumulator holds the only
    // truth (completed replaces pending, no duplication). Poll with the
    // injected sleeper so tests never wait on real time.
    let started = Date()
    let baseline: Int = committedCount()
    var waited: TimeInterval = 0
    while Date().timeIntervalSince(started) < deadline {
      if Task.isCancelled {
        await cancel()
        throw RealtimeSessionError.cancelled
      }
      // Completion observed when a new committed turn lands, or when the
      // session already carried committed text and the buffer drained.
      if committedCount() > baseline { break }
      if baseline > 0 && pendingCount() == 0 { break }
      await sleeper(0.05)
      waited += 0.05
      // Empty dictation (no audio, no deltas): do not wait the full
      // timeout — one short grace step is enough, then close cleanly.
      if baseline == 0 && pendingCount() == 0 && waited >= 0.2 { break }
      if failedMessage() != nil { break }
    }
    if let message = failedMessage() {
      await closeTransport()
      throw RealtimeSessionError.provider(message)
    }
    if Task.isCancelled {
      await cancel()
      throw RealtimeSessionError.cancelled
    }
    let final = finalText()
    await closeTransport()
    lock.lock()
    if state == .committing {
      state = .closed
    }
    lock.unlock()
    return final
  }

  /// Cancel immediately: drop buffered audio, close the transport,
  /// wake waiters. Idempotent, safe from any state, never throws.
  public func cancel() async {
    cancelSync()
    receiveTask?.cancel()
    await transport.close()
  }

  /// Deterministic final transcript snapshot (committed turns only).
  public func finalText() -> String {
    lock.lock()
    defer { lock.unlock() }
    return accumulator.finalTranscript()
  }

  /// Live preview snapshot (committed + open partials).
  public func livePreview() -> String {
    lock.lock()
    defer { lock.unlock() }
    return accumulator.liveText()
  }

  // MARK: - Private

  private func startReceiveLoop() {
    receiveTask = Task { [weak self] in
      guard let self else { return }
      while !Task.isCancelled {
        do {
          guard let text = try await self.transport.receiveText() else { break }
          self.processServerMessage(text)
        } catch is CancellationError {
          break
        } catch {
          self.fail(state: error.localizedDescription)
          break
        }
        if self.isTerminal() { break }
      }
    }
  }

  private func isTerminal() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    switch state {
    case .closed, .failed, .cancelled:
      return true
    case .idle, .connecting, .ready, .streaming, .committing:
      return false
    }
  }

  private func committedCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return accumulator.committed.count
  }

  private func pendingCount() -> Int {
    lock.lock()
    defer { lock.unlock() }
    return accumulator.pending.count
  }

  private func failedMessage() -> String? {
    lock.lock()
    defer { lock.unlock() }
    if case let .failed(message) = state { return message }
    return nil
  }

  private func fail(state message: String) {
    lock.lock()
    // Terminal states win: never overwrite closed/cancelled with failed.
    switch state {
    case .closed, .cancelled:
      lock.unlock()
      return
    default:
      state = .failed(message)
      lock.unlock()
    }
    receiveTask?.cancel()
  }

  private func cancelSync() {
    lock.lock()
    state = .cancelled
    lock.unlock()
    receiveTask?.cancel()
  }

  private func closeTransport() async {
    receiveTask?.cancel()
    await transport.close()
  }
}
