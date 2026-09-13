import Foundation

// MARK: - Отладочный дамп STT-запросов

/// Сборка и запись отладочного лога транскрибации (`transcriber-debug.log`).
///
/// Включается уровнем лога `debug` (см. `Transcriber.logLevel`). Логика сборки
/// записи — чистая функция `summarize(...)` без I/O; враппер `append(entry:)`
/// только дописывает готовый текст в конец файла. При `debug` сырые байты аудио
/// дополнительно сохраняются в `recordingsDirectory` как `recording-*.wav`.
///
/// Секреты маскируются всегда: `Authorization` → `Bearer ***`,
/// `X-Proxy-Key` → `***`, в теле ответа затираются значения вложенных ключей
/// `api_key` / `proxy_key` / `authorization`.
public enum DebugDump {

    /// Каталог отладочного лога; `~` раскрывается автоматически.
    /// По умолчанию совпадает с каталогом `Logger` — `~/Library/Logs/Dictation`.
    public static var dumpDirectory: String = "~/Library/Logs/Dictation"

    /// Имя файла отладочного лога транскрибации.
    public static var dumpFileName: String = "transcriber-debug.log"

    /// Каталог сохранения аудиозаписей (`recording-*.wav`). Пишутся только при
    /// `log_level == "debug"` и только сами сырые байты WAV. Каталог создаётся
    /// автоматически при записи.
    public static var recordingsDirectory: String = "~/Library/Logs/Dictation/recordings"

    private static let lock = NSLock()

    /// Метаданные file-парта multipart-запроса (сырые байты не сохраняются).
    public struct FilePart {
        public let fieldName: String
        public let filename: String
        public let contentType: String
        public let byteCount: Int

        public init(fieldName: String, filename: String, contentType: String, byteCount: Int) {
            self.fieldName = fieldName
            self.filename = filename
            self.contentType = contentType
            self.byteCount = byteCount
        }
    }

    /// Информация о сохранённой аудиозаписи (путь на диске + размер в байтах).
    /// Попадает в запись дампа, если при `debug` WAV был сохранён.
    public struct RecordingInfo {
        public let path: String
        public let byteCount: Int

        public init(path: String, byteCount: Int) {
            self.path = path
            self.byteCount = byteCount
        }
    }

    // MARK: - Маскирование

    /// Маскирует значение заголовка по имени (сравнение без учёта регистра).
    /// Authorization маскируется целиком: `Bearer ***`; X-Proxy-Key: `***`.
    public static func maskedHeaderValue(name: String, value: String) -> String {
        switch name.lowercased() {
        case "authorization":
            return "Bearer ***"
        case "x-proxy-key":
            return "***"
        default:
            return value
        }
    }

