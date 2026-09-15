import Foundation

// MARK: - Ответственность: пакетное распознавание файла
// Sequential-конвейер для ОЧЕНЬ длинных аудиофайлов: фиксированные чанки с
// оверлэпом (BatchSegmenter) → по-чанковая транскрибация ОДНИМ провайдером
// (никакой routing segment/final и никакого автоfailover) → сшивка с дедупом
// по границе (BatchTextJoiner) → checkpoint/resume.
//
// Пайплайн ЧИСТЫЙ: STT и сон инъецируются замыканиями (тесты без сети и без
// реальных пауз); реальный HTTP-путь — `URLSessionBatchTransport` + построение
// запроса из полей провайдера через ProviderRequestBuilder (тот же
// OpenAI-совместимый мультипарт, что и legacy-путь Transcriber).

// MARK: - Ошибки и HTTP-ответ батча

/// Ошибка одного чанка. Транспортные сбои и перегруженность сервера
/// (429/503/5xx) — ретраябельны; 4xx (кроме 429) и не-JSON ответы — нет.
public struct BatchHTTPError: Error, Equatable {
    public enum Kind: Equatable {
        case network
        case http
        case invalidResponse
    }

    public let kind: Kind
    /// HTTP-статус (только для .http).
    public let status: Int?
    public let message: String
    /// Retry-After из заголовка ответа (секунды); nil — нет заголовка.
    public let retryAfter: TimeInterval?

    public init(kind: Kind, status: Int? = nil, message: String, retryAfter: TimeInterval? = nil) {
        self.kind = kind
        self.status = status
        self.message = message
        self.retryAfter = retryAfter
    }

    public static func network(_ message: String) -> BatchHTTPError {
        BatchHTTPError(kind: .network, message: message)
    }

    public static func http(_ status: Int, message: String, retryAfter: TimeInterval?) -> BatchHTTPError {
        BatchHTTPError(kind: .http, status: status, message: message, retryAfter: retryAfter)
    }

    public static func invalidResponse(_ message: String) -> BatchHTTPError {
        BatchHTTPError(kind: .invalidResponse, message: message)
    }

    /// Ретраябельно: транспортный сбой, 429 (rate limit), 503/5xx.
    /// 4xx (кроме 429) и не-JSON ответ — нет (повторять бессмысленно).
    public var isRetryable: Bool {
        switch kind {
        case .network:
            return true
        case .invalidResponse:
            return false
        case .http:
            guard let status = status else { return false }
            return status == 429 || status >= 500
        }
    }
}

/// Ответ HTTP-запроса батча (заголовки нужны для Retry-After).
public struct BatchHTTPResponse: Equatable {
    public let status: Int
    /// Заголовки ответа с НИЖНИМ регистром ключей (для case-insensitive поиска).
    public let headers: [String: String]
    public let body: Data

    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    /// Значение заголовка Retry-After: целое число секунд. HTTP-дата не
    /// разбирается (возвращается nil — фолбэк на backoff).
    public var retryAfterSeconds: TimeInterval? {
        guard let raw = headers["retry-after"], let value = Double(raw), value >= 0 else { return nil }
        return value
    }
}

/// Транспорт батча: тот же минимальный контракт, что HTTPTransport у
/// Transcriber, но с заголовками в ответе (Retry-After). Существующий
/// HTTPTransport не трогаем — батч живёт на своей схеме.
public protocol BatchHTTPTransport: AnyObject {
    func send(request: URLRequest) async throws -> BatchHTTPResponse
}

/// Реальный транспорт батча: URLSession.
public final class URLSessionBatchTransport: BatchHTTPTransport {
    public init() {}

    public func send(request: URLRequest) async throws -> BatchHTTPResponse {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        var headers: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            guard let k = key as? String, let v = value as? String else { continue }
            headers[k.lowercased()] = v
        }
        return BatchHTTPResponse(status: httpResponse.statusCode, headers: headers, body: data)
    }
}

// MARK: - Checkpoint

/// Результат одного чанка в чекпоинте.
public struct BatchSegmentRecord: Codable, Equatable {
    public static let statusOK = "ok"
    public static let statusSkipped = "skipped"

