import Foundation

// MARK: - STTAdapterID

/// Известные id адаптеров STT-провайдеров. ID выбирается по имени секции
/// `[providers.<id>]` (и, как следствие, по `active_provider`). Неизвестный id
/// отображается на `.openAICompatible` — ручной провайдер со своими
/// base_url/model работает как раньше.
public enum STTAdapterID: String, Equatable {
    case openai
    case groq
    case local
    case deepgram
    case gigaChat = "giga-chat"
    case relay
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
        case .openai:   return "https://api.openai.com/v1/audio/transcriptions"
        case .groq:     return "https://api.groq.com/openai/v1/audio/transcriptions"
        case .local:    return "http://127.0.0.1:8080/v1/audio/transcriptions"
        case .deepgram: return "https://api.deepgram.com/v1/listen"
        case .gigaChat: return "https://gigachat.devices.sberbank.ru/api/v1/audio/transcriptions"
        // relay — личный транспорт, openAICompatible — ручной: base_url обязателен.
        case .relay, .openAICompatible: return ""
        }
    }

    /// Дефолтная модель — когда у провайдера model пуст.
    public var defaultModel: String {
        switch self {
        case .openai:   return "whisper-1"
        case .groq:     return "whisper-large-v3"
        case .local:    return "whisper-1"
        case .deepgram: return "nova-3"
        // GigaChat-модель задаётся в конфиге (GigaAM и т.п.) — устойчивого
        // публичного дефолта нет, пустое значение убирает поле model из запроса.
        case .gigaChat: return ""
        case .relay, .openAICompatible: return ""
        }
    }
}

// MARK: - OAuth step (giga-chat)

/// OAuth-шаг перед основным запросом распознавания. Transcriber исполняет его
/// ДО сборки основного запроса: шлёт `POST url` с заголовками, извлекает токен
/// по `tokenJSONKey` из JSON-ответа и добавляет заголовок
/// `Authorization: Bearer <токен>` к основному запросу.
///
/// Equatable не синтезируется (поле `[(String, String)]`), сравнение шагов нигде
/// не требуется — сверка в тестах по полям.
public struct STTOAuthStep {
    public var url: URL
    public var headers: [(String, String)]
    /// Уже url-encoded тело формы (например `grant_type=client_credentials&scope=...`).
    public var body: String
    /// Ключ в JSON-ответе, где лежит токен.
    public var tokenJSONKey: String

    public init(url: URL, headers: [(String, String)], body: String, tokenJSONKey: String) {
        self.url = url
        self.headers = headers
        self.body = body
        self.tokenJSONKey = tokenJSONKey
    }
}

// MARK: - STTRequestSpec

/// Полная спецификация HTTP-запроса распознавания, которую собирает адаптер
/// (`ProviderRequestBuilder.plan`). Transcriber исполняет её: oauth-шаг (если
/// есть) → URLRequest из полей поступает в `send`; транспорт, Byet-cookie-слой,
/// preflight сети и ретраи остаются в Transcriber.
public struct STTRequestSpec {
    /// Конечный URL (включая query-параметры). nil — не собрался («Invalid base URL»).
    public var url: URL?
    /// Дополнительные заголовки (Authorization, RqUID, …) — готовые к установке.
    public var headers: [(String, String)]
    public var body: STTRequestBody
    /// JSON-путь к тексту распознавания в ответе; nil — плоский ключ "text"
    /// (OpenAI-совместимый формат).
    public var transcriptPath: [String]?
    /// OAuth-шаг перед основным запросом (giga-chat); nil — без OAuth.
    public var oauth: STTOAuthStep?

    public enum STTRequestBody: Equatable {
        /// OpenAI-совместимый multipart/form-data: file первым, затем поля.
        case multipart(data: Data, contentType: String)
        /// Сырое аудио (deepgram): тело = WAV целиком, Content-Type задаёт формат.
        case rawAudio(data: Data, contentType: String)
    }

    public init(url: URL?, headers: [(String, String)], body: STTRequestBody, transcriptPath: [String]? = nil, oauth: STTOAuthStep? = nil) {
        self.url = url
        self.headers = headers
        self.body = body
        self.transcriptPath = transcriptPath
        self.oauth = oauth
    }

    /// Значение Content-Type для URLRequest («multipart/form-data; boundary=…»,
    /// «audio/wav», …).
    public var contentType: String {
        switch body {
        case .multipart(_, let contentType), .rawAudio(_, let contentType):
            return contentType
        }
    }

