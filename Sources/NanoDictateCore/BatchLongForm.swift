import Foundation

// MARK: - Пакетные практики длинной речи

//
// Long-speech report recommendations, BATCH path only (BatchTranscriber/BatchSegmenter).
// Interactive dictation untouched: chunk chaining, stable transcription params, provider gating.

// MARK: - Контекстный промпт (chaining между чанками)

/// Chain chunks: tail of last successful chunk passes to next as prompt
/// (Groq/OpenAI/selfhosted whisper/GigaAM; Cloudflare no). Capped ~600 chars
/// (~224 ru tokens, Whisper context limit) at word boundary.
public enum BatchPromptChain {
  /// Tail of `text` ≤ `maxLength` chars starting at a whole word.
  /// Empty/whitespace → "". Longer: last maxLength chars; window cutting a
  /// word mid-way drops its partial first word; no spaces — tail as-is.
  public static func tail(_ text: String, maxLength: Int = 600) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    guard trimmed.count > maxLength else { return trimmed }

    let windowStart = trimmed.index(trimmed.endIndex, offsetBy: -maxLength)
    let startsAtWordBoundary =
      windowStart == trimmed.startIndex
      || trimmed[trimmed.index(before: windowStart)] == " "
    guard !startsAtWordBoundary, let firstSpace = trimmed[windowStart...].firstIndex(of: " ") else {
      // Word-boundary window or no spaces — nothing to trim.
      return String(trimmed[windowStart...])
    }
    return String(trimmed[trimmed.index(after: firstSpace)...])
  }
}

// MARK: - Параметры устойчивой транскрибации

/// Stable chunk transcription params (report): temperature 0 mandatory —
/// >0.5 drops context prompt (deterministic decoder keeps chaining);
/// vad_filter=true — server-side VAD trims silence; whisper hallucination
/// thresholds (defaults 0.6/2.4/-1.0), meaningful only for whisper.cpp-class.
/// Actual request fields decided by BatchStableMultipartFields gating.
public struct BatchSTTParams: Equatable {
  /// Context prompt (previous chunk tail); nil — none.
  public var prompt: String?
  /// Decoding temperature; 0 — deterministic, prompt carried.
  public var temperature: Double
  /// Server-side VAD trims silence before recognition.
  public var vadFilter: Bool
  /// <|nospeech|> probability threshold.
  public var noSpeechThreshold: Double
  /// Hallucination cutoff (long repetition).
  public var compressionRatioThreshold: Double
  /// Drops low log-probability segments.
  public var logprobThreshold: Double

  public init(
    prompt: String? = nil,
    temperature: Double = 0,
    vadFilter: Bool = true,
    noSpeechThreshold: Double = 0.6,
    compressionRatioThreshold: Double = 2.4,
    logprobThreshold: Double = -1.0
  ) {
    self.prompt = prompt
    self.temperature = temperature
    self.vadFilter = vadFilter
    self.noSpeechThreshold = noSpeechThreshold
    self.compressionRatioThreshold = compressionRatioThreshold
    self.logprobThreshold = logprobThreshold
  }
}

// MARK: - Мультипарт-поля стабильной транскрибации

/// Stable fields adapter actually adds to multipart after provider gating;
/// nil field = not sent.
public struct BatchStableMultipartFields: Equatable {
  /// Accepted by any multipart provider.
  public var temperature: Double?
  /// Groq only (per spec); not sent to others.
  public var vadFilter: Bool?
  /// Not sent to current providers.
  public var noSpeechThreshold: Double?
  /// Not sent to current providers.
  public var compressionRatioThreshold: Double?
  /// Not sent to current providers.
  public var logprobThreshold: Double?

  public init(
    temperature: Double? = nil,
    vadFilter: Bool? = nil,
    noSpeechThreshold: Double? = nil,
    compressionRatioThreshold: Double? = nil,
    logprobThreshold: Double? = nil
  ) {
    self.temperature = temperature
    self.vadFilter = vadFilter
    self.noSpeechThreshold = noSpeechThreshold
    self.compressionRatioThreshold = compressionRatioThreshold
    self.logprobThreshold = logprobThreshold
  }

  /// Locale-independent multipart number. String(format: "%g") yields "0,6"
  /// in ru_RU — provider rejects. String(Double) always dots; trailing zeros trimmed.
  public static func numberString(_ value: Double) -> String {
    var string = String(value)
    if string.contains(".") {
      while string.hasSuffix("0") {
        string.removeLast()
      }
      if string.hasSuffix(".") {
        string.removeLast()
      }
    }
    return string
  }

  /// Gate stable fields by provider; nil — prompt outside adapter's reach
  /// (raw body / query-only). Support (2026-09):
  /// openai/groq/openAICompatible — prompt + temperature, vad_filter groq only
  /// (groq strict about unknown fields; openai lacks it in Create transcription);
  /// whisper thresholds documented for whisper.cpp-class only — none in current
  /// set, wiring whisper.cpp selfhost = three lines below;
  /// cloudflare — raw WAV body, no multipart at all.
  public static func stableFields(
    for adapterID: String,
    params: BatchSTTParams?
  ) -> BatchStableMultipartFields? {
    guard let params else { return nil }
    switch STTAdapterID.from(adapterID) {
    case .cloudflare:
      return nil
    case .openai, .groq, .openAICompatible:
      return BatchStableMultipartFields(
        temperature: params.temperature,
        vadFilter: (STTAdapterID.from(adapterID) == .groq) ? params.vadFilter : nil,
        noSpeechThreshold: nil,
        compressionRatioThreshold: nil,
        logprobThreshold: nil
      )
    }
  }
}
