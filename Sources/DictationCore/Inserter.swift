import AppKit
import CoreGraphics
import Darwin

// MARK: - TextRefinement

public enum TextRefinement {

    /// Капитализация первой буквы предложения; если предложение не
    /// заканчивается знаком препинания — добавить точку.
    public static func finalize(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        var result = trimmed

        // Capitalize the first symbol (word-safe for Cyrillic).
        if let first = result.first {
            let upper = String(first).uppercased()
            result.replaceSubrange(result.startIndex...result.startIndex,
                                   with: upper)
        }

        // Append a period if the text does not end with sentence punctuation.
        if let last = result.last,
           !".!?…".contains(last) {
            result.append(".")
        }

        return result
    }
}

// MARK: - Inserter

public enum Inserter {

    /// Размер пачки символов/backspace'ов между паузами (вставки и отката).
    static let chunkSize = 16
    private static let delayUSec: useconds_t = 5000 // 5 мс

    /// Тестовые хуки (internal, видны через @testable): подменяют побочные
    /// эффекты — сон между пачками и post CGEvent-ов. В production не
    /// выставляются; нужны юнит-тесту, чтобы посчитать число пауз/событий
    /// и не печатать в активное приложение. Не синхронизированы: тесты
    /// однопоточные.
    static var sleepHook: ((useconds_t) -> Void)?
    static var postHook: ((CGEvent, CGEventTapLocation) -> Void)?

    /// Вставить текст через CGEvent keyDown/keyUp с
    /// keyboardSetUnicodeString, пакетами по chunkSize символов.
    /// Пауза 5 мс — только между пачками (не на каждый символ).
    public static func insert(text: String) {
        guard !text.isEmpty else { return }

        let source = CGEventSource(stateID: .hidSystemState)

        let chars = Array(text)
        var offset = 0

        while offset < chars.count {
            let end = min(offset + chunkSize, chars.count)
            let chunk = String(chars[offset..<end])
            sendChunk(chunk, source: source)
            offset = end

            if offset < chars.count {
                sleepAWhile(delayUSec)
            }
        }
    }

    // MARK: - Откат (undo)

    /// Стереть ровно столько графем, сколько было вставлено: backspace
    /// (virtualKey 51 / kVK_Delete) по числу символов — симметричный откат
    /// к `insert(text:)` с той же паузой 5 мс. Пауза — между пачками по
    /// chunkSize символов (как в insert), а НЕ на каждый символ: длинное
    /// undo (~500–1000 графем) не блокирует главный поток агента на секунды
    /// (было ~count пауз по 5 мс — стало ~count/16). count = 0 — no-op;
    /// отрицательные безопасно обрезаются до no-op.
    ///
    /// Ограничение подхода: undo бьёт backspace'ами по текущей позиции
    /// курсора / фронт-аппу. Если за время между вставкой и откатом курсор
    /// уехал или активное приложение сменилось — сотрётся не то, что
    /// вставили.
    public static func delete(characters: String) {
        delete(count: characters.count)
    }

    public static func delete(count: Int) {
        guard count > 0 else { return }
        let source = CGEventSource(stateID: .hidSystemState)
        var remaining = count
        while remaining > 0 {
            let batch = min(remaining, chunkSize)
            pressBackspace(batch, source: source)
            remaining -= batch
            // Пауза только между пачками, после последней — нет (как в insert).
            if remaining > 0 {
                sleepAWhile(delayUSec)
            }
        }
    }

    // MARK: - Private

    private static func sendChunk(_ chunk: String, source: CGEventSource?) {
        let utf16 = Array(chunk.utf16)

        // keyDown
        if let keyDown = CGEvent(keyboardEventSource: source,
                                 virtualKey: 0,
                                 keyDown: true) {
            keyDown.keyboardSetUnicodeString(stringLength: utf16.count,
                                             unicodeString: utf16)
            post(keyDown, tap: .cghidEventTap)
        }

        // keyUp
        if let keyUp = CGEvent(keyboardEventSource: source,
                               virtualKey: 0,
                               keyDown: false) {
            keyUp.keyboardSetUnicodeString(stringLength: utf16.count,
                                           unicodeString: utf16)
            post(keyUp, tap: .cghidEventTap)
        }
    }

    /// Отправить `times` нажатий backspace (keyDown + keyUp каждое).
    private static func pressBackspace(_ times: Int, source: CGEventSource?) {
        for _ in 0..<times {
            // keyDown
            if let keyDown = CGEvent(keyboardEventSource: source,
                                     virtualKey: 51,
                                     keyDown: true) {
                post(keyDown, tap: .cghidEventTap)
            }
            // keyUp
            if let keyUp = CGEvent(keyboardEventSource: source,
                                  virtualKey: 51,
                                  keyDown: false) {
                post(keyUp, tap: .cghidEventTap)
            }
        }
    }

