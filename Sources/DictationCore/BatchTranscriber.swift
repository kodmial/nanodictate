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

// MARK: - Параллельное состояние прогона

/// Потокобезопасное состояние параллельного прогона (maxConcurrent > 1).
/// Все изменяемые поля под NSLock; методы короткие, I/O (чекпоинт, прогресс)
/// выполняется вызвавшим воркером ПОСЛЕ возврата из метода. Поля доступны
/// только через методы — поэтому класс помечен @unchecked Sendable.
private final class BatchRunState: @unchecked Sendable {
    private let lock = NSLock()
    private let total: Int
    /// Раздатчик работ: следующий индекс чанка для обработки.
    private var nextJob = 0
    /// Слоты результатов: nil — не разрешён; запись — ok/skipped.
    private var slots: [BatchSegmentRecord?]
    /// Сколько слотов уже разрешено (для прогресса).
    private var resolvedCount = 0
    /// Курсор: первый индекс, с которого слоты ещё не заполнены подряд.
    private var cursor = 0
    /// Сколько записей уже сохранено в чекпоинт (подряд с 0).
    private var savedCount = 0

    /// - Parameters:
    ///   - total: число чанков (specs.count).
    ///   - seeded: разрешённые resume-слоты (nil — распознавать). Слоты из
    ///     чекпоинта уже сохранены в файле — они не переписываются.
    init(total: Int, seeded: [BatchSegmentRecord?]) {
        self.total = total
        self.slots = Array(repeating: nil, count: total)
        for (i, record) in seeded.enumerated() {
            if let record = record {
                slots[i] = record
                resolvedCount += 1
            }
        }
        while cursor < total, slots[cursor] != nil { cursor += 1 }
        savedCount = cursor
    }

    /// Следующий индекс чанка для обработки (nil — работы закончились).
    /// Уже разрешённые слоты (resume-сеяные из чекпоинта) пропускает:
    /// повторно распознавать их не надо.
    func takeJob() -> Int? {
        lock.lock()
        defer { lock.unlock() }
        while nextJob < total {
            let job = nextJob
            nextJob += 1
            if slots[job] == nil { return job }
        }
        return nil
    }

    /// Результат store(index:record:): для чекпоинта и прогресса воркером.
    struct StoreResult {
        let record: BatchSegmentRecord
        let completed: Int
        /// Конец нового подряд резолвленного префикса; -1 — курсор не сдвинулся
        /// (чекпоинт не надо переписывать).
        let prefixEnd: Int
    }

    /// Кладёт результат чанка; двигает курсор и возвращает, что надо
    /// сохранить/показать. НЕ делает I/O — только атомарное обновление.
    func store(_ index: Int, _ record: BatchSegmentRecord) -> StoreResult {
        lock.lock()
        defer { lock.unlock() }
        slots[index] = record
        resolvedCount += 1
        while cursor < total, slots[cursor] != nil { cursor += 1 }
        let prefixEnd = cursor > savedCount ? cursor : -1
        if prefixEnd >= 0 { savedCount = prefixEnd }
        return StoreResult(record: record, completed: resolvedCount, prefixEnd: prefixEnd)
    }

    /// Резолвленные записи в порядке индексов (для итоговой сборки).
    func resolvedRecords() -> [BatchSegmentRecord] {
        lock.lock()
        defer { lock.unlock() }
        return slots.compactMap { $0 }
    }

    /// Подряд резолвленный префикс [0..<end] (для чекпоинта).
    /// Гарантируется: все слоты в диапазоне заполнены (инвариант курсора).
    func resolvedPrefix(_ end: Int) -> [BatchSegmentRecord] {
        lock.lock()
        defer { lock.unlock() }
        guard end > 0 else { return [] }
        return (0..<min(end, total)).compactMap { slots[$0] }
    }
}

/// Сериализованный писатель чекпоинта для ПАРАЛЛЕЛЬНОГО прохода.
///
/// Проблема, которую он решает: воркеры параллельно зовут
/// `saveCheckpoint(cp, path)` (атомарная запись в тот же файл). Даже
/// `.atomic`-запись в один и тот же URL не сериализуется: две записи могут
/// пересечься на временном файле (обрыв/пустой файл) или финальный rename
/// старого (меньшего) префикса может лечь ПОСЛЕ rename нового (бОльшего) —
/// файл в момент resume окажется пустым или устаревшим, и разрешённые из
/// чекпоинта чанки приходится распознавать заново.
///
/// Здесь запись идёт строго по одному воркеру и только когда новый префикс
/// строго длиннее уже сохранённого: файл монотонно растёт, всегда валиден.
final class CheckpointWriter: @unchecked Sendable {
    private let lock = NSLock()
    private var savedEnd = 0

