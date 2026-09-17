import CoreGraphics

/// Маркер СВОЕГО синтетического Return.
///
/// Проблема: синтетический Enter постится через `.cghidEventTap`, но наш
/// session-тап видит его повторно только на СЛЕДУЮЩЕЙ итерации run loop —
/// синхронный флаг «сейчас постится» к моменту обработки уже снят. Маркер
/// ставится в поле `.eventSourceUserData` САМОГО события ДО постинга и
/// переживает асинхронную доставку: по нему тап исключает событие из
/// роутинга (не зовёт enterKeyPressed, не гасит cancelPendingTap) и из
/// глотания — синтетика доходит до приложения.
public enum SyntheticReturnMarker {

    /// Постоянный токен между постами ("NDTK"). Менять не нужно: исключение
    /// действует на ЛЮБОЙ наш синтетический Return, а не на конкретный пост.
    public static let token: Int64 = 0x4E44544B

    /// Пометить событие как собственный синтетический Return (до постинга).
    public static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: token)
    }

    /// Является ли событие нашим синтетическим Return (по полю события).
    public static func isOwnSyntheticReturn(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == token
    }
}