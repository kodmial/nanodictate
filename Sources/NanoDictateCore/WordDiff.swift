import Foundation

// MARK: - По-словный diff для финального прохода пошаговой диктовки
//
// Сравнивает уже-вставленный (чанками) текст с финальным текстом всего WAV и
// выделяет ОДИН непрерывный диапазон изменений (префикс/суффикс по общим
// словам, как рекурсивный LCS по словам). Один диапазон — одно клавиатурное
// действие в конце вставленного текста: undo пользователя не ломается.
//
// Гранулярность — слова: даже точечная правка внутри слова целиком меняет это
// слово («карова» → «корова» заменяет слово). Это намеренно: на клавиатуре
// проще заменить целое слово, чем попасть в одну букву.

public enum WordDiff {

    /// Результат diff: изменённый диапазон + «хвосты» для одного действия
    /// replaceRange (backspace хвоста старого текста, печать хвоста нового).
    public struct Change: Equatable {
        /// Вставленный (чанками) текст.
        public let oldText: String
        /// Финальный текст (весь WAV одним запросом).
        public let newText: String

        /// Только изменённые слова старого текста (между общим префиксом и
        /// общим суффиксом), через один пробел. Пусто — чистая вставка.
        public let spanOld: String
        /// Изменённые слова нового текста. Пусто — чистое удаление.
        public let spanNew: String
        /// Символьный offset начала расхождения в `oldText` (после общего
        /// префикса) — для расчёта количества backspace.
        public let spanStartOld: Int
        /// Символьный offset начала расхождения в `newText`.
        public let spanStartNew: Int

        /// Хвост старого текста от начала расхождения до конца: ровно то, что
        /// уйдёт под backspace (одно действие).
        public var tailOld: String {
            String(oldText[oldText.index(oldText.startIndex, offsetBy: spanStartOld)...])
        }
        /// Хвост нового текста от начала расхождения до конца: что печатать.
        public var tailNew: String {
            String(newText[newText.index(newText.startIndex, offsetBy: spanStartNew)...])
        }

        public init(oldText: String, newText: String, spanOld: String, spanNew: String,
                    spanStartOld: Int, spanStartNew: Int) {
            self.oldText = oldText
            self.newText = newText
            self.spanOld = spanOld
            self.spanNew = spanNew
            self.spanStartOld = spanStartOld
            self.spanStartNew = spanStartNew
        }
    }

    /// По-словный diff между вставленным и финальным текстом.
    /// nil — изменений нет (тексты совпали по словам).
    public static func change(old: String, new: String) -> Change? {
        guard old != new else { return nil }
        let oldWords = words(old)
        let newWords = words(new)

        // Общий префикс по словам.
        var prefix = 0
        while prefix < oldWords.count, prefix < newWords.count,
              oldWords[prefix] == newWords[prefix] {
            prefix += 1
        }
        // Общий суффикс по словам (не пересекая префикс).
        var suffix = 0
        while suffix < oldWords.count - prefix, suffix < newWords.count - prefix,
              oldWords[oldWords.count - 1 - suffix] == newWords[newWords.count - 1 - suffix] {
            suffix += 1
        }

        // Слова совпали (различие только в пробелах/регистре вне слов) — не трогаем.
        if prefix == oldWords.count && prefix == newWords.count {
            return nil
        }

        let spanOldWords = oldWords[prefix..<(oldWords.count - suffix)]
        let spanNewWords = newWords[prefix..<(newWords.count - suffix)]

        return Change(
            oldText: old,
            newText: new,
            spanOld: spanOldWords.joined(separator: " "),
            spanNew: spanNewWords.joined(separator: " "),
            spanStartOld: offsetAfter(words: prefix, in: old),
            spanStartNew: offsetAfter(words: prefix, in: new)
        )
    }

    /// Разбиение на слова (run-ы не-пробелов).
    private static func words(_ text: String) -> [String] {
        text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Хвост текста после первых `wordCount` слов — по СИМВОЛЬНОМУ смещению
    /// (не реконструкция из токенов: внутренняя пунктуация/пробелы целы).
    /// Один пробел (или несколько) после последнего вырезанного слова остаётся
    /// хвосту — вызывающий (временнáя сшивка сегментов) обрезает ведущие
    /// пробелы сам. `wordCount >= числа слов` → пустая строка.
    public static func tailAfterWords(_ wordCount: Int, in text: String) -> String {
        let offset = offsetAfter(words: wordCount, in: text)
        guard offset < text.count else { return "" }
        return String(text[text.index(text.startIndex, offsetBy: offset)...])
    }

    /// Символьный offset сразу после конца n-го слова (n = 0 → 0).
    /// Пробелы после последнего общего слова остаются «хвосту».
    private static func offsetAfter(words wordCount: Int, in text: String) -> Int {
        guard wordCount > 0 else { return 0 }
        let chars = Array(text)
        var seen = 0
        var i = 0
        while i < chars.count {
            if !chars[i].isWhitespace {
                var j = i
                while j < chars.count && !chars[j].isWhitespace { j += 1 }
                seen += 1
                if seen == wordCount { return j }
                i = j
            } else {
                i += 1
            }
        }
        return chars.count
    }
}