    /// Сохраняет префикс [0..<end], если он длиннее уже записанного.
    /// `makeCheckpoint(end)` строит чекпоинт ПОД lock — длина и содержимое
    /// не успевают разойтись с уже сохранённым префиксом.
    func saveIfLonger(
        end: Int,
        path: String,
        saveCheckpoint: (BatchCheckpoint, String) throws -> Void,
        makeCheckpoint: (Int) -> BatchCheckpoint
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard end > savedEnd else { return }
        savedEnd = end
        let cp = makeCheckpoint(end)
        try? saveCheckpoint(cp, path)
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
    ///   - samples: PCM-сэмплы всего файла (in-memory путь).
    ///   - maxSegment/overlap/sampleRate: параметры BatchSegmenter.
    ///   - providerID/sourceFile: для чекпоинта (идентичность при resume).
    ///   - checkpointStore/resume: хранилище чекпоинта и флаг продолжения;
    ///     `store == nil` — чекпоинт не пишется.
    ///   - sendOne: ТРАНСПОРТ без ретраев (ретраи внутри). Принимает WAV-данные
    ///     чанка и возвращает текст; ошибка — BatchHTTPError.
    ///   - delay: пауза между ретраями (в тестах — мгновенный).
    ///   - maxConcurrent: параллельных воркеров. 1 (по умолчанию) — строго
    ///     последовательная отправка (один сервер). > 1 — пул воркеров:
    ///     чанки распознаются по мере готовности, порядок результата и
    ///     чекпоинт/resume не меняются (чекпоинт пишет подряд резолвленный
    ///     префикс).
    ///   - cutAtPauses/pauseDuration/maxDrift: выравнивание границ чанка на
    ///     паузу речи (опционально, см. BatchSegmenter.plan).
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
        saveCheckpoint: @escaping (BatchCheckpoint, String) throws -> Void = { try Self.saveCheckpoint($0, to: $1) },
        sendOne: @escaping SendOne,
        delay: @escaping (TimeInterval) async throws -> Void,
        maxConcurrent: Int = 1,
        cutAtPauses: Bool = false,
        pauseDuration: TimeInterval = 1.0,
        maxDrift: TimeInterval = 5.0,
        onProgress: ProgressHandler? = nil
    ) async throws -> BatchOutcome {
        let content = ArrayPCMBatchContent(samples: samples, sampleRate: sampleRate)
        let specs = try BatchSegmenter.plan(
            content: content, maxSegment: maxSegment, overlap: overlap,
            cutAtPauses: cutAtPauses, pauseDuration: pauseDuration, maxDrift: maxDrift
        )
        return try await execute(
            specs: specs, content: content, sampleRate: sampleRate,
            providerID: providerID, sourceFile: sourceFile,
            checkpointPath: checkpointPath, resume: resume,
            loadCheckpoint: loadCheckpoint, saveCheckpoint: saveCheckpoint,
            sendOne: sendOne, delay: delay, maxConcurrent: maxConcurrent,
            onProgress: onProgress
        )
    }

