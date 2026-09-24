// swiftlint:disable file_length

import AppKit
import CoreGraphics

// MARK: - Delegate

public protocol HotkeyDelegate: AnyObject {
  func altDoubleTapped()
  /// Escape (53) is the only cancel key; Enter/Keypad Enter are not.
  func cancelKeyPressed()
  /// Enter (36/76): agent decides by state — .recording stops + latches
  /// synthetic Enter, .transcribing no-op, .idle never reaches here.
  func enterKeyPressed()
  /// Swallow physical Return? true hides event from apps. Agent decides:
  /// .recording/.transcribing swallow (no newline in input field),
  /// .idle passes. Called synchronously from event tap on main run loop.
  func shouldSwallowReturnKeyEvent() -> Bool
}

// MARK: - HotkeyService

public final class HotkeyService {
  // MARK: Public

  public weak var delegate: HotkeyDelegate?
  public let doubleTapMaxInterval: TimeInterval

  // MARK: Private

  /// debug: log every key event + double-Alt detector state; info: hotkeys silent.
  private let logLevel: String

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var optionDetector: DoubleAltDetector

  /// Last key event timestamp — debug deltas between events.
  private var lastEventTime: CFAbsoluteTime?
  /// Last Option-down timestamp — debug-only delta; duplicates detector state.
  private var lastOptionDownAt: CFAbsoluteTime?

  // MARK: - Init

  public init(doubleTapMaxInterval: TimeInterval = 0.4, logLevel: String = "info") {
    self.doubleTapMaxInterval = doubleTapMaxInterval
    self.logLevel = logLevel
    optionDetector = DoubleAltDetector(maxInterval: doubleTapMaxInterval)
  }

  deinit {
    // Tap callback holds an unretained self; always tear the tap down so a
    // released service does not leave a dangling pointer on the run loop.
    stop()
  }

  private var isDebug: Bool {
    logLevel.lowercased() == "debug"
  }

  // MARK: - Lifecycle

  public func start() throws {
    guard eventTap == nil else { return }

    // Modifiers often arrive as flagsChanged, not keyDown — listen to both.
    let mask: CGEventMask =
      (1 << CGEventType.keyDown.rawValue)
      | (1 << CGEventType.flagsChanged.rawValue)

    let tap = CGEvent.tapCreate(
      tap: .cgSessionEventTap,
      place: .headInsertEventTap,
      options: .defaultTap,
      eventsOfInterest: mask,
      callback: Self.eventTapCallback,
      userInfo: Unmanaged.passUnretained(self).toOpaque()
    )

    guard let tap else {
      throw HotkeyServiceError.eventTapCreationFailed
    }

    let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)

