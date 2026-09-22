import Foundation

// swiftlint:disable file_length

// MARK: - STTAdapterID

/// Known STT adapter ids, chosen by the `[providers.<id>]` section name
/// (hence `active_provider`). Unknown id maps to `.openAICompatible` — a
/// manual provider with its own base_url/model works as before.
public enum STTAdapterID: String, Equatable {
  case openai
  case groq
  /// Cloudflare Workers AI Whisper: raw WAV bytes + `Authorization: Bearer` +
  /// `Content-Type: audio/wav` (multipart rejected: 400 code 8001).
  /// base_url required (model baked into URL), no defaults.
  case cloudflare
  /// Unknown id: OpenAI-compatible request with own base_url/model, no
  /// defaults injected (no personal endpoint remains).
  case openAICompatible = "openai-compatible"

  public static func from(_ id: String) -> STTAdapterID {
    STTAdapterID(rawValue: id) ?? .openAICompatible
  }

  /// Default endpoint when config base_url empty (`config init` template).
  public var defaultBaseURL: String {
    switch self {
    case .openai: return "https://api.openai.com/v1/audio/transcriptions"
    case .groq: return "https://api.groq.com/openai/v1/audio/transcriptions"
    // cloudflare/openAICompatible — manual: base_url required.
    case .cloudflare, .openAICompatible: return ""
    }
  }

  public var defaultModel: String {
    switch self {
    case .openai: return "whisper-1"
    case .groq: return "whisper-large-v3"
    // Cloudflare: model in Workers AI URL, no separate default.
    case .cloudflare, .openAICompatible: return ""
    }
  }
}

// MARK: - STTRequestSpec

/// Full STT request spec built by the adapter plan; Transcriber executes it
/// (transport, cookie relay, network preflight, retries).
public struct STTRequestSpec {
  /// Final URL (query included). nil = not built ("Invalid base URL").
  public var url: URL?
  public var headers: [(String, String)]
  public var body: STTRequestBody
  /// JSON path to transcript text; nil = flat "text" (OpenAI-compatible).
  public var transcriptPath: [String]?

  public enum STTRequestBody: Equatable {
    /// OpenAI-compatible multipart/form-data: file first, then fields.
    case multipart(data: Data, contentType: String)
    /// Raw audio (cloudflare): body = whole WAV; Content-Type sets format.
    case rawAudio(data: Data, contentType: String)
  }

  public init(
    url: URL?, headers: [(String, String)], body: STTRequestBody, transcriptPath: [String]? = nil
  ) {
    self.url = url
    self.headers = headers
    self.body = body
    self.transcriptPath = transcriptPath
  }

  /// Content-Type for URLRequest ("multipart/form-data; boundary=…", …).
  public var contentType: String {
    switch body {
    case .multipart(_, let contentType), .rawAudio(_, let contentType):
      return contentType
    }
  }

  public var bodyData: Data {
    switch body {
    case .multipart(let data, _), .rawAudio(let data, _):
      return data
    }
  }
}

// MARK: - ProviderRequestBuilder

/// Sole STT request builder: provider config fields → `STTRequestSpec`.
/// Transcriber turns it into HTTP; transport, cookie relay, network
/// preflight and retries live there too.
///
/// baseURL/model resolved to adapter defaults before `plan` (empty config →
/// adapter default). cloudflare/openAICompatible have none — empty base_url
/// yields spec.url == nil, Transcriber answers with "Invalid base URL".
public enum ProviderRequestBuilder {
  /// Known adapter ids in canonical order (CLI reference).
  public static let knownProviderIDs: [String] =
    ["openai", "groq", "cloudflare"]

  /// Human name for overlay/log labels; unknown id — the id itself.
  public static func displayName(for id: String) -> String {
    switch STTAdapterID.from(id) {
    case .openai: return "OpenAI"
    case .groq: return "Groq"
    case .cloudflare: return "Cloudflare"
    case .openAICompatible: return id
    }
  }

