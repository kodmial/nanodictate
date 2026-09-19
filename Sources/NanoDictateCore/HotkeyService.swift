// swiftlint:disable file_length

import AppKit
import CoreGraphics

// MARK: - Delegate

public protocol HotkeyDelegate: AnyObject {
  func altDoubleTapped()
  /// Единственная клавиша отмены — Escape (53). Enter/Keypad Enter отменой
  /// больше НЕ являются (см. enterKeyPressed).
  func cancelKeyPressed()
  /// Enter/Keypad Enter (36/76): агент сам решает по своему состоянию
  /// (.recording → стоп записи + латч синтетического Enter; .transcribing
  /// → no-op; .idle сюда не приходит — тап пропускает физический Enter).
  func enterKeyPressed()
  /// Синхронный предикат «глотать ли физический Return»: true — событие
  /// НЕ доходит до приложения. Агент отвечает от своего состояния:
  /// .recording/.transcribing глотают (физический Enter не вставляет
  /// перевод строки в поле ввода), .idle — пропускает как обычно.
  /// Вызывается синхронно из event-тапа на main run loop — гонок нет.
  func shouldSwallowReturnKeyEvent() -> Bool
}

// MARK: - HotkeyService

public final class HotkeyService {
  // MARK: Public

  public weak var delegate: HotkeyDelegate?
  public let doubleTapMaxInterval: TimeInterval

  // MARK: Private

  /// Уровень логирования: при `"debug"` каждая клавиатурная активность (keyDown/
  /// flagsChanged) и каждое состояние детектора двойного Alt пишутся в agent.log.
  /// При `"info"` горячие клавиши молчат (только lifecycle).
  private let logLevel: String

  private var eventTap: CFMachPort?
  private var runLoopSource: CFRunLoopSource?
  private var optionDetector: DoubleAltDetector

  /// Timestamp последнего события клавиатуры — для debug-дельт между событиями.
  private var lastEventTime: CFAbsoluteTime?
  /// Timestamp последнего нажатия Option — для debug-дельт между тапами
  /// (дубль состояния самого детектора, вычисляемый только для лога).
  private var lastOptionDownAt: CFAbsoluteTime?

  // MARK: - Init

  public init(doubleTapMaxInterval: TimeInterval = 0.4, logLevel: String = "info") {
    self.doubleTapMaxInterval = doubleTapMaxInterval
    self.logLevel = logLevel
    optionDetector = DoubleAltDetector(maxInterval: doubleTapMaxInterval)
  }

  private var isDebug: Bool {
    logLevel.lowercased() == "debug"
  }

  // MARK: - Lifecycle

  public func start() throws {
    guard eventTap == nil else { return }

    // Модификаторы (Option/Shift/Cmd) на многих клавиатурах приходят как
    // flagsChanged, а не keyDown — слушаем оба типа.
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
      return Unmanaged.passRetained(event)
    }

    let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
    service.handleEvent(type: type, event: event)

    // Физический Return/Keypad Enter вне .idle глотается: .defaultTap —
    // активный тап, возврат nil подавляет событие, перевод строки в поле
    // ввода не вставляется. Синтетический Return (постинг после
    // Enter-останова) тап видит повторно на следующей итерации run loop,
    // но тот помечен маркером SyntheticReturnMarker — по нему событие
    // исключается и доходит до приложения.
    if service.shouldSwallowEvent(
      type: type,
      keyCode: event.getIntegerValueField(.keyboardEventKeycode),
      event: event
    ) {
      return nil
    }

