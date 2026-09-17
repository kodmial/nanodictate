import Foundation

// MARK: - EnterSendLatch

/// Латч «после вставки текста постить РОВНО ОДИН синтетический Enter»
/// (фича «Enter стопит запись»). Одноразовый и идемпотентный:
/// - `arm()` — поставить латч (Enter во время .recording); повторные вызовы
///   ничего не меняют — повторный Enter (хоть во время записи, хоть во время
///   распознавания) не инкрементирует счётчик;
/// - `consume()` — вытащить латч один раз: `true` — синтетический Enter нужно
///   постить (латч снят), `false` — латч не стоял;
/// - `cancel()` — погасить латч без постинга (Esc / пустой результат /
///   ошибка транскрибации);
/// - `isPending` — латч стоит.
/// Не потокобезопасен по дизайну: используется только на main (агент и
/// event-тап живут на main run loop).
public final class EnterSendLatch {

    private var isArmed = false

    public init() {}

    /// Поставить латч. Идемпотентна: синтетический Enter всегда ровно один.
    public func arm() {
        isArmed = true
    }

    /// Вытащить латч (одноразово). `true` — синтетический Enter нужно
    /// постить; латч при этом снят, повторный `consume()` вернёт `false`.
    public func consume() -> Bool {
        guard isArmed else { return false }
        isArmed = false
        return true
    }

    /// Погасить латч без постинга синтетического Enter. Идемпотентна.
    public func cancel() {
        isArmed = false
    }

    /// Латч стоит?
    public var isPending: Bool { isArmed }
}