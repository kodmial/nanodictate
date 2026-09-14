//
//  SysSounds.swift
//  DictationCore
//
//  Короткие системные звуки начала/окончания диктовки + файловый логгер.
//  Только AppKit + Foundation (macOS 12, Swift 5.7).
//
//  Звуки берутся из системных звуков macOS через NSSound(named:):
//  файлы лежат в /System/Library/Sounds/*.aiff (Tink, Pop, Ping и др.).
//  Числовые SystemSoundID из iOS-каталога macOS молча игнорирует,
//  поэтому играем именно через NSSound.
//
//  Защита от повторного переигрывания: перед play() останавливаем предыдущее
//  воспроизведение (NSSound.stop), а если запрошен тот же самый звук и он ещё
//  играет (NSSound.isPlaying) — повторно не запускаем, чтобы не накладывать
//  звук сам на себя (перезапуск того же звука допустим только после того,
//  как он завершился).
//

import AppKit
import Foundation

// MARK: - Системные звуки

/// Воспроизводит короткие системные звуки macOS через NSSound.
public final class SysSounds {

    /// `enabled == false` — полностью молчит.
    public var enabled: Bool

    /// Системные звуки macOS (имена файлов без расширения из /System/Library/Sounds).
    private static let startSoundName = "Tink"
    private static let endSoundName = "Pop"
    private static let cancelSoundName = "Ping"
    /// Классический «звук ошибки» macOS — для сетевых сбоев (нет интернета /
    /// таймаут STT).
    private static let errorSoundName = "Basso"

    // MARK: Новые кейсы (быстрые UX-победы). Каждый — отдельный кейс с дефолтным
    // поведением: существующие кейсы/методы (start/end/cancel/error) НЕ меняются.

    /// Звук успешного завершения ПОСЛЕ вставки текста. Дефолт — тот же Pop,
    /// что у playEnd, но отдельный кейс/метод: новая очередь «вставка → звук»
    /// закреплена за ним, старый playEnd не трогается.
    private static let completionAfterInsertSoundName = "Pop"
    /// Звук «пустого результата»: STT вернул меньше двух слов — текст не
    /// вставляем, вместо успеха играем Funk (не Basso — это не ошибка).
    private static let emptyResultSoundName = "Funk"
    /// Звук отката последней вставки (undo двойным Alt).
    private static let undoSoundName = "Pop"

    // Ленивый кэш: NSSound создаётся один раз на имя и переиспользуется.
    private var startSound: NSSound?
    private var endSound: NSSound?
    private var cancelSound: NSSound?
    private var errorSound: NSSound?
    /// Кэш остальных имён (новые кейсы вроде "Funk", а также "Pop" как
    /// completionAfterInsert/undo): один NSSound на имя, как у четырёх старых.
    private var otherSounds: [String: NSSound] = [:]

    /// Звук, который сейчас играет (останавливаем его при смене звука).
    private var playingSound: NSSound?

    /// Имя звука, помеченного играющим (internal — читается тестами).
    internal private(set) var playingName: String?

    /// Метка последнего запрошенного звука (start/end/cancel/error/
    /// completionAfterInsert/emptyResult/undo). Даёт тестам различать разные
    /// кейсы с одним и тем же звуком ("Pop" у end и completionAfterInsert),
    /// тогда как playingName хранит только имя файла.
    internal private(set) var lastPlayedLabel: String?

    private let lock = NSLock()

    public init(enabled: Bool = true) {
        self.enabled = enabled
    }

    /// Начало диктовки.
    public func playStart() {
        play(Self.startSoundName, label: "start")
    }

    /// Удачное завершение (текст вставлен).
    public func playEnd() {
        play(Self.endSoundName, label: "end")
    }

    /// Отмена (Esc).
    public func playCancel() {
        play(Self.cancelSoundName, label: "cancel")
    }

    /// Ошибка диктовки (нет интернета / таймаут STT).
    public func playError() {
        play(Self.errorSoundName, label: "error")
    }

    // MARK: Новые методы (UX quick wins)

