import AppKit
import CoreGraphics
import Darwin

// MARK: - TextRefinement

public enum TextRefinement {
  /// Capitalize first letter of sentence; append period if none at end.
  public static func finalize(_ text: String) -> String {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return "" }

    var result = trimmed

    // Capitalize the first symbol (word-safe for Cyrillic).
    if let first = result.first {
      let upper = String(first).uppercased()
      result.replaceSubrange(result.startIndex...result.startIndex, with: upper)
    }

    // Append a period if the text does not end with sentence punctuation.
    if let last = result.last,
      !".!?…".contains(last)
    {  // swiftlint:disable:this opening_brace
      result.append(".")
    }

    return result
  }
}

// MARK: - Inserter

public enum Inserter {
  /// Chunk size (chars/backspaces) between pauses (insert and undo).
  static let chunkSize = 16
  private static let delayUSec: useconds_t = 5000  // 5 ms

  /// Test hooks (internal, visible via @testable): replace side effects — sleep
  /// between chunks and post CGEvent. Nil in prod; unit tests count pauses/events
  /// without typing into the active app. Not synchronized: tests are single-threaded.
  static var sleepHook: ((useconds_t) -> Void)?
  static var postHook: ((CGEvent, CGEventTapLocation) -> Void)?

  /// Insert text via CGEvent keyDown/keyUp with keyboardSetUnicodeString,
  /// chunks of chunkSize chars. 5 ms pause only between chunks (not per char).
  public static func insert(text: String) {
    guard !text.isEmpty else { return }
    typeText(text)
  }

  /// Step-by-step dictation: append next segment at END of already inserted text.
  /// Insert leaves cursor at end (does not move it), so just type — same as insert,
  /// contract for pipeline (append ≠ overwrite selection).
  public static func append(_ text: String) {
    insert(text: text)
  }

  /// Step-by-step dictation, final pass: replace ONE range `old` (already inserted)
  /// with `new`. Segments insert sequentially, so range found by Option+Shift+arrow
  /// word jumps — single action, undo intact.
  ///
  /// Contract: `old` is exactly what sits under the cursor (last insertion);
  /// `old == new` — no-op. Input: backspace excess chars, type diff-span.
  public static func replaceRange(old: String, new: String) {
    replaceText(old: old, new: new)
  }

  // MARK: - Private