    /// Тело запроса (мультипарт или сырое аудио).
    public var bodyData: Data {
        switch body {
        case .multipart(let data, _), .rawAudio(let data, _):
            return data
        }
    }
}

// MARK: - ProviderRequestBuilder

/// Единственный строитель STT-запросов: из полей конфига провайдера собирает
/// `STTRequestSpec`. В HTTP-запрос его превращает Transcriber; транспорт,
/// Byet-cookie-слой, preflight сети и ретраи — тоже зона Transcriber.
///
/// baseURL/model перед вызовом `plan` уже разрешены в дефолты адаптера
/// (пусто в конфиге → свой дефолт адаптера). Для relay/openAICompatible
/// дефолтов нет — пустое base_url даёт spec.url == nil, Transcriber отвечает
/// понятной ошибкой «Invalid base URL».
public enum ProviderRequestBuilder {

    /// Имена известных адаптеров в каноническом порядке (справочник CLI).
    public static let knownProviderIDs: [String] =
        ["openai", "groq", "local", "deepgram", "giga-chat", "relay"]

    /// «Human name» провайдера для подписи оверлея/логов; неизвестный id —
    /// сам id.
    public static func displayName(for id: String) -> String {
        switch STTAdapterID.from(id) {
        case .openai:   return "OpenAI"
        case .groq:     return "Groq"
        case .local:    return "Local"
        case .deepgram: return "Deepgram"
        case .gigaChat: return "GigaChat"
        case .relay:    return "Relay"
        case .openAICompatible: return id
        }
    }

    /// Собирает спецификацию запроса под известный адаптер.
    ///
    /// - Parameters:
    ///   - adapterID: id провайдера («openai», «giga-chat», …). Неизвестный —
    ///     OpenAI-совместимый формат.
    ///   - baseURL/model/apiKey/apiSecret: поля секции; пустые baseURL/model
    ///     разрешаются в дефолты адаптера здесь же (единая точка).
    ///   - language: код языка (для OpenAI-совместимых — form-поле language,
    ///     для deepgram — query-параметр language).
    ///   - wav/filename/prompt: аудио и опциональный контекст (multipart-поля).
    public static func plan(
        adapterID: String,
        baseURL: String,
        model: String,
        apiKey: String,
        apiSecret: String = "",
        language: String,
        wav: Data,
        filename: String = "audio.wav",
        prompt: String? = nil
    ) -> STTRequestSpec {
        // Пустые baseURL/model из конфига (шаблон `config init`) разрешаются
        // в дефолты адаптера. Повторный вызов resolve для уже непустых
        // значений — no-op, так что вызывающий может резолвить заранее.
        let resolvedBaseURL = resolveBaseURL(baseURL, for: adapterID)
        let resolvedModel = resolveModel(model, for: adapterID)
        switch STTAdapterID.from(adapterID) {
        case .deepgram:
            return planDeepgram(baseURL: resolvedBaseURL, model: resolvedModel, apiKey: apiKey, language: language, wav: wav)
        case .gigaChat:
            return planGigaChat(baseURL: resolvedBaseURL, model: resolvedModel, apiKey: apiKey, apiSecret: apiSecret, language: language, wav: wav, filename: filename, prompt: prompt)
        case .openai, .groq, .local, .relay, .openAICompatible:
            return planOpenAICompatible(adapterID: adapterID, baseURL: resolvedBaseURL, model: resolvedModel, apiKey: apiKey, language: language, wav: wav, filename: filename, prompt: prompt)
        }
    }

    /// Разрешение пустых полей провайдера в дефолты адаптера.
    public static func resolveBaseURL(_ baseURL: String, for adapterID: String) -> String {
        if !baseURL.isEmpty { return baseURL }
        return STTAdapterID.from(adapterID).defaultBaseURL
    }

    public static func resolveModel(_ model: String, for adapterID: String) -> String {
        if !model.isEmpty { return model }
        return STTAdapterID.from(adapterID).defaultModel
    }