    return Unmanaged.passRetained(event)
  }

  private func handleEvent(type: CGEventType, event: CGEvent) {
    // Re-enable tap if it gets disabled by the system (timeout)
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
      if let tap = eventTap {
        CGEvent.tapEnable(tap: tap, enable: true)
      }
      if isDebug {
        let reason = type == .tapDisabledByTimeout ? "timeout" : "user input"
        Logger.log("event tap re-enabled after \(reason)", level: "debug")
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

  /// Решение event-тапа «подавить ли событие»: сегодня — keyDown
  /// физического Return/Keypad Enter (36/76), когда делегат (агент) отвечает
  /// «глотать» (состояние не .idle). Свой синтетический Return (маркер
  /// SyntheticReturnMarker в поле события) НЕ глотается — должен дойти до
  /// приложения. Внутренний шов — юнит-тесты проверяют предикат без живого
  /// CGEvent-тапа: `event` опционален, маркерная ветка проверяется по
  /// реальному CGEvent.
  func shouldSwallowEvent(type: CGEventType, keyCode: Int64, event: CGEvent? = nil) -> Bool {
    guard type == .keyDown, keyCode == 36 || keyCode == 76 else { return false }
    if let event, isOwnSyntheticReturnEvent(event) {
      return false
    }
    return delegate?.shouldSwallowReturnKeyEvent() ?? false
  }

  /// Предикат «это СВОЙ синтетический Return?» — тест-хук: принимает
  /// CGEvent, реальная реализация проверяет поле события
  /// (SyntheticReturnMarker), тест гоняет это же поле через реальный CGEvent.
  func isOwnSyntheticReturnEvent(_ event: CGEvent) -> Bool {
    SyntheticReturnMarker.isOwnSyntheticReturn(event)
  }

  /// Внутренний шов без CGEvent: вся маршрутизация клавиш, вызывается из
  /// event-тапа (`handleEvent`) и напрямую из тестов; `type` — keyDown или
  /// flagsChanged (маска тапа).
  ///
  /// Ключевое правило (чинит ложный двойной Alt): `flagsChanged` приходит при
  /// смене ЛЮБОГО модификатора, `flags` содержат текущий полный набор зажатых.
  /// «Alt + Control» даёт flagsChanged по Control с флагом Option — это не
  /// второй Alt. Нажатием Alt считается только событие, у которого keyCode —
  /// сама Option (58/61); любая другая клавиша между нажатиями Option рвёт
  /// пару: незавершённый первый тап аннулируется.
  func handleKeyboardEvent(
    type: CGEventType,
    keyCode: Int64,
    flags: CGEventFlags,
    isRepeat: Bool,
    at time: TimeInterval = CFAbsoluteTimeGetCurrent(),
    event: CGEvent? = nil
  ) {
    let now = time
    // Дельта от ПРЕДЫДУЩЕГО события клавиатуры — период нажатий наглядно виден.
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

  /// flagsChanged: смена состояния ЛЮБОГО модификатора. Нажатием Alt считается
  /// только событие с keyCode самой Option (58/61); «Alt + Control» — не второй Alt.
  private func handleFlagsChanged(keyCode: Int64, optionDown: Bool, now: TimeInterval) {
    let isOptionKeyCode = keyCode == 58 || keyCode == 61
    if isOptionKeyCode {
      // Сменилось состояние самой Option: нажатие (флаг есть) — тап;
      // отпускание (флага нет) — не тап и не рвёт незавершённый первый
      // тап, чтобы чистый «Alt down/up/down» остался валидным.
      if optionDown {
        handleOptionTap(at: now)
      }
    } else {
      // Сменилось состояние ДРУГОГО модификатора (Control/Shift/Cmd…),
      // нажатие или отпускание, пока между нажатиями Option — это
      // «Alt + что угодно ещё», а не второй Alt: аннулируем незавершённый
      // первый тап.
      if isDebug, optionDetector.lastTimestamp != nil {
        Logger.log("other modifier keyCode=\(keyCode) — pending Alt tap cancelled", level: "debug")
      }
      optionDetector.cancelPendingTap()
    }
  }

  /// keyDown: Option — тап (без автоповтора), Escape — отмена, Return/Keypad
  /// Enter — Enter-предикат, прочее между двумя нажатиями Option — сброс тапа.
  private func handleKeyDownCode(
    _ keyCode: Int64, isRepeat: Bool, now: TimeInterval, event: CGEvent?
  ) {
    switch keyCode {
    case 58, 61:
      // Автоповтор зажатой Option — не новое нажатие.
      if !isRepeat {
        handleOptionTap(at: now)
      }
    case 53:  // Escape (53) — ЕДИНСТВЕННАЯ клавиша отмены
      if isDebug, optionDetector.lastTimestamp != nil {
        Logger.log(
          "cancel key pressed keyCode=\(keyCode) — pending Alt tap cancelled", level: "debug")
      }
      optionDetector.cancelPendingTap()
      delegate?.cancelKeyPressed()
    case 36, 76:  // Return (36), Keypad Enter (76) — НЕ клавиша отмены
      if isDebug, optionDetector.lastTimestamp != nil {
        Logger.log(
          "enter key pressed keyCode=\(keyCode) — pending Alt tap cancelled", level: "debug")
      }
      // Свой синтетический Return (постинг после Enter-останова) тап
      // видит повторно на следующей итерации run loop — по маркеру в
      // поле события исключаем его целиком: ни cancelPendingTap (иначе
      // пере-просмотр между двумя Alt-тапами съел бы первый тап), ни
      // enterKeyPressed (иначе синтетика остановила бы новую запись).
      let isOwnSynthetic = event.map { isOwnSyntheticReturnEvent($0) } ?? false
      if !isOwnSynthetic {
        optionDetector.cancelPendingTap()
        delegate?.enterKeyPressed()
      }
    default:
      // Любая другая клавиша между двумя нажатиями Option — не двойной Alt:
      // первый тап аннулируется.
      if isDebug, optionDetector.lastTimestamp != nil {
        Logger.log("foreign key keyCode=\(keyCode) — pending Alt tap cancelled", level: "debug")
      }
      optionDetector.cancelPendingTap()
    }
  }

  /// Дебаг-лог клавиатурного события: строка совпадает с исходным форматом.
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

  /// Регистрирует нажатие Option в момент `now` (время берётся из `handleKeyboardEvent`,
  /// чтобы тестовый шов мог управлять окном детекта детерминированно).
  private func handleOptionTap(at now: TimeInterval) {
    logOptionTapState(at: now)
    if optionDetector.registerTap(at: now) {
      if isDebug {
        Logger.log("ALT+ALT fired — delegate.altDoubleTapped()", level: "debug")
      }
      delegate?.altDoubleTapped()
    }
  }

  /// Debug-лог состояния машины детектора ПЕРЕД регистрацией тапа:
  /// первый тап / второй тап в окне / таймаут (окно перезапущено).
  /// Ничего не меняет — только читает состояние и пишет строку.
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

/// Чистая логика детекта двойного нажатия Option, вынесенная из `HotkeyService`
/// для возможности юнит-тестирования: не зависит от `CGEventTap`, работает
/// только с timestamp'ами нажатий.
public struct DoubleAltDetector {
  /// Максимальный интервал между двумя нажатиями (секунды) для детекта двойного тапа.
  public let maxInterval: TimeInterval

  /// Допуск при сравнении интервалов: `5.4 - 5.0` в Double равно
  /// `0.40000000000000036`, поэтому граница сравнивается с эпсилоном.
  private let epsilon: TimeInterval = 1e-9

  /// Timestamp последнего нажатия; `nil` — «нет предыдущего нажатия».
  /// Optional вместо sentinel-нуля: тап секунда в момент 0.0 (как в тестах)
  /// не должен «съедать» следующий тап (0.0 не `> 0`).
  /// `internal private(set)` — setter приватный (детект меняет состояние только
  /// через `registerTap`/`reset`/`cancelPendingTap`), чтение открыто для
  /// debug-лога HotkeyService.
  private(set) var lastTimestamp: TimeInterval?

  public init(maxInterval: TimeInterval = 0.4) {
    self.maxInterval = maxInterval
  }

  /// Регистрирует нажатие в момент `timestamp` и возвращает `true`, если это
  /// второй тап в пределах `maxInterval` от предыдущего. После срабатывания
  /// детектор сбрасывается: следующее нажатие начинает новое окно детекта.
  public mutating func registerTap(at timestamp: TimeInterval) -> Bool {
    guard let last = lastTimestamp else {
      lastTimestamp = timestamp
      return false
    }

    if timestamp - last <= maxInterval + epsilon {
      lastTimestamp = nil  // сброс — детектируем пары, а не серии
      return true
    }

    lastTimestamp = timestamp
    return false
  }

  /// Полный сброс состояния.
  public mutating func reset() {
    lastTimestamp = nil
  }

  /// Аннулирует незавершённый первый тап: между двумя нажатиями Option была
  /// другая клавиша (или другой модификатор) — это «Alt + что угодно ещё»,
  /// а не двойной Alt. Идемпотентна: при отсутствии первого тапа — no-op.
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
        System Preferences > Security & Privacy > Privacy > Accessibility.
        """
    }
  }
}
