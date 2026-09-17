import Foundation
import AVFoundation
@testable import DictationCore

/// Юнит-тесты цифрового усиления входа (AGC) — см. InputGain.swift.
///
/// Задача фичи: штатный вход речи лежит в районе −55…−40 dBFS и диктовка пишет
/// тихий сигнал; AGC доводит текущий RMS буфера до целевого `targetRmsDb`
/// (−20 dBFS), но не более чем на `maxGainDb` (+30 дБ). Требования, которые
/// проверяются здесь напрямую на чистой математике (без аудио-железа):
///
///   (а) тихий вход (RMS ≈ −49…−50 dBFS) усиливается до примерно −20 dBFS
///       (допуск ±3 дБ) — «целевой уровень речи»;
///   (б) громкий вход (RMS −15 dBFS) НЕ усиливается — gain 0, буфер без изменений;
///   (в) тишина (RMS ≤ −50 dBFS, порог nearSilenceThreshold) не усиливается —
///       шум микрофона не тянется вверх;
///   (г) клип: пик после усиления клампится в [−1.0, 1.0] — Int16-конверсия
///       ниже не клиппит;
///   (д) сглаживание: два вызова подряд — gain меняется плавно (one-pole,
///       attack 25 мс / release 300 мс), а не скачком;
///   (е) env-конфиг: DICTATION_GAIN_DISABLED=1 отключает (gain 0),
///       DICTATION_GAIN_TARGET_DB / DICTATION_GAIN_MAX_DB парсятся и
///       доезжают до применения.
///
/// Единица времени в тестах: 1 сэмпл при sampleRate 16000 = 1/16000 c.
/// Константа сглаживания: α = 1 − e^(−1/τ), τ = τ_сек × 16000.
final class InputGainTests: XCTestCase {

    private let sampleRate = 16000

    /// Амплитуда, дающая RMS ровно `rmsDb` dBFS на константном буфере.
    private func amplitude(forRmsDb rmsDb: Float) -> Float {
        return powf(10, rmsDb / 20)
    }

    private func dbfs(_ linear: Float) -> Float {
        return AudioMetrics.dbfs(linear)
    }

    /// Константный буфер заданной амплитуды (синуса нет — нужен ровный RMS,
    /// чтобы отслеживать усиление по «чистому» уровню).
    private func constantBuffer(_ amplitude: Float, frames: Int) -> [Float] {
        return [Float](repeating: amplitude, count: frames)
    }

    /// RMS Float-буфера (локальная копия метрики — AudioMetrics.rms работает
    /// с [Int16], а здесь буфер ещё не конвертирован).
    private func rmsOf(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return sqrt(sum / Float(samples.count))
    }

    // MARK: - (а) тихий вход усиливается до цели

    /// Тихий вход −49 dBFS (штатный уровень речи): после apply RMS ≈ −20 dBFS
    /// (цель ± 3 дБ), gain добрался до ~+29 дБ — «речь стала слышной».
    @objc func testQuietSpeechIsAmplifiedTowardTarget() {
        let gain = InputGain()
        var buffer = constantBuffer(amplitude(forRmsDb: -49), frames: sampleRate)
        let inRms = rmsOf(buffer) // ≈ 0.003548 → −49 dBFS
        XCTAssertEqual(dbfs(inRms), -49, accuracy: 1.0, "предусловие: тихий вход")
        XCTAssertTrue(dbfs(inRms) > AudioMetrics.dbfs(AudioMetrics.nearSilenceThreshold), "предусловие: выше порога тишины")

        let outRms = gain.apply(to: &buffer, rms: inRms, sampleRate: sampleRate)

        XCTAssertEqual(dbfs(outRms), -20, accuracy: 3.0, "тихий вход доведён до цели −20 dBFS ±3 дБ")
        XCTAssertGreaterThanOrEqual(dbfs(outRms), -23, "не ниже −23 dBFS")
        XCTAssertLessThanOrEqual(dbfs(outRms), -17, "не выше −17 dBFS")
        XCTAssertEqual(gain.currentGainDb, 29, accuracy: 0.5, "к концу буфера gain ≈ полный целевой +29 дБ")
        // После усиления уровень выше исходного более чем в 10 раз (≈ +20 дБ) —
        // сигнал реально стал громче, а не «как был».
        XCTAssertGreaterThanOrEqual(dbfs(outRms), dbfs(inRms) + 20)
    }

