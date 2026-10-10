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

  // MARK: - Retention policy for debug audio recordings

  /// Retention policy (documented upper bound for debug-audio disk usage):
  /// keep at most `maxRecordingFiles` newest `recording-*.wav` files,
  /// at most `maxRecordingBytes` total bytes, and no file older than
  /// `maxRecordingAge`. Eviction order is deterministic: oldest first by
  /// modification date (filename tiebreak), age first, then count, then bytes.
  /// Only regular files directly inside `recordingsDirectory` whose name
  /// matches `recording-*.wav` are ever deleted; subdirectories and
  /// unexpected files are ignored. Dumping stays opt-in (debug level only).
  public static var maxRecordingFiles: Int = 20
  public static var maxRecordingBytes: Int64 = 50 * 1024 * 1024
  public static var maxRecordingAge: TimeInterval = 7 * 24 * 3600

  /// Filename prefix for managed debug recordings.
  public static var recordingsFilePrefix: String = "recording-"

  /// One managed recording candidate for pure pruning planning (no I/O).
  public struct RecordingEntry {
    public let name: String
    public let modificationDate: Date
    public let byteCount: Int64

    public init(name: String, modificationDate: Date, byteCount: Int64) {
      self.name = name
      self.modificationDate = modificationDate
      self.byteCount = byteCount
    }
  }

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
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else if !fileManager.fileExists(atPath: fileURL.path) {
      try? data.write(to: fileURL)
    }
  }

  /// Save WAV to `path`, creating dir as needed. Never throws —
  /// failures only logged; must not break transcription.
  /// On success, schedules background retention pruning when the saved file
  /// lives inside `recordingsDirectory` (async, off the caller thread, so a
  /// realtime audio callback is never blocked by cleanup).
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
    } catch {
      Logger.log(
        L10n.tr("debug.recordingSaveFailed")
          .replacingOccurrences(of: "{path}", with: path)
          .replacingOccurrences(of: "{error}", with: "\(error)"),
        level: "error"
      )
      return
    }

    if isPathInsideRecordingsDirectory(path) {
      scheduleRecordingsPruning()
    }
  }

  // MARK: - Retention pruning (never escapes recordings directory)

  /// Pure pruning plan: names to delete, in deletion order (oldest first).
  /// Age eviction first (`now - mtime > maxAge`; exactly `maxAge` is kept),
  /// then count (`> maxFiles`), then total bytes (`> maxBytes`).
  /// Negative limits are clamped to zero. Deterministic for equal dates via
  /// filename tiebreak.
  public static func plannedDeletions(
    entries: [RecordingEntry],
    now: Date,
    maxFiles: Int,
    maxBytes: Int64,
    maxAge: TimeInterval
  ) -> [String] {
    let effectiveMaxFiles = max(0, maxFiles)
    let effectiveMaxBytes = max(0, maxBytes)
    let effectiveMaxAge = max(0, maxAge)
    let sorted = entries.sorted {
      if $0.modificationDate != $1.modificationDate {
        return $0.modificationDate < $1.modificationDate
      }
      return $0.name < $1.name
    }
    var toDelete: [String] = []
    var survivors = sorted
    // Age first.
    survivors = survivors.filter { entry in
      if now.timeIntervalSince(entry.modificationDate) > effectiveMaxAge {
        toDelete.append(entry.name)
        return false
      }
      return true
    }
    // Count.
    while survivors.count > effectiveMaxFiles {
      toDelete.append(survivors.removeFirst().name)
    }
    // Total bytes.
    var total = survivors.reduce(Int64(0)) { $0 + max(0, $1.byteCount) }
    while total > effectiveMaxBytes, let oldest = survivors.first {
      survivors.removeFirst()
      toDelete.append(oldest.name)
      total -= max(0, oldest.byteCount)
    }
    return toDelete
  }

  /// Expanded + standardized recordings directory for safe path comparison.
  public static func expandedRecordingsDirectory() -> String {
    ((recordingsDirectory as NSString).expandingTildeInPath as NSString).standardizingPath
  }

  /// True when `path` resolves inside the dedicated recordings directory.
  /// Used to guarantee cleanup never escapes that directory.
  public static func isPathInsideRecordingsDirectory(_ path: String) -> Bool {
    let dir = expandedRecordingsDirectory()
    let standardized = ((path as NSString).expandingTildeInPath as NSString).standardizingPath
    return standardized != dir && standardized.hasPrefix(dir + "/")
  }

  /// Schedules retention pruning on a background queue (outside any realtime
  /// audio callback). Snapshots directory + limits so later config changes
  /// cannot redirect cleanup. Never throws; failures are logged inside prune.
  public static func scheduleRecordingsPruning() {
    let directory = recordingsDirectory
    let maxFiles = maxRecordingFiles
    let maxBytes = maxRecordingBytes
    let maxAge = maxRecordingAge
    DispatchQueue.global(qos: .utility).async {
      pruneRecordings(in: directory, now: Date(), maxFiles: maxFiles, maxBytes: maxBytes, maxAge: maxAge)
    }
  }

  /// Synchronous retention cleanup inside `recordingsDirectory`. Never throws
  /// and never fails transcription: errors are logged only. Only managed
  /// `recording-*.wav` regular files directly inside the directory are
  /// candidates; subdirectories and unexpected files are left untouched.
  public static func pruneRecordings(now: Date = Date()) {
    pruneRecordings(
      in: recordingsDirectory, now: now,
      maxFiles: maxRecordingFiles, maxBytes: maxRecordingBytes, maxAge: maxRecordingAge)
  }

  /// Snapshot overload used by the background scheduler (and tests).
  public static func pruneRecordings(
    in directory: String, now: Date, maxFiles: Int, maxBytes: Int64, maxAge: TimeInterval
  ) {
    let fileManager = FileManager.default
    let expandedDir = ((directory as NSString).expandingTildeInPath as NSString).standardizingPath
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: expandedDir, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return }
    let names: [String]
    do {
      names = try fileManager.contentsOfDirectory(atPath: expandedDir)
    } catch {
      Logger.log(
        L10n.tr("debug.recordingPruneFailed")
          .replacingOccurrences(of: "{dir}", with: expandedDir)
          .replacingOccurrences(of: "{error}", with: "\(error)"),
        level: "error"
      )
      return
    }
    var entries: [RecordingEntry] = []
    for name in names {
      // Never follow paths that could escape: flat names only.
      guard !name.contains("/"), !name.contains("\0"), name != ".", name != ".." else { continue }
      guard name.hasPrefix(recordingsFilePrefix), name.hasSuffix(".wav") else { continue }
      let fullPath = (expandedDir as NSString).appendingPathComponent(name)
      let standardized = (fullPath as NSString).standardizingPath
      // Ownership guard: candidate must stay inside the dedicated directory.
      guard standardized.hasPrefix(expandedDir + "/") else { continue }
      var isDir: ObjCBool = false
      guard fileManager.fileExists(atPath: standardized, isDirectory: &isDir), !isDir.boolValue else {
        continue
      }
      guard
        let attributes = try? fileManager.attributesOfItem(atPath: standardized),
        let mtime = attributes[.modificationDate] as? Date
      else { continue }
      let sizeValue = (attributes[.size] as? NSNumber)?.int64Value ?? 0
      entries.append(RecordingEntry(name: name, modificationDate: mtime, byteCount: sizeValue))
    }
    let deletions = plannedDeletions(
      entries: entries, now: now, maxFiles: maxFiles, maxBytes: maxBytes, maxAge: maxAge)
    for name in deletions {
      let fullPath = (expandedDir as NSString).appendingPathComponent(name)
      let standardized = (fullPath as NSString).standardizingPath
      guard standardized.hasPrefix(expandedDir + "/") else { continue }
      do {
        try fileManager.removeItem(atPath: standardized)
      } catch {
        Logger.log(
          L10n.tr("debug.recordingPruneFailed")
            .replacingOccurrences(of: "{dir}", with: expandedDir)
            .replacingOccurrences(of: "{error}", with: "\(error)"),
          level: "error"
        )
      }
    }
  }
}
