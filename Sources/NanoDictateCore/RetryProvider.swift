import Foundation

// MARK: - RetryProvider

//
// Хранение последнего WAV в ПАМЯТИ (не на диске) + повторное распознавание
// другим провайдером. Два сценария использования:
//   1. Автоfailover: при сетевой/серверной ошибке основного провайдера агент
//      пробует следующих из списка (ключи `providers`/`auto_failover` в конфиге).
//      Ошибки микрофона/записи (НЕ TranscribeError) failover НЕ запускают.
//   2. Ручной retry: `nanodictate retry <provider>` просит агента повторить
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
  /// Lock-backed: при параллельном failover (main.swift transcribeAutomatically)
  /// писать/читать могут разные Task-и одновременно.
  private var _lastFailedProviderID: String?
  public var lastFailedProviderID: String? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _lastFailedProviderID
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      _lastFailedProviderID = newValue
    }
  }

  public init(transcribeFunction: TranscribeFunction? = nil) {
    self.transcribeFunction = transcribeFunction ?? RetryProvider.defaultTranscribe
  }

  /// Дефолтная реализация: Transcriber из полей провайдера.
  /// `transport` в секции провайдера равен "cookie-relay" (legacy-алиасы
  /// канонизируются при парсинге) — включается
  /// cookie-relay-слой. Кэш cookie-relay-провайдеров по baseURL — ОДИН
  /// инстанс на origin (cookie-токен живёт в памяти инстанса): иначе каждый
  /// retry/failover создавал бы новый провайдер без токена и первый же
  /// запрос уходил бы без куки на лишний челлендж-раундтрип.
  /// Значения общие для всех экземпляров RetryProvider.
  private static func defaultTranscribe(
    _ wav: Data,
    _ provider: AppConfig.Provider
  ) async throws -> TranscriptionResult {
    let relay = await Self.sharedCookieRelay(for: provider)
    let transcriber = Transcriber(
      baseURL: provider.baseURL,
      model: provider.model,
      // Дефолт не знает активного провайдера конфига (init вызывается без
      // конфиг-контекста): env-ключ НЕ выдаётся (fail-closed) — провайдер
      // работает собственным api_key/api_key_file либо запрос падает штатно.
      apiKey: resolveAPIKey(for: provider, activeProviderID: nil),
      proxyKey: provider.proxyKey,
      cookieRelayProvider: relay,
      httpProxy: provider.httpProxy,
      proxyUser: provider.proxyUser,
      proxyPassword: provider.proxyPassword,
      adapterID: provider.id
    )
    return try await transcriber.transcribe(wav: wav)
  }

  /// Общий кэш cookie-relay-провайдеров (ключ — baseURL провайдера).
  private static let cookieRelayLock = NSLock()
  private static var cookieRelayByURL: [String: CookieRelayProvider] = [:]

  /// Cookie-relay-провайдер провайдера: переиспользует инстанс из кэша, иначе
  /// создаёт и кладёт в кэш. Синхронный доступ к кэшу — через хелперы
  /// (NSLock не трогаем из async-контекста).
  private static func sharedCookieRelay(for provider: AppConfig.Provider) async
    -> CookieRelayProvider?
  {  // swiftlint:disable:this opening_brace
    guard provider.transport == "cookie-relay" else { return nil }
    if let existing = cachedCookieRelay(provider.baseURL) {
      return existing
    }
    guard let made = CookieRelayProvider.makeForCookieRelay(baseURL: provider.baseURL) else {
      return nil
    }
    storeCookieRelay(provider.baseURL, made)
    return made
  }

  private static func cachedCookieRelay(_ baseURL: String) -> CookieRelayProvider? {
    cookieRelayLock.lock()
    defer { cookieRelayLock.unlock() }
    return cookieRelayByURL[baseURL]
  }

  private static func storeCookieRelay(_ baseURL: String, _ provider: CookieRelayProvider) {
    cookieRelayLock.lock()
    defer { cookieRelayLock.unlock() }
    cookieRelayByURL[baseURL] = provider
  }

  /// Ключ провайдера для ЗАПРОСА. Env-переменная NANODICTATE_API_KEY (высший
  /// приоритет, никогда не пишется в файл) отдаётся ТОЛЬКО активному
  /// провайдеру — тому, чей `id` совпадает с `activeProviderID` (см.
  /// applyEnvAPIKey в Config). Неактивным провайдерам (failover-кандидаты,
  /// retry, роли маршрутизации) env-ключ НЕ утекает: они получают собственный
  /// ключ (api_key из конфига → api_key_file), а без ключа — пустую строку
  /// (запрос падает штатно).
  /// `activeProviderID` — id активной секции из конфига; nil (активный не
  /// задан / legacy-конфиг / нет конфиг-контекста) — env не выдаётся никому
  /// (fail-closed). public — агент переиспользует её в конфиг-зависимой
  /// функции распознавания.
  public static func resolveAPIKey(
    for provider: AppConfig.Provider,
    activeProviderID: String?
  ) -> String {
    // Env-ключ — только активному провайдеру (тот же источник, что
    // applyEnvAPIKey; здесь — на случай, если конфиг читался без env).
    let envKey = ProcessInfo.processInfo.environment["NANODICTATE_API_KEY"]
    if provider.id == activeProviderID, let envKey, !envKey.isEmpty {
      return envKey
    }
    if !provider.apiKey.isEmpty {
      return provider.apiKey
    }
    guard let file = provider.apiKeyFile else { return "" }
    let expanded = (file as NSString).expandingTildeInPath
    guard let content = try? String(contentsOfFile: expanded, encoding: .utf8) else { return "" }
    for line in content.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty || trimmed.hasPrefix("#") {
        continue
      }
      if trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") {
        return String(trimmed.dropFirst().dropLast())
      }
      return trimmed
    }
    return ""
  }

  // MARK: Последняя запись (в памяти, без диска)

  /// Сохранить последний буфер WAV (вызывается из обработчика сэмплов агента).
  public func store(wav: Data) {
    lock.lock()
    defer { lock.unlock() }
    _lastWAV = wav
    _lastWAVCreatedAt = Date()
  }

  /// Последний буфер WAV (nil — ещё не было записи в этой сессии).
  public var lastWAV: Data? {
    lock.lock()
    defer { lock.unlock() }
    return _lastWAV
  }

  /// Время сохранения последней записи (для свежести retry из CLI).
  public var lastWAVCreatedAt: Date? {
    lock.lock()
    defer { lock.unlock() }
    return _lastWAVCreatedAt
  }

  /// Была ли хоть одна запись в этой сессии.
  public var hasLastRecording: Bool {
    lock.lock()
    defer { lock.unlock() }
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

  // MARK: - Параллельный failover (withTaskGroup)

  /// Параллельный failover по кандидатам: все транскрибации запускаются одним
  /// withTaskGroup (независимые STT-запросы), первый успех выигрывает и
  /// отменяет остальных (cancelAll). Семантика (перенесена из NanoDictateAgent
  /// transcribeAutomatically 1:1):
  /// - первый `.success` → `group.cancelAll()` и возврат;
  /// - TranscribeError → запоминается как `lastFailure`, побеждает ПОСЛЕДНИЙ
  ///   завершившийся (исход возвращается как Result и разворачивается после
  ///   withTaskGroup — тело группы не бросает);
  /// - НЕ-TranscribeError (abortError, например ошибка микрофона) → абортит
  ///   группу и пробрасывается независимо от накопленного `lastFailure`;
  /// - пустые кандидаты → `TranscribeError.invalidResponse("failover has no
  ///   candidates")`.
  ///
  /// `lastFailedProviderID` функция НЕ трогает: он ставится вызывающим ДО
  /// группы и сбрасывается на успехе в `retranscribe`/`transcribeWithFailover`.
  /// `Candidate` — минимальный тип, из которого транскрибация достаёт нужные
  /// поля (в проде — `AppConfig.Provider`, в тестах — простой id).
  public static func parallelFailover<Candidate>(
    candidates: [Candidate],
    transcribe: @escaping (Candidate) async throws -> (TranscriptionResult, String)
  ) async throws -> (TranscriptionResult, String) {
    guard !candidates.isEmpty else {
      throw TranscribeError.invalidResponse("failover has no candidates")
    }
    let outcome = await withTaskGroup(
      of: Result<(TranscriptionResult, String), Error>.self,
      returning: Result<(TranscriptionResult, String), Error>.self
    ) { group in
      for candidate in candidates {
        group.addTask {
          do {
            return try await .success(transcribe(candidate))
          } catch {
            return .failure(error)
          }
        }
      }
      var lastFailure: TranscribeError?
      var abortError: Error?
      while let outcome = await group.next() {
        switch outcome {
        case .success(let hit):
          group.cancelAll()
          return .success(hit)
        case .failure(let error):
          if let transcribeError = error as? TranscribeError {
            lastFailure = transcribeError
          } else {
            abortError = error
            group.cancelAll()
            // Не-TranscribeError (микрофон и т.п.): прерываем,
            // остальные результаты группы больше не нужны.
          }
        }
      }
      if let abortError {
        return .failure(abortError)
      }
      if let lastFailure {
        return .failure(lastFailure)
      }
      return .failure(TranscribeError.invalidResponse("failover has no candidates"))
    }
    return try outcome.get()
  }
}
