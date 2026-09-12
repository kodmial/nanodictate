//
//  SysSounds.swift
//  DictationCore
//
//  Короткие системные звуки начала/окончания диктовки + файловый логгер.
//  Только AppKit + AudioToolbox + Foundation (macOS 12, Swift 5.7).
//
//  SystemSoundID (macOS, безопасный набор):
//    start  = 1103 — "Tink"   (KeyPressed / Tink.caf)
//    end    = 1053 — "Pop"    (короткий акцент успеха)
//    cancel = 1006 — default alert beep
//  Если ID не сработает — AudioServices молча его игнорирует, падать не будем.
//

import AudioToolbox
import Foundation

// MARK: - Системные звуки

/// Воспроизводит короткие системные звуки macOS через AudioServices.
public final class SysSounds {

    /// `enabled == false` — полностью молчит.
    public var enabled: Bool

    private static let startSoundID: SystemSoundID = 1103
    private static let endSoundID: SystemSoundID = 1053
    private static let cancelSoundID: SystemSoundID = 1006

    private let lock = NSLock()

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }

    /// Начало диктовки.
    public func playStart() {
        play(Self.startSoundID)
    }

    /// Удачное завершение (текст вставлен).
    public func playEnd() {
        play(Self.endSoundID)
    }

    /// Отмена (Esc).
    public func playCancel() {
        play(Self.cancelSoundID)
    }

    private func play(_ soundID: SystemSoundID) {
        guard enabled else { return }
        lock.lock()
        defer { lock.unlock() }
        AudioServicesPlaySystemSound(soundID)
    }
}

// MARK: - Логгер

/// Простейший потокобезопасный файловый логгер: append в `<logDirectory>/agent.log`.
public enum Logger {

    /// Каталог логов; `~` раскрывается автоматически.
    public static var logDirectory: String = "~/Library/Logs/Dictation"

    private static let lock = NSLock()

    /// Пишет строку `yyyy-MM-dd HH:mm:ss [level] message` в конец agent.log.
    /// Создаёт каталог и файл при необходимости. Никогда не бросает исключений.
    public static func log(_ message: String, level: String = "info") {
        lock.lock()
        defer { lock.unlock() }

        let expanded = (logDirectory as NSString).expandingTildeInPath
        let fileManager = FileManager.default

        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory) {
            do {
                try fileManager.createDirectory(atPath: expanded, withIntermediateDirectories: true)
            } catch {
                return // нет доступа к каталогу логов — молча пропускаем
            }
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let line = "\(formatter.string(from: Date())) [\(level)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }

        let fileURL = URL(fileURLWithPath: expanded).appendingPathComponent("agent.log")

        if let handle = try? FileHandle(forWritingTo: fileURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else if !fileManager.fileExists(atPath: fileURL.path) {
            try? data.write(to: fileURL)
        }
    }
}