  /// Builds the request spec for a known adapter.
  ///
  /// - Parameters:
  ///   - adapterID: provider id ("openai", "groq", ...); unknown →
  ///     OpenAI-compatible format.
  ///   - baseURL/model/apiKey: section fields; empty baseURL/model resolve
  ///     to adapter defaults here (single point).
  ///   - language: language code (OpenAI-compatible: form field `language`).
  ///   - wav/filename/prompt: audio and optional context (multipart fields).
  ///   - batchParams: stable-transcription batch params (contextual prompt
  ///     chaining + temperature + stable fields). nil = batch path unused
  ///     (stepwise dictation): byte-identical behavior.
  // swiftlint:disable:next function_parameter_count
  public static func plan(
    adapterID: String,
    baseURL: String,
    model: String,
    apiKey: String,
    language: String,
    wav: Data,
    filename: String = "audio.wav",
    prompt: String? = nil,
    batchParams: BatchSTTParams? = nil
  ) -> STTRequestSpec {
    // Empty config baseURL/model resolve to adapter defaults; re-resolve of
    // already non-empty values is a no-op — caller may resolve in advance.
    let resolvedBaseURL = resolveBaseURL(baseURL, for: adapterID)
    let resolvedModel = resolveModel(model, for: adapterID)
    // Batch chaining prompt wins over explicit; stable fields gated per
    // provider (cloudflare = nil).
    let effectivePrompt = batchParams?.prompt ?? prompt
    let stable = BatchStableMultipartFields.stableFields(for: adapterID, params: batchParams)
    switch STTAdapterID.from(adapterID) {
    case .cloudflare:
      return planCloudflare(baseURL: resolvedBaseURL, apiKey: apiKey, wav: wav)
    case .openai, .groq, .openAICompatible:
      return planOpenAICompatible(
        adapterID: adapterID,
        baseURL: resolvedBaseURL,
        model: resolvedModel,
        apiKey: apiKey,
        language: language,
        wav: wav,
        filename: filename,
        prompt: effectivePrompt,
        stable: stable
      )
    }
  }

  public static func resolveBaseURL(_ baseURL: String, for adapterID: String) -> String {
    if !baseURL.isEmpty {
      return baseURL
    }
    return STTAdapterID.from(adapterID).defaultBaseURL
  }

  public static func resolveModel(_ model: String, for adapterID: String) -> String {
    if !model.isEmpty {
      return model
    }
    return STTAdapterID.from(adapterID).defaultModel
  }