    /// Звук завершения ПОСЛЕ вставки текста (а не до неё). Вызывается из
    /// completeInsertion после Inserter.insert, чтобы пользователь слышал
    /// звук только когда текст гарантированно вставлен.
    public func playCompletionAfterInsert() {
        play(Self.completionAfterInsertSoundName, label: "completionAfterInsert")
    }

    /// Звук «пустого результата»: STT вернул <2 слов — ничего не вставляем.
    /// Отдельный от ошибки микрофона (Basso): «пустота» ≠ сбой.
    public func playEmptyResult() {
        play(Self.emptyResultSoundName, label: "emptyResult")
    }

    /// Звук отката последней вставки (undo двойным Alt в пределах окна).
    public func playUndo() {
        play(Self.undoSoundName, label: "undo")
    }

    /// Защита от дублей: пропустить ли повторное воспроизведение `name`.
    /// Пропускаем только тогда, когда это тот же самый звук и он действительно
    /// ещё играет — иначе звук с тем же именем можно играть повторно.
    internal func shouldSkipReplay(of name: String, currentlyPlaying: Bool) -> Bool {
        playingName == name && currentlyPlaying
    }

    private func play(_ name: String, label: String) {
        guard enabled else { return } // enabled == false — полный no-op
        Logger.log("sounds: \(label)", level: "debug")

        // Тестовый раннер (DICTATION_TESTS=1): реальный системный звук НЕ
        // проигрываем — пользователя ничем не тревожим. Но намерение звука
        // фиксируем (playingName, lastPlayedLabel), потому что на них
        // строятся тесты: какой звук вызывается и защита от повторного
        // переигрывания. lastPlayedLabel различает кейсы с одним звуком
        // (end и completionAfterInsert оба "Pop", но разные лейблы).
        if RuntimeEnvironment.isTestRun {
            lock.lock()
            defer { lock.unlock() }
            playingSound = nil
            playingName = name
            lastPlayedLabel = label
            return
        }

        lock.lock()
        defer { lock.unlock() }

        guard let sound = sound(name: name) else {
            // Звук не найден в системном каталоге — молча пропускаем
            // (как раньше AudioServices молча игнорировал SystemSoundID).
            // Диагностика причины тишины — на уровне debug.
            Logger.log("sounds: \(name) not found in system catalog — skipped", level: "debug")
            return
        }

        // Не перезапускаем тот же звук, если он ещё играет.
        guard !shouldSkipReplay(of: name, currentlyPlaying: sound.isPlaying) else {
            return
        }

        // Звук сменился и ещё играет — останавливаем предыдущее воспроизведение.
        if let current = playingSound, current !== sound, current.isPlaying {
            current.stop()
        }

        sound.play()
        playingSound = sound
        playingName = name
        lastPlayedLabel = label
    }

    private func sound(name: String) -> NSSound? {
        switch name {
        case Self.startSoundName:
            if startSound == nil { startSound = NSSound(named: name) }
            return startSound
        case Self.endSoundName:
            if endSound == nil { endSound = NSSound(named: name) }
            return endSound
        case Self.cancelSoundName:
            if cancelSound == nil { cancelSound = NSSound(named: name) }
            return cancelSound
        case Self.errorSoundName:
            if errorSound == nil { errorSound = NSSound(named: name) }
            return errorSound
        default:
            // Новые кейсы (completionAfterInsert/undo — "Pop", emptyResult —
            // "Funk") кэшируем по имени. Старые четыре кейса выше не тронуты.
            if let cached = otherSounds[name] { return cached }
            guard let created = NSSound(named: name) else { return nil }
            otherSounds[name] = created
            return created
        }
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

        // Тестовый раннер: боевой ~/Library/Logs/Dictation/agent.log не
        // трогаем — тестовые строки уходят в /tmp/dictation-tests/agent.log.
        // Если какой-то тест сам перенаправил logDirectory (LoggerTests) —
        // уважаем его настройку.
        var effectiveDirectory = logDirectory
        if RuntimeEnvironment.isTestRun && logDirectory == "~/Library/Logs/Dictation" {
            effectiveDirectory = "/tmp/dictation-tests"
        }

        let expanded = (effectiveDirectory as NSString).expandingTildeInPath
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