import Foundation

// swiftlint:disable file_length

// MARK: - STTAdapterID

/// Известные id адаптеров STT-провайдеров. ID выбирается по имени секции
/// `[providers.<id>]` (и, как следствие, по `active_provider`). Неизвестный id
/// отображается на `.openAICompatible` — ручной провайдер со своими
/// base_url/model работает как раньше.
public enum STTAdapterID: String, Equatable {
  case openai
  case groq
  case local
  /// Cloudflare Workers AI Whisper: сырые WAV-байты + `Authorization: Bearer` +
  /// `Content-Type: audio/wav` (multipart эта сторона отвергает: 400 code 8001).
  /// base_url обязателен (модель зашита в URL), дефолтов нет.
  case cloudflare
  /// Неизвестный id: OpenAI-совместимый запрос с собственными base_url/model,
  /// дефолты НЕ подставляются (никакого личного endpoint у нас больше нет).
  case openAICompatible = "openai-compatible"

  public static func from(_ id: String) -> STTAdapterID {
    STTAdapterID(rawValue: id) ?? .openAICompatible
  }

  /// Дефолтный endpoint базы — используется, когда у провайдера base_url пуст
  /// (шаблон `config init` создаёт секции без личных значений).
  public var defaultBaseURL: String {
    switch self {
    case .openai: return "https://api.openai.com/v1/audio/transcriptions"
    case .groq: return "https://api.groq.com/openai/v1/audio/transcriptions"
    case .local: return "http://127.0.0.1:8080/v1/audio/transcriptions"
    // cloudflare/openAICompatible — ручные: base_url обязателен.
    case .cloudflare, .openAICompatible: return ""
    }
  }

  /// Дефолтная модель — когда у провайдера model пуст.
  public var defaultModel: String {
    switch self {
    case .openai: return "whisper-1"
    case .groq: return "whisper-large-v3"
    case .local: return "whisper-1"
    // Cloudflare: модель в URL Workers AI, отдельной дефолтной нет.
    case .cloudflare, .openAICompatible: return ""
    }
  }
}

// MARK: - STTRequestSpec

/// Полная спецификация HTTP-запроса распознавания, которую собирает адаптер
/// (`ProviderRequestBuilder.plan`). Transcriber исполняет её: URLRequest из
/// полей поступает в `send`; транспорт, cookie-relay-слой, preflight сети и
/// ретраи остаются в Transcriber.
public struct STTRequestSpec {
  /// Конечный URL (включая query-параметры). nil — не собрался («Invalid base URL»).
  public var url: URL?
  /// Дополнительные заголовки (Authorization, …) — готовые к установке.
  public var headers: [(String, String)]
  public var body: STTRequestBody
  /// JSON-путь к тексту распознавания в ответе; nil — плоский ключ "text"
  /// (OpenAI-совместимый формат).
  public var transcriptPath: [String]?

  public enum STTRequestBody: Equatable {
    /// OpenAI-совместимый multipart/form-data: file первым, затем поля.
    case multipart(data: Data, contentType: String)
    /// Сырое аудио (cloudflare): тело = WAV целиком, Content-Type задаёт формат.
    case rawAudio(data: Data, contentType: String)
  }

  public init(url: URL?, headers: [(String, String)], body: STTRequestBody, transcriptPath: [String]? = nil) {
    self.url = url
    self.headers = headers
    self.body = body
    self.transcriptPath = transcriptPath
  }

  /// Значение Content-Type для URLRequest («multipart/form-data; boundary=…»,
  /// «audio/wav», …).
  public var contentType: String {
    switch body {
    case let .multipart(_, contentType), let .rawAudio(_, contentType):
      return contentType
    }
  }

  /// Тело запроса (мультипарт или сырое аудио).
  public var bodyData: Data {
    switch body {
    case let .multipart(data, _), let .rawAudio(data, _):
      return data
    }
  }
}

// MARK: - ProviderRequestBuilder