    eventTap = tap
    runLoopSource = source
  }

  public func stop() {
    guard let tap = eventTap else { return }

    CGEvent.tapEnable(tap: tap, enable: false)
    if let source = runLoopSource {
      CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
    }
    CFMachPortInvalidate(tap)

    eventTap = nil
    runLoopSource = nil
  }

  // MARK: - Callback

  private static let eventTapCallback: CGEventTapCallBack = {
    // swiftlint:disable:next closure_parameter_position
    _, type, event, userInfo -> Unmanaged<CGEvent>? in
    guard let userInfo else {
      return Unmanaged.passUnretained(event)
    }

    let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
    service.handleEvent(type: type, event: event)

    // Return outside .idle is swallowed (nil suppresses, no newline in field).
    // Own synthetic Return (posted after Enter stop) reappears next run-loop
    // iteration — SyntheticReturnMarker lets it through to the app.
    if service.shouldSwallowEvent(
      type: type,
      keyCode: event.getIntegerValueField(.keyboardEventKeycode),
      event: event
    ) {
      return nil
    }

    return Unmanaged.passUnretained(event)
  }

  private func handleEvent(type: CGEventType, event: CGEvent) {
    // Re-enable tap only if the SYSTEM disabled it (watchdog timeout);
    // .tapDisabledByUserInput means our own stop() already turned it off —
    // re-enabling would resurrect a stopped tap. Logging kept for both.
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if type == .tapDisabledByTimeout, let tap = eventTap {
        CGEvent.tapEnable(tap: tap, enable: true)
        if isDebug {
          Logger.log("event tap re-enabled after timeout", level: "debug")
        }
      } else if isDebug {
        // own stop() disabled it — re-enabling would resurrect a stopped tap
        Logger.log("event tap not re-enabled after user input; restore on agent restart", level: "debug")
      }
      return
    }

    guard type == .keyDown || type == .flagsChanged else { return }

    let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
    let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    handleKeyboardEvent(
      type: type,
      keyCode: keyCode,
      flags: event.flags,
      isRepeat: isRepeat,
      at: CFAbsoluteTimeGetCurrent(),
      event: event
    )
  }

  /// Suppress keyDown of physical Return/Keypad Enter (36/76) when delegate
  /// says so (state ≠ .idle). Own synthetic Return (SyntheticReturnMarker)
  /// passes through. Test seam: event optional, marker path via real CGEvent.
  func shouldSwallowEvent(type: CGEventType, keyCode: Int64, event: CGEvent? = nil) -> Bool {
    guard type == .keyDown, keyCode == 36 || keyCode == 76 else { return false }
    if let event, isOwnSyntheticReturnEvent(event) {
      return false
    }
    return delegate?.shouldSwallowReturnKeyEvent() ?? false
  }

  /// Is this our synthetic Return? Test hook over SyntheticReturnMarker field.
  func isOwnSyntheticReturnEvent(_ event: CGEvent) -> Bool {
    SyntheticReturnMarker.isOwnSyntheticReturn(event)
  }

  /// CGEvent-free key routing, called by event tap and directly by tests.
  ///
  /// Key rule (fixes false double-Alt): flagsChanged fires on ANY modifier
  /// change; "Alt + Control" is not a second Alt. Only keyCode 58/61 counts
  /// as Alt; any other key between Alt presses cancels the pending first tap.
  func handleKeyboardEvent(
    type: CGEventType,
    keyCode: Int64,
    flags: CGEventFlags,
    isRepeat: Bool,
    at time: TimeInterval = CFAbsoluteTimeGetCurrent(),
    event: CGEvent? = nil
  ) {
    let now = time
    let delta = lastEventTime.map { now - $0 } ?? 0
    lastEventTime = now

    switch type {
    case .flagsChanged:
      let optionDown = flags.contains(.maskAlternate)
      logKeyboardEvent(
        kind: "flagsChanged", optionDown: optionDown, keyCode: keyCode, delta: delta, flags: flags)
      handleFlagsChanged(keyCode: keyCode, optionDown: optionDown, now: now)
    case .keyDown:
      logKeyboardEvent(
        kind: "keyDown", optionDown: nil, keyCode: keyCode, delta: delta, flags: flags)
      handleKeyDownCode(keyCode, isRepeat: isRepeat, now: now, event: event)
    default:
      break
    }
  }

  /// Any modifier state change; only Option keyCode (58/61) counts as Alt tap.
  private func handleFlagsChanged(keyCode: Int64, optionDown: Bool, now: TimeInterval) {
    let isOptionKeyCode = keyCode == 58 || keyCode == 61
    if isOptionKeyCode {
      // Option state changed: down = tap; up keeps pending first tap valid
      // (clean "Alt down/up/down" stays valid).
      if optionDown {
        handleOptionTap(at: now)
      }
    } else {
      // Other modifier (Control/Shift/Cmd) between Alt presses cancels the
      // pending first tap — "Alt + anything else" is not a double Alt.
      if isDebug, optionDetector.lastTimestamp != nil {
        Logger.log("other modifier keyCode=\(keyCode) — pending Alt tap cancelled", level: "debug")
      }
      optionDetector.cancelPendingTap()
    }
  }

  private func handleKeyDownCode(
    _ keyCode: Int64, isRepeat: Bool, now: TimeInterval, event: CGEvent?
  ) {
    switch keyCode {
    case 58, 61:
      // Held Option autorepeat is not a new tap.
      if !isRepeat {
        handleOptionTap(at: now)
      }
    case 53:  // Escape (53) — the only cancel key
      if isDebug, optionDetector.lastTimestamp != nil {
        Logger.log(
          "cancel key pressed keyCode=\(keyCode) — pending Alt tap cancelled", level: "debug")
      }
      optionDetector.cancelPendingTap()
      delegate?.cancelKeyPressed()
    case 36, 76:  // Return (36), Keypad Enter (76) — not cancel keys
      if isDebug, optionDetector.lastTimestamp != nil {
        Logger.log(
          "enter key pressed keyCode=\(keyCode) — pending Alt tap cancelled", level: "debug")
      }
      // Own synthetic Return (posted after Enter stop) reappears next
      // run-loop iteration — marker excludes it entirely: no cancelPendingTap
      // (would eat the first Alt tap), no enterKeyPressed (would stop new
      // recording).
      let isOwnSynthetic = event.map { isOwnSyntheticReturnEvent($0) } ?? false
      if !isOwnSynthetic {
        optionDetector.cancelPendingTap()
        delegate?.enterKeyPressed()
      }
    default:
      if isDebug, optionDetector.lastTimestamp != nil {
        Logger.log("foreign key keyCode=\(keyCode) — pending Alt tap cancelled", level: "debug")
      }
      optionDetector.cancelPendingTap()
    }
  }

  private func logKeyboardEvent(
    kind: String, optionDown: Bool?, keyCode: Int64, delta: TimeInterval, flags: CGEventFlags
  ) {
    guard isDebug else { return }
    let middle = optionDown.map { $0 ? " optionDOWN" : " (maskAlternate absent)" } ?? ""
    Logger.log(
      "event \(kind) keyCode=\(keyCode) dt=\(String(format: "%.4f", delta))"
        + middle
        + " rawFlags=0x\(String(format: "%X", flags.rawValue))",
      level: "debug"
    )
  }

  /// Alt tap at `now`; time passed in so tests control the detect window.
  private func handleOptionTap(at now: TimeInterval) {
    logOptionTapState(at: now)
    if optionDetector.registerTap(at: now) {
      if isDebug {
        Logger.log("ALT+ALT fired — delegate.altDoubleTapped()", level: "debug")
      }
      delegate?.altDoubleTapped()
    }
  }

  /// Read-only debug log of detector state before registering the tap.
  private func logOptionTapState(at now: TimeInterval) {
    guard isDebug else { return }
    let last = optionDetector.lastTimestamp
    let timeSinceLastOptionDown = lastOptionDownAt.map { now - $0 }
    lastOptionDownAt = now

    let state: String
    if let last {
      let interval = now - last
      if interval <= doubleTapMaxInterval + 1e-9 {
        state = String(
          format: "SECOND tap (interval=%.4f <= max %.2f) — will fire",
          interval,
          doubleTapMaxInterval)
      } else {
        state = String(
          format: "TIMEOUT (interval=%.4f > max %.2f) — window restarted",
          interval,
          doubleTapMaxInterval)
      }
    } else {
      state = "FIRST tap — awaiting second"
    }

    var parts = [String(format: "now=%.4f", now)]
    if let last {
      parts.append(String(format: "lastTap=%.4f", last))
    }
    if let timeSinceLastOptionDown {
      parts.append(String(format: "dtSincePrevOption=%.4f", timeSinceLastOptionDown))
    }
    parts.append("max=\(doubleTapMaxInterval)")
    Logger.log("option tap: \(parts.joined(separator: ", ")) -> \(state)", level: "debug")
  }
}

