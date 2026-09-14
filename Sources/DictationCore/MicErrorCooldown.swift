import Foundation

// MARK: - Cooldown микрофонных ошибок

/// Cooldown повторных терминальных микрофонных ошибок (нет доступа к микрофону /
/// движок не поднялся). Пока неисправность не устранена, каждый Alt+Alt в
/// состоянии ошибки не должен заново играть звук ошибки (Basso) и мигать
/// оверлеем: сообщение показывается не чаще одного раза в `interval` секунд.
///
/// Чистая тестируемая единица: не зависит ни от AppKit, ни от времени суток —
/// работает только с timestamp'ами (TimeInterval, секунды, любая база отсчёта).
public struct MicErrorCooldown {

    /// Минимальный интервал между двумя показами ошибки, секунды.
    public let interval: TimeInterval

    /// Момент последнего РАЗРЕШЁННОГО показа. `-.infinity` — «ещё ни разу»:
    /// первый показ всегда разрешён (тап в момент 0.0 не должен «съедать»
    /// следующий тап, ср. DoubleAltDetector.lastTimestamp).
    private var lastFiredAt: TimeInterval = -.infinity

    public init(interval: TimeInterval) {
        self.interval = interval
    }

    /// Возвращает `true`, если с последнего показа прошло не менее `interval`
    /// (событие можно показать), и запоминает момент `now` как последний показ.
    /// `false` — событие подавляется, состояние не меняется.
    public mutating func allow(at now: TimeInterval) -> Bool {
        guard now - lastFiredAt >= interval else { return false }
        lastFiredAt = now
        return true
    }
}