    /// Прогон пакетного распознавания из WAV-ФАЙЛА напрямую (read-окна):
    /// PCM-сэмплы читаются из файла по мере необходимости, в RAM не
    /// поднимается весь файл (важно для длинных записей). Всё остальное
    /// идентично run(samples:...) — чекпоинт/resume, ретраи, порядок.
    /// sampleRate берётся из заголовка WAV (клиент конвертирует в 16 кГц).
    /// maxConcurrent — как в run(samples:...): 1 последовательно, > 1 пул.
    public static func run(
        fileURL: URL,
        maxSegment: TimeInterval = 30,
        overlap: TimeInterval = 2.5,
        providerID: String,
        sourceFile: String,
        checkpointPath: String? = nil,
        resume: Bool = false,
        loadCheckpoint: (String) -> BatchCheckpoint? = { try? Self.loadCheckpoint(from: $0) },
        saveCheckpoint: @escaping (BatchCheckpoint, String) throws -> Void = { try Self.saveCheckpoint($0, to: $1) },
        sendOne: @escaping SendOne,
        delay: @escaping (TimeInterval) async throws -> Void,
        maxConcurrent: Int = 1,
        cutAtPauses: Bool = false,
        pauseDuration: TimeInterval = 1.0,
        maxDrift: TimeInterval = 5.0,
        onProgress: ProgressHandler? = nil
    ) async throws -> BatchOutcome {
        let content = try WAVFilePCMBatchContent(wavURL: fileURL)
        let specs = try BatchSegmenter.plan(
            content: content, maxSegment: maxSegment, overlap: overlap,
            cutAtPauses: cutAtPauses, pauseDuration: pauseDuration, maxDrift: maxDrift
        )
        return try await execute(
            specs: specs, content: content, sampleRate: content.sampleRate,
            providerID: providerID, sourceFile: sourceFile,
            checkpointPath: checkpointPath, resume: resume,
            loadCheckpoint: loadCheckpoint, saveCheckpoint: saveCheckpoint,
            sendOne: sendOne, delay: delay, maxConcurrent: maxConcurrent,
            onProgress: onProgress
        )
    }

    // MARK: Общее ядро (sequential / параллельный пул)

    /// Общее исполнение для обоих входов (массив/файл). Границы уже
    /// посчитаны в `specs`; сэмплы материализуем по требованию из `content`.
    /// maxConcurrent = 1 — строго последовательный проход (режим по
    /// умолчанию); > 1 — пул воркеров с общим раздатчиком чанков. Оба пути
    /// дают одинаковый итог: порядок текста, чекпоинт/resume, плейсхолдеры.
    private static func execute(
        specs: [BatchBodySpec],
        content: PCMBatchContent,
        sampleRate: Int,
        providerID: String,
        sourceFile: String,
        checkpointPath: String?,
        resume: Bool,
        loadCheckpoint: (String) -> BatchCheckpoint?,
        saveCheckpoint: @escaping (BatchCheckpoint, String) throws -> Void,
        sendOne: @escaping SendOne,
        delay: @escaping (TimeInterval) async throws -> Void,
        maxConcurrent: Int = 1,
        onProgress: ProgressHandler?
    ) async throws -> BatchOutcome {
        let started = CFAbsoluteTimeGetCurrent()

        guard !specs.isEmpty else {
            return BatchOutcome(text: "", totalSegments: 0, okCount: 0, skippedCount: 0,
                                skippedIndexes: [], elapsed: 0)
        }

        // Resume: валидный чекпоинт — та же версия, тот же провайдер, ТОТ ЖЕ
        // ФАЙЛ (sourceFile) и то же число сегментов. Чекпоинт чужого файла или
        // другой нарезки молча не применяем — разрешённые чанки берём только
        // из подходящего, остальные распознаём заново (вызывающий в main.swift
        // дополнительно предупреждает в stderr о несовпадении sourceFile).
        // Слоты: nil — чанк надо распознавать; запись — уже разрешён (ok/skipped).
        var slots = Array<BatchSegmentRecord?>(repeating: nil, count: specs.count)
        if resume, let path = checkpointPath, let cp = loadCheckpoint(path) {
            if cp.version == BatchCheckpoint.currentVersion,
               cp.providerID == providerID,
               cp.sourceFile == sourceFile,
               cp.totalSegments == specs.count {
                for (i, _) in specs.enumerated() {
                    // resolvedRecord уже гарантирует index в пределах
                    // totalSegments == slots.count — дополнительный guard не нужен.
                    if let resolved = cp.resolvedRecord(index: i) {
                        slots[i] = resolved
                    }
                }
            }
        }

        let outcome: BatchOutcome
        if maxConcurrent <= 1 {
            outcome = try await executeSequential(
                specs: specs, content: content, sampleRate: sampleRate,
                providerID: providerID, sourceFile: sourceFile,
                checkpointPath: checkpointPath,
                saveCheckpoint: saveCheckpoint,
                slots: slots,
                sendOne: sendOne, delay: delay,
                started: started,
                onProgress: onProgress
            )
        } else {
            outcome = try await executeParallel(
                specs: specs, content: content, sampleRate: sampleRate,
                providerID: providerID, sourceFile: sourceFile,
                checkpointPath: checkpointPath,
                saveCheckpoint: saveCheckpoint,
                slots: slots,
                sendOne: sendOne, delay: delay,
                maxConcurrent: maxConcurrent,
                started: started,
                onProgress: onProgress
            )
        }
        return outcome
    }