    public let index: Int
    public let bodyStart: TimeInterval
    public let bodyEnd: TimeInterval
    /// "ok" — распознан; "skipped" — после исчерпания ретраев поставлен «[…]».
    public let status: String
    public let text: String

    public init(index: Int, bodyStart: TimeInterval, bodyEnd: TimeInterval, status: String, text: String) {
        self.index = index
        self.bodyStart = bodyStart
        self.bodyEnd = bodyEnd
        self.status = status
        self.text = text
    }

    public var isResolved: Bool { status == Self.statusOK || status == Self.statusSkipped }
}

/// Чекпоинт пакетного распознавания: сохраняется после КАЖДОГО чанка, чтобы
/// Ctrl+C + `--resume` продолжали с места.
public struct BatchCheckpoint: Codable, Equatable {
    public static let currentVersion = 1

    public let version: Int
    public let providerID: String
    public let sourceFile: String
    public let totalSegments: Int
    public let segments: [BatchSegmentRecord]

    public init(version: Int, providerID: String, sourceFile: String, totalSegments: Int, segments: [BatchSegmentRecord]) {
        self.version = version
        self.providerID = providerID
        self.sourceFile = sourceFile
        self.totalSegments = totalSegments
        self.segments = segments
    }

    /// Запись чанка (по ключу — index), если он уже разрешён (ok/skipped).
    public func resolvedRecord(index: Int) -> BatchSegmentRecord? {
        guard index >= 0, index < totalSegments else { return nil }
        guard segments.indices.contains(index), segments[index].isResolved else { return nil }
        return segments[index]
    }
}

// MARK: - Outcome

/// Итог прогона пакетного распознавания.
public struct BatchOutcome: Equatable {
    public let text: String
    public let totalSegments: Int
    public let okCount: Int
    public let skippedCount: Int
    /// Порядковые номера (1-based) пропущенных (placeholder) чанков.
    public let skippedIndexes: [Int]
    public let elapsed: TimeInterval

    public init(text: String, totalSegments: Int, okCount: Int, skippedCount: Int,
                skippedIndexes: [Int], elapsed: TimeInterval) {
        self.text = text
        self.totalSegments = totalSegments
        self.okCount = okCount
        self.skippedCount = skippedCount
        self.skippedIndexes = skippedIndexes
        self.elapsed = elapsed
    }
}

// MARK: - Пайплайн

public enum BatchTranscriber {

    /// Транскрибация ОДНОГО запроса (без ретраев); throws BatchHTTPError.
    /// Параметры: `attempt` (0-based, для диагностики), WAV-данные чанка,
    /// 0-based индекс чанка (для имени multipart-файла).
    public typealias SendOne = (Int, Data, Int) async throws -> String
    /// Ретраябельная транскрибация одной попытки (`attempt` 0-based).
    public typealias SendRetryable = (Int) async throws -> String
    /// Прогресс: (i, N, bodyStartSec, bodyEndSec, elapsedSec, status) — 1-based i.
    public typealias ProgressHandler = (Int, Int, TimeInterval, TimeInterval, TimeInterval, String) -> Void

    /// Плейсхолдер для чанка, распознавание которого провалилось.
    public static let placeholder = "[…]"

    // MARK: Ретраи чанка

    /// Ретраи одного чанка: до `1 + retries` попыток. Между попытками —
    /// backoff (`2s/4s/8s` по умолчанию), при HTTP 429/503 — Retry-After
    /// (если есть; иначе backoff). Неретраябельная ошибка — сразу наружу;
    /// любые не-BatchHTTPError ошибки (транспорт) трактуются как ретраябельные.
    public static func transcribeChunk(
        send: SendRetryable,
        retries: Int = 3,
        backoff: [TimeInterval] = [2, 4, 8],
        delay: (TimeInterval) async throws -> Void
    ) async throws -> String {
        precondition(retries >= 0)
        let schedule = backoff.isEmpty ? [2.0] : backoff
        for attempt in 0...retries {
            do {
                return try await send(attempt)
            } catch let error as BatchHTTPError where !error.isRetryable {
                // 4xx (кроме 429) / не-JSON ответ — повторять бессмысленно.
                throw error
            } catch {
                // Отмена — не сетевой сбой: прерываемся сразу, без ретраев.
                if Task.isCancelled { throw CancellationError() }
                let batchError = error as? BatchHTTPError
                guard attempt < retries else {
                    throw batchError ?? BatchHTTPError.network(error.localizedDescription)
                }
                let wait = batchError?.retryAfter ?? schedule[min(attempt, schedule.count - 1)]
                try await delay(wait)
            }
        }
        throw BatchHTTPError.network("unreachable (retries exhausted)")
    }

