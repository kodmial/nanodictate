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

  /// Serial background queue for confirmAsync: the synchronous confirm(text:)
  /// blocks the calling thread for the user's whole decision time. The agent's
  /// insertion paths run on the main queue — the same run loop as the hotkey
  /// event tap — so a blocking read there would stall overlay updates and can
  /// time out the tap (CR16). The serial queue also guarantees that two
  /// concurrent confirmations never interleave on the terminal.
  private static let confirmQueue: DispatchQueue = {
    DispatchQueue(label: "nanodictate.review-gate", qos: .userInitiated)
  }()

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

  /// Asynchronous confirmation (CR16): runs the same prompt + read as
  /// confirm(text:) on a private serial BACKGROUND queue — the main run loop
  /// (hotkey event tap, overlay) stays responsive while the user decides —
  /// and delivers the Decision to the MAIN queue via `completion`. The caller
  /// keeps its processing state non-idle until the completion processes the
  /// decision.
  public static func confirmAsync(
    text: String,
    completion: @escaping (Decision) -> Void
  ) {
    confirmQueue.async {
      let decision = confirm(text: text)
      DispatchQueue.main.async {
        completion(decision)
      }
    }
  }
}