/// Единственный строитель STT-запросов: из полей конфига провайдера собирает
/// `STTRequestSpec`. В HTTP-запрос его превращает Transcriber; транспорт,
/// cookie-relay-слой, preflight сети и ретраи — тоже зона Transcriber.
///
/// baseURL/model перед вызовом `plan` уже разрешены в дефолты адаптера
/// (пусто в конфиге → свой дефолт адаптера). Для cloudflare/openAICompatible
/// дефолтов нет — пустое base_url даёт spec.url == nil, Transcriber отвечает
/// понятной ошибкой «Invalid base URL».
public enum ProviderRequestBuilder {
  /// Имена известных адаптеров в каноническом порядке (справочник CLI).
  public static let knownProviderIDs: [String] =
    ["openai", "groq", "local", "cloudflare"]

  /// «Human name» провайдера для подписи оверлея/логов; неизвестный id —
  /// сам id.
  public static func displayName(for id: String) -> String {
    switch STTAdapterID.from(id) {
    case .openai: return "OpenAI"
    case .groq: return "Groq"
    case .local: return "Local"
    case .cloudflare: return "Cloudflare"
    case .openAICompatible: return id
    }
  }

  /// Собирает спецификацию запроса под известный адаптер.
  ///
  /// - Parameters:
  ///   - adapterID: id провайдера («openai», «groq», …). Неизвестный —
  ///     OpenAI-совместимый формат.
  ///   - baseURL/model/apiKey: поля секции; пустые baseURL/model
  ///     разрешаются в дефолты адаптера здесь же (единая точка).
  ///   - language: код языка (для OpenAI-совместимых — form-поле language).
  ///   - wav/filename/prompt: аудио и опциональный контекст (multipart-поля).
  ///   - batchParams: пакетные параметры устойчивой транскрибации
  ///     (контекстный prompt chaining + temperature + stable-поля). nil —
  ///     пакетный путь не задействован (пошаговая диктовка): поведение
  ///     байт-в-байт прежнее.
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
    // Пустые baseURL/model из конфига (шаблон `config init`) разрешаются
    // в дефолты адаптера. Повторный вызов resolve для уже непустых
    // значений — no-op, так что вызывающий может резолвить заранее.
    let resolvedBaseURL = resolveBaseURL(baseURL, for: adapterID)
    let resolvedModel = resolveModel(model, for: adapterID)
    // Пакетный контекстный prompt (chaining) имеет приоритет над явным;
    // stable-поля — гейтинг по провайдеру (cloudflare = nil).
    let effectivePrompt = batchParams?.prompt ?? prompt
    let stable = BatchStableMultipartFields.stableFields(for: adapterID, params: batchParams)
    switch STTAdapterID.from(adapterID) {
    case .cloudflare:
      return planCloudflare(baseURL: resolvedBaseURL, apiKey: apiKey, wav: wav)
    case .openai, .groq, .local, .openAICompatible:
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

  /// Разрешение пустых полей провайдера в дефолты адаптера.
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

  /// Извлечение текста распознавания из тела ответа.
  /// - `path == nil` — плоский JSON `{"text": "…"}` (OpenAI-совместимый);
  /// - `path == ["result","text"]` — cloudflare (часть JSON-пути адаптера).
  public static func extractText(from body: Data, path: [String]?) throws -> String {
    guard !body.isEmpty,
          let json = try? JSONSerialization.jsonObject(with: body) // swiftlint:disable:this indentation_width
    else {
      throw TranscribeError.invalidResponse("Response is not a JSON object")
    }
    guard let path else {
      guard let dict = json as? [String: Any],
            let text = dict["text"] as? String // swiftlint:disable:this indentation_width
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
      } else if let array = current as? [Any], let index = Int(segment), array.indices.contains(index) {
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

  /// Извлечение word-таймстампов из тела ответа (пустое — провайдер их не
  /// вернул, и это НЕ ошибка: сшивка сегментов деградирует к по-словному diff).
  /// - `path == nil` — OpenAI-совместимый `verbose_json`: массив `words` на
  ///   верхнем уровне (`[{"word":…,"start":…,"end":…}]`).
  /// Битые/частичные записи в массиве пропускаются, битый JSON — пустой
  /// результат.
  public static func extractWords(from body: Data, path: [String]?) -> [TimedWord] {
    guard !body.isEmpty,
          let json = try? JSONSerialization.jsonObject(with: body) // swiftlint:disable:this indentation_width
    else {
      return []
    }
    var wordsValue: Any?
    if let path {
      // Тот же путь, что для текста, но последний сегмент — "words".
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
        } else if let array = current as? [Any], let index = Int(segment), array.indices.contains(index) {
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
            let start = (item["start"] as? NSNumber)?.doubleValue, // swiftlint:disable:this indentation_width
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
  /// OpenAI-совместимый multipart/form-data: file первым, затем model,
  /// language (если не пусто), prompt (если не пусто), опционально
  /// response_format/timestamp_granularities[] (word-таймстампы), затем
  /// stable-поля устойчивой транскрибации (температура/vad_filter/пороги —
  /// только не-nil, после гейтинга), закрывающий boundary. Это ЕДИНЫЙ
  /// источник правды о формате тела — адаптеры openai/groq/local дают
  /// байт-в-байт те же данные (поля таймстампов и stable добавляются только
  /// явными параметрами).
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

    // Field: prompt — контекст уже распознанных сегментов (пошаговая диктовка)
    if let prompt, !prompt.isEmpty {
      appendField("prompt", value: prompt)
    }

    // Field: response_format — просим verbose_json (даёт word-таймстампы)
    if let responseFormat, !responseFormat.isEmpty {
      appendField("response_format", value: responseFormat)
    }

    // Fields: timestamp_granularities[] — включаем word-таймстампы
    for granularity in timestampGranularities {
      appendField("timestamp_granularities[]", value: granularity)
    }

    // Fields: stable — устойчивая транскрибация (порядок полей фиксирован,
    // значения компактны: «0» вместо «0.0», «-1» вместо «-1.0»).
    if let stable {
      if let temperature = stable.temperature {
        appendField("temperature", value: BatchStableMultipartFields.numberString(temperature))
      }
      if let vadFilter = stable.vadFilter {
        appendField("vad_filter", value: vadFilter ? "true" : "false")
      }
      if let threshold = stable.noSpeechThreshold {
        appendField("no_speech_threshold", value: BatchStableMultipartFields.numberString(threshold))
      }
      if let ratio = stable.compressionRatioThreshold {
        appendField("compression_ratio_threshold", value: BatchStableMultipartFields.numberString(ratio))
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

  /// OpenAI / Groq / Local / openAI-compatible: мультипарт + Bearer.
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
    // Word-таймстампы (verbose_json) — только где поддержка гарантирована.
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

  /// Провайдеры, у которых включаем word-таймстампы (verbose_json +
  /// timestamp_granularities[]=word). local/cloudflare не включаем:
  /// whisper.cpp/sherpa поддержку не гарантируют, cloudflare ходит сырым
  /// WAV-телом (см. planCloudflare).
  private static func supportsWordTimestamps(_ adapterID: String) -> Bool {
    switch STTAdapterID.from(adapterID) {
    case .openai, .openAICompatible: return true
    case .groq, .local, .cloudflare: return false
    }
  }

  /// Провайдеры, где просим verbose_json. Groq формально поддерживает
  /// verbose_json (word-таймстампы в ответе), но отвергает параметр
  /// timestamp_granularities[] — HTTP 400. Поэтому granularities отдельно.
  private static func supportsVerboseJSON(_ adapterID: String) -> Bool {
    switch STTAdapterID.from(adapterID) {
    case .openai, .groq, .openAICompatible: return true
    case .local, .cloudflare: return false
    }
  }

  /// Cloudflare Workers AI Whisper: тело — сырые WAV-байты (мультипарт эта
  /// сторона отвергает: 400 code 8001), `Authorization: Bearer <key>`,
  /// `Content-Type: audio/wav`. Модель зашита в base_url
  /// (`/@cf/openai/whisper-large-v3-turbo`). Текст ответа — `result.text`.
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
