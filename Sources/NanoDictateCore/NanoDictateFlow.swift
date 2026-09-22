import Foundation

// MARK: - Чистая логика решений цикла диктовки

/// Pure dictation-cycle decisions (empty / STT delivery / undo window); unit-tested without agent.
public enum NanoDictateFlow {
  // MARK: Пустой результат STT

  /// Empty = whitespace-only or no letter/digit; no insert, no success sound; yes/no valid.
  public static func isEmptyResult(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty || !trimmed.contains { $0.isLetter || $0.isNumber }
  }

  /// Cycle end: insert text or empty.
  public enum CompletionOutcome: Equatable {
    case insert(String)
    case empty
  }

  public static func outcome(for text: String) -> CompletionOutcome {
    isEmptyResult(text) ? .empty : .insert(text)
  }

  // MARK: Доставка результата STT

  /// Accept STT result only if session active and not Esc-cancelled — Esc gate kills both paths.
  public static func shouldDeliverResult(isCancelled: Bool, sessionActive: Bool) -> Bool {
    !isCancelled && sessionActive
  }

  // MARK: Undo-окно последней вставки

  /// Undo double-Alt: insert exists and within `window` seconds; nil — no undo.
  public static func shouldUndoInsertion(
    lastInsertedAt: TimeInterval?,
    now: TimeInterval,
    window: TimeInterval
  ) -> Bool {
    guard let since = lastInsertedAt else { return false }
    return now - since <= window
  }

  /// Undo only in .idle: recording Alt = stop, processing Alt ignored — never confused with undo.
  public static func shouldUndoInsteadOfStart(
    state: NanoDictateState,
    lastInsertedAt: TimeInterval?,
    now: TimeInterval,
    undoWindow: TimeInterval
  ) -> Bool {
    guard state == .idle else { return false }
    return shouldUndoInsertion(lastInsertedAt: lastInsertedAt, now: now, window: undoWindow)
  }
}
