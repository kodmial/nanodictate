import Foundation
import NanoDictateRustBridge

// MARK: - RustEngine: composition seam between Swift and the shared engine
//
// Migration status (see docs/architecture-rust-engine.md): the shared Rust
// engine (`nanodictate-core`) implements the deterministic product logic,
// the Swift bridge (`NanoDictateRustBridge`) exposes it, and this seam
// connects both to the native macOS layer.
//
// The deterministic subsystems listed below run on the engine by default:
// model/profile resolution and portable STT defaults, transcript parsing,
// failover ordering and deterministic retry/backoff, chunk text joining,
// word diff and overlap tails, review decisions, and offline WAV
// encode/decode. Each entry point fails loudly on engine errors — the
// shipping path never silently falls back to the Swift reference.
// Realtime VAD/input-gain/autostop/segmenter capture, networking
// (URLSession/proxy/cookie transport), and macOS integration stay native.
// The Swift reference implementations are retained until the final parity
// gate in #123 removes them (see Tests/NanoDictateCoreTests/
// RustDeterministicCutoverTests.swift for production-path proof and
// RustParityTests.swift for reference parity).
//
// New code that needs deterministic shared behavior should enter through
// this seam so the cutover is a call-site change, not a redesign.

/// Entry points into the shared Rust engine for native macOS code.
public enum RustEngine {
  /// The linked engine speaks the ABI this bridge was built for.
  /// Checked once at startup; a mismatch is a hard integration error.
  public static func checkAvailable() throws {
    try assertEngineABIVersion()
  }

  /// Creates one dictation session on the shared engine for the active
  /// macOS dictation/session lifecycle. The ABI is checked first so a
  /// link mismatch fails loudly here instead of silently leaving Rust
  /// unused on the shipping path. The caller drives the returned session
  /// with the native macOS events (engineStarted, firstBuffer,
  /// engineFailed, cancelled, stopRequested, transcriptionDone) and
  /// consumes its capture-readiness decision for the ready-cue gate.
  /// - Parameter sessionFactory: handle construction (production default
  ///   builds a live `RustSession`; tests may inject a throwing factory to
  ///   prove the shipping path fails loudly instead of falling back).
  /// - Returns: the live session and its engine generation.
  public static func makeSession(
    sessionFactory: () throws -> RustSession = { try RustSession() }
  ) throws -> (session: RustSession, generation: UInt64) {
    try checkAvailable()
    let session = try sessionFactory()
    let generation = try session.start()
    return (session, generation)
  }

  /// Word-level diff between inserted (`old`) and final (`new`) text.
  /// Engine equivalent of `WordDiff.change` (see `RustWordDiff.change`).
  public static func wordDiff(old: String, new: String) throws -> RustWordDiff {
    try rustWordDiff(old: old, new: new)
  }

  /// Typed word-level diff for the insertion layer: nil when the texts
  /// match word-wise (nothing to change). The change spans and scalar
  /// offsets come from the engine; the tail slices stay native `String`
  /// computation (grapheme clusters remain the insertion layer's job).
  /// Engine failure throws loudly — never a silent Swift fallback.
  public static func wordDiffChange(old: String, new: String) throws -> WordDiff.Change? {
    let diff = try wordDiff(old: old, new: new)
    guard diff.change else { return nil }
    return WordDiff.Change(
      oldText: old,
      newText: new,
      spanOld: diff.spanOld,
      spanNew: diff.spanNew,
      spanStartOld: diff.spanStartOld,
      spanStartNew: diff.spanStartNew
    )
  }

  /// Text tail after the first `wordCount` words (overlap helper).
  /// Engine equivalent of `WordDiff.tailAfterWords` without the empty-tail
  /// clamp (callers trim leading whitespace themselves, as before).
  public static func tailAfterWords(_ wordCount: Int, in text: String) throws -> String {
    let tail = try rustWordTailAfterWords(wordCount, in: text)
    guard !tail.isEmpty else { return "" }
    return tail
  }

  /// Encodes Int16 samples as 16-bit PCM WAV.
  /// Engine equivalent of `WAVEncoder.encode`.
  public static func wavEncode(
    samples: [Int16], sampleRate: UInt32, channels: UInt16
  ) throws -> Data {
    try rustWAVEncode(samples: samples, sampleRate: sampleRate, channels: channels)
  }

