import AppKit
import CoreGraphics

// MARK: - Delegate

public protocol HotkeyDelegate: AnyObject {
    func altDoubleTapped()
    func cancelKeyPressed()
}

// MARK: - HotkeyService

public final class HotkeyService {

    // MARK: Public

    public weak var delegate: HotkeyDelegate?
    public let doubleTapMaxInterval: TimeInterval

    // MARK: Private

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var optionDetector: DoubleAltDetector

    // MARK: - Init

    public init(doubleTapMaxInterval: TimeInterval = 0.4) {
        self.doubleTapMaxInterval = doubleTapMaxInterval
        self.optionDetector = DoubleAltDetector(maxInterval: doubleTapMaxInterval)
    }

    // MARK: - Lifecycle

    public func start() throws {
        guard eventTap == nil else { return }

        // Модификаторы (Option/Shift/Cmd) на многих клавиатурах приходят как
        // flagsChanged, а не keyDown — слушаем оба типа.
        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        // swiftlint:disable:next force_cast
        let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: Self.eventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        )

        guard let tap = tap else {
            throw HotkeyServiceError.eventTapCreationFailed
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        self.eventTap = tap
        self.runLoopSource = source
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
        proxy, type, event, userInfo -> Unmanaged<CGEvent>? in
        guard let userInfo = userInfo else {
            return Unmanaged.passRetained(event)
        }

        let service = Unmanaged<HotkeyService>.fromOpaque(userInfo).takeUnretainedValue()
        service.handleEvent(type: type, event: event)

        return Unmanaged.passRetained(event)
    }

    private func handleEvent(type: CGEventType, event: CGEvent) {
        // Re-enable tap if it gets disabled by the system (timeout)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return
        }

        guard type == .keyDown || type == .flagsChanged else { return }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        Logger.log("keyDown keyCode=\(keyCode)", level: "debug")

        switch type {
        case .flagsChanged:
            // Option приходит сюда как флаг; событие приходит и на нажатие
            // (флаг присутствует), и на отпускание (флага нет) — ловим только факт
            // нажатия для детекта double-tap.
            if event.flags.contains(.maskAlternate) {
                Logger.log("optionDown flagsChanged", level: "debug")
                handleOptionTap()
            }
        case .keyDown:
            switch keyCode {
            case 58, 61: // kVK_Option (58), kVK_RightOption (61)
                handleOptionTap()
            case 53, 36, 76: // Escape (53), Return (36), Keypad Enter (76)
                delegate?.cancelKeyPressed()
            default:
                break
            }
        default:
            break
        }
    }

    private func handleOptionTap() {
        let now = CFAbsoluteTimeGetCurrent()
        if optionDetector.registerTap(at: now) {
            delegate?.altDoubleTapped()
        }
    }
}

// MARK: - DoubleAltDetector

/// Чистая логика детекта двойного нажатия Option, вынесенная из `HotkeyService`
/// для возможности юнит-тестирования: не зависит от `CGEventTap`, работает
/// только с timestamp'ами нажатий.
public struct DoubleAltDetector {

    /// Максимальный интервал между двумя нажатиями (секунды) для детекта двойного тапа.
    public let maxInterval: TimeInterval

    /// Timestamp последнего нажатия; `0` означает «нет предыдущего нажатия».
    private var lastTimestamp: TimeInterval = 0

    public init(maxInterval: TimeInterval = 0.4) {
        self.maxInterval = maxInterval
    }

    /// Регистрирует нажатие в момент `timestamp` и возвращает `true`, если это
    /// второй тап в пределах `maxInterval` от предыдущего. После срабатывания
    /// детектор сбрасывается: следующее нажатие начинает новое окно детекта.
    public mutating func registerTap(at timestamp: TimeInterval) -> Bool {
        guard lastTimestamp > 0 else {
            lastTimestamp = timestamp
            return false
        }

        if timestamp - lastTimestamp <= maxInterval {
            lastTimestamp = 0 // сброс — детектируем пары, а не серии
            return true
        }

        lastTimestamp = timestamp
        return false
    }

    /// Полный сброс состояния.
    public mutating func reset() {
        lastTimestamp = 0
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
