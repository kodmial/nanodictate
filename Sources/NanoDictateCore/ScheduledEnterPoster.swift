import Foundation

/// Отменяемое отложенное действие: один синтетический Enter после вставки
/// текста Enter-останова.
///
/// Зачем отдельный класс: пост планируется через ~250 мс (приложение в фокусе
/// успевает обработать вставленный текст), и Esc ДОЛЖЕН уметь отменять УЖЕ
/// запланированный пост (латч к этому моменту уже снят — consume() произошёл
/// в момент вставки). Голый `DispatchQueue.main.asyncAfter` не отменяется;
/// здесь планирование держится в `DispatchWorkItem` + поколении: отмена или
/// перепланирование инвалидирует срабатывание.
public final class ScheduledEnterPoster {

    /// Что выполняется при срабатывании (если действие не отменено).
    public var action: (() -> Void)?

    /// Пауза от планирования до срабатывания. По умолчанию 0.25 с — целевое
    /// приложение успевает обработать вставленный текст.
    public var delay: TimeInterval = 0.25

    /// Поколение планирования: каждый schedule/cancel инвалидирует предыдущее.
    private var generation: UInt64 = 0
    private var workItem: DispatchWorkItem?

    public init() {}

    /// Запланировать действие через `delay`. Повторный вызов отменяет
    /// предыдущее планирование (сработать может только последнее).
    public func schedule() {
        cancelScheduled()
        generation &+= 1
        let myGeneration = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.workItem = nil
            // Отменено (cancelScheduled / перепланировано schedule-ом)?
            guard self.generation == myGeneration else { return }
            self.action?()
        }
        workItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Отменить запланированное действие (Esc). Идемпотентна; действие
    /// не выполнится, если срабатывание ещё не наступило.
    public func cancelScheduled() {
        workItem?.cancel()
        workItem = nil
        generation &+= 1
    }
}