    /// Извлечение текста распознавания из тела ответа.
    /// - `path == nil` — плоский JSON `{"text": "…"}` (OpenAI-совместимый);
    /// - `path == ["results","channels","0","alternatives","0","transcript"]` —
    ///   deepgram; числовые сегменты индексируют массивы.
    public static func extractText(from body: Data, path: [String]?) throws -> String {
        guard body.count > 0,
              let json = try? JSONSerialization.jsonObject(with: body) else {
            throw TranscribeError.invalidResponse("Response is not a JSON object")
        }
        guard let path = path else {
            guard let dict = json as? [String: Any],
                  let text = dict["text"] as? String else {
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
    /// - `path == ["results","channels","0","alternatives","0","transcript"]` —
    ///   deepgram: слова в `results.channels[0].alternatives[0].words`, слово
    ///   из `word` (fallback — `punctuated_word`).
    /// Битые/частичные записи в массиве пропускаются, битый JSON — пустой
    /// результат.
    public static func extractWords(from body: Data, path: [String]?) -> [TimedWord] {
        guard body.count > 0,
              let json = try? JSONSerialization.jsonObject(with: body) else {
            return []
        }
        var wordsValue: Any?
        if let path = path {
            // Тот же путь, что для текста, но последний сегмент — "words".
            guard path.count > 1 else { return [] }
            var current: Any = json
            var ok = true
            for segment in path.dropLast() {
                if let dict = current as? [String: Any] {
                    guard let next = dict[segment] else { ok = false; break }
                    current = next
                } else if let array = current as? [Any], let index = Int(segment), array.indices.contains(index) {
                    current = array[index]
                } else {
                    ok = false
                    break
                }
            }
            wordsValue = ok ? (current as? [String: Any])?["words"] : nil
        } else {
            wordsValue = (json as? [String: Any])?["words"]
        }
        guard let items = wordsValue as? [[String: Any]] else { return [] }
        var words: [TimedWord] = []
        for item in items {
            guard let word = (item["word"] as? String) ?? (item["punctuated_word"] as? String),
                  let start = (item["start"] as? NSNumber)?.doubleValue,
                  let end = (item["end"] as? NSNumber)?.doubleValue else {
                continue
            }
            words.append(TimedWord(word: word, start: start, end: end))
        }
        return words
    }

    /// OpenAI-совместимый multipart/form-data: file первым, затем model,
    /// language (если не пусто), prompt (если не пусто), опционально
    /// response_format/timestamp_granularities[] (word-таймстампы), закрывающий
    /// boundary. Это ЕДИНЫЙ источник правды о формате тела — legacy-путь
    /// Transcriber (adapterID == nil) и адаптеры openai/groq/local/relay дают
    /// байт-в-байт те же данные (поля таймстампов добавляются только явными
    /// параметрами).
    public static func multipartBody(wav: Data, filename: String, model: String, language: String, prompt: String?, boundary: String,
                                     responseFormat: String? = nil, timestampGranularities: [String] = []) -> Data {
        var body = Data()

        func append(_ string: String) {
            body.append(Data(string.utf8))
        }

        // Field: file
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
        append("Content-Type: audio/wav\r\n")
        append("\r\n")
        body.append(wav)
        append("\r\n")

        // Field: model
        append("--\(boundary)\r\n")
        append("Content-Disposition: form-data; name=\"model\"\r\n")
        append("\r\n")
        append(model)
        append("\r\n")

        // Field: language (only when non-empty — tells Whisper the spoken language)
        if !language.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"language\"\r\n")
            append("\r\n")
            append(language)
            append("\r\n")
        }

        // Field: prompt — контекст уже распознанных сегментов (пошаговая диктовка)
        if let prompt = prompt, !prompt.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"prompt\"\r\n")
            append("\r\n")
            append(prompt)
            append("\r\n")
        }