    // MARK: Sequential-проход

    /// Последовательный проход (maxConcurrent <= 1): чанки строго по порядку;
    /// чекпоинт пишется после КАЖДОГО чанка, прогресс — по каждому чанку.
    private static func executeSequential(
        specs: [BatchBodySpec],
        content: PCMBatchContent,
        sampleRate: Int,
        providerID: String,
        sourceFile: String,
        checkpointPath: String?,
        saveCheckpoint: @escaping (BatchCheckpoint, String) throws -> Void,
        slots: [BatchSegmentRecord?],
        sendOne: @escaping SendOne,
        delay: @escaping (TimeInterval) async throws -> Void,
        started: TimeInterval,
        onProgress: ProgressHandler?
    ) async throws -> BatchOutcome {
        var records = slots
        for (i, spec) in specs.enumerated() {
            if let resolved = records[i] {
                onProgress?(i + 1, specs.count, spec.bodyStart, spec.bodyEnd,
                            CFAbsoluteTimeGetCurrent() - started, resolved.status)
                continue
            }

            let chunkSamples = try spec.samples(from: content)
            let wav = WAVEncoder.encode(samples: chunkSamples, sampleRate: sampleRate)
            let text: String
            let status: String
            do {
                text = try await transcribeChunk(send: { attempt in
                    try await sendOne(attempt, wav, spec.index)
                }, delay: delay)
                status = BatchSegmentRecord.statusOK
            } catch {
                if Task.isCancelled { throw CancellationError() }
                text = Self.placeholder
                status = BatchSegmentRecord.statusSkipped
            }
            records[i] = BatchSegmentRecord(
                index: i,
                bodyStart: spec.bodyStart,
                bodyEnd: spec.bodyEnd,
                status: status,
                text: text
            )

            if let path = checkpointPath {
                let cp = BatchCheckpoint(
                    version: BatchCheckpoint.currentVersion,
                    providerID: providerID,
                    sourceFile: sourceFile,
                    totalSegments: specs.count,
                    segments: records.compactMap { $0 }
                )
                try? saveCheckpoint(cp, path)
            }
            onProgress?(i + 1, specs.count, spec.bodyStart, spec.bodyEnd,
                        CFAbsoluteTimeGetCurrent() - started, status)
        }

        return makeOutcome(records: records.compactMap { $0 }, totalSegments: specs.count, started: started)
    }

    // MARK: Параллельный проход (maxConcurrent > 1)

