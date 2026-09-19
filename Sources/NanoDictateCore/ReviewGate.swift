import Foundation

// MARK: - ReviewGate

// review_before_insert: text printed to stdout, Enter/empty = insert, else/Esc = cancel.
// Terminal-only: launchd/overlay have no stdout, so default false inserts immediately.

public enum ReviewGate {
  public enum Decision: Equatable {
    case insert
    case cancel
  }

  /// Input line; injectable in tests, default readLine().
  public static var readLineFunction: () -> String? = { readLine() }

  /// Show text, await decision: Enter/empty/y/Y → .insert; else (incl. Esc) → .cancel.
  public static func confirm(text: String) -> Decision {
    print("\(L10n.tr("review.prompt")): \(text)")
    print(L10n.tr("review.confirmInsert"), terminator: " ")
    fflush(stdout)
    guard let input = readLineFunction() else { return .cancel }
    let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty || trimmed == "y" || trimmed == "Y" {
      return .insert
    }
    return .cancel
  }
}
