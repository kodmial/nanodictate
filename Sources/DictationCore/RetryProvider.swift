import Foundation

// MARK: - RetryProvider
//
// Хранение последнего WAV в ПАМЯТИ (не на диске) + повторное распознавание
// другим провайдером. Два сценария использования:
//   1. Автоfailover: при сетевой/серверной ошибке основного провайдера агент
//      пробует следующих из списка (ключи `providers`/`auto_failover` в конфиге).
//      Ошибки микрофона/записи (НЕ TranscribeError) failover НЕ запускают.
//   2. Ручной retry: `dictatorctl retry <provider>` просит агента повторить
//      распознавание последнего WAV выбранным провайдером.
//
// Сама по себе структура потокобезопасна (NSLock); асинхронные вызовы
// транскрибации выполняются вызывающим кодом.

/// Тип функции распознавания одного провайдера.
public typealias TranscribeFunction = (Data, AppConfig.Provider) async throws -> TranscriptionResult

public final class RetryProvider {

    // MARK: Состояние последней записи

    private let lock = NSLock()
    private var _lastWAV: Data?
    private var _lastWAVCreatedAt: Date?

    /// Функция распознавания; по умолчанию — Transcriber, собранный из полей
    /// провайдера (base_url/model/api_key/proxy_key/language/timeout).
    public var transcribeFunction: TranscribeFunction

    /// Провайдер, которым последняя запись уже была распознана (неуспешно) —
    /// исключается из failover-очереди.
    public var lastFailedProviderID: String?

    public init(transcribeFunction: TranscribeFunction? = nil) {
        self.transcribeFunction = transcribeFunction ?? RetryProvider.defaultTranscribe
    }

    /// Дефолтная реализация: Transcriber из полей провайдера.
    private static func defaultTranscribe(
        _ wav: Data,
        _ provider: AppConfig.Provider
    ) async throws -> TranscriptionResult {
        let transcriber = Transcriber(
            baseURL: provider.baseURL,
            model: provider.model,
            apiKey: resolveAPIKey(for: provider),
            proxyKey: provider.proxyKey
        )
        return try await transcriber.transcribe(wav: wav)
    }

    /// Ключ провайдера: явный api_key, либо чтение api_key_file (с раскрытием ~).
    /// public — агент переиспользует её в конфиг-зависимой функции распознавания.
    public static func resolveAPIKey(for provider: AppConfig.Provider) -> String {
        if !provider.apiKey.isEmpty { return provider.apiKey }
        guard let file = provider.apiKeyFile else { return "" }
        let expanded = (file as NSString).expandingTildeInPath
        guard let content = try? String(contentsOfFile: expanded, encoding: .utf8) else { return "" }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if trimmed.count >= 2,
               trimmed.hasPrefix("\""),
               trimmed.hasSuffix("\"") {
                return String(trimmed.dropFirst().dropLast())
            }
            return trimmed
        }
        return ""
    }

    // MARK: Последняя запись (в памяти, без диска)

    /// Сохранить последний буфер WAV (вызывается из обработчика сэмплов агента).
    public func store(wav: Data) {
        lock.lock(); defer { lock.unlock() }
        _lastWAV = wav
        _lastWAVCreatedAt = Date()
    }

    /// Последний буфер WAV (nil — ещё не было записи в этой сессии).
    public var lastWAV: Data? {
        lock.lock(); defer { lock.unlock() }
        return _lastWAV
    }

    /// Время сохранения последней записи (для свежести retry из CLI).
    public var lastWAVCreatedAt: Date? {
        lock.lock(); defer { lock.unlock() }
        return _lastWAVCreatedAt
    }

    /// Была ли хоть одна запись в этой сессии.
    public var hasLastRecording: Bool {
        lock.lock(); defer { lock.unlock() }
        return _lastWAV != nil
    }

    // MARK: Retry одним провайдером

    /// Повторить распознавание последнего WAV указанным провайдером.
    /// Возвращает nil, если последней записи нет.
    public func retranscribe(
        with provider: AppConfig.Provider
    ) async throws -> TranscriptionResult? {
        guard let wav = lastWAV else { return nil }
        let result = try await transcribeFunction(wav, provider)
        lastFailedProviderID = nil
        return result
    }

    // MARK: Failover-цепочка

    /// Распознать WAV с автоматическим failover по `order`.
    /// - `autoFailover == false` → пробуем только первый провайдер из `order`.
    /// - При TranscribeError (сеть/сервер/ответ) → следующий провайдер из
    ///   очереди; провайдер, упавший последним, исключается.
    /// - НЕ-TranscribeError (например, ошибка микрофона) → пробрасывается сразу,
    ///   failover не запускается.
    /// - Возвращает (результат, id успешного провайдера).
    public func transcribeWithFailover(
        wav: Data,
        order: [AppConfig.Provider],
        autoFailover: Bool = false
    ) async throws -> (result: TranscriptionResult, providerID: String) {
        guard !order.isEmpty else {
            throw TranscribeError.invalidResponse("no providers configured for failover")
        }
        var attempts = order
        if let failed = lastFailedProviderID {
            attempts.removeAll { $0.id == failed }
        }
        let candidateCount = autoFailover ? attempts.count : min(1, attempts.count)
        let candidates = Array(attempts.prefix(candidateCount))

        var lastError: TranscribeError?
        for provider in candidates {
            do {
                let result = try await transcribeFunction(wav, provider)
                lastFailedProviderID = nil
                return (result, provider.id)
            } catch let error as TranscribeError {
                lastError = error
                lastFailedProviderID = provider.id
            } catch {
                // Не-TranscribeError (микрофон и т.п.) — failover НЕ запускаем.
                throw error
            }
        }
        throw lastError ?? TranscribeError.invalidResponse("failover failed without a provider error")
    }
}