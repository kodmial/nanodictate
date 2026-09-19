import Foundation

// MARK: - Пакетные практики длинной речи

//
// Реализация 5 рекомендаций отчёта «Практики длинной речи» в ПАКЕТНОМ пути
// распознавания (BatchTranscriber/BatchSegmenter). Интерактивная диктовка
// (ChunkedPipeline/Transcriber) НЕ затрагивается: здесь живёт только то,
// что специфично для длинных файлов — контекстная склейка (chaining),
// стабильные параметры транскрибации и их гейтинг по провайдерам.

// MARK: - Контекстный промпт (chaining между чанками)

/// Контекстная склейка чанков: хвост распознанного текста предыдущего чанка
/// передаётся следующему чанку как prompt (там, где провайдер prompt
/// принимает — Groq/OpenAI/selfhosted whisper/GigaAM; Cloudflare —
/// нет). Порядок работы: текст последнего УСПЕШНОГО чанка обрезается до
/// ~600 символов (≈ 224 токена русского текста — верхняя полезная граница
/// контекста Whisper по рекомендации отчёта) и нормируется к целым словам.
public enum BatchPromptChain {
  /// Хвост `text` не длиннее `maxLength` символов, начинающийся с целого
  /// слова.
  ///
  /// - Пустой / пробельный текст → "".
  /// - Текст не длиннее maxLength → как есть (после трима пробелов).
  /// - Длиннее: берутся последние maxLength символов; если окно начинается
  ///   ПОСЕРЕДИНЕ слова — неполное первое слово отбрасывается до первого
  ///   пробела; если окно началось точно на границе слова (перед ним
  ///   пробел или начало строки) — слово сохраняется целиком. Когда в окне
  ///   нет пробела вовсе (одно длинное слово) — хвост возвращается как есть.
  public static func tail(_ text: String, maxLength: Int = 600) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }
    guard trimmed.count > maxLength else { return trimmed }

    let windowStart = trimmed.index(trimmed.endIndex, offsetBy: -maxLength)
    let startsAtWordBoundary = windowStart == trimmed.startIndex
      || trimmed[trimmed.index(before: windowStart)] == " "
    guard !startsAtWordBoundary, let firstSpace = trimmed[windowStart...].firstIndex(of: " ") else {
      // Окно целиком на границе слова (неполных слов нет) либо в окне
      // нет пробелов — неполное/полное слово сохранить нельзя или нечего.
      return String(trimmed[windowStart...])
    }
    return String(trimmed[trimmed.index(after: firstSpace)...])
  }
}

// MARK: - Параметры устойчивой транскрибации

/// Стабильные параметры транскрибации чанка (рекомендации отчёта):
/// - температура 0 обязательна: при температуре > 0.5 контекстный prompt НЕ
///   переносится (детерминированный декодер + работающий chaining);
/// - vad_filter=true — отсечение тишины/пауз VAD-детектором на стороне
///   сервера (где поддержан);
/// - no_speech_threshold / compression_ratio_threshold / logprob_threshold —
///   whisper-параметры отсева галлюцинаций (дефолты самого Whisper: 0.6,
///   2.4, -1.0); слать их имеет смысл только серверам whisper.cpp-класса.
///
/// Что реально уходит в запрос, решает гейтинг BatchStableMultipartFields.
public struct BatchSTTParams: Equatable {
  /// Контекстный prompt (хвост предыдущего чанка); nil — без prompt.
  public var prompt: String?
  /// Температура декодирования; 0 — детерминированно + prompt переносится.
  public var temperature: Double
  /// vad_filter: серверный VAD отрезает тишину до распознавания.
  public var vadFilter: Bool
  /// no_speech_threshold: порог вероятности <|nospeech|>.
  public var noSpeechThreshold: Double
  /// compression_ratio_threshold: отсев галлюцинаций (длинный повтор).
  public var compressionRatioThreshold: Double
  /// logprob_threshold: отсев сегментов с низким лог-правдоподобием.
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

/// Набор stable-полей, которые адаптер РЕАЛЬНО добавит в multipart-запрос
/// после гейтинга по провайдеру. nil-поле = поле не шлётся вовсе.
public struct BatchStableMultipartFields: Equatable {
  /// temperature (любой multipart-провайдер принимает).
  public var temperature: Double?
  /// vad_filter (groq — по тексту задачи; остальным не шлём).
  public var vadFilter: Bool?
  /// no_speech_threshold (никому из текущих провайдеров).
  public var noSpeechThreshold: Double?
  /// compression_ratio_threshold (никому из текущих провайдеров).
  public var compressionRatioThreshold: Double?
  /// logprob_threshold (никому из текущих провайдеров).
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

  /// Локально-независимая запись числа для multipart-поля. String(format:
  /// "%g") дал бы «0,6» в ru_RU-локали — провайдер такое поле не примет.
  /// String(Double) всегда пишет точку. Хвостовые нули обрезаются:
  /// «0.0» → «0», «-1.0» → «-1», «0.6» → «0.6», «2.4» → «2.4».
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

  /// Гейтинг stable-полей по провайдеру. nil — контекст/prompt вне прав
  /// адаптера (raw body / query-only). Матрица поддержки (2026-09):
  ///
  /// | адаптер            | prompt | temperature | vad_filter |
  /// |--------------------|--------|-------------|------------|
  /// | openai             | ✓      | ✓           | ✗ (нет в API Create transcription) |
  /// | groq               | ✓      | ✓           | ✓ (задача: поддерживает; groq строгий к неизвестным полям) |
  /// | local/gigaam       | ✓      | ✓           | ✗ (sherpa/GigaAM не гарантируют) |
  /// | cloudflare         | ✗      | ✗           | ✗ (тело = сырые WAV-байты, multipart невозможен) |
  ///
  /// no_speech_threshold / compression_ratio_threshold / logprob_threshold
  /// — параметры whisper-сэмплера (дефолты Whisper 0.6/2.4/-1.0):
  /// документированы только у whisper.cpp-класса серверов, которого в
  /// текущем провайдерском наборе нет. Механизм и дефолты в BatchSTTParams
  /// готовы; для whisper.cpp-селфхоста подключение = три строки ниже.
  public static func stableFields(
    for adapterID: String,
    params: BatchSTTParams?
  ) -> BatchStableMultipartFields? {
    guard let params else { return nil }
    switch STTAdapterID.from(adapterID) {
    case .cloudflare:
      return nil
    case .openai, .groq, .local, .openAICompatible:
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