// MARK: - DoubleAltDetector

/// Pure double-Option detection, extracted from `HotkeyService` for unit
/// testing: CGEventTap-free, works on tap timestamps only.
public struct DoubleAltDetector {
  /// Max interval between two presses (seconds) to count as double tap.
  public let maxInterval: TimeInterval

  /// Double precision (5.4 - 5.0 = 0.40000000000000036) — compare
  /// intervals against the boundary with epsilon.
  private let epsilon: TimeInterval = 1e-9

  /// Last tap timestamp; nil = none. Optional, not sentinel 0: a tap at
  /// exactly 0.0 (tests) must not swallow the next (0.0 not > 0).
  /// `internal private(set)` — detect mutates only via
  /// registerTap/reset/cancelPendingTap; read open for debug log.
  private(set) var lastTimestamp: TimeInterval?

  public init(maxInterval: TimeInterval = 0.4) {
    self.maxInterval = maxInterval
  }

  /// True when this is a second tap within maxInterval of the previous;
  /// detector then resets, so the next tap opens a new window.
  public mutating func registerTap(at timestamp: TimeInterval) -> Bool {
    guard let last = lastTimestamp else {
      lastTimestamp = timestamp
      return false
    }

    if timestamp - last <= maxInterval + epsilon {
      lastTimestamp = nil  // reset — detect pairs, not series
      return true
    }

    lastTimestamp = timestamp
    return false
  }

  public mutating func reset() {
    lastTimestamp = nil
  }

  /// Cancel pending first tap: any other key or modifier between Alt
  /// presses — "Alt + anything else", not a double Alt. Idempotent.
  public mutating func cancelPendingTap() {
    lastTimestamp = nil
  }
}

// MARK: - Errors

public enum HotkeyServiceError: LocalizedError {
  case eventTapCreationFailed

  public var errorDescription: String? {
    switch self {
    case .eventTapCreationFailed:
      return """
        Failed to create CGEvent tap. \
        Ensure the app has Accessibility permission in \
        System Settings > Privacy & Security > Accessibility.
        """
    }
  }
}
