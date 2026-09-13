import Foundation

// MARK: - Чистая логика решений цикла диктовки

/// Чистые решения цикла диктовки (пустой результат / доставка STT / undo-окно),
/// вынесенные из агента (DictatorAgent/main.swift) в DictationCore, чтобы
/// UX-правила покрывались юнит-тестами без запуска агента и AppKit.
public enum DictationFlow {

    // MARK: Пустой результат STT

    /// «Пустой» результат STT — нечего вставлять и нечему радоваться.
    /// Пустой/пробельный текст, а также результат короче ДВУХ слов (одиночные
    /// «да» / «нет», случайный тап в микрофон) считаем пустым: мусор в текст
    /// не вставляем, звук успеха не играем.
    public static func isEmptyResult(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        let words = trimmed.split(whereSeparator: { $0.isWhitespace })
        return words.count < 2
    }

    /// Чем завершается цикл распознавания: вставкой текста или «пусто».
    public enum CompletionOutcome: Equatable {
        case insert(String)
        case empty
    }

    public static func outcome(for text: String) -> CompletionOutcome {
        isEmptyResult(text) ? .empty : .insert(text)
    }

    // MARK: Доставка результата STT

    /// Принять ли результат STT в завершение цикла: сессия «обработка» ещё
    /// активна (processingSession совпал, state все ещё .transcribing) И
    /// пользователь не отменил распознавание по Esc. Отмена по Esc ставит
    /// токен отмены + state = .idle — этот страж гасит и успешный, и
    /// ошибочный путь (текст после Esc не вставляется).
    public static func shouldDeliverResult(isCancelled: Bool, sessionActive: Bool) -> Bool {
        !isCancelled && sessionActive
    }

    // MARK: Undo-окно последней вставки

    /// Откатить ли последнюю вставку двойным Alt: вставка была (записано
    /// время) и с того момента прошло не более `window` секунд. nil —
    /// вставки не было (или она уже откачена) — откат невозможен.
    public static func shouldUndoInsertion(
        lastInsertedAt: TimeInterval?,
        now: TimeInterval,
        window: TimeInterval
    ) -> Bool {
        guard let since = lastInsertedAt else { return false }
        return now - since <= window
    }

    /// Наличие свежей вставки, при которой двойной Alt в состоянии `state`
    /// должен откатить вставку, а не начать новую запись. Undo-окно действует
    /// ТОЛЬКО в .idle: фаза «запись» (Alt = «завершить запись») и фаза
    /// «обработка» (Alt игнорируется) не путаются с откатом.
    public static func shouldUndoInsteadOfStart(
        state: DictationState,
        lastInsertedAt: TimeInterval?,
        now: TimeInterval,
        undoWindow: TimeInterval
    ) -> Bool {
        guard state == .idle else { return false }
        return shouldUndoInsertion(lastInsertedAt: lastInsertedAt, now: now, window: undoWindow)
    }
}