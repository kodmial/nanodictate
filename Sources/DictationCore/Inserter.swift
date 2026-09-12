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

    // MARK: - Private

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