import Foundation
import Network

// MARK: - TranscriptionResult

public struct TranscriptionResult {
    public let text: String
    public let rawData: Data // raw API response (JSON as-is)

    public init(text: String, rawData: Data) {
        self.text = text
        self.rawData = rawData
    }
}

// MARK: - TranscribeError

public enum TranscribeError: Error, Equatable {
    case network(String)
    case http(Int, String) // HTTP code + body text (truncated to ~500 characters)
    case invalidResponse(String) // not JSON or missing "text" field
}

// MARK: - Сетевая доступность (preflight)

/// Быстрая проверка наличия сети перед STT-запросом через Network framework.
///
/// NWPathMonitor создаётся на ОДИН асинхронный замер текущего состояния и сразу
/// отменяется — постоянного слушателя держать не нужно. Проверяется ОБЩАЯ
/// связность, а не наличие локального интерфейса: STT уходит на внешний API
/// (провайдер через Render-форвардер или GigaAM). Случай «роутер есть, интернета
/// нет» этот замер не видит — его добивает жёсткий сетевой таймаут запроса
/// (`Transcriber.networkRequestTimeout`).
public enum NetworkReachability {

    /// Упрощённый статус пути для чистой логики (из NWPath.status).
    public enum PathStatus {
        case satisfied
        case requiresConnection
        case unsatisfied
    }

    /// Чистое решение «есть ли общий доступ в сеть» — тестируется без реальной сети.
    /// - `unsatisfied` — маршрута нет вовсе → интернета нет.
    /// - `requiresConnection` — маршрут есть, но по требованию (VPN/PPP) →
    ///   пробуем запрос, жёсткий таймаут подстрахует.
    /// - `satisfied` — маршрут есть; интернет достижим, только если в маршруте
    ///   есть не-loopback интерфейс (иначе это лишь локальная петля, до внешнего
    ///   API не достучаться).
    public static func isReachable(status: PathStatus, possibleExternalRoute: Bool) -> Bool {
        switch status {
        case .unsatisfied:
            return false
        case .requiresConnection:
            return true
        case .satisfied:
            return possibleExternalRoute
        }
    }

    /// Асинхронный замер текущего состояния сети: один NWPathMonitor, первое
    /// обновление пути, немедленная отмена.
    public static func isInternetReachable() async -> Bool {
        guard let snapshot = await currentPathSnapshot() else {
            // Monitor не ответил за отведённое время — не блокируем диктовку:
            // оптимистично считаем сеть доступной, жёсткий таймаут подстрахует.
            return true
        }
        return isReachable(status: snapshot.status, possibleExternalRoute: snapshot.possibleExternalRoute)
    }

    // MARK: - NWPath

    private struct PathSnapshot {
        let status: PathStatus
        let possibleExternalRoute: Bool
    }

    /// Ждёт первый (текущий) путь от NWPathMonitor; максимум 2 секунды — после
    /// этого возвращает nil, чтобы диктовка не зависла на самом preflight.
    private static func currentPathSnapshot() async -> PathSnapshot? {
        let monitor = NWPathMonitor()
        return await withCheckedContinuation { continuation in
            let lock = NSLock()
            var finished = false
            let resume: (PathSnapshot?) -> Void = { value in
                lock.lock()
                guard !finished else { lock.unlock(); return }
                finished = true
                lock.unlock()
                // Обнуляем handler ДО cancel: иначе монитор держится замыканием
                // (а то — continuation-ом и lock-ом) и не освобождается. Оба пути
                // (первый путь и 2-секундный фоллбэк) приходят только сюда,
                // а finished гарантирует ровно один вызов — nil+cancel один раз.
                monitor.pathUpdateHandler = nil
                monitor.cancel()
                continuation.resume(returning: value)
            }
            monitor.pathUpdateHandler = { path in
                resume(snapshot(path: path))
            }
            monitor.start(queue: DispatchQueue(label: "dictation.network-monitor", qos: .utility))
            // Фоллбэк: первый путь обязан прийти быстро; если NWPathMonitor молчит —
            // не держим диктовку, возвращаем nil (оптимистично, таймаут подстрахует).
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
                resume(nil)
            }
        }
    }

    private static func snapshot(path: NWPath) -> PathSnapshot {
        let status: PathStatus
        switch path.status {
        case .satisfied:
            status = .satisfied
        case .requiresConnection:
            status = .requiresConnection
        default:
            status = .unsatisfied
        }
        let interfaces = path.availableInterfaces
        // Пустой список интерфейсов — «неизвестно»: оптимистично считаем внешний
        // маршрут возможным (пусть запрос попробует, таймаут решит).
        let possibleExternalRoute = interfaces.isEmpty || interfaces.contains { $0.type != .loopback }
        return PathSnapshot(status: status, possibleExternalRoute: possibleExternalRoute)
    }
}