        // Field: response_format — просим verbose_json (даёт word-таймстампы)
        if let responseFormat = responseFormat, !responseFormat.isEmpty {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"response_format\"\r\n")
            append("\r\n")
            append(responseFormat)
            append("\r\n")
        }

        // Fields: timestamp_granularities[] — включаем word-таймстампы
        for granularity in timestampGranularities {
            append("--\(boundary)\r\n")
            append("Content-Disposition: form-data; name=\"timestamp_granularities[]\"\r\n")
            append("\r\n")
            append(granularity)
            append("\r\n")
        }

        // Closing boundary
        append("--\(boundary)--\r\n")

        return body
    }

    // MARK: - Адаптеры

    /// OpenAI / Groq / Local / Relay / openAI-compatible: мультипарт + Bearer.
    private static func planOpenAICompatible(
        adapterID: String,
        baseURL: String,
        model: String,
        apiKey: String,
        language: String,
        wav: Data,
        filename: String,
        prompt: String?
    ) -> STTRequestSpec {
        let boundary = "Boundary-\(UUID().uuidString)"
        // Word-таймстампы (verbose_json) — только где поддержка гарантирована.
        let timestamps = supportsWordTimestamps(adapterID)
        let multipart = multipartBody(
            wav: wav, filename: filename, model: model, language: language, prompt: prompt, boundary: boundary,
            responseFormat: timestamps ? "verbose_json" : nil,
            timestampGranularities: timestamps ? ["word"] : []
        )
        return STTRequestSpec(
            url: URL(string: baseURL),
            headers: [("Authorization", "Bearer \(apiKey)")],
            body: .multipart(data: multipart, contentType: "multipart/form-data; boundary=\(boundary)")
        )
    }

    /// Провайдеры, у которых включаем word-таймстампы (verbose_json +
    /// timestamp_granularities[]=word). local/giga-chat/relay не включаем:
    /// whisper.cpp/sherpa/GigaAM поддержку не гарантируют, личный relay
    /// консервативен (пусть вернёт базовый текст). deepgram ходит своим
    /// query-параметром `words=true` (см. planDeepgram).
    private static func supportsWordTimestamps(_ adapterID: String) -> Bool {
        switch STTAdapterID.from(adapterID) {
        case .openai, .groq, .openAICompatible: return true
        case .local, .deepgram, .gigaChat, .relay: return false
        }
    }

    /// Deepgram (проверено по докам): `Authorization: Token <key>`, тело — сырой
    /// WAV c `Content-Type: audio/wav`, параметры в query (model/language/
    /// smart_format). Текст ответа — `results.channels[0].alternatives[0].transcript`.
    private static func planDeepgram(
        baseURL: String,
        model: String,
        apiKey: String,
        language: String,
        wav: Data
    ) -> STTRequestSpec {
        guard var components = URLComponents(string: baseURL) else {
            return STTRequestSpec(url: nil, headers: [], body: .rawAudio(data: wav, contentType: "audio/wav"))
        }
        var items = components.queryItems ?? []
        items.append(URLQueryItem(name: "model", value: model))
        if !language.isEmpty {
            items.append(URLQueryItem(name: "language", value: language))
        }
        items.append(URLQueryItem(name: "smart_format", value: "true"))
        // Word-таймстампы native: `words=true` (временнáя сшивка сегментов).
        items.append(URLQueryItem(name: "words", value: "true"))
        components.queryItems = items
        return STTRequestSpec(
            url: components.url,
            headers: [
                ("Authorization", "Token \(apiKey)"),
                ("Content-Type", "audio/wav"),
            ],
            body: .rawAudio(data: wav, contentType: "audio/wav"),
            transcriptPath: ["results", "channels", "0", "alternatives", "0", "transcript"]
        )
    }

    /// GigaChat: OAuth (client_credentials) → второй запрос с Bearer-токеном.
    /// OAuth: POST https://ngw.devices.sberbank.ru:9443/api/v2/oauth,
    /// `Authorization: Basic base64(client_id:client_secret)`, заголовок RqUID
    /// (uuid4), тело `grant_type=client_credentials&scope=GIGACHAT_API_PERS`,
    /// токен в `access_token`. Основной запрос — OpenAI-совместимый мультипарт
    /// с `RqUID` и `Authorization: Bearer <токен>`.
    private static func planGigaChat(
        baseURL: String,
        model: String,
        apiKey: String,
        apiSecret: String,
        language: String,
        wav: Data,
        filename: String,
        prompt: String?
    ) -> STTRequestSpec {
        let rqUID = UUID().uuidString.uppercased()
        let basic = Data("\(apiKey):\(apiSecret)".utf8).base64EncodedString()
        let boundary = "Boundary-\(UUID().uuidString)"
        let multipart = multipartBody(wav: wav, filename: filename, model: model, language: language, prompt: prompt, boundary: boundary)
        return STTRequestSpec(
            url: URL(string: baseURL),
            headers: [("RqUID", rqUID)],
            body: .multipart(data: multipart, contentType: "multipart/form-data; boundary=\(boundary)"),
            oauth: STTOAuthStep(
                url: URL(string: "https://ngw.devices.sberbank.ru:9443/api/v2/oauth")!,
                headers: [
                    ("Authorization", "Basic \(basic)"),
                    ("RqUID", rqUID),
                    ("Content-Type", "application/x-www-form-urlencoded"),
                ],
                body: "grant_type=client_credentials&scope=GIGACHAT_API_PERS",
                tokenJSONKey: "access_token"
            )
        )
    }
}