    // MARK: Основной прогон

    /// Прогон пакетного распознавания: сегментация → по-чанковая
    /// транскрибация (с ретраями и плейсхолдерами) → сшивка с дедупом.
    ///
    /// - Parameters:
    ///   - samples: PCM-сэмплы всего файла.
    ///   - maxSegment/overlap/sampleRate: параметры BatchSegmenter.
    ///   - providerID/sourceFile: для чекпоинта (идентичность при resume).
    ///   - checkpointStore/resume: хранилище чекпоинта и флаг продолжения;
    ///     `store == nil` — чекпоинт не пишется.
    ///   - sendOne: ТРАНСПОРТ без ретраев (ретраи внутри). Принимает WAV-данные
    ///     чанка и возвращает текст; ошибка — BatchHTTPError.
    ///   - delay: пауза между ретраями (в тестах — мгновенный).
    ///   - onProgress: прогресс-колбэк (первый вызов после первого чанка).
    public static func run(
        samples: [Int16],
        sampleRate: Int = 16000,
        maxSegment: TimeInterval = 30,
        overlap: TimeInterval = 2.5,
        providerID: String,
        sourceFile: String,
        checkpointPath: String? = nil,
        resume: Bool = false,
        loadCheckpoint: (String) -> BatchCheckpoint? = { try? Self.loadCheckpoint(from: $0) },
        saveCheckpoint: (BatchCheckpoint, String) throws -> Void = { try Self.saveCheckpoint($0, to: $1) },
        sendOne: SendOne,
        delay: (TimeInterval) async throws -> Void,
        onProgress: ProgressHandler? = nil
    ) async throws -> BatchOutcome {
        let chunks = BatchSegmenter.segments(
            samples: samples, sampleRate: sampleRate, maxSegment: maxSegment, overlap: overlap
        )
        let started = CFAbsoluteTimeGetCurrent()

        guard !chunks.isEmpty else {
            return BatchOutcome(text: "", totalSegments: 0, okCount: 0, skippedCount: 0,
                                skippedIndexes: [], elapsed: 0)
        }

        // Resume: валидный чекпоинт — та же версия, тот же провайдер, ТОТ ЖЕ
        // ФАЙЛ (sourceFile) и то же число сегментов. Чекпоинт чужого файла или
        // другой нарезки молча не применяем — разрешённые чанки берём только
        // из подходящего, остальные распознаём заново (вызывающий в main.swift
        // дополнительно предупреждает в stderr о несовпадении sourceFile).
        var records = Array(repeating: BatchSegmentRecord(
            index: 0, bodyStart: 0, bodyEnd: 0, status: "pending", text: ""
        ), count: chunks.count)
        if resume, let path = checkpointPath, let cp = loadCheckpoint(path) {
            if cp.version == BatchCheckpoint.currentVersion,
               cp.providerID == providerID,
               cp.sourceFile == sourceFile,
               cp.totalSegments == chunks.count {
                for (i, _) in chunks.enumerated() {
                    // resolvedRecord уже гарантирует index в пределах
                    // totalSegments == records.count — дополнительный guard не нужен.
                    if let resolved = cp.resolvedRecord(index: i) {
                        records[resolved.index] = resolved
                    }
                }
            }
        }

        for (i, chunk) in chunks.enumerated() {
            let existing = records[i]
            if existing.isResolved {
                onProgress?(i + 1, chunks.count, chunk.bodyStart, chunk.bodyEnd,
                            CFAbsoluteTimeGetCurrent() - started, existing.status)
                continue
            }

            let wav = WAVEncoder.encode(samples: chunk.samples, sampleRate: sampleRate)
            let text: String
            let status: String
            do {
                text = try await transcribeChunk(send: { attempt in
                    try await sendOne(attempt, wav, chunk.index)
                }, delay: delay)
                status = BatchSegmentRecord.statusOK
            } catch {
                text = Self.placeholder
                status = BatchSegmentRecord.statusSkipped
            }
            records[i] = BatchSegmentRecord(
                index: i,
                bodyStart: chunk.bodyStart,
                bodyEnd: chunk.bodyEnd,
                status: status,
                text: text
            )

            if let path = checkpointPath {
                let cp = BatchCheckpoint(
                    version: BatchCheckpoint.currentVersion,
                    providerID: providerID,
                    sourceFile: sourceFile,
                    totalSegments: chunks.count,
                    segments: records
                )
                try? saveCheckpoint(cp, path)
            }
            onProgress?(i + 1, chunks.count, chunk.bodyStart, chunk.bodyEnd,
                        CFAbsoluteTimeGetCurrent() - started, status)
        }

        let joined = BatchTextJoiner.join(records.map { $0.text })
        let skippedIndexes = records.enumerated()
            .filter { $0.element.status == BatchSegmentRecord.statusSkipped }
            .map { $0.offset + 1 }
        return BatchOutcome(
            text: joined,
            totalSegments: chunks.count,
            okCount: records.filter { $0.status == BatchSegmentRecord.statusOK }.count,
            skippedCount: skippedIndexes.count,
            skippedIndexes: skippedIndexes,
            elapsed: CFAbsoluteTimeGetCurrent() - started
        )
    }

