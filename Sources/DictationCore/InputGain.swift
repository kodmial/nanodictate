import Foundation

// MARK: - Цифровое усиление входного сигнала (AGC)

/// Конфигурация цифрового усиления входа (AGC).
///
/// Идея фичи: штатный вход речи лежит в районе −55…−40 dBFS (метеорология
/// записи: min/avg/max RMS по буферам) — это в 2–3 раза тише «нормального»
/// речевого уровня −25…−18 dBFS, поэтому STT-провайдеры и WAV-снимки получают
/// тихий сигнал. AGC доводит текущий RMS буфера до целевого уровня `targetRmsDb`,
/// но не более чем на `maxGainDb` децибел: `gain = clamp(target − current, 0, max)`.
/// Тишина (RMS ≤ порога «около-тишины», −50 dBFS) не усиливается вовсе — шум
/// микрофона не тянется вверх и не сбивает VAD/автостоп.
///
/// Усиление применяется к Float32-буферу ПОСЛЕ конвертации в 16 кГц/моно и ДО
/// Int16-конверсии (и до расчёта метрики уровня): все потребители — анимация
/// уровня, live-VAD, автоостановка, запись в WAV — видят уже усиленный сигнал.
/// Сглаживание — one-pole с разными постоянными времени: быстрый attack (~25 мс)
/// при подъёме, медленный release (~300 мс) при спаде; пики после усиления
/// клампятся в [−1.0, 1.0], чтобы не клиппить Int16-конверсию.
public struct InputGainConfig: Equatable {
    /// Рубильник фичи: `false` полностью выключает AGC (буфер проходит без
    /// изменений). Спасательный люк — `DICTATION_GAIN_DISABLED=1`. По умолчанию
    /// включено — ровно по задаче.
    public var enabled: Bool

    /// Целевой RMS речи в dBFS: к нему тянется текущий уровень. Задача: −20 dBFS
    /// (речь −55…−40 dBFS доводится до −25…−18 dBFS, середины диапазона).
    public var targetRmsDb: Float

    /// Потолок усиления в дБ: даже очень тихий вход не усиливается более чем
    /// на это значение (защита от раздувания шума/шипения в 30+ раз).
    public var maxGainDb: Float

    /// Постоянная времени сглаживания при ПОДЪЁМЕ усиления, секунды (~25 мс).
    public var attackTime: TimeInterval

    /// Постоянная времени сглаживания при СПАДЕ усиления, секунды (~300 мс).
    public var releaseTime: TimeInterval

    public init(
        enabled: Bool = true,
        targetRmsDb: Float = -20,
        maxGainDb: Float = 30,
        attackTime: TimeInterval = 0.025,
        releaseTime: TimeInterval = 0.300
    ) {
        self.enabled = enabled
        // Защита от патологического конфига: цель всегда ниже полной шкалы,
        // потолок — в разумных пределах (0…60 дБ), постоянные времени > 0.
        self.targetRmsDb = min(max(targetRmsDb, -120), -1)
        self.maxGainDb = min(max(maxGainDb, 1), 60)
        self.attackTime = max(attackTime, 0.001)
        self.releaseTime = max(releaseTime, 0.001)
    }

    /// Конфигурация по умолчанию: включено, цель −20 dBFS, потолок +30 дБ,
    /// attack ~25 мс, release ~300 мс.
    public static let defaults = InputGainConfig()

    /// Фабрика из окружения — пломбинг конфига из Agent без правки конфиг-файлов
    /// (тот же путь, что `DICTATION_AUTOSTOP_*` в `AutoStopConfig.fromEnvironment`).
    ///
    /// Пустое окружение даёт ровно `.defaults` — поведение по задаче (включено,
    /// −20 dBFS, +30 дБ). Переопределения (все опциональны, некорректные значения
    /// игнорируются и оставляют значение по умолчанию):
    ///   • `DICTATION_GAIN_DISABLED=1` (или `true`) — рубильник: AGC выключен,
    ///     буфер проходит без изменений;
    ///   • `DICTATION_GAIN_TARGET_DB=-25` — целевой RMS речи в dBFS (Double,
    ///     строго ниже 0 и выше −120);
    ///   • `DICTATION_GAIN_MAX_DB=40` — потолок усиления в дБ (Double, 1…60).
    public static func fromEnvironment(
        _ env: [String: String] = ProcessInfo.processInfo.environment
    ) -> InputGainConfig {
        var config = InputGainConfig.defaults
        if env["DICTATION_GAIN_DISABLED"].map(parseDisabledFlag) ?? false {
            config.enabled = false
        }
        if let raw = env["DICTATION_GAIN_TARGET_DB"],
           let d = Double(raw), d < 0, d > -120 {
            config.targetRmsDb = Float(d)
        }
        if let raw = env["DICTATION_GAIN_MAX_DB"],
           let d = Double(raw), d > 0, d <= 60 {
            config.maxGainDb = Float(d)
        }
        return config
    }

    /// Признак «AGC выключен» для `DICTATION_GAIN_DISABLED`.
    private static func parseDisabledFlag(_ raw: String) -> Bool {
        raw == "1" || raw == "true" || raw == "TRUE"
    }
}