    /// Граничный тихий вход ровно на пороге тишины (−50 dBFS): РОВНО на пороге
    /// усиление ещё 0 (порог строго ниже — «уже не тишина» начинается выше),
    /// но на один шаг выше (−49) — уже работает (покрыто тестом выше).
    @objc func testQuietAtSilenceThresholdGainZero() {
        let gain = InputGain()
        var buffer = constantBuffer(AudioMetrics.nearSilenceThreshold, frames: sampleRate)
        XCTAssertEqual(dbfs(buffer[0]), AudioMetrics.dbfs(AudioMetrics.nearSilenceThreshold), accuracy: 0.1)

        let outRms = gain.apply(to: &buffer, rms: AudioMetrics.nearSilenceThreshold, sampleRate: sampleRate)

        XCTAssertEqual(gain.currentGainDb, 0, accuracy: 0.000001, "ровно на пороге тишины — gain 0 (порог строго ниже)")
        XCTAssertEqual(outRms, AudioMetrics.nearSilenceThreshold, accuracy: 0.000001, "буфер не тронут")
    }

    // MARK: - (б) громкий вход не усиливается

    /// Вход −15 dBFS: уже громче цели, усиление 0, буфер проходит без изменений.
    @objc func testLoudInputIsNotAmplified() {
        let gain = InputGain()
        var buffer = constantBuffer(amplitude(forRmsDb: -15), frames: sampleRate)
        let original = buffer
        let inRms = rmsOf(buffer)

        let outRms = gain.apply(to: &buffer, rms: inRms, sampleRate: sampleRate)

        XCTAssertEqual(gain.currentGainDb, 0, "громкий вход не усиливается")
        XCTAssertEqual(outRms, inRms, accuracy: 0.000001, "RMS без изменений")
        XCTAssertEqual(buffer, original, "буфер не тронут — нет ни усиления, ни клампа")
    }

    // MARK: - (в) тишина не усиливается

    /// Тишина −60 dBFS (RMS 0.001 — ниже порога −50): gain 0, буфер проходит
    /// как есть — фоновый шум микрофона не тянется к речевому уровню.
    @objc func testSilenceIsNotAmplified() {
        let gain = InputGain()
        var buffer = constantBuffer(0.001, frames: sampleRate)
        let original = buffer

        let outRms = gain.apply(to: &buffer, rms: 0.001, sampleRate: sampleRate)

        XCTAssertEqual(gain.currentGainDb, 0, "тишина ≤ −50 dBFS не усиливается")
        XCTAssertEqual(outRms, 0.001, accuracy: 0.0000001, "RMS без изменений")
        XCTAssertEqual(buffer, original, "тихий буфер не тронут")
    }

    // MARK: - (г) клип клампится в [−1.0, 1.0]

    /// Один громкий пик 0.9 в тихом буфере: RMS буфера ~ −41 dBFS → целевое
    /// усиление ~ +21 дБ; пик после усиления ≈ 0.9 × 11.5 ≈ 10.4 → клампится
    /// в 1.0. Ни один сэмпл после apply не превышает 1.0 по модулю.
    @objc func testPeakIsClampedAfterGain() {
        let gain = InputGain()
        var buffer = constantBuffer(0.005, frames: sampleRate)
        buffer[sampleRate - 1] = 0.9 // пик в самом конце, когда gain уже сошёлся
        let inRms = rmsOf(buffer)
        XCTAssertEqual(dbfs(inRms), -41, accuracy: 1.0, "предусловие: RMS ниже цели, усиление нужно")

        gain.apply(to: &buffer, rms: inRms, sampleRate: sampleRate)

        let maxAbs = buffer.map { abs($0) }.max() ?? 0
        XCTAssertEqual(maxAbs, 1.0, "пик после усиления клампится ровно в 1.0")
        XCTAssertLessThanOrEqual(maxAbs, 1.0, "ни один сэмпл не выходит из [−1, 1]")
        XCTAssertEqual(gain.currentGainDb, 21.2, accuracy: 0.5, "gain ~ +21 дБ — до клампа пик был ~10.4")
        // Кламп коснулся только пика: уровень «хвоста» буфера всё ещё усилен,
        // но не клиппит — тихая часть осталась < 1.0.
        XCTAssertLessThanOrEqual(buffer[sampleRate / 2], 0.2, "середина буфера не на клампе")
        XCTAssertGreaterThanOrEqual(buffer[sampleRate / 2], 0.03, "середина буфера усилена")
    }

