import Foundation

// MARK: - Ответственность: склейка текстов чанков с дедупом по границе

// Из-за оверлэпа хвост предыдущего чанка пересекается с головой следующего
// (одна и та же речь распознана дважды). Дедуп: сравниваем суффикс слов
// предыдущего текста с префиксом слов следующего (тот же словесный механизм,
// что WordDiff — words() через split по пробелам) и при совпадении выбрасываем
// из головы следующего чанка первые совпавшие слова. Выбирается НАИБОЛЬШЕЕ
// совпадение (максимум k, где k последних слов prev == k первых слов next).
// Без совпадения — фолбэк: склейка с разделительным пробелом.

public enum BatchTextJoiner {
  /// Сколько первых слов `next` дублируют хвост `previous` (дедуп по границе).
  /// 0 — совпадения нет. Слова сравниваются без учёта регистра; пунктуация
  /// внутри слова сравнивается как есть (как в WordDiff.words).
  public static func boundaryDropCount(previous: String, next: String) -> Int {
    let prevWords = words(previous)
    let nextWords = words(next)
    guard !prevWords.isEmpty, !nextWords.isEmpty else { return 0 }

    let maxK = min(prevWords.count, nextWords.count)
    guard maxK >= 1 else { return 0 }

    // Наибольшее candidate, где candidate последних слов previous == candidate первых слов next.
    for candidate in stride(from: maxK, through: 1, by: -1) {
      let prevSuffix = prevWords.suffix(candidate).map { $0.lowercased() }
      let nextPrefix = nextWords.prefix(candidate).map { $0.lowercased() }
      if prevSuffix == nextPrefix {
        return candidate
      }
    }
    return 0
  }

  /// Склейка текстов чанков с дедупом по каждой границе. Каждый текст
  /// тримится, внутренние переводы строк схлопываются в пробел; чанки
  /// соединяются одним пробелом.
  public static func join(_ texts: [String]) -> String {
    var parts: [String] = []
    var previous = ""
    for raw in texts {
      let text = collapse(raw)
      guard !text.isEmpty else { continue }
      let drop = boundaryDropCount(previous: previous, next: text)
      let tail = drop > 0 ? words(text).dropFirst(drop).joined(separator: " ") : text
      if !tail.isEmpty {
        parts.append(tail)
      }
      previous = text
    }
    return parts.joined(separator: " ")
  }

  /// Разбиение на слова (run-ы не-пробелов) — как WordDiff.words.
  static func words(_ text: String) -> [String] {
    text.split { $0.isWhitespace }.map(String.init)
  }

  /// Трим + схлопывание whitespace (включая переводы строк) в один пробел.
  static func collapse(_ text: String) -> String {
    text.split { $0.isWhitespace }.joined(separator: " ")
  }
}