  /// Common chunked path for insert/append.
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
        sleepAWhile(delayUSec)
      }
    }
  }

  // MARK: - Откат (undo)

  /// Erase exactly as many graphemes as inserted: backspace (virtualKey 51 /
  /// kVK_Delete) per char — symmetric undo to `insert(text:)`, same 5 ms pause.
  /// Pause between chunks of chunkSize (like insert), NOT per char: long undo
  /// (~500–1000 graphemes) must not block agent's main thread for seconds
  /// (was ~count × 5 ms — now ~count/16). count = 0 — no-op; negative clamps
  /// to no-op.
  ///
  /// Limitation: undo backspaces at current cursor position / front app. If cursor
  /// moved or active app changed between insert and undo — wrong text erased.
  public static func delete(characters: String) {
    delete(count: characters.count)
  }

  public static func delete(count: Int) {
    guard count >= 1 else { return }
    let source = CGEventSource(stateID: .hidSystemState)
    var remaining = count
    while remaining > 0 {
      let batch = min(remaining, chunkSize)
      pressBackspace(batch, source: source)
      remaining -= batch
      // Pause only between chunks, none after last (as in insert).
      if remaining > 0 {
        sleepAWhile(delayUSec)
      }
    }
  }

  /// Range replace: backspace `old` length, then type `new`.
  /// Cursor sits right after last insertion's text.
  private static func replaceText(old: String, new: String) {
    guard old != new else { return }
    if old.isEmpty {
      // Empty old — just type (mid-word insert via diff would be backspace+type,
      // but empty string has nothing to erase — type only).
      typeText(new)
      return
    }

    let source = CGEventSource(stateID: .hidSystemState)
    // Backspace erases one grapheme cluster per press; WordDiff yields `old` whole
    // along grapheme boundaries — count Characters, not UTF-16 units (else emoji
    // would take twice as many presses).
    let backspaceCount = old.count

    // Backspace: key 51 (delete). Multiple presses — multiple times. Идёт через
    // общий post() — postHook и isTestRun-гейт применимы (в отличие от postKey).
    pressBackspace(backspaceCount, source: source)
    typeText(new)
  }

  /// Single key press (keyDown+keyUp) via CGEvent.
  private static func postKey(virtualKey: CGKeyCode, source: CGEventSource?) {
    if let keyDown = CGEvent(
      keyboardEventSource: source,
      virtualKey: virtualKey,
      keyDown: true
    ) {
      keyDown.post(tap: .cghidEventTap)
    }
    if let keyUp = CGEvent(
      keyboardEventSource: source,
      virtualKey: virtualKey,
      keyDown: false
    ) {
      keyUp.post(tap: .cghidEventTap)
    }
  }

  /// Synthetic Enter (Return, kVK 36): keyDown + keyUp into .cghidEventTap.
  /// Agent posts it AFTER text insertion when Enter-stop latch is armed (Enter stops
  /// recording → post exactly one Enter after recognition+insert). Goes through the
  /// common post() — test postHook and isTestRun gate apply (unlike private postKey),
  /// so unit tests count events without typing into the active app.
  public static func postReturnKeyDownUp() {
    let source = CGEventSource(stateID: .hidSystemState)
    if let keyDown = CGEvent(
      keyboardEventSource: source,
      virtualKey: 36,
      keyDown: true
    ) {
      // Marker of OUR synthetic Return: session tap re-sees the event on next
      // run-loop iteration — via .eventSourceUserData it excludes it from routing.
      SyntheticReturnMarker.mark(keyDown)
      post(keyDown, tap: .cghidEventTap)
    }
    if let keyUp = CGEvent(
      keyboardEventSource: source,
      virtualKey: 36,
      keyDown: false
    ) {
      SyntheticReturnMarker.mark(keyUp)
      post(keyUp, tap: .cghidEventTap)
    }
  }

  private static func sendChunk(_ chunk: String, source: CGEventSource?) {
    let utf16 = Array(chunk.utf16)

    if let keyDown = CGEvent(
      keyboardEventSource: source,
      virtualKey: 0,
      keyDown: true
    ) {
      keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
      post(keyDown, tap: .cghidEventTap)
    }

    if let keyUp = CGEvent(
      keyboardEventSource: source,
      virtualKey: 0,
      keyDown: false
    ) {
      keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
      post(keyUp, tap: .cghidEventTap)
    }
  }

  private static func pressBackspace(_ times: Int, source: CGEventSource?) {
    for _ in 0..<times {
      if let keyDown = CGEvent(
        keyboardEventSource: source,
        virtualKey: 51,
        keyDown: true
      ) {
        post(keyDown, tap: .cghidEventTap)
      }
      if let keyUp = CGEvent(
        keyboardEventSource: source,
        virtualKey: 51,
        keyDown: false
      ) {
        post(keyUp, tap: .cghidEventTap)
      }
    }
  }

  private static func sleepAWhile(_ usec: useconds_t) {
    if let hook = sleepHook {
      hook(usec)
    } else {
      usleep(usec)
    }
  }

  private static func post(_ event: CGEvent, tap: CGEventTapLocation) {
    if let hook = postHook {
      hook(event, tap)
    } else if RuntimeEnvironment.isTestRun {
      // Тестовый раннер в активное приложение не печатает.
    } else {
      event.post(tap: tap)
    }
  }
}

// MARK: - Вставка выбранным способом (insert_method)

extension Inserter {
  /// Insert text using selected method.
  /// - `.cgevent`: legacy path — direct keyboard emulation (prod default).
  /// - `.clipboard`: via pasteboard with Cmd+V and old-buffer restore.
  public static func insert(text: String, method: InsertMethod) {
    insert(text: text, method: method, bridge: .default)
  }