    // MARK: - (д) плавное сглаживание

    /// Два вызова подряд (по 160 сэмплов = 10 мс при 16 кГц) на тихом входе:
    /// gain после первого ∝ (1 − e^(−160/400)) ≈ 33% пути к цели, после второго —
    /// ещё ≈ 33% остатка. Требование: НЕ скачок сразу к полной цели за один
    /// буфер (иначе «дыхание»/щёлчки на каждом буфере).
    @objc func testGainSmoothsAcrossBuffers() {
        let gain = InputGain()
        // α = 1 − e^(−1/400); закрытая форма one-pole после N шагов:
        // target·(1 − (1−α)^N), (1−α)^N = e^(−N/400) — совпадает с рекурсией.
        let tauAttack = 0.025 * Double(sampleRate) // 400 сэмплов = 25 мс
        let target: Float = 29 // −49 → −20 дБ
        let framesPerCall = sampleRate / 100 // 160 сэмплов = 10 мс
        let p1 = 1 - exp(-Double(framesPerCall) / tauAttack)
        let expectedAfter1 = Float(Double(target) * p1) // 29·(1−e^(−0.4)) ≈ 9.56
        let p2 = 1 - exp(-2 * Double(framesPerCall) / tauAttack)
        let expectedAfter2 = Float(Double(target) * p2) // ≈ 15.97

        var buffer = constantBuffer(amplitude(forRmsDb: -49), frames: framesPerCall)
        let inRms = rmsOf(buffer)

        gain.apply(to: &buffer, rms: inRms, sampleRate: sampleRate)
        let gain1 = gain.currentGainDb
        XCTAssertGreaterThanOrEqual(gain1, 5, "первый буфер уже двинулся к цели")
        XCTAssertLessThanOrEqual(gain1, 20, "первый буфер НЕ даёт полного скачка к цели")
        XCTAssertEqual(gain1, expectedAfter1, accuracy: 0.1, "первый шаг ≈ 33% пути (attack 25 мс)")

        gain.apply(to: &buffer, rms: inRms, sampleRate: sampleRate)
        let gain2 = gain.currentGainDb
        XCTAssertGreaterThanOrEqual(gain2, gain1 + 3, "второй шаг продолжает подъём")
        XCTAssertLessThanOrEqual(gain2, 20, "второй шаг всё ещё не конец — плавная асимптота")
        XCTAssertEqual(gain2, expectedAfter2, accuracy: 0.1, "второй шаг ≈ ещё 33% остатка")
    }

    /// Спад (release, 300 мс) тоже плавный: подняли gain на тихом буфере,
    /// затем дали громкий буфер (цель 0) — gain уходит вниз постепенно,
    /// не обнуляется мгновенно (иначе щёлкает на стыке «тихо→громко»).
    @objc func testGainReleasesSmoothly() {
        let gain = InputGain()
        // Разогнали gain на полную цель тихим буфером.
        var quiet = constantBuffer(amplitude(forRmsDb: -49), frames: sampleRate)
        let quietRms = rmsOf(quiet)
        gain.apply(to: &quiet, rms: quietRms, sampleRate: sampleRate)
        XCTAssertEqual(gain.currentGainDb, 29, accuracy: 0.5, "предусловие: gain на цели")

        // Громкий буфер: цель 0, но release 300 мс — за 1600 сэмплов (100 мс)
        // gain уменьшается лишь до ~72% (это НЕ мгновенный скачок вниз).
        let decayPerStep = Float(exp(-Double(sampleRate / 10) / (0.300 * Double(sampleRate))))
        let gainBefore = gain.currentGainDb
        var loud = constantBuffer(amplitude(forRmsDb: -15), frames: sampleRate / 10)
        let loudRms = rmsOf(loud)
        gain.apply(to: &loud, rms: loudRms, sampleRate: sampleRate)

        let gainAfter100ms = gain.currentGainDb
        XCTAssertLessThanOrEqual(gainAfter100ms, gainBefore - 0.01, "gain пошёл вниз")
        XCTAssertEqual(gainAfter100ms, gainBefore * decayPerStep, accuracy: 1.0, "за 100 мс ушло ~28%, а не всё")

        // И продолжает спускаться к 0: ещё 3 буфера по 1600 сэмплов
        // (суммарно 6400 ≈ 0.4 c → e^(−6400/4800) ≈ 0.26 от остатка).
        for _ in 0..<3 {
            gain.apply(to: &loud, rms: loudRms, sampleRate: sampleRate)
        }
        XCTAssertLessThanOrEqual(gain.currentGainDb, gainAfter100ms * 0.9, "release прогрессирует к нулю")
        XCTAssertGreaterThanOrEqual(gain.currentGainDb, 0.1, "и пока не добил до нуля (ещё остаток)")
    }

