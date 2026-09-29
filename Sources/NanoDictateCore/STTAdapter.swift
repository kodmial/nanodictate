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
    // Recommended high-accuracy batch transcription model (verified against
    // the official transcription guide). Explicit `whisper-1` remains a
    // compatibility path; empty config resolves here.
    case .openai: return "gpt-transcribe"
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
  ///   - language: language code (single-hint profiles: form field `language`;
  ///     multi-hint profiles such as `gpt-transcribe`: mapped to a single
  ///     `languages[]` entry; `none` profiles: never sent).
  ///   - wav/filename/prompt: audio and optional context (multipart fields).
  ///   - needsWordTimestamps: request `verbose_json` + word granularities
  ///     where the concrete profile supports them (chunked/live segment
  ///     overlap stitching). Default false: normal single-request
  ///     push-to-talk sends plain transcription without timestamps.
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
    needsWordTimestamps: Bool = false,
    batchParams: BatchSTTParams? = nil
  ) -> STTRequestSpec {
    // Empty config baseURL/model resolve to adapter defaults; re-resolve of
    // already non-empty values is a no-op — caller may resolve in advance.
    let resolvedBaseURL = resolveBaseURL(baseURL, for: adapterID)
    let resolvedModel = resolveModel(model, for: adapterID)
    // Model-aware profile drives every parameter decision below: a parameter
    // is sent only when the concrete (adapterID, model) profile supports it,
    // never merely because the provider family supports it on another model.
    let profile = STTModelRegistry.resolve(adapterID: adapterID, model: resolvedModel)
    let caps = profile.capabilities
    // Batch chaining prompt wins over explicit; gated by prompt support.
    // Language hint routing: none — never sent; single — `language` field;
    // multi (gpt-transcribe) — `languages[]` array (never both).
    let effectivePrompt = caps.supportsPrompt ? (batchParams?.prompt ?? prompt) : nil
    let effectiveLanguage: String
    let effectiveLanguages: [String]
    switch caps.languageHint {
    case .none:
      effectiveLanguage = ""
      effectiveLanguages = []
    case .single:
      effectiveLanguage = language
      effectiveLanguages = []
    case .multi:
      effectiveLanguage = ""
      effectiveLanguages = language.isEmpty ? [] : [language]
    }
    let stable = BatchStableMultipartFields.stableFields(
      for: adapterID, model: resolvedModel, params: batchParams)
    switch caps.transport {
    case .batchRawAudio:
      return planCloudflare(baseURL: resolvedBaseURL, apiKey: apiKey, wav: wav)
    case .batchMultipart:
      return planOpenAICompatible(
        adapterID: adapterID,
        baseURL: resolvedBaseURL,
        model: resolvedModel,
        apiKey: apiKey,
        language: effectiveLanguage,
        languages: effectiveLanguages,
        wav: wav,
        filename: filename,
        prompt: effectivePrompt,
        needsWordTimestamps: needsWordTimestamps,
        stable: stable,
        capabilities: caps
      )
    case .streamingSession:
      // Reserved for future WebSocket streaming (non-goal): no profile uses
      // it yet; fall back to multipart so the request path stays total.
      return planOpenAICompatible(
        adapterID: adapterID,
        baseURL: resolvedBaseURL,
        model: resolvedModel,
        apiKey: apiKey,
        language: effectiveLanguage,
        languages: effectiveLanguages,
        wav: wav,
        filename: filename,
        prompt: effectivePrompt,
        needsWordTimestamps: needsWordTimestamps,
        stable: stable,
        capabilities: caps
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

  /// Model-aware profile for a concrete (adapterID, model) pair.
  /// Single entry point for request construction, stable-field gating and
  /// audio preparation — callers never branch on provider/model themselves.
  public static func profile(adapterID: String, model: String) -> STTModelProfile {
    let resolvedModel = resolveModel(model, for: adapterID)
    return STTModelRegistry.resolve(adapterID: adapterID, model: resolvedModel)
  }

  /// Model-aware capabilities for a concrete (adapterID, model) pair.
  public static func capabilities(adapterID: String, model: String) -> STTCapabilities {
    profile(adapterID: adapterID, model: model).capabilities
  }

  /// Model-specific audio requirements (sample rate / channels / format).
  /// Audio preparation consults this instead of assuming the common batch
  /// profile; all built-in models currently require 16 kHz mono WAV.
  public static func audioProfile(adapterID: String, model: String) -> STTAudioProfile {
    profile(adapterID: adapterID, model: model).audio
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
  /// language (if non-empty) or `languages[]` entries (multi-hint profiles
  /// such as `gpt-transcribe` — never both), prompt (if non-empty),
  /// optionally response_format / timestamp_granularities[] (word
  /// timestamps, only when explicitly required by the processing mode), then
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
    languages: [String] = [],
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

    // Field: language (only when non-empty — tells Whisper the spoken language).
    // Multi-hint profiles (gpt-transcribe) never receive this field: they
    // get `languages[]` below instead (the API rejects sending both).
    if !language.isEmpty {
      appendField("language", value: language)
    }

    // Fields: languages[] — expected input languages for multi-hint profiles.
    for hint in languages where !hint.isEmpty {
      appendField("languages[]", value: hint)
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
  /// Parameter inclusion is driven by `capabilities` (model-aware profile),
  /// never by the adapter id alone. Word timestamps (`verbose_json` + word
  /// granularities) are sent only when the caller explicitly requires them
  /// for its processing mode AND the concrete profile supports them.
  // swiftlint:disable:next function_parameter_count
  private static func planOpenAICompatible(
    adapterID: String,
    baseURL: String,
    model: String,
    apiKey: String,
    language: String,
    languages: [String] = [],
    wav: Data,
    filename: String,
    prompt: String?,
    needsWordTimestamps: Bool = false,
    stable: BatchStableMultipartFields? = nil,
    capabilities: STTCapabilities? = nil
  ) -> STTRequestSpec {
    let boundary = "Boundary-\(UUID().uuidString)"
    // Word timestamps (verbose_json) — only where the concrete model profile
    // guarantees support AND the processing mode requires them (chunked/live
    // segment overlap stitching). Normal single-request push-to-talk sends
    // plain transcription.
    let caps = capabilities ?? STTModelRegistry.resolve(adapterID: adapterID, model: model).capabilities
    let timestamps = needsWordTimestamps && caps.supportsWordTimestamps
    let verbose = needsWordTimestamps && caps.supportsVerboseJSON
    let multipart = multipartBody(
      wav: wav,
      filename: filename,
      model: model,
      language: language,
      prompt: prompt,
      boundary: boundary,
      languages: languages,
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
