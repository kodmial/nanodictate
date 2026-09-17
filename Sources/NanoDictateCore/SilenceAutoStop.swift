import Foundation

// MARK: - Автоостановка записи по непрерывной тишине (~3 c)

/// Конфигурация автоостановки записи по тишине.
///
/// Идея фичи: когда распознавание включено двойным Alt (агент слушает
/// микрофон), непрерывная тишина ~3 секунды означает «пользователь закончил
/// говорить и ждёт результат» — запись останавливается автоматически, и
/// запускается распознавание тем же путём, что ручное повторное Alt+Alt.
///
/// Модель тишины — самая простая RMS-проверка (промежуточный путь до Silero
/// VAD, см. память проекта): буфер, чей RMS строго ниже порога, считается
/// молчанием. Порог общий с остальным VAD кодовой базы
/// (`AudioMetrics.nearSilenceThreshold`, −50 dBFS): единый стандарт
/// «тишины» в записи, сегментации и автоостановке.
public struct AutoStopConfig: Equatable {
    /// Рубильник фичи: `false` полностью выключает автоостановку (запись живёт
    /// до ручного Alt+Alt или 60-секундного лимита — поведение до фичи).
    /// Спасательный люк для шумного окружения/длинных диктовок/PTT; по
    /// умолчанию включено — ровно по задаче.
    public var enabled: Bool

    /// Порог тишины одного буфера: RMS буфера СТРОГО ниже порога → молчание.
    /// Документированная константа: −50 dBFS (0.00316 линейной шкалы) — тот же
    /// порог, что у live-VAD и оффлайн-сегментера.
    public var silenceRMSThreshold: Float

    /// Минимальная длительность НЕПРЕРЫВНОЙ тишины (сек) для срабатывания.
    /// Фича-требование: ~3 секунды; паузы < 3 c не останавливают запись.
    public var requiredSilenceDuration: TimeInterval

    public init(
        enabled: Bool = true,
        silenceRMSThreshold: Float = AudioMetrics.nearSilenceThreshold,
        requiredSilenceDuration: TimeInterval = 3.0
    ) {
        self.enabled = enabled
        self.silenceRMSThreshold = silenceRMSThreshold
        self.requiredSilenceDuration = requiredSilenceDuration
    }

    /// Конфигурация по умолчанию: включено, тишина −50 dBFS длительностью 3 c.
    public static let defaults = AutoStopConfig()

    /// Фабрика из окружения — пломбинг конфига из Agent без правки конфиг-файлов
    /// (тот же путь, что `NANODICTATE_API_KEY` в `Config.swift`/`RetryProvider`).
    ///
    /// Пустое окружение даёт ровно `.defaults` — поведение по задаче (включено,
    /// 3 c, −50 dBFS). Переопределения (все опциональны, некорректные значения
    /// игнорируются и оставляют значение по умолчанию):
    ///   • `NANODICTATE_AUTOSTOP_DISABLED=1` (или `true`) — рубильник: фича
    ///     выключена вовсе, любая пауза не останавливает запись;
    ///   • `NANODICTATE_AUTOSTOP_DURATION=5` — порог непрерывной тишины в
    ///     секундах (Double, строго > 0);
    ///   • `NANODICTATE_AUTOSTOP_RMS=0.01` — порог «тишины» одного буфера в
    ///     линейной шкале (Float, строго > 0; −50 дБФС ≈ 0.00316).
    /// Значения провайдеров/конфиг-файлов здесь не затрагиваются.
    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> AutoStopConfig {
        var config = AutoStopConfig.defaults
        if env["NANODICTATE_AUTOSTOP_DISABLED"].map(parseDisabledFlag) ?? false {
            config.enabled = false
        }
        if let raw = env["NANODICTATE_AUTOSTOP_DURATION"], let d = Double(raw), d > 0 {
            config.requiredSilenceDuration = d
        }
        if let raw = env["NANODICTATE_AUTOSTOP_RMS"], let f = Float(raw), f > 0 {
            config.silenceRMSThreshold = f
        }
        return config
    }

    /// Признак «фича выключена» для `NANODICTATE_AUTOSTOP_DISABLED`.
    private static func parseDisabledFlag(_ raw: String) -> Bool {
        raw == "1" || raw == "true" || raw == "TRUE"
    }
}

/// Чистый детектор автоостановки: накапливает длительность НЕПРЕРЫВНОЙ
/// тишины по RMS-меткам буферов. Никакого I/O — только математика, поэтому
/// логика решения «тишина ≥ 3 c → стоп» полностью юнит-тестируема.
///
/// Питается из цикла записи (AudioService.process): для каждого буфера —
/// его RMS (0...1, как в level-метриках) и его РЕАЛЬНАЯ длительность
/// (фреймы конвертированного буфера / 16000). Накопление идёт по фактической
/// длительности, а не по счётчику буферов: частота колбэков зависит от
/// частоты дискретизации железа (~85 мс @ 48 кГц, ~93 мс @ 44.1 кГц,
/// ~256 мс @ 16 кГц) — по буферам «3 секунды» не меряются, по времени — да.
///
/// Семантика результата: как только `silenceDuration` достиг `requiredSilenceDuration`,
/// `feed` возвращает true (сработало). Любой буфер с речью
/// (RMS ≥ порога) сбрасывает накопитель — пауза короче 3 c не «запоминается»
/// для следующего срабатывания. Защёлку «сработало один раз» держит внешний
/// слой (AudioService помечает остановку запланированной): у детектора
/// ответственность — только честно отвечать «тишина сейчас ≥ порога или нет».
public struct SilenceAutoStopDetector {
    /// Порог тишины буфера (см. AutoStopConfig.silenceRMSThreshold).
    public let silenceRMSThreshold: Float

    /// Требуемая длительность непрерывной тишины (см. AutoStopConfig).
    public let requiredSilenceDuration: TimeInterval

    /// Накопленная длительность текущей непрерывной тишины (сек).
    /// Доступно на чтение для диагностики и тестов.
    public private(set) var silenceDuration: TimeInterval

    public init(
        silenceRMSThreshold: Float = AudioMetrics.nearSilenceThreshold,
        requiredSilenceDuration: TimeInterval = 3.0
    ) {
        self.silenceRMSThreshold = silenceRMSThreshold
        self.requiredSilenceDuration = requiredSilenceDuration
        self.silenceDuration = 0
    }

    /// Кормит детектор одним буфером.
    ///
    /// - Parameters:
    ///   - rms: линейный RMS буфера (0...1). Буфер молчит, если RMS СТРОГО
    ///     ниже `silenceRMSThreshold` (согласовано с `AudioMetrics.isNearSilence`
    ///     и live-VAD сегментера).
    ///   - duration: реальная длительность буфера в секундах. Отрицательная
    ///     длительность (защита от мусорного ввода) клампится в 0 — накопление
    ///     не может пойти назад.
    /// - Returns: `true`, когда накопленная непрерывная тишина достигла
    ///   `requiredSilenceDuration` (≥). Возвращает `true` и на последующих
    ///   тихих буферах, пока накопитель не сброшен речью или `reset()`.
    @discardableResult
    public mutating func feed(rms: Float, duration: TimeInterval) -> Bool {
        if rms < silenceRMSThreshold {
            silenceDuration += max(0, duration)
        } else {
            // Речь: непрерывность тишины прервана — накопитель обнуляется.
            silenceDuration = 0
        }
        return silenceDuration >= requiredSilenceDuration
    }

    /// Сбрасывает накопитель в ноль (новый сеанс записи).
    public mutating func reset() {
        silenceDuration = 0
    }
}