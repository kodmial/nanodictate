import Foundation

// MARK: - По-словный diff для финального прохода пошаговой диктовки

//
// Diffs already-inserted (chunked) text vs final text of whole WAV and emits
// ONE contiguous change range (prefix/suffix over common words, recursive LCS
// over words). One range = one keyboard action at end of inserted text: user
// undo stays intact.
//
// Granularity — words: even a point fix inside a word replaces that whole word
// ("карова" → "корова" replaces the word). Deliberate: on keyboard, replacing
// a whole word beats hitting a single letter.

public enum WordDiff {
  /// Diff result: changed range + "tails" for one replaceRange action
  /// (backspace over old text tail, print new text tail).
  public struct Change: Equatable {
    /// Inserted (chunked) text.
    public let oldText: String
    /// Final text (whole WAV in one request).
    public let newText: String

    /// Only changed words of old text (between common prefix and common
    /// suffix), single-spaced. Empty — pure insertion.
    public let spanOld: String
    /// Changed words of new text. Empty — pure deletion.
    public let spanNew: String
    /// Char offset of divergence start in `oldText` (after common prefix) —
    /// for backspace count.
    public let spanStartOld: Int
    /// Char offset of divergence start in `newText`.
    public let spanStartNew: Int

    /// Old text tail from divergence start to end: exactly what backspace
    /// removes (one action).
    public var tailOld: String {
      String(oldText[oldText.index(oldText.startIndex, offsetBy: spanStartOld)...])
    }

    /// New text tail from divergence start to end: what to print.
    public var tailNew: String {
      String(newText[newText.index(newText.startIndex, offsetBy: spanStartNew)...])
    }

    public init(
      oldText: String,
      newText: String,
      spanOld: String,
      spanNew: String,
      spanStartOld: Int,
      spanStartNew: Int
    ) {
      self.oldText = oldText
      self.newText = newText
      self.spanOld = spanOld
      self.spanNew = spanNew
      self.spanStartOld = spanStartOld
      self.spanStartNew = spanStartNew
    }
  }

  /// Word-level diff between inserted and final text.
  /// nil — no changes (texts match word-wise).
  public static func change(old: String, new: String) -> Change? {
    guard old != new else { return nil }
    let oldWords = words(old)
    let newWords = words(new)

    // Common prefix by words.
    var prefix = 0
    while prefix < oldWords.count, prefix < newWords.count,
      oldWords[prefix] == newWords[prefix]
    {  // swiftlint:disable:this opening_brace
      prefix += 1
    }
    // Common suffix by words (not crossing prefix).
    var suffix = 0
    while suffix < oldWords.count - prefix, suffix < newWords.count - prefix,
      oldWords[oldWords.count - 1 - suffix] == newWords[newWords.count - 1 - suffix]
    {  // swiftlint:disable:this opening_brace
      suffix += 1
    }

    // Words equal — only whitespace/case differ outside words; leave as-is.
    if prefix == oldWords.count, prefix == newWords.count {
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

  /// Split into words (non-whitespace runs).
  private static func words(_ text: String) -> [String] {
    text.split { $0.isWhitespace }.map(String.init)
  }

  /// Text tail after first `wordCount` words — by CHARACTER offset (not token
  /// reconstruction: inner punctuation/whitespace intact). One (or more) space
  /// after last cut word stays on tail — caller (temporal segment stitching)
  /// trims leading spaces itself. `wordCount >= word count` → empty string.
  public static func tailAfterWords(_ wordCount: Int, in text: String) -> String {
    let offset = offsetAfter(words: wordCount, in: text)
    guard offset < text.count else { return "" }
    return String(text[text.index(text.startIndex, offsetBy: offset)...])
  }

  /// Char offset right after end of n-th word (n = 0 → 0).
  /// Spaces after last common word stay on "tail".
  private static func offsetAfter(words wordCount: Int, in text: String) -> Int {
    guard wordCount > 0 else { return 0 }
    let chars = Array(text)
    var seen = 0
    var i = 0
    while i < chars.count {
      if !chars[i].isWhitespace {
        var endIndex = i
        while endIndex < chars.count, !chars[endIndex].isWhitespace {
          endIndex += 1
        }
        seen += 1
        if seen == wordCount {
          return endIndex
        }
        i = endIndex
      } else {
        i += 1
      }
    }
    return chars.count
  }
}
