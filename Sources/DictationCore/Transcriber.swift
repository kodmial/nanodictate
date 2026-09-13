import Foundation

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

public enum TranscribeError: Error {
    case network(String)
    case http(Int, String) // HTTP code + body text (truncated to ~500 characters)
    case invalidResponse(String) // not JSON or missing "text" field
}

// MARK: - HTTPTransport

public protocol HTTPTransport: AnyObject {
    /// Send a request; return the response (status + body).
    /// The default implementation is URLSession.
    func send(request: URLRequest) async throws -> (status: Int, body: Data)
}

// MARK: - Transcriber

public final class Transcriber {

    private let baseURL: String
    private let model: String
    private let apiKey: String
    private let proxyKey: String
    private let language: String
    private let timeout: TimeInterval
    private let logLevel: String
    private let transport: HTTPTransport?

    public init(
        baseURL: String,
        model: String,
        apiKey: String,
        proxyKey: String = "",
        language: String = "ru",
        timeout: TimeInterval = 120,
        logLevel: String = "info",
        transport: HTTPTransport? = nil
    ) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.proxyKey = proxyKey
        self.language = language
        self.timeout = timeout
        self.logLevel = logLevel
        self.transport = transport
    }

    /// Transcribe WAV audio via a multipart/form-data POST to the transcription endpoint.
    /// On network failure, retries once (2 attempts total). HTTP and invalid-response
    /// errors are not retried.
    public func transcribe(wav: Data, filename: String = "audio.wav") async throws -> TranscriptionResult {
        guard let url = URL(string: baseURL) else {
            throw TranscribeError.network("Invalid base URL")
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        let body = Self.makeMultipartBody(wav: wav, filename: filename, model: model, language: language, boundary: boundary)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if !proxyKey.isEmpty {
            request.setValue(proxyKey, forHTTPHeaderField: "X-Proxy-Key")
        }
        request.timeoutInterval = timeout

        // При log_level == "debug" сохраняем саму аудиозапись (WAV) на диск
        // один раз, до отправки; информация о файле уходит в debug-дамп.
        let recording = saveRecordingIfDebug(wav: wav)

        // 2 attempts total: initial + 1 retry (network errors only).
        var lastError: TranscribeError?
        for _ in 0..<2 {
            do {
                let response = try await send(request: request)
                debugDump(request: request, wavByteCount: wav.count, filename: filename, recording: recording, response: response)
                return try Self.parseResponse(response)
            } catch let error as TranscribeError {
                // http / invalidResponse — do not retry.
                throw error
            } catch is CancellationError {
                // Do not retry cancelled requests.
                throw TranscribeError.network("Request cancelled")
            } catch let error as URLError where error.code == .cancelled {
                throw TranscribeError.network("Request cancelled")
            } catch {
                // Transport-level (network) failure — eligible for retry.
                lastError = TranscribeError.network(error.localizedDescription)
            }
        }
        // Все попытки упали на транспортном уровне — ответа так и нет.
        // В debug-дампе фиксируем и сам факт запроса (метод/URL/заголовки/поля),
        // чтобы было видно, что до HTTP дело не дошло; ошибки дампа не роняют.
        debugDump(request: request, wavByteCount: wav.count, filename: filename, recording: recording, response: nil)
        throw lastError ?? TranscribeError.network("Unknown transport error")
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
    private func debugDump(request: URLRequest, wavByteCount: Int, filename: String, recording: DebugDump.RecordingInfo?, response: (status: Int, body: Data)?) {
        guard logLevel.lowercased() == "debug" else { return }

        var headers: [(name: String, value: String)] = []
        for (name, value) in request.allHTTPHeaderFields ?? [:] {
            headers.append((name: name, value: value))
        }

        var fields: [(name: String, value: String)] = [(name: "model", value: model)]
        if !language.isEmpty {
            fields.append((name: "language", value: language))
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

    private static func parseResponse(_ response: (status: Int, body: Data)) throws -> TranscriptionResult {
        let status = response.status
        let body = response.body
        guard (200...299).contains(status) else {
            let text = String(data: body, encoding: .utf8) ?? ""
            guard !text.isEmpty else {
                throw TranscribeError.http(status, "")
            }
            throw TranscribeError.http(status, String(text.prefix(500)))
        }

        guard body.count > 0,
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw TranscribeError.invalidResponse("Response is not a JSON object")
        }
        guard let text = json["text"] as? String else {
            throw TranscribeError.invalidResponse("Missing 'text' field")
        }
        return TranscriptionResult(text: text, rawData: body)
    }

    // MARK: - Multipart body

    private static func makeMultipartBody(wav: Data, filename: String, model: String, language: String, boundary: String) -> Data {
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

        // Closing boundary
        append("--\(boundary)--\r\n")

        return body
    }
}