  /// Non-throwing WAV encode for call sites that cannot fail the request
  /// path on practically infallible input (bounded session audio always
  /// fits the WAV header). An engine failure traps loudly with the
  /// diagnostic instead of silently falling back to the Swift encoder.
  public static func requireWAVEncode(
    samples: [Int16], sampleRate: Int = 16000, channels: Int = 1
  ) -> Data {
    do {
      return try wavEncode(
        samples: samples, sampleRate: UInt32(sampleRate), channels: UInt16(channels))
    } catch {
      preconditionFailure("Rust engine WAV encode failed: \(error)")
    }
  }

  /// Reads WAV header metadata without copying samples.
  /// Engine equivalent of `WAVDecoder.pcmHeader`.
  public static func wavInfo(_ data: Data) throws -> RustWAVInfo {
    try rustWAVDecodeInfo(data)
  }

  /// Full WAV header for file-backed batch sources (rate/channels/bits
  /// plus the payload offset/size the windowed reader seeks with).
  /// Engine equivalent of `WAVDecoder.pcmHeader` with its offset/size.
  public static func wavHeader(_ data: Data) throws -> WAVPCMHeader {
    let header = try rustWAVHeaderFull(data)
    return WAVPCMHeader(
      sampleRate: Int(header.sampleRate),
      channels: Int(header.channels),
      bitsPerSample: Int(header.bitsPerSample),
      dataOffset: header.dataOffset,
      dataSize: header.dataSize
    )
  }

  /// Decodes a whole WAV file into Int16 samples.
  /// Engine equivalent of `WAVDecoder.decodePCM16`.
  public static func wavDecodeSamples(_ data: Data) throws -> WAVInfo {
    let decoded = try rustWAVDecodeSamples(data)
    return WAVInfo(
      sampleRate: Int(decoded.sampleRate),
      channels: Int(decoded.channels),
      samples: decoded.samples
    )
  }

  /// Encodes one planned segment straight from the source buffer:
  /// overlap tail + body are concatenated in order, then encoded by the
  /// shared engine. Range clamping mirrors `WAVEncoder.encodeSegment`
  /// (index math stays native); the byte encoding is canonical engine
  /// output. Only the segment being sent is touched.
  public static func wavEncodeSegment(
    source: [Int16],
    bodyRange: Range<Int>,
    overlapRange: Range<Int>? = nil,
    sampleRate: Int = 16000,
    channels: Int = 1
  ) throws -> Data {
    let total = source.count
    let bodyLow = max(0, min(total, bodyRange.lowerBound))
    let bodyHigh = max(0, min(total, bodyRange.upperBound))
    var overlapLow = 0
    var overlapHigh = 0
    if let overlap = overlapRange {
      overlapLow = max(0, min(total, overlap.lowerBound))
      overlapHigh = max(0, min(total, overlap.upperBound))
      if overlapLow >= overlapHigh {
        overlapLow = 0
        overlapHigh = 0
      }
    }
    var combined: [Int16] = []
    combined.reserveCapacity((overlapHigh - overlapLow) + max(0, bodyHigh - bodyLow))
    if overlapHigh > overlapLow {
      combined.append(contentsOf: source[overlapLow..<overlapHigh])
    }
    if bodyHigh > bodyLow {
      combined.append(contentsOf: source[bodyLow..<bodyHigh])
    }
    return try wavEncode(
      samples: combined, sampleRate: UInt32(sampleRate), channels: UInt16(channels))
  }

  /// Joins chunk texts with boundary-overlap dedup.
  /// Engine equivalent of `BatchTextJoiner.join`.
  public static func joinChunkTexts(_ texts: [String]) throws -> String {
    try rustTextJoin(texts)
  }

  /// Resolves the model profile for an (adapter id, model) pair as JSON.
  /// Engine equivalent of `STTModelRegistry.resolve`.
  public static func resolveSTTProfile(adapterID: String, model: String) throws -> String {
    try rustSTTResolve(adapterID: adapterID, model: model)
  }

  /// Typed model profile resolved by the shared engine. The engine is the
  /// canonical policy source the host transport consumes; the Swift
  /// registry remains only as the parity reference. Malformed engine
  /// output throws loudly — never a silent Swift fallback.
  public static func sttModelProfile(adapterID: String, model: String) throws -> STTModelProfile {
    try decodeSTTProfile(json: resolveSTTProfile(adapterID: adapterID, model: model))
  }

  /// Non-throwing profile resolution for request-planning call sites whose
  /// signatures cannot fail on practically infallible engine output
  /// (valid UTF-8 input never fails to resolve). An engine failure traps
  /// loudly instead of silently falling back to the Swift registry.
  public static func requireSTTProfile(adapterID: String, model: String) -> STTModelProfile {
    do {
      return try sttModelProfile(adapterID: adapterID, model: model)
    } catch {
      preconditionFailure("Rust engine STT profile resolution failed: \(error)")
    }
  }