  /// Transcript text from response body. path == nil → flat {"text": "…"}
  /// (OpenAI-compatible); ["result","text"] → cloudflare JSON path.
  public static func extractText(from body: Data, path: [String]?) throws -> String {
    guard !body.isEmpty,
      let json = try? JSONSerialization.jsonObject(with: body)
    else {
      throw TranscribeError.invalidResponse("Response is not a JSON object")
    }
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
      {  // swiftlint:disable:this opening_brace
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

  /// Word timestamps from response body. Empty — provider returned none,
  /// NOT an error: stitching degrades to word diff. path == nil → top-level
  /// `words` array (OpenAI-compatible verbose_json). Broken entries skipped;
  /// broken JSON yields empty result.
  public static func extractWords(from body: Data, path: [String]?) -> [TimedWord] {
    guard !body.isEmpty,
      let json = try? JSONSerialization.jsonObject(with: body)
    else {
      return []
    }
    var wordsValue: Any?
    if let path {
      // Same path as for text, but the last segment is "words".
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
        {  // swiftlint:disable:this opening_brace
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

// MARK: - Мультипарт-тело и адаптеры

extension ProviderRequestBuilder {
  /// OpenAI-compatible multipart/form-data: file first, then model,
  /// language (if non-empty), prompt (if non-empty), optionally
  /// response_format / timestamp_granularities[] (word timestamps), then
  /// stable-transcription fields (temperature/vad_filter/thresholds — only
  /// non-nil, post-gating), closing boundary. THE single source of truth for
  /// the body format — openai/groq adapters produce byte-identical data
  /// (timestamp and stable fields added only by explicit params).
  // swiftlint:disable:next function_parameter_count
  public static func multipartBody(
    wav: Data,
    filename: String,
    model: String,
    language: String,
    prompt: String?,
    boundary: String,
    responseFormat: String? = nil,
    timestampGranularities: [String] = [],
    stable: BatchStableMultipartFields? = nil
  ) -> Data {
    var body = Data()

    func append(_ string: String) {
      body.append(Data(string.utf8))
    }

    func appendField(_ name: String, value: String) {
      append("--\(boundary)\r\n")
      append("Content-Disposition: form-data; name=\"\(name)\"\r\n")
      append("\r\n")
      append(value)
      append("\r\n")
    }

    // Field: file
    append("--\(boundary)\r\n")
    append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
    append("Content-Type: audio/wav\r\n")
    append("\r\n")
    body.append(wav)
    append("\r\n")

    // Field: model
    appendField("model", value: model)

    // Field: language (only when non-empty — tells Whisper the spoken language)
    if !language.isEmpty {
      appendField("language", value: language)
    }

    // Field: prompt — context of already-recognized segments (stepwise dictation)
    if let prompt, !prompt.isEmpty {
      appendField("prompt", value: prompt)
    }

    // Field: response_format — request verbose_json (yields word timestamps)
    if let responseFormat, !responseFormat.isEmpty {
      appendField("response_format", value: responseFormat)
    }

    // Fields: timestamp_granularities[] — word timestamps for stitching
    for granularity in timestampGranularities {
      appendField("timestamp_granularities[]", value: granularity)
    }

    // Fields: stable — fixed field order, compact values ("0" not "0.0").
    if let stable {
      if let temperature = stable.temperature {
        appendField("temperature", value: BatchStableMultipartFields.numberString(temperature))
      }
      if let vadFilter = stable.vadFilter {
        appendField("vad_filter", value: vadFilter ? "true" : "false")
      }
      if let threshold = stable.noSpeechThreshold {
        appendField(
          "no_speech_threshold", value: BatchStableMultipartFields.numberString(threshold))
      }
      if let ratio = stable.compressionRatioThreshold {
        appendField(
          "compression_ratio_threshold", value: BatchStableMultipartFields.numberString(ratio))
      }
      if let logprob = stable.logprobThreshold {
        appendField("logprob_threshold", value: BatchStableMultipartFields.numberString(logprob))
      }
    }

    // Closing boundary
    append("--\(boundary)--\r\n")

    return body
  }

  // MARK: - Адаптеры

  /// OpenAI / Groq / openai-compatible: multipart + Bearer.
  // swiftlint:disable:next function_parameter_count
  private static func planOpenAICompatible(
    adapterID: String,
    baseURL: String,
    model: String,
    apiKey: String,
    language: String,
    wav: Data,
    filename: String,
    prompt: String?,
    stable: BatchStableMultipartFields? = nil
  ) -> STTRequestSpec {
    let boundary = "Boundary-\(UUID().uuidString)"
    // Word timestamps (verbose_json) — only where support is guaranteed.
    let timestamps = supportsWordTimestamps(adapterID)
    let verbose = supportsVerboseJSON(adapterID)
    let multipart = multipartBody(
      wav: wav,
      filename: filename,
      model: model,
      language: language,
      prompt: prompt,
      boundary: boundary,
      responseFormat: verbose ? "verbose_json" : nil,
      timestampGranularities: timestamps ? ["word"] : [],
      stable: stable
    )
    return STTRequestSpec(
      url: URL(string: baseURL),
      headers: [("Authorization", "Bearer \(apiKey)")],
      body: .multipart(data: multipart, contentType: "multipart/form-data; boundary=\(boundary)")
    )
  }

  /// Providers with word timestamps (verbose_json +
  /// timestamp_granularities[]=word). Not cloudflare: raw WAV body
  /// (see planCloudflare).
  private static func supportsWordTimestamps(_ adapterID: String) -> Bool {
    switch STTAdapterID.from(adapterID) {
    case .openai: return true
    // openAICompatible — произвольный сторонний endpoint: granularity не
    // гарантирована, включаем только у guaranteed-совместимых.
    case .openAICompatible, .groq, .cloudflare: return false
    }
  }

  /// Providers asked for verbose_json. Groq formally supports it (word
  /// timestamps in response) but rejects timestamp_granularities[] — HTTP
  /// 400. So granularities stay separate.
  private static func supportsVerboseJSON(_ adapterID: String) -> Bool {
    switch STTAdapterID.from(adapterID) {
    case .openai, .groq: return true
    // openAICompatible не гарантирует verbose_json — не запрашиваем.
    case .openAICompatible, .cloudflare: return false
    }
  }

  /// Cloudflare Workers AI Whisper: body — raw WAV bytes (multipart
  /// rejected: 400 code 8001), `Authorization: Bearer <key>`,
  /// `Content-Type: audio/wav`. Model baked into base_url
  /// (`/@cf/openai/whisper-large-v3-turbo`). Transcript at `result.text`.
  private static func planCloudflare(
    baseURL: String,
    apiKey: String,
    wav: Data
  ) -> STTRequestSpec {
    STTRequestSpec(
      url: URL(string: baseURL),
      headers: [
        ("Authorization", "Bearer \(apiKey)"),
        // swiftlint:disable:next trailing_comma
        ("Content-Type", "audio/wav"),
      ],
      body: .rawAudio(data: wav, contentType: "audio/wav"),
      transcriptPath: ["result", "text"]
    )
  }
}

// swiftlint:enable file_length
