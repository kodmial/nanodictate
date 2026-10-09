import Foundation

// MARK: - STT request/response efficiency (issue #32)
//
// Memory/network/CPU efficiency for every batch request without changing
// transcription results:
//
// - `STTTimestampRequest`: the single decision point for word-timestamp
//   payloads. Normal single-request transcription sends plain text; word
//   timestamps (`verbose_json` + word granularities) are requested only when
//   the processing mode needs them AND the concrete model profile supports
//   them (capability gating from #22).
// - `STTResponseDecoder`: a response payload is deserialized exactly once
//   into the fields the caller needs (text plus word timestamps). The legacy
//   `ProviderRequestBuilder.extractText` / `extractWords` entry points stay as
//   thin single-parse wrappers so no call path parses the body twice.
// - `MultipartFileUpload`: a streaming/file-backed multipart writer. The
//   audio bytes are streamed to a temporary file (no second full-size body
//   `Data` is materialized), and every retry re-opens a fresh `InputStream`
//   over the same file, so `RetryProvider`/retry semantics stay repeatable
//   and deterministic. The temporary file is removed after the request
//   completes, so no audio is left on disk.
// - `STTRequestMemoryReport`: deterministic request-body accounting for the
//   near-60-second benchmark (audio bytes, body bytes, overhead, strategy and
//   peak-transient estimates).

// MARK: - Word-timestamp request decision

/// Single decision point for timestamp-related request parameters.
///
/// - Normal single-request mode passes `needsWordTimestamps == false` and
///   sends plain transcription (no `response_format`, no granularities).
/// - Chunked/live segment stitching passes `true`; the parameters are then
///   still gated by the concrete model profile: `verbose_json` only when
///   `supportsVerboseJSON`, word granularities only when
///   `supportsWordTimestamps` (Groq accepts `verbose_json` but rejects
///   `timestamp_granularities[]` with HTTP 400, so the two flags stay
///   independent).
public enum STTTimestampRequest {
  public struct Decision: Equatable {
    /// Value for the `response_format` field, or nil when plain text suffices.
    public var responseFormat: String?
    /// Values for the repeated `timestamp_granularities[]` field.
    public var granularities: [String]

    public init(responseFormat: String? = nil, granularities: [String] = []) {
      self.responseFormat = responseFormat
      self.granularities = granularities
    }
  }

  public static func resolve(
    needsWordTimestamps: Bool, capabilities: STTCapabilities
  ) -> Decision {
    guard needsWordTimestamps else {
      return Decision()
    }
    return Decision(
      responseFormat: capabilities.supportsVerboseJSON ? "verbose_json" : nil,
      granularities: capabilities.supportsWordTimestamps ? ["word"] : []
    )
  }
}

// MARK: - Single-parse response decoding

/// Transcript decoded from one STT response payload: final text plus word
/// timestamps (empty when the provider returned none — never an error).
public struct STTTranscript: Equatable {
  public var text: String
  public var words: [TimedWord]

  public init(text: String, words: [TimedWord] = []) {
    self.text = text
    self.words = words
  }
}

/// Decodes an STT response body with exactly one JSON deserialization.
///
/// Error classes and messages match the legacy `extractText` contract:
/// unparsable/empty bodies throw `invalidResponse("Response is not a JSON
/// object")`; a missing transcript throws `invalidResponse("Missing 'text'
/// field")` (flat responses) or `invalidResponse("Missing '<dotted path>'
/// field")` (adapter JSON paths such as Cloudflare `result.text`).
public enum STTResponseDecoder {
  /// Parse once into text plus words.
  public static func decode(body: Data, path: [String]?) throws -> STTTranscript {
    let json = try parseJSON(body)
    return STTTranscript(
      text: try text(from: json, path: path), words: words(from: json, path: path))
  }

  /// The single JSON deserialization shared by every accessor below.
  public static func parseJSON(_ body: Data) throws -> Any {
    guard !body.isEmpty,
      let json = try? JSONSerialization.jsonObject(with: body)
    else {
      throw TranscribeError.invalidResponse("Response is not a JSON object")
    }
    return json
  }

  /// Transcript text from an already-parsed payload (no re-parsing).
  /// `path == nil` reads the flat `text` key (OpenAI-compatible).
  public static func text(from json: Any, path: [String]?) throws -> String {
    guard let path else {
      guard let dict = json as? [String: Any],
        let text = dict["text"] as? String
      else {
        throw TranscribeError.invalidResponse("Missing 'text' field")
      }
      return text
    }
    var current: Any = json
    for segment in path {
      if let dict = current as? [String: Any] {
        guard let next = dict[segment] else {
          throw TranscribeError.invalidResponse("Missing '\(path.joined(separator: "."))' field")
        }
        current = next
      } else if let array = current as? [Any], let index = Int(segment),
        array.indices.contains(index)
      {
        current = array[index]
      } else {
        throw TranscribeError.invalidResponse("Missing '\(path.joined(separator: "."))' field")
      }
    }
    guard let text = current as? String else {
      throw TranscribeError.invalidResponse("Missing '\(path.joined(separator: "."))' field")
    }
    return text
  }