// MARK: - HTTPTransport

public protocol HTTPTransport: AnyObject {
    /// Send a request; return the response (status + body).
    /// The default implementation is URLSession.
    func send(request: URLRequest) async throws -> (status: Int, body: Data)
}

// MARK: - Transcriber

public final class Transcriber {

    // MARK: - Константы

    /// Жёсткий сетевой таймаут HTTP-запроса STT (сек), ~15–20 с. Отдельная
    /// константа от конфигурационного `timeout_seconds` (Transcriber.timeout):
    /// конфиг может только ОГРАНИЧИТЬ его меньшим значением, но не увеличить —
    /// иначе диктовка снова будет висеть до 120 с. Таймаут терминальный (без
    /// ретрая), поэтому фаза «обработка» в оверлее живёт не дольше таймаута
    /// + небольшой запас.
    public static let networkRequestTimeout: TimeInterval = 20

    /// Каноническое сообщение «нет интернета» — на него опирается маппинг
    /// оверлея `OverlayErrorText` и тесты.
    public static let noInternetMessage = "Нет интернета"

    /// Каноническое сообщение «таймаут STT» — на него опирается маппинг
    /// оверлея `OverlayErrorText` и тесты.
    public static let sttTimeoutMessage = "Таймаут STT"

    private let baseURL: String
    private let model: String
    private let apiKey: String
    private let apiSecret: String
    private let proxyKey: String
    private let language: String
    /// Таймаут из конфига (`timeout_seconds`); фактический таймаут запроса —
    /// `min(timeout, networkRequestTimeout)`.
    private let timeout: TimeInterval
    private let logLevel: String
    private let transport: HTTPTransport?
    /// Preflight сети перед отправкой: true — сеть доступна. По умолчанию
    /// реальный замер через NetworkReachability; тесты инъецируют мок.
    private let networkChecker: () async -> Bool
    /// Byet-cookie-слой (transport == "relay"/legacy "infinityfree"): вычисляемая
    /// `__test`-кука в памяти + единый Chrome UA. nil — cookie-логики нет,
    /// поведение как раньше.
    private let byetCookieProvider: ByetCookieProvider?
    /// ID адаптера запроса («openai», «groq», «deepgram», «giga-chat», …).
    /// nil — legacy-путь: OpenAI-совместимый мультипарт ровно как раньше
    /// (byte-identical запросы, тесты не меняются).
    private let adapterID: String?

    public init(
        baseURL: String,
        model: String,
        apiKey: String,
        proxyKey: String = "",
        language: String = "ru",
        timeout: TimeInterval = 120,
        logLevel: String = "info",
        transport: HTTPTransport? = nil,
        networkChecker: (() async -> Bool)? = nil,
        byetCookieProvider: ByetCookieProvider? = nil,
        apiSecret: String = "",
        adapterID: String? = nil
    ) {
        if let adapterID = adapterID, !adapterID.isEmpty {
            // Адаптер известного провайдера: пустые baseURL/model из конфига
            // (шаблон `config init`) разрешаются в дефолты адаптера.
            let resolvedBaseURL = ProviderRequestBuilder.resolveBaseURL(baseURL, for: adapterID)
            let resolvedModel = ProviderRequestBuilder.resolveModel(model, for: adapterID)
            self.baseURL = resolvedBaseURL
            self.model = resolvedModel
        } else {
            self.baseURL = baseURL
            self.model = model
        }
        self.apiKey = apiKey
        self.apiSecret = apiSecret
        self.proxyKey = proxyKey
        self.language = language
        self.timeout = timeout
        self.logLevel = logLevel
        self.transport = transport
        self.networkChecker = networkChecker ?? { await NetworkReachability.isInternetReachable() }
        self.byetCookieProvider = byetCookieProvider
        self.adapterID = adapterID
    }