  /// Test-stamped entry: same branch choice, but with injected clipboard bridge
  /// (covers both `.clipboard` path and branch over `cgEventInsertOverride`).
  static func insert(text: String, method: InsertMethod, bridge: ClipboardInsertBridge) {
    switch method {
    case .cgevent:
      if let override = cgEventInsertOverride {
        override(text)
      } else {
        insert(text: text)
      }
    case .clipboard:
      insertViaClipboard(text: text, bridge: bridge)
    }
  }

  /// Test hook: overridden in tests so `.cgevent` branch posts no real CGEvent to the
  /// focused app. Prod — nil, legacy behavior.
  static var cgEventInsertOverride: ((String) -> Void)?
}

// MARK: - Вставка через буфер обмена

/// Clipboard bridge; all ops injected for tests (no real NSPasteboard/CGEvent).
  /// `.default` — real prod implementation.
public struct ClipboardInsertBridge {
  /// Current pasteboard content (nil = empty).
  public var readClipboard: () -> String?
  /// Write text to pasteboard (empty string = clear).
  public var writeClipboard: (String) -> Void
  /// Emulate Cmd+V.
  public var sendPaste: () -> Void
  /// Delay before restoring old buffer (sec; default 0.5).
  public var restoreDelay: TimeInterval
  /// Delayed execution of the restore.
  public var scheduleRestore: (@escaping () -> Void, TimeInterval) -> Void

  public init(
    readClipboard: @escaping () -> String? = ClipboardInsertBridge.defaultReadClipboard,
    writeClipboard: @escaping (String) -> Void = ClipboardInsertBridge.defaultWriteClipboard,
    sendPaste: @escaping () -> Void = ClipboardInsertBridge.defaultSendPaste,
    restoreDelay: TimeInterval = 0.5,
    scheduleRestore: @escaping (@escaping () -> Void, TimeInterval) -> Void =
      ClipboardInsertBridge.defaultScheduleRestore
  ) {
    self.readClipboard = readClipboard
    self.writeClipboard = writeClipboard
    self.sendPaste = sendPaste
    self.restoreDelay = restoreDelay
    self.scheduleRestore = scheduleRestore
  }

  /// Real prod impl: NSPasteboard + CGEvent Cmd+V + async restore.
  public static var `default`: ClipboardInsertBridge {
    ClipboardInsertBridge()
  }

  // MARK: Дефолтные реализации

  public static func defaultReadClipboard() -> String? {
    NSPasteboard.general.string(forType: .string)
  }

  public static func defaultWriteClipboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    if !text.isEmpty {
      pasteboard.setString(text, forType: .string)
    }
  }

  /// Cmd+V (kVK_ANSI_V = 9) via hidSystemState.
  public static func defaultSendPaste() {
    let source = CGEventSource(stateID: .hidSystemState)
    if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true) {
      keyDown.flags = .maskCommand
      keyDown.post(tap: .cghidEventTap)
    }
    if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) {
      keyUp.flags = .maskCommand
      keyUp.post(tap: .cghidEventTap)
    }
  }

  public static func defaultScheduleRestore(_ restore: @escaping () -> Void, delay: TimeInterval) {
    DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: restore)
  }
}

extension Inserter {
  /// Insert via clipboard: save current buffer → write text → Cmd+V → restore
  /// old buffer after `restoreDelay` (~0.5 s).
  public static func insertViaClipboard(
    text: String,
    bridge: ClipboardInsertBridge = .default
  ) {
    guard !text.isEmpty else { return }
    let old = bridge.readClipboard()
    bridge.writeClipboard(text)
    bridge.sendPaste()
    let restore: () -> Void = {
      if let old {
        bridge.writeClipboard(old)
      } else {
        bridge.writeClipboard("")
      }
    }
    bridge.scheduleRestore(restore, bridge.restoreDelay)
  }
}
