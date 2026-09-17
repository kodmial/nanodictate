import Foundation
import CoreGraphics

/// Состояния цикла диктовки. Объявлены в ядре (а не в Agent-таргете), чтобы
/// решение о жизненном цикле оверлея было чистым и покрывалось юнит-тестами
/// без запуска агента.
public enum NanoDictateState {
    case idle
    case recording
    case transcribing
}

/// Чистая логика жизненного цикла оверлея: когда его можно прятать.
///
/// Оверлей живёт ВЕСЬ цикл записи/распознавания и прячется только из
/// терминальных точек (стоп/ошибка/вставка/отмена/лимит). Скрытие разрешено
/// только вне активного цикла (idle); во время recording/transcribing hide
/// запрещён — иначе пользователь потеряет индикатор посреди сеанса.
public enum OverlayLifecycle {

    /// Можно ли прятать оверлей в состоянии `currentState`.
    public static func shouldHide(currentState: NanoDictateState) -> Bool {
        switch currentState {
        case .idle:
            return true
        case .recording, .transcribing:
            return false
        }
    }

    /// Планирует скрытие оверлея с задержкой `delay` (оставляет на экране
    /// финальный статус «Завершаю…»/«Отменено»), но к моменту срабатывания
    /// перепроверяет состояние через `stateProvider`: если цикл уже начат
    /// заново (.recording/.transcribing) — оверлей остаётся видимым весь
    /// новый цикл, hide не вызывается.
    ///
    /// Контракт: одно планирование → не более одного вызова `hide()`.
    public static func scheduleHide(
        after delay: TimeInterval,
        stateProvider: @escaping () -> NanoDictateState,
        hide: @escaping () -> Void
    ) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            if shouldHide(currentState: stateProvider()) {
                hide()
            }
        }
    }
}