/// Процессор цифрового усиления входа. Чистая единица — только математика над
/// Float32-буфером, без аудио-железа, поэтому полностью юнит-тестируема.
///
/// Семантика `apply`: целевое усиление считается по ТЕКУЩЕМУ (неусиленному) RMS
/// буфера — «сколько дБ не хватает до targetRmsDb», но не более maxGainDb и
/// только если RMS выше порога тишины (−50 dBFS). Фактическое усиление плавно
/// догоняет цель one-pole-фильтром: каждый сэмпл сдвигает `currentGainDb` на
/// долю `α` от разницы с целью (α — из attack при подъёме, из release при спаде;
/// постоянные времени выражены в сэмплах: секунды × sampleRate). Сэмпл после
/// усиления клампится в [−1.0, 1.0]. Возвращает RMS УСИЛЕННОГО буфера (с учётом
/// клампа) — им кормится метрика уровня, live-VAD и автостоп.
public final class InputGain {
    public let config: InputGainConfig

    /// Текущее сглаженное усиление в дБ (0 — без усиления). Меняется one-pole
    /// от сэмпла к сэмплу внутри `apply`; доступно для диагностики и тестов.
    public private(set) var currentGainDb: Float = 0

    public init(config: InputGainConfig = .defaults) {
        self.config = config
    }

    /// Сброс сглаженного усиления в ноль (новый сеанс записи): первый буфер
    /// сеанса не стартует с остаточного усиления прошлой записи.
    public func reset() {
        currentGainDb = 0
    }

    /// Целевое усиление для текущего RMS буфера (дБ): сколько не хватает до
    /// `targetRmsDb`, в диапазоне 0…maxGainDb. Тишина (RMS ≤ −50 dBFS) и
    /// выключенный рубильник дают 0 — шум микрофона не усиливается.
    public func targetGainDb(forRms rms: Float) -> Float {
        guard config.enabled else { return 0 }
        let currentDb = AudioMetrics.dbfs(rms)
        // Порог «около-тишины» — общая константа кодовой базы (−50 dBFS).
        // Строго: усиливаем только то, что выше тишины; на самой тишине (≤ порога)
        // усиление 0 — иначе фоновый шум тянулся бы к речевому уровню и
        // сбивал VAD/автостоп.
        guard currentDb > AudioMetrics.dbfs(AudioMetrics.nearSilenceThreshold) else { return 0 }
        return min(max(config.targetRmsDb - currentDb, 0), config.maxGainDb)
    }

    /// Применяет усиление к Float32-каналу на месте (inout-семантика через
    /// указатель, чтобы не копировать буфер тапа).
    ///
    /// - Parameters:
    ///   - channel: буфер сэмплов (16 кГц моно), модифицируется на месте.
    ///   - frameLength: число сэмплов в `channel`.
    ///   - rms: RMS буфера ДО усиления (линейный 0…1) — вход расчёта цели.
    ///   - sampleRate: частота дискретизации для перевода постоянных времени
    ///     сглаживания из секунд в сэмплы (по умолчанию 16000 — формат конвертера).
    /// - Returns: RMS УСИЛЕННОГО буфера (0…1) — уровень, который реально
    ///   уходит в метрику/запись. При выключенном AGC или пустом буфере — `rms`
    ///   без изменений.
    @discardableResult
    public func apply(
        to channel: UnsafeMutablePointer<Float>,
        frameLength: Int,
        rms: Float,
        sampleRate: Int = 16000
    ) -> Float {
        guard config.enabled, frameLength > 0 else { return rms }
        // Тишина (RMS ≤ порога «около-тишины», −50 dBFS) НЕ усиливается ВООБЩЕ:
        // целью — 0 (см. targetGainDb), но без этого гарда и СГЛАЖЕННЫЙ gain
        // после речи утекал бы в тишину хвостом release (~0.3 c) — тишина
        // тянулась бы вверх и сбивала VAD/автостоп. Тишина — passthrough плюс
        // сброс накопленного усиления: пауза разрывает контекст, следующая
        // речь атакует с нуля, без наследия прошлой порции.
        guard AudioMetrics.dbfs(rms) > AudioMetrics.dbfs(AudioMetrics.nearSilenceThreshold) else {
            currentGainDb = 0
            return rms
        }
        let target = targetGainDb(forRms: rms)
        // One-pole α = 1 − e^(−dt/τ): при τ в секундах и dt в сэмплах
        // постоянная времени в сэмплах = τ·sampleRate (время × частота).
        let rate = max(1, sampleRate)
        let attackAlpha = 1 - exp(-1 / max(1, config.attackTime * Double(rate)))
        let releaseAlpha = 1 - exp(-1 / max(1, config.releaseTime * Double(rate)))

        var sum: Float = 0
        for i in 0..<frameLength {
            // Направление сглаживания: подъём — быстрый attack, спад — медленный
            // release. Разница ровно 0 не двигает gain — ветка не важна.
            let alpha = Float(target > currentGainDb ? attackAlpha : releaseAlpha)
            currentGainDb += alpha * (target - currentGainDb)
            let factor = powf(10, currentGainDb / 20)
            let amplified = channel[i] * factor
            // Кламп пиков: усиленный сэмпл никогда не выходит из [−1.0, 1.0] —
            // Int16-конверсия ниже не клиппит.
            let clamped = min(max(amplified, -1), 1)
            channel[i] = clamped
            sum += clamped * clamped
        }
        return sqrt(sum / Float(frameLength))
    }

    /// Удобная обёртка над `apply(to:frameLength:rms:sampleRate:)` для тестов и
    /// владельцев `[Float]`-буферов: модифицирует массив на месте и возвращает
    /// RMS усиленного сигнала.
    @discardableResult
    public func apply(
        to samples: inout [Float],
        rms: Float,
        sampleRate: Int = 16000
    ) -> Float {
        samples.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return rms }
            return apply(to: base, frameLength: buf.count, rms: rms, sampleRate: sampleRate)
        }
    }
}