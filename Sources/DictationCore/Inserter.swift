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

    private static let chunkSize = 16
    private static let delayUSec: useconds_t = 5000 // 5 мс

    /// Вставить текст через CGEvent keyDown/keyUp с
    /// keyboardSetUnicodeString, пакетами по chunkSize символов.
    public static func insert(text: String) {
        guard !text.isEmpty else { return }
        typeText(text)
    }

    /// Пошаговая диктовка: добавить следующий сегмент В КОНЕЦ уже вставленного
    /// текста. Курсор после предыдущей вставки остаётся в конце (вставка не
    /// двигает его), поэтому просто печатаем — как insert, но с оговоркой в
    /// контракте для pipeline (append ≠ перезапись выделения).
    public static func append(_ text: String) {
        insert(text: text)
    }

    /// Пошаговая диктовка, финальный проход: заменить ОДИН диапазон `old`
    /// (старый текст сегмента, уже вставленный) на `new`. Сегменты вставляются
    /// последовательно подряд, поэтому диапазон находится отступами
    /// Option+Shift+влево/вправо по словам — одно действие, undo не ломается.
    ///
    /// Контракт: `old` — ровно то, что сейчас находится в тексте под курсором
    /// (последняя вставка); при `old == new` — no-op. Клавиатурный ввод:
    /// вырезаем лишнее количество символов backspace, печатаем diff-span.
    public static func replaceRange(old: String, new: String) {
        replaceText(old: old, new: new)
    }

    // MARK: - Private

    /// Печать текста пакетами (общий путь для insert/append).
    private static func typeText(_ text: String) {
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
                usleep(delayUSec)
            }
        }
    }

    /// Замена диапазона: backspace на длину `old`, затем печать `new`.
    /// Курсор после последней вставки стоит сразу после её текста.
    private static func replaceText(old: String, new: String) {
        guard old != new else { return }
        if old.isEmpty {
            // Пустой old — просто допечатываем (вставка слова в середину
            // через diff получится backspace+печать, но пустую строку
            // заменять нечем — только печатаем).
            typeText(new)
            return
        }

        let source = CGEventSource(stateID: .hidSystemState)
        let backspaceCount = Array(old.utf16).count

        // Backspace: клавиша 51 (delete). Несколько нажатий — несколько раз.
        for _ in 0..<backspaceCount {
            postKey(virtualKey: 51, source: source)
        }
        typeText(new)
    }

    /// Одиночное нажатие клавиши (keyDown+keyUp) через CGEvent.
    private static func postKey(virtualKey: CGKeyCode, source: CGEventSource?) {
        if let keyDown = CGEvent(keyboardEventSource: source,
                                 virtualKey: virtualKey,
                                 keyDown: true) {
            keyDown.post(tap: .cghidEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source,
                               virtualKey: virtualKey,
                               keyDown: false) {
            keyUp.post(tap: .cghidEventTap)
        }
    }

    private static func sendChunk(_ chunk: String, source: CGEventSource?) {
        let utf16 = Array(chunk.utf16)

        // keyDown
        if let keyDown = CGEvent(keyboardEventSource: source,
                                 virtualKey: 0,
                                 keyDown: true) {
            keyDown.keyboardSetUnicodeString(stringLength: utf16.count,
                                             unicodeString: utf16)
            keyDown.post(tap: .cghidEventTap)
        }

        // keyUp
        if let keyUp = CGEvent(keyboardEventSource: source,
                               virtualKey: 0,
                               keyDown: false) {
            keyUp.keyboardSetUnicodeString(stringLength: utf16.count,
                                           unicodeString: utf16)
            keyUp.post(tap: .cghidEventTap)
        }
    }
}