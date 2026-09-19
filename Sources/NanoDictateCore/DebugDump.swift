import Foundation

// MARK: - Отладочный дамп STT-запросов

/// Debug transcription log (`transcriber-debug.log`), enabled at log level debug.
/// Entry built by pure `summarize`; `append` only writes. At debug, raw audio
/// also saved as `recording-*.wav`. Secrets always masked: Authorization → "Bearer ***",
/// headers outside safe allowlist → "***" (custom proxy_key_header names), response
/// body keys api_key/proxy_key/authorization scrubbed.
public enum DebugDump {
  /// Debug log dir; `~` expanded. Default matches Logger dir.
  public static var dumpDirectory: String = "~/Library/Logs/NanoDictate"

  public static var dumpFileName: String = "transcriber-debug.log"

  /// Audio recordings dir (`recording-*.wav`), written only at debug; created on write.
  public static var recordingsDirectory: String = "~/Library/Logs/NanoDictate/recordings"

  /// Max audio recordings kept on disk; oldest pruned on save beyond this cap.
  /// Debug audio grows fast — bound the footprint.
  private static let maxRecordings = 50

  private static let lock = NSLock()

  /// Multipart file-part metadata; raw bytes not saved.
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

  /// Saved recording (path + byte size); appears in dump when audio saved.
  public struct RecordingInfo {
    public let path: String
    public let byteCount: Int

    public init(path: String, byteCount: Int) {
      self.path = path
      self.byteCount = byteCount
    }
  }

  // MARK: - Маскирование

  /// Mask header value by name (case-insensitive). Authorization whole → "Bearer ***",
  /// X-Proxy-Key → "***". Anything outside `safeDumpHeaders` masked — secret
  /// header names may be custom (proxy_key_header).
  public static func maskedHeaderValue(name: String, value: String) -> String {
    let normalized = name.lowercased()
    switch normalized {
    case "authorization":
      return "Bearer ***"
    case "x-proxy-key":
      return "***"
    default:
      return safeDumpHeaders.contains(normalized) ? value : "***"
    }
  }

  /// Headers safe to log verbatim; everything else masked — custom proxy
  /// header (proxy_key_header) auto-masked.
  private static let safeDumpHeaders: Set<String> = [
    "accept", "accept-encoding", "accept-language", "cache-control",
    "connection", "content-length", "content-type", "host", "origin",
    "pragma", "referer", "rquid",
    // swiftlint:disable:next trailing_comma
    "user-agent",
  ]

  /// Mask secret keys in response body (api_key/proxy_key/authorization → "***");
  /// regex works on non-JSON too. Never throws; undecodable → "".
  public static func maskedResponseBody(_ data: Data) -> String {
    // String(data:encoding:) deliberate: invalid UTF-8 → nil, contract says
    // unrepresentable → "". String(decoding:as:) inserts U+FFFD — changes behavior.
    // swiftlint:disable:next non_optional_string_data_conversion
    guard !data.isEmpty, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
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

  /// Recording filename: `recording-<yyyyMMdd-HHmmss-SSS>.wav`; milliseconds
  /// avoid collisions within one second.
  public static func recordingFileName(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
    return "recording-\(formatter.string(from: date)).wav"
  }

  public static func recordingPath(for date: Date) -> String {
    let dir = (recordingsDirectory as NSString).expandingTildeInPath
    return (dir as NSString).appendingPathComponent(recordingFileName(for: date))
  }

  // MARK: - Сборка записи (чистая функция, без I/O)

  /// One log entry: request (method/url/masked headers/fields/file meta) and
  /// response (status + masked body). No response → "(no response — transport error)".
  // 7 of 10 params significant; splitting would break log entry atomicity.
  // swiftlint:disable:next function_parameter_count
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
    for header in headers.sorted(by: {
      $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
    }) {
      lines.append("  \(header.name): \(maskedHeaderValue(name: header.name, value: header.value))")
    }
    lines.append("Multipart fields:")
    if fields.isEmpty {
      lines.append("  (none)")
    }
    for field in fields {
      lines.append("  \(field.name) = \(field.value)")
    }
    if let filePart {
      lines.append("File part:")
      lines.append("  name = \(filePart.fieldName)")
      lines.append("  filename = \(filePart.filename)")
      lines.append("  content-type = \(filePart.contentType)")
      lines.append("  size = \(filePart.byteCount) bytes")
    } else {
      lines.append("File part: (none)")
    }
    if let recording {
      lines.append("Saved audio:")
      lines.append("  path = \(recording.path)")
      lines.append("  size = \(recording.byteCount) bytes")
    }

    lines.append("=== STT Response ===")
    if let status {
      lines.append("HTTP \(status)")
      lines.append(maskedResponseBody(responseBody ?? Data()))
    } else {
      lines.append("HTTP (no response — transport error)")
    }

    return lines.joined(separator: "\n") + "\n"
  }

  // MARK: - Запись в файл (враппер)

  /// Append entry to `dumpDirectory/dumpFileName`; creates dir/file as needed.
  /// Never throws — debug log must not break transcription.
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
        return  // no access — skip silently
      }
    }

    guard let data = entry.data(using: .utf8) else { return }
    let fileURL = URL(fileURLWithPath: expanded).appendingPathComponent(dumpFileName)

    if let handle = try? FileHandle(forWritingTo: fileURL) {
      defer { try? handle.close() }
      // Debug-лог секретосодержащий (маскированные заголовки): приводим к 0600
      // и на аппенде — файлы, созданные до этого фикса, могли остаться шире.
      try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
      handle.seekToEndOfFile()
      handle.write(data)
    } else if !fileManager.fileExists(atPath: fileURL.path) {
      // Создание: 0600 (как config/plist).
      try? data.write(to: fileURL)
      try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
  }

  /// Save WAV to `path`, creating dir as needed. Never throws —
  /// failures only logged; must not break transcription. Recording restricted
  /// to owner (0600); oldest pruned when `maxRecordings` exceeded.
  public static func saveRecording(data: Data, to path: String) {
    lock.lock()
    defer { lock.unlock() }

    guard !data.isEmpty else { return }
    let fileURL = URL(fileURLWithPath: path)
    let fileManager = FileManager.default

    do {
      try fileManager.createDirectory(
        at: fileURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
      )
      try data.write(to: fileURL)
      // Запись — речь пользователя: только владелец (0600).
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    } catch {
      Logger.log(
        L10n.tr("debug.recordingSaveFailed")
          .replacingOccurrences(of: "{path}", with: path)
          .replacingOccurrences(of: "{error}", with: "\(error)"),
        level: "error"
      )
    }
    pruneRecordings(fileManager: fileManager)
  }

  /// Remove oldest `recording-*.wav` when the directory exceeds
  /// `maxRecordings`. Filenames are timestamp-prefixed, so lexicographic order
  /// equals chronological. Best-effort — never throws.
  private static func pruneRecordings(fileManager: FileManager) {
    let dir = (recordingsDirectory as NSString).expandingTildeInPath
    guard
      let urls = try? fileManager.contentsOfDirectory(
        at: URL(fileURLWithPath: dir, isDirectory: true),
        includingPropertiesForKeys: nil
      )
    else { return }
    let names = urls
      .map { $0.lastPathComponent }
      .filter { $0.hasPrefix("recording-") && $0.hasSuffix(".wav") }
      .sorted()
    guard names.count > maxRecordings else { return }
    for name in names.prefix(names.count - maxRecordings) {
      try? fileManager.removeItem(atPath: (dir as NSString).appendingPathComponent(name))
    }
  }
}