    /// Тот же буфер (в том числе с уже накопленным gain): повторный apply на
    /// тихом входе не «взрывает» усиление — асимптота к цели, не рост вверх
    /// без ограничения (стабильность при непрерывной тихой речи).
    @objc func testRepeatedQuietApplysNeverExceedTarget() {
        let gain = InputGain()
        var buffer = constantBuffer(amplitude(forRmsDb: -49), frames: sampleRate / 10)
        let inRms = rmsOf(buffer)
        var last = Float.zero
        for i in 0..<20 {
            gain.apply(to: &buffer, rms: inRms, sampleRate: sampleRate)
            if i > 0 {
                XCTAssertGreaterThanOrEqual(gain.currentGainDb, last, "монотонный подъём")
            }
            last = gain.currentGainDb
        }
        XCTAssertEqual(gain.currentGainDb, 29, accuracy: 0.5, "устоялся на цели, не выше")
    }

    // MARK: - (е) конфиг по умолчанию и пломбинг из окружения

    /// Дефолт ровно по задаче: включено, −20 dBFS, max +30 дБ, attack 25 мс,
    /// release 300 мс. Рубильник не меняет поведение по умолчанию.
    @objc func testDefaultsMatchTask() {
        let config = InputGainConfig.defaults
        XCTAssertTrue(config.enabled, "дефолт — фича включена")
        XCTAssertEqual(config.targetRmsDb, -20, "целевой RMS речи −20 dBFS")
        XCTAssertEqual(config.maxGainDb, 30, "потолок +30 дБ")
        XCTAssertEqual(config.attackTime, 0.025, accuracy: 0.0000001, "attack ~25 мс")
        XCTAssertEqual(config.releaseTime, 0.300, accuracy: 0.0000001, "release ~300 мс")
        XCTAssertEqual(InputGainConfig(), config, "init по умолчанию == .defaults")
    }

    /// Пустое окружение → ровно `.defaults` (как у AutoStopConfig).
    @objc func testFromEnvironmentDefaultsWhenEmpty() {
        let config = InputGainConfig.fromEnvironment([:])
        XCTAssertEqual(config, .defaults)
    }

    /// Рубильник: DICTATION_GAIN_DISABLED=1/true/TRUE выключает фичу,
    /// нераспознанное значение не трогает (fail-closed).
    @objc func testFromEnvironmentDisabledSwitch() {
        for value in ["1", "true", "TRUE"] {
            let config = InputGainConfig.fromEnvironment(["DICTATION_GAIN_DISABLED": value])
            XCTAssertFalse(config.enabled, "DICTATION_GAIN_DISABLED=\(value) выключает фичу")
        }
        let config = InputGainConfig.fromEnvironment(["DICTATION_GAIN_DISABLED": "maybe"])
        XCTAssertTrue(config.enabled, "некорректное значение рубильника игнорируется")
    }

    /// Цель и потолок из окружения доезжают до применения.
    @objc func testFromEnvironmentTargetAndMaxParse() {
        let config = InputGainConfig.fromEnvironment([
            "DICTATION_GAIN_TARGET_DB": "-25",
            "DICTATION_GAIN_MAX_DB": "40",
        ])
        XCTAssertEqual(config.targetRmsDb, -25, accuracy: 0.000001)
        XCTAssertEqual(config.maxGainDb, 40, accuracy: 0.000001, "потолок из окружения")
        XCTAssertTrue(config.enabled, "параметры не трогают рубильник")
        XCTAssertEqual(config.attackTime, InputGainConfig.defaults.attackTime, "постоянные времени — дефолтные")

        // Применение: с кастомной целью ±25 дБ работает та же математика.
        let gain = InputGain(config: config)
        var buffer = constantBuffer(amplitude(forRmsDb: -49), frames: sampleRate)
        let inRms = rmsOf(buffer)
        let outRms = gain.apply(to: &buffer, rms: inRms, sampleRate: sampleRate)
        XCTAssertEqual(dbfs(outRms), -25, accuracy: 3.0, "кастомная цель ±25 dBFS")
    }

