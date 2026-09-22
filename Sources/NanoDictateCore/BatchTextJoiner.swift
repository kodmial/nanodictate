import Foundation

// MARK: - Ответственность: склейка текстов чанков с дедупом по границе

// Overlap duplicates prev tail in next head (same speech twice).
// Dedup: largest k where prev's last k words == next's first k (WordDiff words).
// No match → join with a single space.

public enum BatchTextJoiner {
  /// `next` head dup of `previous` tail; 0 = none. Case-insensitive, punctuation as-is.
  public static func boundaryDropCount(previous: String, next: String) -> Int {
    let prevWords = words(previous)
    let nextWords = words(next)
    guard !prevWords.isEmpty, !nextWords.isEmpty else { return 0 }

    let maxK = min(prevWords.count, nextWords.count)
    guard maxK >= 1 else { return 0 }

    // Largest k where prev suffix == next prefix.
    for candidate in stride(from: maxK, through: 1, by: -1) {
      let prevSuffix = prevWords.suffix(candidate).map { $0.lowercased() }
      let nextPrefix = nextWords.prefix(candidate).map { $0.lowercased() }
      if prevSuffix == nextPrefix {
        return candidate
      }
    }
    return 0
  }

  /// Join chunk texts with boundary dedup; trim, collapse newlines, single-space join.
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

  /// Split into non-whitespace runs (WordDiff.words).
  static func words(_ text: String) -> [String] {
    text.split { $0.isWhitespace }.map(String.init)
  }

  /// Trim + collapse whitespace (incl. newlines) to single spaces.
  static func collapse(_ text: String) -> String {
    text.split { $0.isWhitespace }.joined(separator: " ")
  }
}