    private static func sleepAWhile(_ usec: useconds_t) {
        if let hook = sleepHook {
            hook(usec)
        } else {
            usleep(usec)
        }
    }

    private static func post(_ event: CGEvent, tap: CGEventTapLocation) {
        if let hook = postHook {
            hook(event, tap)
        } else if RuntimeEnvironment.isTestRun {
            // Тестовый раннер в активное приложение не печатает.
        } else {
            event.post(tap: tap)
        }
    }
}

// MARK: - Вставка выбранным способом (insert_method)

extension Inserter {

    /// Вставить текст выбранным способом.
    /// - `.cgevent`: прежний путь — прямая эмуляция клавиатуры (прод-дефолт).
    /// - `.clipboard`: через буфер обмена с Cmd+V и восстановлением старого буфера.
    public static func insert(text: String, method: InsertMethod) {
        insert(text: text, method: method, bridge: .default)
    }

    /// Тестовая расшифровка: тот же выбор ветки, но с инжектированным мостом
    /// буфера обмена (закрывает и путь `.clipboard`, и ветку над `cgEventInsertOverride`).
    internal static func insert(text: String, method: InsertMethod, bridge: ClipboardInsertBridge) {
        switch method {
        case .cgevent:
            if let override = cgEventInsertOverride {
                override(text)
            } else {
                insert(text: text)
            }
        case .clipboard:
            insertViaClipboard(text: text, bridge: bridge)
        }
    }

    /// Тестовый хук: переопределяется в тестах, чтобы `.cgevent`-ветка не постила
    /// реальные CGEvent в сфокусированное приложение. В проде nil — прежнее поведение.
    internal static var cgEventInsertOverride: ((String) -> Void)?
}

// MARK: - Вставка через буфер обмена

/// Мост к буферу обмена; все операции инжектятся для тестов (никакого реального
/// NSPasteboard/CGEvent). `.default` — реальная реализация для прода.
public struct ClipboardInsertBridge {

    /// Чтение текущего содержимого буфера (nil — буфер пуст).
    public var readClipboard: () -> String?
    /// Запись текста в буфер обмена (пустая строка = очистить).
    public var writeClipboard: (String) -> Void
    /// Эмуляция Cmd+V.
    public var sendPaste: () -> Void
    /// Задержка перед восстановлением старого буфера (сек; по умолчанию 0.5).
    public var restoreDelay: TimeInterval
    /// Отложенное выполнение восстановления.
    public var scheduleRestore: (@escaping () -> Void, TimeInterval) -> Void

    public init(
        readClipboard: @escaping () -> String? = ClipboardInsertBridge.defaultReadClipboard,
        writeClipboard: @escaping (String) -> Void = ClipboardInsertBridge.defaultWriteClipboard,
        sendPaste: @escaping () -> Void = ClipboardInsertBridge.defaultSendPaste,
        restoreDelay: TimeInterval = 0.5,
        scheduleRestore: @escaping (@escaping () -> Void, TimeInterval) -> Void = ClipboardInsertBridge.defaultScheduleRestore
    ) {
        self.readClipboard = readClipboard
        self.writeClipboard = writeClipboard
        self.sendPaste = sendPaste
        self.restoreDelay = restoreDelay
        self.scheduleRestore = scheduleRestore
    }

    /// Реальная реализация (прод): NSPasteboard + CGEvent Cmd+V + async-восстановление.
    public static var `default`: ClipboardInsertBridge {
        ClipboardInsertBridge()
    }

    // MARK: Дефолтные реализации

    public static func defaultReadClipboard() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    public static func defaultWriteClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if !text.isEmpty {
            pasteboard.setString(text, forType: .string)
        }
    }

    /// Cmd+V (kVK_ANSI_V = 9) по hidSystemState.
    public static func defaultSendPaste() {
        let source = CGEventSource(stateID: .hidSystemState)
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) {
            keyDown.flags = .maskCommand
            keyDown.post(tap: .cghidEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) {
            keyUp.flags = .maskCommand
            keyUp.post(tap: .cghidEventTap)
        }
    }

    public static func defaultScheduleRestore(_ restore: @escaping () -> Void, delay: TimeInterval) {
        DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: restore)
    }
}

extension Inserter {

    /// Вставить текст через буфер обмена: сохранить текущий буфер → записать
    /// текст → Cmd+V → восстановить старый буфер через `restoreDelay` (~0.5 c).
    public static func insertViaClipboard(
        text: String,
        bridge: ClipboardInsertBridge = .default
    ) {
        guard !text.isEmpty else { return }
        let old = bridge.readClipboard()
        bridge.writeClipboard(text)
        bridge.sendPaste()
        let restore: () -> Void = {
            if let old = old {
                bridge.writeClipboard(old)
            } else {
                bridge.writeClipboard("")
            }
        }
        bridge.scheduleRestore(restore, bridge.restoreDelay)
    }
}