    /// Transcribe WAV audio via a multipart/form-data POST to the transcription endpoint.
    /// On network failure, retries once (2 attempts total). HTTP and invalid-response
    /// errors are not retried.
    /// - Parameter prompt: необязательный контекст для Whisper-совместимых API
    ///   (поле `prompt` form-data): текст уже распознанных сегментов при пошаговой
    ///   диктовке. По умолчанию nil — старый путь (одного запроса) не меняется.
    public func transcribe(wav: Data, filename: String = "audio.wav", prompt: String? = nil) async throws -> TranscriptionResult {
        if logLevel.lowercased() == "debug" {
            // URL/модель/размер — без api_key/proxy_key и заголовков.
            Logger.log(String(
                format: "STT send: url=%@ model=%@ language=%@ wavBytes=%d",
                baseURL, model, language.isEmpty ? "-" : language, wav.count
            ), level: "debug")
        }

        // Адаптерный путь (известный провайдер): спецификацию запроса строит
        // ProviderRequestBuilder, OAuth (giga-chat) исполняется до основного запроса.
        if let adapterID = adapterID, !adapterID.isEmpty {
            return try await transcribeViaAdapter(adapterID: adapterID, wav: wav, filename: filename, prompt: prompt)
        }

        // Legacy-путь (adapterID == nil): byte-identical поведение, что было
        // всегда — мультипарт, Bearer, Byet-UA/кука, таймаут, ретраи.
        guard let url = URL(string: baseURL) else {
            Logger.log("STT error: invalid base URL", level: "error")
            throw TranscribeError.network("Invalid base URL")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        let body = ProviderRequestBuilder.multipartBody(wav: wav, filename: filename, model: model, language: language, prompt: prompt, boundary: boundary)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if !proxyKey.isEmpty {
            request.setValue(proxyKey, forHTTPHeaderField: "X-Proxy-Key")
        }
        await applyByetHeaders(to: &request)
        request.timeoutInterval = min(timeout, Self.networkRequestTimeout)

        return try await sendWithRetry(
            request: request,
            transcriptPath: nil,
            wav: wav,
            filename: filename,
            prompt: prompt,
            skipPreflight: false
        )
    }

    // MARK: - Адаптерный путь

    private func transcribeViaAdapter(adapterID: String, wav: Data, filename: String, prompt: String?) async throws -> TranscriptionResult {
        // Preflight ДО OAuth: без сети не тратим запрос на заведомо мёртвый OAuth.
        if !(await networkChecker()) {
            Logger.log("STT not sent: no internet (preflight)", level: "error")
            throw TranscribeError.network(Self.noInternetMessage)
        }

        let spec = ProviderRequestBuilder.plan(
            adapterID: adapterID,
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            apiSecret: apiSecret,
            language: language,
            wav: wav,
            filename: filename,
            prompt: prompt
        )
        guard let url = spec.url else {
            Logger.log("STT error: invalid base URL", level: "error")
            throw TranscribeError.network("Invalid base URL")
        }

        var headers = spec.headers
        if let oauth = spec.oauth {
            guard !apiSecret.isEmpty else {
                Logger.log("STT error: giga-chat требует api_secret (client_secret)", level: "error")
                throw TranscribeError.network("giga-chat: не задан api_secret (client_secret провайдера)")
            }
            headers.append(("Authorization", try await performOAuth(oauth)))
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = spec.bodyData
        request.setValue(spec.contentType, forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        if !proxyKey.isEmpty {
            request.setValue(proxyKey, forHTTPHeaderField: "X-Proxy-Key")
        }
        await applyByetHeaders(to: &request)
        request.timeoutInterval = min(timeout, Self.networkRequestTimeout)

        return try await sendWithRetry(
            request: request,
            transcriptPath: spec.transcriptPath,
            wav: wav,
            filename: filename,
            prompt: prompt,
            skipPreflight: true
        )
    }

    /// OAuth-шаг (giga-chat): POST на oauth.url c заголовками из спецификации,
    /// извлекает токен по `tokenJSONKey`. Токен вставляется в основной запрос
    /// заголовком `Authorization: Bearer <токен>` (вызывающий код).
    private func performOAuth(_ oauth: STTOAuthStep) async throws -> String {
        var request = URLRequest(url: oauth.url)
        request.httpMethod = "POST"
        request.httpBody = Data(oauth.body.utf8)
        for (name, value) in oauth.headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.timeoutInterval = min(timeout, Self.networkRequestTimeout)

        let response: (status: Int, body: Data)
        do {
            response = try await send(request: request)
        } catch is CancellationError {
            throw TranscribeError.network("Request cancelled")
        } catch let error as URLError where error.code == .cancelled {
            throw TranscribeError.network("Request cancelled")
        } catch {
            // OAuth вне retry-цикла: транспортный сбой здесь ≈ «нет интернета»
            // (preflight уже прошёл, но сеть могла отвалиться за миллисекунды).
            Logger.log("STT OAuth network error: \(error.localizedDescription)", level: "error")
            throw TranscribeError.network(Self.noInternetMessage)
        }
        guard (200...299).contains(response.status) else {
            let text = String(data: response.body, encoding: .utf8) ?? ""
            throw TranscribeError.http(response.status, String(text.prefix(500)))
        }
        guard let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let token = json[oauth.tokenJSONKey] as? String, !token.isEmpty else {
            throw TranscribeError.invalidResponse("OAuth: отсутствует '\(oauth.tokenJSONKey)' в ответе")
        }
        return token
    }

    // MARK: - Общий цикл отправки (legacy и адаптерный пути)

    /// Byet-cookie-слой (transport == "relay"/legacy "infinityfree"): единый
    /// браузерный UA + cookie-заголовок. `ensureFresh()` неблокирующий: свежий
    /// токен (< 120 с) возвращается мгновенно, без сети; протухший обновляется
    /// ФОНОМ, запрос уходит с текущим токеном. На челлендж отвечает ретрай
    /// в `sendWithRetry` (refreshBlocking до результата).
    private func applyByetHeaders(to request: inout URLRequest) async {
        guard let byet = byetCookieProvider else { return }
        request.setValue(ByetCookieProvider.chromeUA, forHTTPHeaderField: "User-Agent")
        if let cookie = await byet.ensureFresh() {
            request.setValue(cookie, forHTTPHeaderField: "Cookie")
        }
    }

    /// Общий цикл «отправить + (по необходимости) повторить» для обоих путей.
    /// - 2 попытки суммарно: первичный + 1 ретрай (только сетевые ошибки);
    /// - Byet-челлендж ретраится один раз со свежей кукой (attempt не сжигается);
    /// - `transcriptPath == nil` — плоский ключ "text"; иначе извлекается по
    ///   JSON-пути адаптера (deepgram).
    /// - `skipPreflight: true` — адаптерный путь уже сделал preflight до OAuth.
    private func sendWithRetry(
        request inputRequest: URLRequest,
        transcriptPath: [String]?,
        wav: Data,
        filename: String,
        prompt: String?,
        skipPreflight: Bool
    ) async throws -> TranscriptionResult {
        var request = inputRequest

        // При log_level == "debug" сохраняем саму аудиозапись (WAV) на диск
        // один раз, до отправки; информация о файле уходит в debug-дамп.
        let recording = saveRecordingIfDebug(wav: wav)

        // Preflight сети: сети нет — HTTP-запрос не отправляем вовсе, ошибка
        // мгновенная («Нет интернета»), вместо зависшего оверлея на 120 с.
        if !skipPreflight, !(await networkChecker()) {
            Logger.log("STT not sent: no internet (preflight)", level: "error")
            debugDump(request: request, wavByteCount: wav.count, filename: filename, prompt: prompt, recording: nil, response: nil)
            throw TranscribeError.network(Self.noInternetMessage)
        }

        // 2 attempts total: initial + 1 retry (network errors only).
        var lastError: TranscribeError?
        var attempt = 0
        // Byet-челлендж ретраится не больше одного раза (свежей кукой).
        var challengeRetried = false
        for _ in 0..<2 {
            attempt += 1
            do {
                let started = CFAbsoluteTimeGetCurrent()
                let response = try await send(request: request)
                let elapsed = CFAbsoluteTimeGetCurrent() - started
                debugDump(request: request, wavByteCount: wav.count, filename: filename, prompt: prompt, recording: recording, response: response)
                if logLevel.lowercased() == "debug" {
                    Logger.log(String(format: "STT response: HTTP %d in %.2f s, bodyBytes=%d", response.status, elapsed, response.body.count), level: "debug")
                }
                // Byet-челлендж (transport == "relay"/"infinityfree"): сервер вместо
                // контента прислал JS-заглушку. Единственный ретрай — со свежей
                // кукой (refreshBlocking до результата); attempt не сжигается.
                // Повторный челлендж после свежего токена — серьёзная ошибка.
                if let byet = byetCookieProvider,
                   !challengeRetried,
                   ByetCookieProvider.looksLikeChallenge(response.body) {
                    if let freshCookie = await byet.refreshBlocking() {
                        challengeRetried = true
                        request.setValue(freshCookie, forHTTPHeaderField: "Cookie")
                        attempt -= 1
                        Logger.log("STT Byet challenge: cookie обновлён, повтор с новым __test", level: "info")
                        continue
                    }
                    Logger.log("STT Byet challenge: свежий cookie не получен", level: "error")
                    throw TranscribeError.invalidResponse("Byet challenge page received; cookie refresh failed")
                }
                let result = try Self.parseResponse(response, transcriptPath: transcriptPath)
                if logLevel.lowercased() == "debug" {
                    let text = result.text
                    let head = text.count > 80 ? String(text.prefix(80)) + "…" : text
                    Logger.log("STT text: \"\(head)\" (\(text.count) chars)", level: "debug")
                }
                return result
            } catch let error as TranscribeError {
                // http / invalidResponse — do not retry.
                Logger.log("STT error (attempt \(attempt)): \(Self.describe(error))", level: "error")
                throw error
            } catch is CancellationError {
                // Do not retry cancelled requests.
                Logger.log("STT cancelled (attempt \(attempt))", level: "error")
                throw TranscribeError.network("Request cancelled")
            } catch let error as URLError where error.code == .cancelled {
                Logger.log("STT cancelled (URLError.cancelled, attempt \(attempt))", level: "error")
                throw TranscribeError.network("Request cancelled")
            } catch let error as URLError where error.code == .timedOut {
                // Жёсткий сетевой таймаут запроса (networkRequestTimeout).
                // Терминальный, БЕЗ ретрая: повторный запрос почти наверняка
                // упрётся в тот же таймаут и снова заставит оверлей крутить
                // точки — поэтому фаза «обработка» не живёт дольше таймаута
                // + небольшой запас (см. OverlayController.processingMaxDuration).
                Logger.log("STT timeout (attempt \(attempt)): \(error.localizedDescription)", level: "error")
                throw TranscribeError.network(Self.sttTimeoutMessage)
            } catch {
                // Transport-level (network) failure — eligible for retry.
                let message = error.localizedDescription
                Logger.log("STT network error (attempt \(attempt)/2): \(message)", level: "error")
                lastError = TranscribeError.network(message)
            }
        }
        // Все попытки упали на транспортном уровне — ответа так и нет.
        // В debug-дампе фиксируем и сам факт запроса (метод/URL/заголовки/поля),
        // чтобы было видно, что до HTTP дело не дошло; ошибки дампа не роняют.
        debugDump(request: request, wavByteCount: wav.count, filename: filename, prompt: prompt, recording: recording, response: nil)
        if let lastError = lastError {
            Logger.log("STT failed after 2 attempts: \(Self.describe(lastError))", level: "error")
            throw lastError
        }
        throw TranscribeError.network("Unknown transport error")
    }

    /// Человекочитаемое описание ошибки для лога. Тело HTTP-ответа маскируется
    /// через `DebugDump.maskedResponseBody` (секреты затираются по ПОЛНОМУ телу),
    /// затем отсекается до ~120 символов, чтобы api_key/proxy_key провайдера
    /// не попали в лог.
    static func describe(_ error: TranscribeError) -> String {
        switch error {
        case .network(let message):
            return "network: \(message)"
        case .http(let code, let body):
            // Маскируем ПОЛНОЕ тело (секрет может пересечь границу обрезки),
            // потом отсекаем до ~120 символов.
            return "HTTP \(code): \(String(DebugDump.maskedResponseBody(Data(body.utf8)).prefix(120)))"
        case .invalidResponse(let message):
            return "invalid response: \(message)"
        }
    }

    // MARK: - Send

    private func send(request: URLRequest) async throws -> (status: Int, body: Data) {
        if let transport = transport {
            return try await transport.send(request: request)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (httpResponse.statusCode, data)
    }

    // MARK: - Debug dump (log_level == "debug")

    /// При `log_level == "debug"` сохраняет WAV в `recordingsDirectory` и
    /// возвращает информацию о файле (путь + размер) для дампа; иначе `nil`.
    /// Пустые данные не сохраняются. Ошибки записи не бросаются наружу.
    private func saveRecordingIfDebug(wav: Data) -> DebugDump.RecordingInfo? {
        guard logLevel.lowercased() == "debug", wav.count > 0 else { return nil }
        let path = DebugDump.recordingPath(for: Date())
        DebugDump.saveRecording(data: wav, to: path)
        return DebugDump.RecordingInfo(path: path, byteCount: wav.count)
    }

    /// При `log_level == "debug"` дописывает в `~/Library/Logs/Dictation/
    /// transcriber-debug.log` точный исходящий запрос (метод, URL, заголовки с
    /// маскировкой, form-поля, метаданные file-парта), путь и размер сохранённой
    /// аудиозаписи — и ответ (HTTP-статус + тело целиком). Если `response` — nil
    /// (все попытки упали на транспортном уровне до HTTP), в секции ответа
    /// пишется `(no response — transport error)`. Поведение запроса/ответа не
    /// меняет; ошибок не бросает.
    private func debugDump(request: URLRequest, wavByteCount: Int, filename: String, prompt: String?, recording: DebugDump.RecordingInfo?, response: (status: Int, body: Data)?) {
        guard logLevel.lowercased() == "debug" else { return }

        var headers: [(name: String, value: String)] = []
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            headers.append((name: name, value: value))
        }

        var fields: [(name: String, value: String)] = [(name: "model", value: model)]
        if !language.isEmpty {
            fields.append((name: "language", value: language))
        }
        if let prompt = prompt, !prompt.isEmpty {
            fields.append((name: "prompt", value: String(prompt.prefix(80)) + (prompt.count > 80 ? "…" : "")))
        }

        let filePart = DebugDump.FilePart(
            fieldName: "file",
            filename: filename,
            contentType: "audio/wav",
            byteCount: wavByteCount
        )

        let entry = DebugDump.summarize(
            method: request.httpMethod ?? "POST",
            url: request.url?.absoluteString ?? baseURL,
            headers: headers,
            fields: fields,
            filePart: filePart,
            recording: recording,
            status: response?.status,
            responseBody: response?.body
        )
        DebugDump.append(entry: entry)
    }

    // MARK: - Response parsing

    /// Разбор HTTP-ответа в результат распознавания.
    /// - `transcriptPath == nil` — OpenAI-совместимый плоский `{"text": "…"}`;
    /// - иначе текст извлекается по JSON-пути адаптера (deepgram).
    /// Ошибки и их строки — ровно те же, что были в legacy-пути (см. тесты).
    private static func parseResponse(_ response: (status: Int, body: Data), transcriptPath: [String]? = nil) throws -> TranscriptionResult {
        let status = response.status
        let body = response.body
        guard (200...299).contains(status) else {
            let text = String(data: body, encoding: .utf8) ?? ""
            guard !text.isEmpty else {
                throw TranscribeError.http(status, "")
            }
            throw TranscribeError.http(status, String(text.prefix(500)))
        }
        let text = try ProviderRequestBuilder.extractText(from: body, path: transcriptPath)
        return TranscriptionResult(text: text, rawData: body)
    }

    // MARK: - Multipart body

    // Единый источник правды о multipart-формате — ProviderRequestBuilder
    // (STTAdapter.swift): legacy-путь и все OpenAI-совместимые адаптеры дают
    // байт-в-байт одинаковое тело (см. ProviderRequestBuilder.multipartBody).
}