  /// Word timestamps from an already-parsed payload (no re-parsing).
  /// Empty when the provider returned none — never an error. Broken entries
  /// are skipped. `path == nil` reads the top-level `words` array; otherwise
  /// the `words` array next to the transcript text (last path segment
  /// replaced by `words`).
  public static func words(from json: Any, path: [String]?) -> [TimedWord] {
    var wordsValue: Any?
    if let path {
      guard path.count > 1 else { return [] }
      var current: Any = json
      var pathValid = true
      for segment in path.dropLast() {
        if let dict = current as? [String: Any] {
          guard let next = dict[segment] else {
            pathValid = false
            break
          }
          current = next
        } else if let array = current as? [Any], let index = Int(segment),
          array.indices.contains(index)
        {
          current = array[index]
        } else {
          pathValid = false
          break
        }
      }
      wordsValue = pathValid ? (current as? [String: Any])?["words"] : nil
    } else {
      wordsValue = (json as? [String: Any])?["words"]
    }
    guard let items = wordsValue as? [[String: Any]] else { return [] }
    var words: [TimedWord] = []
    for item in items {
      guard let word = (item["word"] as? String) ?? (item["punctuated_word"] as? String),
        let start = (item["start"] as? NSNumber)?.doubleValue,
        let end = (item["end"] as? NSNumber)?.doubleValue
      else {
        continue
      }
      words.append(TimedWord(word: word, start: start, end: end))
    }
    return words
  }
}

// MARK: - Streaming/file-backed multipart upload

/// A multipart body streamed to a temporary file instead of a second
/// full-size `Data`.
///
/// - The file content is byte-identical to the in-memory multipart body for
///   the same parameters (same boundary, same field order).
/// - Retries re-open a fresh stream per attempt (`makeBodyStream`), so a
///   consumed stream never breaks a repeat: retry behavior stays correct and
///   deterministic, matching the `Data`-body semantics.
/// - `cleanup` removes the temporary file; callers remove it after the
///   request (success, failure or cancellation) so no audio stays on disk.
public struct STTFileBackedUpload: Equatable {
  public var fileURL: URL
  public var byteCount: Int
  public var contentType: String

  public init(fileURL: URL, byteCount: Int, contentType: String) {
    self.fileURL = fileURL
    self.byteCount = byteCount
    self.contentType = contentType
  }
}