    /// Параллельный проход: пул воркеров берёт чанки из общего раздатчика.
    /// Итоговый порядок текста — по индексам (join по records), чекпоинт
    /// пишет подряд резолвленный префикс (как в sequential — формат файла
    /// не меняется), прогресс — по монотонному счётчику завершённых.
    private static func executeParallel(
        specs: [BatchBodySpec],
        content: PCMBatchContent,
        sampleRate: Int,
        providerID: String,
        sourceFile: String,
        checkpointPath: String?,
        saveCheckpoint: @escaping (BatchCheckpoint, String) throws -> Void,
        slots: [BatchSegmentRecord?],
        sendOne: @escaping SendOne,
        delay: @escaping (TimeInterval) async throws -> Void,
        maxConcurrent: Int,
        started: TimeInterval,
        onProgress: ProgressHandler?
    ) async throws -> BatchOutcome {
        let state = BatchRunState(total: specs.count, seeded: slots)
        let completedCount = slots.filter { $0 != nil }.count

        // Разрешённые resume-чанки: прогресс сразу, работа им не нужна.
        for (i, spec) in specs.enumerated() {
            if let resolved = slots[i] {
                onProgress?(completedCount, specs.count, spec.bodyStart, spec.bodyEnd,
                            CFAbsoluteTimeGetCurrent() - started, resolved.status)
            }
        }

        // Пустых работ не осталось — весь прогон уже в чекпоинте.
        if completedCount == specs.count {
            let records = slots.compactMap { $0 }
            return makeOutcome(records: records, totalSegments: specs.count, started: started)
        }

        let workers = min(maxConcurrent, specs.count - completedCount)
        let ckWriter = CheckpointWriter()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<workers {
                group.addTask {
                    while let job = state.takeJob() {
                        let spec = specs[job]
                        let chunkSamples = try spec.samples(from: content)
                        let wav = WAVEncoder.encode(samples: chunkSamples, sampleRate: sampleRate)
                        let text: String
                        let status: String
                        do {
                            text = try await transcribeChunk(send: { attempt in
                                try await sendOne(attempt, wav, spec.index)
                            }, delay: delay)
                            status = BatchSegmentRecord.statusOK
                        } catch {
                            if Task.isCancelled { throw CancellationError() }
                            text = Self.placeholder
                            status = BatchSegmentRecord.statusSkipped
                        }
                        let record = BatchSegmentRecord(
                            index: job,
                            bodyStart: spec.bodyStart,
                            bodyEnd: spec.bodyEnd,
                            status: status,
                            text: text
                        )
                        let stored = state.store(job, record)

                        // Чекпоинт: серилизованная запись через CheckpointWriter.
                        // Guard `end > savedEnd` внутри serializedWriter гарантирует
                        // монотонный рост: файл всегда содержит полный подряд
                        // резолвленный префикс, и параллельные Atomic-записи
                        // в один и тот же путь не пересекаются.
                        if stored.prefixEnd >= 0, let path = checkpointPath {
                            let prefixEnd = stored.prefixEnd
                            ckWriter.saveIfLonger(
                                end: prefixEnd,
                                path: path,
                                saveCheckpoint: saveCheckpoint
                            ) { end in
                                let prefix = state.resolvedPrefix(end)
                                return BatchCheckpoint(
                                    version: BatchCheckpoint.currentVersion,
                                    providerID: providerID,
                                    sourceFile: sourceFile,
                                    totalSegments: specs.count,
                                    segments: prefix
                                )
                            }
                        }
                        // Прогресс: монотонный счётчик завершённых (не индекс).
                        if let onProgress = onProgress {
                            onProgress(stored.completed, specs.count, spec.bodyStart, spec.bodyEnd,
                                       CFAbsoluteTimeGetCurrent() - started, stored.record.status)
                        }
                    }
                }
            }
            try await group.waitForAll()
        }

        let records = state.resolvedRecords()
        return makeOutcome(records: records, totalSegments: specs.count, started: started)
    }

    // MARK: Сборка итога

    private static func makeOutcome(records: [BatchSegmentRecord], totalSegments: Int, started: TimeInterval) -> BatchOutcome {
        let joined = BatchTextJoiner.join(records.map { $0.text })
        let skippedIndexes = records.enumerated()
            .filter { $0.element.status == BatchSegmentRecord.statusSkipped }
            .map { $0.offset + 1 }
        return BatchOutcome(
            text: joined,
            totalSegments: totalSegments,
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
    /// `[providers.X]` конфига): через ProviderRequestBuilder.plan — провайдер
    /// сам решает формат тела (OpenAI-совместимый мультипарт, deepgram/cloudflare
    /// — сырые WAV-байты). Auth-заголовок добавляется только при непустом ключе.
    /// Прокси-заголовок (X-Api-Key etc.) ставится только при непустом proxyKey,
    /// имя заголовка — из proxyKeyHeader (fallback на корневой — у вызывающего).
    /// Таймаут — из конфига (`timeout_seconds`), без потолка
    /// Transcriber.networkRequestTimeout (чанки длинные, сервер — self-hosted).
    /// nil — не собрался (пустой/битый base_url).
    public static func makeRequest(
        provider: AppConfig.Provider,
        apiKey: String,
        language: String,
        timeout: TimeInterval,
        wav: Data,
        chunkIndex: Int,
        proxyKey: String = "",
        proxyKeyHeader: String = "X-Proxy-Key"
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
        // Прокси-аутентификация (AlwaysData-прокси поверх API): только при
        // непустом proxyKey — пустой не должен уходить пустым заголовком.
        if !proxyKey.isEmpty {
            request.setValue(proxyKey, forHTTPHeaderField: proxyKeyHeader)
        }
        request.timeoutInterval = timeout
        return BatchPreparedRequest(request: request, transcriptPath: spec.transcriptPath)
    }
}