  /// Portable configuration default: endpoint for an adapter id (empty for
  /// manual endpoints). Shared with the future Windows host; the macOS
  /// layer never hard-codes a second copy.
  public static func sttDefaultBaseURL(adapterID: String) throws -> String {
    try rustSTTDefaultBaseURL(adapterID: adapterID)
  }

  /// Portable configuration default: model for an adapter id (empty when
  /// the adapter has none and configuration must supply it).
  public static func sttDefaultModel(adapterID: String) throws -> String {
    try rustSTTDefaultModel(adapterID: adapterID)
  }

  /// Non-throwing base-URL default for config-resolution call sites.
  /// Engine failure traps loudly instead of silently using a Swift default.
  public static func requireSTTBaseURL(_ baseURL: String, for adapterID: String) -> String {
    if !baseURL.isEmpty { return baseURL }
    do {
      return try sttDefaultBaseURL(adapterID: adapterID)
    } catch {
      preconditionFailure("Rust engine STT base-URL default failed: \(error)")
    }
  }

  /// Non-throwing model default for config-resolution call sites.
  public static func requireSTTModel(_ model: String, for adapterID: String) -> String {
    if !model.isEmpty { return model }
    do {
      return try sttDefaultModel(adapterID: adapterID)
    } catch {
      preconditionFailure("Rust engine STT model default failed: \(error)")
    }
  }

  /// Parses an STT response body into `{"text":...,"words":[...]}` JSON.
  public static func parseTranscript(body: String, path: String? = nil) throws -> String {
    try rustTranscriptParse(body: body, path: path)
  }

  /// Typed transcript parsed by the shared engine: text plus word
  /// timestamps (empty when the provider returned none — never an error).
  /// Failure classes match the Swift reference exactly
  /// (`invalidResponse` with the same messages); non-UTF8 bodies throw the
  /// same object error the reference throws. Engine failure throws loudly —
  /// never a silent Swift fallback.
  public static func parseTranscriptResponse(
    body: Data, path: [String]?
  ) throws -> (text: String, words: [TimedWord]) {
    guard let bodyString = String(data: body, encoding: .utf8) else {
      throw TranscribeError.invalidResponse("Response is not a JSON object")
    }
    let dotted = path.flatMap { $0.isEmpty ? nil : $0.joined(separator: ".") }
    let json: String
    do {
      json = try parseTranscript(body: bodyString, path: dotted)
    } catch let engineError as RustEngineError {
      // Missing transcript field vs unparsable body: same classes and
      // messages as `ProviderRequestBuilder.extractText`.
      if engineError.message.contains("transcript extract failed") {
        if let path {
          throw TranscribeError.invalidResponse("Missing '\(path.joined(separator: "."))' field")
        }
        throw TranscribeError.invalidResponse("Missing 'text' field")
      }
      throw TranscribeError.invalidResponse("Response is not a JSON object")
    }
    guard let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let text = object["text"] as? String
    else {
      throw TranscribeError.invalidResponse("Response is not a JSON object")
    }
    var words: [TimedWord] = []
    if let items = object["words"] as? [[String: Any]] {
      for item in items {
        guard let word = item["word"] as? String,
          let start = (item["start"] as? NSNumber)?.doubleValue,
          let end = (item["end"] as? NSNumber)?.doubleValue
        else { continue }
        words.append(TimedWord(word: word, start: start, end: end))
      }
    }
    return (text: text, words: words)
  }

  /// Orders failover candidates as id lists.
  /// Engine equivalent of the `RetryProvider` queue policy.
  public static func failoverOrder(
    ids: [String], failedID: String?, autoFailover: Bool
  ) throws -> [String] {
    try rustFailoverOrder(ids: ids, failedID: failedID, autoFailover: autoFailover)
  }

  /// Number of failover candidates the caller may attempt: all with
  /// auto-failover, exactly one without. Deterministic engine policy.
  public static func failoverCandidateCount(orderLen: Int, autoFailover: Bool) -> Int {
    rustFailoverCandidateCount(orderLen: orderLen, autoFailover: autoFailover)
  }

  /// Whether a failed attempt may fall over to the next provider: provider
  /// (`TranscribeError`) failures may, anything else (mic etc.) is
  /// rethrown at once. Deterministic engine classification.
  public static func shouldFailover(error: Error) -> Bool {
    rustShouldFailover(isTranscribeError: error is TranscribeError)
  }