public enum MultipartFileUpload {
  /// Writes one multipart body to a new temporary file and returns its
  /// location, byte count and enclosing content type.
  ///
  /// Field order and values match `ProviderRequestBuilder.multipartBody`
  /// exactly (file part first, then model/language/languages/prompt/
  /// keywords/response_format/granularities/stable fields, closing
  /// boundary); only small text parts are buffered in memory while the audio
  /// payload is streamed to disk.
  // swiftlint:disable:next function_parameter_count
  public static func write(
    audio: Data,
    filename: String,
    model: String,
    language: String,
    prompt: String?,
    boundary: String,
    languages: [String] = [],
    keywords: [String] = [],
    responseFormat: String? = nil,
    timestampGranularities: [String] = [],
    stable: BatchStableMultipartFields? = nil,
    audioContentType: String = STTUploadFormat.wav.contentType
  ) throws -> STTFileBackedUpload {
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(
      "nanodictate-stt-\(UUID().uuidString).body")
    _ = FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    guard let handle = try? FileHandle(forWritingTo: fileURL) else {
      throw TranscribeError.network("Unable to create upload file")
    }
    defer { try? handle.close() }
    func writeText(_ string: String) throws {
      guard let data = string.data(using: .utf8) else { return }
      try handle.write(contentsOf: data)
    }
    func writeField(name: String, value: String) throws {
      try writeText("--\(boundary)\r\n")
      try writeText("Content-Disposition: form-data; name=\"\(name)\"\r\n")
      try writeText("\r\n")
      try writeText(value)
      try writeText("\r\n")
    }
    do {
      try writeText("--\(boundary)\r\n")
      try writeText("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
      try writeText("Content-Type: \(audioContentType)\r\n")
      try writeText("\r\n")
      try handle.write(contentsOf: audio)
      try writeText("\r\n")
      try writeField(name: "model", value: model)
      if !language.isEmpty {
        try writeField(name: "language", value: language)
      }
      for hint in languages where !hint.isEmpty {
        try writeField(name: "languages[]", value: hint)
      }
      if let prompt, !prompt.isEmpty {
        try writeField(name: "prompt", value: prompt)
      }
      for keyword in keywords where !keyword.isEmpty {
        try writeField(name: "keywords[]", value: keyword)
      }
      if let responseFormat, !responseFormat.isEmpty {
        try writeField(name: "response_format", value: responseFormat)
      }
      for granularity in timestampGranularities {
        try writeField(name: "timestamp_granularities[]", value: granularity)
      }
      if let stable {
        if let temperature = stable.temperature {
          try writeField(
            name: "temperature", value: BatchStableMultipartFields.numberString(temperature))
        }
        if let vadFilter = stable.vadFilter {
          try writeField(name: "vad_filter", value: vadFilter ? "true" : "false")
        }
        if let threshold = stable.noSpeechThreshold {
          try writeField(
            name: "no_speech_threshold",
            value: BatchStableMultipartFields.numberString(threshold))
        }
        if let ratio = stable.compressionRatioThreshold {
          try writeField(
            name: "compression_ratio_threshold",
            value: BatchStableMultipartFields.numberString(ratio))
        }
        if let logprob = stable.logprobThreshold {
          try writeField(
            name: "logprob_threshold", value: BatchStableMultipartFields.numberString(logprob))
        }
      }
      try writeText("--\(boundary)--\r\n")
    } catch {
      try? FileManager.default.removeItem(at: fileURL)
      throw error
    }
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
    return STTFileBackedUpload(
      fileURL: fileURL,
      byteCount: byteCount,
      contentType: "multipart/form-data; boundary=\(boundary)")
  }

  /// A fresh repeatable stream over the uploaded file: one per attempt, so
  /// retries never reuse a consumed stream.
  public static func makeBodyStream(fileURL: URL) -> InputStream? {
    InputStream(fileAtPath: fileURL.path)
  }

  /// Reads the whole file-backed body back (tests and mock transports that
  /// assert on `httpBody` bytes).
  public static func readBody(fileURL: URL) throws -> Data {
    try Data(contentsOf: fileURL)
  }

  /// Removes the temporary upload file. Never throws.
  public static func cleanup(fileURL: URL) {
    try? FileManager.default.removeItem(at: fileURL)
  }
}

// MARK: - Request-body memory accounting

/// Upload strategy of one STT request: in-memory `Data` body or a
/// streaming/file-backed body.
public enum STTUploadStrategy: String, Equatable {
  /// `URLRequest.httpBody`: the whole multipart body is held in memory
  /// alongside the source audio (small requests, mock transports, retries).
  case inMemory
  /// `URLRequest.httpBodyStream` over a temporary file: only the source
  /// audio plus small text parts are held in memory (large requests on the
  /// real network path).
  case fileBacked
}

/// Deterministic request-body accounting for one STT request: audio bytes,
/// body bytes, multipart overhead and peak-transient estimates.
///
/// Peak estimates are deliberately simple and documented: the in-memory path
/// holds the source audio `Data` and the multipart body `Data`
/// simultaneously (`audio + body`); the file-backed path holds the source
/// audio plus small streaming buffers (`audio + 64 KiB`). They measure
/// request-body duplication, not whole-process RSS (see
/// `BenchmarkResources.peakRSSKilobytes` for the latter).
public struct STTRequestMemoryReport: Equatable {
  public var audioBytes: Int
  public var bodyBytes: Int
  public var overheadBytes: Int
  public var strategy: STTUploadStrategy
  /// `bodyBytes / max(1, audioBytes)`: ~1.0 means no meaningful duplication
  /// beyond the multipart framing.
  public var duplicationRatio: Double
  /// Estimated peak transient request-body memory in bytes (see above).
  public var peakTransientBytes: Int

  public init(audioBytes: Int, bodyBytes: Int, strategy: STTUploadStrategy) {
    self.audioBytes = audioBytes
    self.bodyBytes = bodyBytes
    self.overheadBytes = max(0, bodyBytes - audioBytes)
    self.strategy = strategy
    self.duplicationRatio = Double(bodyBytes) / Double(max(1, audioBytes))
    switch strategy {
    case .inMemory:
      self.peakTransientBytes = audioBytes + bodyBytes
    case .fileBacked:
      self.peakTransientBytes = audioBytes + 64 * 1_024
    }
  }

  /// Upper bound of the multipart framing overhead for an estimate before
  /// the body is built (fields, headers, boundaries).
  public static let framingOverheadEstimate = 8 * 1_024
}