    // MARK: - Checkpoint I/O

    public static let checkpointFileExtension = "checkpoint.json"

    public static func saveCheckpoint(_ checkpoint: BatchCheckpoint, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(checkpoint)
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    public static func loadCheckpoint(from path: String) throws -> BatchCheckpoint? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BatchCheckpoint.self, from: data)
    }
}

// MARK: - Построение запроса чанка из конфига провайдера

/// Готовый URLRequest чанка + JSON-путь к тексту в ответе (nil — плоский
/// ключ "text", OpenAI-совместимый).
public struct BatchPreparedRequest {
    public let request: URLRequest
    public let transcriptPath: [String]?

    public init(request: URLRequest, transcriptPath: [String]?) {
        self.request = request
        self.transcriptPath = transcriptPath
    }
}

public enum BatchRequestBuilder {

    /// Собирает URLRequest для ОДНОГО чанка из полей провайдера (секция
    /// `[providers.X]` конфига): OpenAI-совместимый мультипарт через
    /// ProviderRequestBuilder.plan (file → model → language). Auth-заголовок
    /// добавляется только при непустом ключе. Таймаут — из конфига
    /// (`timeout_seconds`), без потолка Transcriber.networkRequestTimeout
    /// (чанки длинные, сервер — self-hosted). nil — не собрался
    /// (пустой/битый base_url).
    public static func makeRequest(
        provider: AppConfig.Provider,
        apiKey: String,
        language: String,
        timeout: TimeInterval,
        wav: Data,
        chunkIndex: Int
    ) -> BatchPreparedRequest? {
        let spec = ProviderRequestBuilder.plan(
            adapterID: provider.id,
            baseURL: provider.baseURL,
            model: provider.model,
            apiKey: apiKey.isEmpty ? "" : apiKey,
            language: language,
            wav: wav,
            filename: "segment-\(chunkIndex + 1).wav"
        )
        guard let url = spec.url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = spec.bodyData
        request.setValue(spec.contentType, forHTTPHeaderField: "Content-Type")
        for (name, value) in spec.headers {
            // Пустой apiKey — Authorization не отправляем вовсе (иначе уйдёт
            // «Bearer » с пустым токеном). Остальные заголовки — как есть.
            if name == "Authorization" && apiKey.isEmpty { continue }
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.timeoutInterval = timeout
        return BatchPreparedRequest(request: request, transcriptPath: spec.transcriptPath)
    }
}