  /// Deterministic exponential backoff base in milliseconds for `attempt`
  /// (0-based), doubling from `baseMs` and capped at `capMs`. The native
  /// layer adds jitter on top; the deterministic growth lives in Rust.
  public static func retryBackoffBaseMs(
    attempt: UInt32, baseMs: UInt64 = 500, capMs: UInt64 = .max
  ) -> UInt64 {
    rustBackoffDelay(attempt: attempt, baseMs: baseMs, capMs: capMs)
  }

  /// Review-before-insert decision: true = insert, false = cancel.
  /// Engine equivalent of the `ReviewGate` confirm decision (I/O stays
  /// native). Engine failure throws loudly — never a silent Swift fallback.
  public static func reviewDecide(line: String?) throws -> Bool {
    try rustReviewDecide(line: line)
  }

  // MARK: - Private decoding

  /// Decodes the engine profile JSON (`nd_stt_resolve`) into the typed
  /// Swift profile. Any shape drift throws loudly so a skewed engine can
  /// never silently degrade request planning.
  static func decodeSTTProfile(json: String) throws -> STTModelProfile {
    guard let data = json.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let adapterID = object["adapter_id"] as? String,
      let model = object["model"] as? String,
      let transportName = object["transport"] as? String,
      let audio = object["audio"] as? [String: Any],
      let sampleRate = (audio["sample_rate"] as? NSNumber)?.intValue,
      let channels = (audio["channels"] as? NSNumber)?.intValue,
      let caps = object["capabilities"] as? [String: Any]
    else {
      throw RustEngineError(code: -1, message: "engine returned malformed profile JSON")
    }
    let transport: STTTransportKind
    switch transportName {
    case "batch_multipart": transport = .batchMultipart
    case "batch_raw_audio": transport = .batchRawAudio
    case "streaming_session": transport = .streamingSession
    default:
      throw RustEngineError(
        code: -1, message: "engine returned unknown transport '\(transportName)'")
    }
    var formats: [STTResponseFormat] = []
    for name in (object["response_formats"] as? [String] ?? []) {
      switch name {
      case "json": formats.append(.json)
      case "verbose_json": formats.append(.verboseJSON)
      default:
        throw RustEngineError(
          code: -1, message: "engine returned unknown response format '\(name)'")
      }
    }
    let languageHint: STTLanguageHintMode
    switch caps["language_hint"] as? String {
    case "none": languageHint = .none
    case "single": languageHint = .single
    case "multi": languageHint = .multi
    default:
      throw RustEngineError(code: -1, message: "engine returned unknown language hint")
    }
    let capabilities = STTCapabilities(
      transport: transport,
      responseFormats: formats,
      supportsVerboseJSON: caps["supports_verbose_json"] as? Bool ?? false,
      supportsWordTimestamps: caps["supports_word_timestamps"] as? Bool ?? false,
      supportsSegmentTimestamps: caps["supports_segment_timestamps"] as? Bool ?? false,
      supportsPrompt: caps["supports_prompt"] as? Bool ?? false,
      supportsTemperature: caps["supports_temperature"] as? Bool ?? false,
      supportsVadFilter: caps["supports_vad_filter"] as? Bool ?? false,
      supportsNoSpeechThreshold: caps["supports_no_speech_threshold"] as? Bool ?? false,
      supportsCompressionRatioThreshold: caps["supports_compression_ratio_threshold"] as? Bool
        ?? false,
      supportsLogprobThreshold: caps["supports_logprob_threshold"] as? Bool ?? false,
      languageHint: languageHint,
      supportsKeywordBiasing: caps["supports_keyword_biasing"] as? Bool ?? false,
      supportsServerVAD: caps["supports_server_vad"] as? Bool ?? false,
      supportsServerChunking: caps["supports_server_chunking"] as? Bool ?? false,
      supportsNoiseReduction: caps["supports_noise_reduction"] as? Bool ?? false
    )
    let audioProfile = STTAudioProfile(
      sampleRate: sampleRate,
      channels: channels,
      uploadFormat: .wav,
      supportedUploadFormats: (audio["supports_flac"] as? Bool ?? false)
        ? [.wav, .flac] : [.wav]
    )
    return STTModelProfile(
      adapterID: adapterID,
      model: model,
      capabilities: capabilities,
      audio: audioProfile,
      transcriptPath: object["transcript_path"] as? [String]
    )
  }
}