    /// Некорректные значения игнорируются — остаётся дефолт (опечатка не ломает
    /// ни включённость, ни границы).
    @objc func testFromEnvironmentInvalidValuesIgnored() {
        let config = InputGainConfig.fromEnvironment([
            "DICTATION_GAIN_TARGET_DB": "abc",   // не число
            "DICTATION_GAIN_TARGET_DBX": "-25",  // другое имя не читается
            "DICTATION_GAIN_TARGET_DB2": "10",   // цель должна быть ниже 0 dBFS
            "DICTATION_GAIN_MAX_DB": "-5",       // потолок должен быть > 0
            "DICTATION_GAIN_MAX_DBX": "70",      // потолок ≤ 60
        ])
        XCTAssertEqual(config, .defaults, "некорректные значения — конфигурация по умолчанию")
    }

    // MARK: - Отключённая фича: буфер проходит без изменений

    /// DICTATION_GAIN_DISABLED → InputGain с enabled=false: apply не трогает
    /// буфер (хоть громкий, хоть тихий) и возвращает исходный RMS.
    @objc func testDisabledGainPassesBufferThrough() {
        let config = InputGainConfig.fromEnvironment(["DICTATION_GAIN_DISABLED": "1"])
        XCTAssertFalse(config.enabled)
        let gain = InputGain(config: config)

        var buffer = constantBuffer(amplitude(forRmsDb: -49), frames: sampleRate)
        let original = buffer
        let inRms = rmsOf(buffer)

        let outRms = gain.apply(to: &buffer, rms: inRms, sampleRate: sampleRate)

        XCTAssertEqual(outRms, inRms, accuracy: 0.000001)
        XCTAssertEqual(buffer, original, "выключенная фича — буфер без изменений")
        XCTAssertEqual(gain.currentGainDb, 0)
        // targetGainDb тоже честно отдаёт 0 при выключенном рубильнике.
        XCTAssertEqual(gain.targetGainDb(forRms: 0.000001), 0)
    }

    /// reset() обнуляет накопленный gain — новый сеанс записи не стартует
    /// с усиления прошлого.
    @objc func testResetClearsAccumulatedGain() {
        let gain = InputGain()
        var buffer = constantBuffer(amplitude(forRmsDb: -49), frames: sampleRate)
        let inRms = rmsOf(buffer)
        gain.apply(to: &buffer, rms: inRms, sampleRate: sampleRate)
        XCTAssertGreaterThanOrEqual(gain.currentGainDb, 20, "предусловие: gain накоплен")
        gain.reset()
        XCTAssertEqual(gain.currentGainDb, 0)
    }

    /// Пустой буфер: apply возвращает rms как есть, ничего не трогает.
    @objc func testEmptyBufferPassesThrough() {
        let gain = InputGain()
        var buffer: [Float] = []
        let outRms = gain.apply(to: &buffer, rms: 0.2, sampleRate: sampleRate)
        XCTAssertEqual(outRms, 0.2, accuracy: 0.000001)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(gain.currentGainDb, 0)
    }

    /// Тишина после усиленной речи проходит БЕЗ изменений и сбрасывает
    /// накопленный gain: без этого гарда хвост release (~0.3 c) утекал бы
    /// в тишину, тянул её вверх и сбивал VAD/автостоп («тишина не усиливается
    /// вовсе» — регресс чанк-тестов AudioServiceVADTests).
    @objc func testSilenceAfterAmplifiedSpeechPassesThroughAndResetsGain() {
        let gain = InputGain()
        var speech = constantBuffer(amplitude(forRmsDb: -49), frames: sampleRate)
        let speechRms = rmsOf(speech)
        gain.apply(to: &speech, rms: speechRms, sampleRate: sampleRate)
        XCTAssertGreaterThanOrEqual(gain.currentGainDb, 20, "предусловие: gain накоплен")

        var silence = constantBuffer(amplitude(forRmsDb: -60), frames: sampleRate)
        let original = silence
        let inRms = rmsOf(silence)
        let outRms = gain.apply(to: &silence, rms: inRms, sampleRate: sampleRate)

        XCTAssertEqual(outRms, inRms, accuracy: 0.000001, "тишина не усиливается")
        XCTAssertEqual(silence, original, "тишина — passthrough без остаточного gain")
        XCTAssertEqual(gain.currentGainDb, 0, "тишина сбрасывает накопленное усиление")
    }