    /// Маскирует секретные ключи в теле ответа (обычно JSON). Тело сохраняется
    /// как есть, кроме значений ключей `api_key` / `proxy_key` / `authorization`,
    /// которые заменяются на `***`. Не-JSON текст тоже обрабатывается регуляркой.
    /// Никогда не бросает; непредставимый текст возвращается как пустая строка.
    public static func maskedResponseBody(_ data: Data) -> String {
        guard data.count > 0, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return ""
        }
        let secretKeys = ["api_key", "proxy_key", "authorization"]
        var result = text
        for key in secretKeys {
            let pattern = "\"\(key)\"\\s*:\\s*\"[^\"]*\""
            result = result.replacingOccurrences(
                of: pattern,
                with: "\"\(key)\": \"***\"",
                options: [.regularExpression]
            )
        }
        return result
    }

    // MARK: - Имена файлов аудиозаписей (чистые функции, без I/O)

    /// Имя файла аудиозаписи для даты: `recording-<yyyyMMdd-HHmmss-SSS>.wav`.
    /// Миллисекунды в имени — защита от коллизий при нескольких записях в одну
    /// секунду.
    public static func recordingFileName(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return "recording-\(formatter.string(from: date)).wav"
    }

    /// Полный путь к файлу аудиозаписи для даты: `recordingsDirectory` + имя.
    public static func recordingPath(for date: Date) -> String {
        let dir = (recordingsDirectory as NSString).expandingTildeInPath
        return (dir as NSString).appendingPathComponent(recordingFileName(for: date))
    }

    // MARK: - Сборка записи (чистая функция, без I/O)

    /// Собирает текст одной записи отладочного лога: запрос (метод, URL,
    /// заголовки с маскировкой, form-поля, метаданные file-парта) и ответ
    /// (HTTP-статус + тело целиком с маскировкой секретов). Если ответа нет
    /// (`status`/`responseBody` = nil — транспортная ошибка до HTTP), в секции
    /// ответа пишется `(no response — transport error)`.
    public static func summarize(
        timestamp: Date = Date(),
        method: String,
        url: String,
        headers: [(name: String, value: String)],
        fields: [(name: String, value: String)],
        filePart: FilePart?,
        recording: RecordingInfo? = nil,
        status: Int?,
        responseBody: Data?
    ) -> String {
        var lines: [String] = []

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        lines.append(formatter.string(from: timestamp))

        lines.append("=== STT Request ===")
        lines.append("\(method.isEmpty ? "-" : method) \(url)")
        lines.append("Headers:")
        if headers.isEmpty {
            lines.append("  (none)")
        }
        for header in headers.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }) {
            lines.append("  \(header.name): \(maskedHeaderValue(name: header.name, value: header.value))")
        }
        lines.append("Multipart fields:")
        if fields.isEmpty {
            lines.append("  (none)")
        }
        for field in fields {
            lines.append("  \(field.name) = \(field.value)")
        }
        if let filePart = filePart {
            lines.append("File part:")
            lines.append("  name = \(filePart.fieldName)")
            lines.append("  filename = \(filePart.filename)")
            lines.append("  content-type = \(filePart.contentType)")
            lines.append("  size = \(filePart.byteCount) bytes")
        } else {
            lines.append("File part: (none)")
        }
        if let recording = recording {
            lines.append("Saved audio:")
            lines.append("  path = \(recording.path)")
            lines.append("  size = \(recording.byteCount) bytes")
        }

        lines.append("=== STT Response ===")
        if let status = status {
            lines.append("HTTP \(status)")
            lines.append(maskedResponseBody(responseBody ?? Data()))
        } else {
            // Ответа нет: все попытки запроса упали на транспортном уровне.
            lines.append("HTTP (no response — transport error)")
        }

        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Запись в файл (враппер)

    /// Дописывает запись в `dumpDirectory/dumpFileName`. Создаёт каталог и файл
    /// при необходимости. Никогда не бросает: отладочный лог не должен ломать
    /// транскрибацию.
    public static func append(entry: String) {
        lock.lock()
        defer { lock.unlock() }

        let expanded = (dumpDirectory as NSString).expandingTildeInPath
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory) {
            do {
                try fileManager.createDirectory(atPath: expanded, withIntermediateDirectories: true)
            } catch {
                return // нет доступа — молча пропускаем
            }
        }

        guard let data = entry.data(using: .utf8) else { return }
        let fileURL = URL(fileURLWithPath: expanded).appendingPathComponent(dumpFileName)

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else if !fileManager.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL)
        }
    }

    /// Сохраняет аудиозапись (WAV) в файл по пути `path`, создавая каталог при
    /// необходимости. Никогда не бросает: ошибка записи не должна ломать
    /// транскрибацию — пишется только в `Logger`.
    public static func saveRecording(data: Data, to path: String) {
        lock.lock()
        defer { lock.unlock() }

        guard data.count > 0 else { return }
        let fileURL = URL(fileURLWithPath: path)
        let fileManager = FileManager.default

        do {
            try fileManager.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fileURL)
        } catch {
            Logger.log("Не удалось сохранить аудиозапись \(path): \(error)", level: "error")
        }
    }
}