    // MARK: - Интеграция через AudioService

    /// Сквозная проверка проводки: AudioService.process применяет gain к
    /// буферу, levelDelegate получает УСИЛЕННЫЙ RMS, а stop() возвращает
    /// усиленные Int16-сэмплы (вход −46 dBFS, на записи пики ~ +26 дБ).
    @objc func testAudioServiceAmplifiesLevelAndSamples() {
        let engine = GainFakeEngine()
        // Явная конфигурация (не fromEnvironment): тест не должен зависеть от
        // DICTATION_GAIN_DISABLED в окружении прогона.
        let service = AudioService(logLevel: "info", engine: engine, gainConfig: InputGainConfig.defaults)
        let delegate = LevelBox()
        service.levelDelegate = delegate

        let result = runStart(service)
        guard case .success = result else {
            XCTFail("старт не удался: \(result)")
            return
        }

        // Один буфер тихой константной речи: −46 dBFS → нужна компенсация.
        engine.node.emit(constantBuffer(amplitude(forRmsDb: -46), frames: 8192, sampleRate: 44100))

        let samples = service.stop()
        XCTAssertFalse(samples.isEmpty, "запись собрала сэмплы")
        let maxAbs = samples.map { abs(Int($0)) }.max() ?? 0
        XCTAssertGreaterThanOrEqual(maxAbs, 1500, "усиленный сигнал: пик Int16 > 1500 (без усиления был бы ~164)")
        XCTAssertLessThanOrEqual(maxAbs, 32767, "Int16 в пределах полной шкалы")
        XCTAssertNotNil(delegate.lastRms, "levelDelegate получил уровень")
        if let rms = delegate.lastRms {
            XCTAssertGreaterThanOrEqual(rms, 0.04, "делегат видит усиленный RMS (~ −22 dBFS), а не входной 0.005")
            XCTAssertLessThanOrEqual(rms, 0.13, "и не выше полной шкалы речи")
        }
    }
}

// MARK: - Фейковый движок для InputGain-интеграции (стиль AudioServiceLifecycleTests)

/// Фейк движка: тап хранит колбэк, emit() дёргает его синхронно (как в
/// существующих lifecycle-тестах), конвертация идёт настоящим AVAudioConverter.
private final class GainFakeNode: AudioInputNodeLike {
    let format: AVAudioFormat
    var tapBlock: AVAudioNodeTapBlock?

    init(sampleRate: Double = 44100) {
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
    }

    func outputFormat(forBus bus: AVAudioNodeBus) -> AVAudioFormat { format }

    func installTap(
        onBus bus: AVAudioNodeBus,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block tapBlock: @escaping AVAudioNodeTapBlock
    ) {
        self.tapBlock = tapBlock
    }

    func removeTap(onBus bus: AVAudioNodeBus) {}

    /// Эмитирует один PCM-буфер в обработку (в проде это делает аудио-поток).
    func emit(_ buffer: AVAudioPCMBuffer) {
        tapBlock?(buffer, AVAudioTime())
    }
}

private final class GainFakeEngine: AudioEngineLike {
    let node = GainFakeNode()
    private(set) var startCount = 0

    func makeInputNode() -> AudioInputNodeLike { node }
    func prepare() {}
    func start() throws { startCount += 1 }
    func stop() {}
}

/// Контейнер для уровня, который получает live-делегат (слабый по контракту).
private final class LevelBox: AudioLevelDelegate {
    var lastRms: Float?
    func audioLevelChanged(rms: Float) {
        lastRms = rms
    }
}

// MARK: - Хелперы ожидания

private extension InputGainTests {
    typealias StartResult = Result<Void, Error>

    /// Ждёт completion асинхронного старта (RunLoop крутится — как в проде
    /// главный поток). Возвращает результат старта.
    func runStart(_ service: AudioService) -> StartResult {
        let done = expectation(description: "audio start completion")
        var result: StartResult = .failure(AudioServiceError.engineGone)
        service.start { r in
            result = r
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return done.isFulfilled ? result : .failure(AudioServiceError.engineGone)
    }

    /// PCM-буфер константной амплитуды для эмиссии в tap.
    func constantBuffer(_ amplitude: Float, frames: Int, sampleRate: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        let data = buf.floatChannelData![0]
        for i in 0..<frames { data[i] = amplitude }
        return buf
    }
}