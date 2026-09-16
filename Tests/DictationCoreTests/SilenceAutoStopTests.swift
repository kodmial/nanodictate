import Foundation
@testable import DictationCore

/// Юнит-тесты чистого детектора автоостановки записи по непрерывной тишине
/// (задача: авто-стоп по 3-секундной тишине). Никакого I/O — только математика
/// `SilenceAutoStopDetector`, поэтому границы проверяются на точных значениях:
///
///   • ровно 3.0 c непрерывной тишины → СРАБАТЫВАЕТ (feed вернул true);
///   • 2.9 c — НЕ срабатывает (пауза короче 3 c запись не останавливает);
///   • возобновление речи сбрасывает накопитель — тишина до и после речи
///     не суммируется;
///   • порог СТРОГО ниже: rms == threshold — это УЖЕ речь (сброс), rms чуть
///     выше порога — речь, rms чуть ниже — тишина (накопление).
///
/// Единица буфера — половина секунды (0.5): точно представима в двоичной
/// арифметике, поэтому граница 3.0 c собирается из 6 буферов РОВНО.
final class SilenceAutoStopTests: XCTestCase {

    /// Порог по умолчанию — документированная константа всей кодовой базы
    /// (−50 dBFS, тот же silenceRMS у сегментера и live-VAD).
    @objc func testDefaultThresholdMatchesAudioMetrics() {
        let detector = SilenceAutoStopDetector()
        XCTAssertEqual(
            detector.silenceRMSThreshold,
            AudioMetrics.nearSilenceThreshold,
            "порог авто-стопа = общему порогу тишины проекта"
        )
        XCTAssertEqual(detector.requiredSilenceDuration, 3.0, "требование фичи: ~3 секунды")
        XCTAssertEqual(detector.silenceDuration, 0, accuracy: 0.000001, "старт с нуля")
    }

    /// Граница: ровно 3.0 c непрерывной тишины → сработало.
    /// Шесть тихих буферов по 0.5 c (0.5 точно представим) = ровно 3.0 — тот
    /// же кейс, что «пользователь замолчал на 3 секунды».
    @objc func testFiresExactlyAtThreeSecondsBoundary() {
        var detector = SilenceAutoStopDetector()
        var fired = false
        // 5 × 0.5 = 2.5 c — ещё нет.
        for _ in 0..<5 {
            fired = detector.feed(rms: 0.001, duration: 0.5)
            XCTAssertFalse(fired, "2.5 c тишины — пауза < 3 c, не срабатывает")
        }
        XCTAssertEqual(detector.silenceDuration, 2.5, accuracy: 0.000001)
        // 6-й буфер доводит ровно до 3.0 c.
        fired = detector.feed(rms: 0.001, duration: 0.5)
        XCTAssertTrue(fired, "ровно 3.0 c непрерывной тишины → стоп")
        XCTAssertEqual(detector.silenceDuration, 3.0, accuracy: 0.000001)
    }

    /// Не срабатывает при 2.9 c: 5 × 0.5 + 0.4. Требование: паузы < 3 c
    /// запись НЕ останавливают — это пауза в речи, а не конец диктовки.
    @objc func testDoesNotFireAtTwoPointNineSeconds() {
        var detector = SilenceAutoStopDetector()
        var fired = false
        for _ in 0..<5 {
            fired = detector.feed(rms: 0.001, duration: 0.5)
        }
        XCTAssertFalse(fired)
        fired = detector.feed(rms: 0.001, duration: 0.4)
        XCTAssertFalse(fired, "2.9 c — всё ещё меньше 3 c")
        XCTAssertEqual(detector.silenceDuration, 2.9, accuracy: 0.000001)
    }

    /// Сброс счётчика при возобновлении речи: 2 c тишины → 0.5 c речи →
    /// 2 c тишины. Суммарно 4 c тишины, но НЕ непрерывной — срабатывания нет
    /// (иначе «задумчивая пауза» посреди речи остановила бы запись).
    @objc func testSpeechResetsAccumulatedSilence() {
        var detector = SilenceAutoStopDetector()
        // 2 c тишины.
        for _ in 0..<4 {
            _ = detector.feed(rms: 0.001, duration: 0.5)
        }
        XCTAssertEqual(detector.silenceDuration, 2.0, accuracy: 0.000001)
        // Речь: RMS ≥ порога → накопитель обнуляется.
        _ = detector.feed(rms: 0.2, duration: 0.5)
        XCTAssertEqual(detector.silenceDuration, 0, accuracy: 0.000001, "речь сбрасывает тишину")
        // Ещё 2 c тишины после речи: накопитель 2.0, а не 4.0 — не сработало.
        for _ in 0..<4 {
            _ = detector.feed(rms: 0.001, duration: 0.5)
        }
        XCTAssertEqual(detector.silenceDuration, 2.0, accuracy: 0.000001, "тишина до и после речи не суммируется")
        // И только НЕПРЕРЫВНОЕ продолжение до 3.0 срабатывает: от 2.0 ещё нужны
        // ДВА буфера по 0.5 (2.5 → 3.0), а не один.
        XCTAssertFalse(detector.feed(rms: 0.001, duration: 0.5), "2.5 c после речи — всё ещё < 3 c")
        let fired = detector.feed(rms: 0.001, duration: 0.5)
        XCTAssertTrue(fired, "непрерывная тишина после сброса считается заново")
    }

    /// Строгий порог (согласовано с AudioMetrics.isNearSilence):
    /// rms РОВНО threshold — это речь (сброс); на один шаг ниже — тишина;
    /// на шаг выше — речь. Mirror поведения сегментера: «уже не тишина».
    @objc func testThresholdIsStrictlyBelow() {
        let threshold = AudioMetrics.nearSilenceThreshold
        var detector = SilenceAutoStopDetector()

        // На один шаг ниже порога → тишина, накопление идёт.
        _ = detector.feed(rms: threshold * 0.999, duration: 1.0)
        XCTAssertEqual(detector.silenceDuration, 1.0, accuracy: 0.000001, "rms чуть ниже порога — тишина")
        XCTAssertFalse(detector.silenceDuration >= 3.0)

        // Ровно на пороге → сброс (речь: порог — граница «в пользу» звука,
        // чтобы нулевой/пограничный RMS не держал накопитель на грани).
        _ = detector.feed(rms: threshold, duration: 1.0)
        XCTAssertEqual(detector.silenceDuration, 0, accuracy: 0.000001, "rms == порог — речь, накопитель сброшен")

        // Чуть выше порога → речь.
        _ = detector.feed(rms: threshold * 1.001, duration: 1.0)
        XCTAssertEqual(detector.silenceDuration, 0, accuracy: 0.000001, "rms чуть выше порога — речь")
    }

    /// После срабатывания детектор продолжает честно отвечать «тишина ≥ 3 c»
    /// на последующих тихих буферах; защёлку «остановка уже запланирована»
    /// держит AudioService (autoStopScheduled), а не детектор.
    @objc func testStaysFiredWhileSilenceContinues() {
        var detector = SilenceAutoStopDetector()
        for _ in 0..<6 { _ = detector.feed(rms: 0.001, duration: 0.5) }
        XCTAssertTrue(detector.feed(rms: 0.001, duration: 0.5), "продолжение тишины — по-прежнему сработано")
        XCTAssertTrue(detector.feed(rms: 0.001, duration: 0.5))
        XCTAssertEqual(detector.silenceDuration, 4.0, accuracy: 0.000001, "накопитель не замирает после порога")
    }

    /// reset(): новый сеанс записи начинает с чистого накопителя, даже если
    /// предыдущий сеанс закончился «сработавшим» детектором.
    @objc func testResetClearsAccumulatorAfterFire() {
        var detector = SilenceAutoStopDetector()
        for _ in 0..<6 { _ = detector.feed(rms: 0.001, duration: 0.5) }
        XCTAssertTrue(detector.feed(rms: 0.001, duration: 0.5))
        detector.reset()
        XCTAssertEqual(detector.silenceDuration, 0, accuracy: 0.000001)
        XCTAssertFalse(detector.feed(rms: 0.001, duration: 1.0), "после reset 1 c тишины не срабатывает")
    }

    /// Правило «>= requiredSilenceDuration» с нестандартной конфигурацией:
    /// требуемая тишина 1.0 c срабатывает ровно на 1.0 (2 × 0.5), а не на 0.5.
    @objc func testCustomRequiredDuration() {
        var detector = SilenceAutoStopDetector(
            silenceRMSThreshold: 0.01,
            requiredSilenceDuration: 1.0
        )
        XCTAssertFalse(detector.feed(rms: 0.001, duration: 0.5), "0.5 c < 1.0 c")
        XCTAssertTrue(detector.feed(rms: 0.001, duration: 0.5), "ровно 1.0 c → сработало")
    }

    /// Один длинный тихий буфер (например, 3-секундный чанк тишины, пришедший
    /// одним обработанным куском) срабатывает сразу — накопление по реальной
    /// длительности, а не по числу буферов.
    @objc func testSingleLongSilenceBufferFires() {
        var detector = SilenceAutoStopDetector()
        XCTAssertTrue(detector.feed(rms: 0.001, duration: 3.0), "один буфер длительностью 3.0 c")
    }

    /// Отрицательная длительность (защита от мусорного ввода) клампится в 0:
    /// накопитель не может пойти назад, срабатывание не наступает по дефектному
    /// вводу.
    @objc func testNegativeDurationIsClampedToZero() {
        var detector = SilenceAutoStopDetector()
        _ = detector.feed(rms: 0.001, duration: -1.0)
        XCTAssertEqual(detector.silenceDuration, 0, accuracy: 0.000001, "отрицательная длительность — 0")
        XCTAssertFalse(detector.feed(rms: 0.001, duration: -0.5), "мусорная длительность не запускает стоп")
    }

    /// Нулевая длительность ничего не накапливает (но и не сбрасывает).
    @objc func testZeroDurationAccumulatesNothing() {
        var detector = SilenceAutoStopDetector()
        _ = detector.feed(rms: 0.001, duration: 0)
        XCTAssertEqual(detector.silenceDuration, 0, accuracy: 0.000001)
        XCTAssertFalse(detector.silenceDuration >= 3.0)
    }

    /// Речь в середине длительной тишины обнуляет накопитель, и следующий за
    /// этим тихий буфер не «добирает» старую тишину — непрерывность обязательна
    /// (сценарий «задумался → сказал слово → замолчал»: 2.9 + слово + 0.2 —
    /// стопа нет, хотя суммарной тишины 3.1 c).
    @objc func testSpeechBetweenSilencesResetsContinuity() {
        var detector = SilenceAutoStopDetector()
        // 2.9 c тишины.
        for _ in 0..<5 { _ = detector.feed(rms: 0.001, duration: 0.5) }
        _ = detector.feed(rms: 0.001, duration: 0.4)
        // Слово (0.2). Накопитель обнулился.
        _ = detector.feed(rms: 0.5, duration: 0.2)
        XCTAssertEqual(detector.silenceDuration, 0, accuracy: 0.000001)
        // 0.2 c тишины после слова.
        XCTAssertFalse(detector.feed(rms: 0.001, duration: 0.2), "0.2 c после слова при суммарных 3.1 c — не стоп")
        XCTAssertEqual(detector.silenceDuration, 0.2, accuracy: 0.000001)
    }

    // MARK: - Рубильник и пломбинг из окружения (AutoStopConfig)

    /// Дефолтная конфигурация — фича ВКЛЮЧЕНА, ровно по задаче: 3 c / −50 dBFS.
    /// Рубильник — спасательный люк, он не должен менять поведение по умолчанию.
    @objc func testDefaultsAreEnabledAndMatchTask() {
        let config = AutoStopConfig.defaults
        XCTAssertTrue(config.enabled, "дефолт — фича включена (задача: 3 c → авто-стоп)")
        XCTAssertEqual(config.requiredSilenceDuration, 3.0)
        XCTAssertEqual(config.silenceRMSThreshold, AudioMetrics.nearSilenceThreshold)
    }

    /// Пустое окружение → ровно `.defaults`: ни один из env-ключей не задан —
    /// пломбинг не трогает поведение, бинарь работает как раньше.
    @objc func testFromEnvironmentDefaultsWhenEmpty() {
        let config = AutoStopConfig.fromEnvironment([:])
        XCTAssertEqual(config, .defaults, "пустое окружение — конфигурация по задаче")
        XCTAssertTrue(config.enabled)
    }

    /// Рубильник DICTATION_AUTOSTOP_DISABLED: 1/true выключают фичу,
    /// остальные ключи не влияют на сам рубильник.
    @objc func testFromEnvironmentDisabledSwitch() {
        for value in ["1", "true", "TRUE"] {
            let config = AutoStopConfig.fromEnvironment(["DICTATION_AUTOSTOP_DISABLED": value])
            XCTAssertFalse(config.enabled, "DICTATION_AUTOSTOP_DISABLED=\(value) выключает фичу")
        }
        // Нераспознанное значение рубильник не трогает (fail-closed: выключение
        // только по явному 1/true — случайная строка не отключает фичу).
        let config = AutoStopConfig.fromEnvironment(["DICTATION_AUTOSTOP_DISABLED": "maybe"])
        XCTAssertTrue(config.enabled, "некорректное значение рубильника игнорируется")
    }

    /// Настройка длительности: DICTATION_AUTOSTOP_DURATION в секундах (Double).
    @objc func testFromEnvironmentDurationOverride() {
        let config = AutoStopConfig.fromEnvironment(["DICTATION_AUTOSTOP_DURATION": "5"])
        XCTAssertEqual(config.requiredSilenceDuration, 5.0, accuracy: 0.000001, "длительность из окружения")
        XCTAssertTrue(config.enabled, "длительность не трогает рубильник")
        XCTAssertEqual(config.silenceRMSThreshold, AudioMetrics.nearSilenceThreshold, "порог RMS остаётся дефолтным")
    }

    /// Настройка порога: DICTATION_AUTOSTOP_RMS в линейной шкале (Float).
    @objc func testFromEnvironmentRMSOverride() {
        let config = AutoStopConfig.fromEnvironment(["DICTATION_AUTOSTOP_RMS": "0.01"])
        XCTAssertEqual(config.silenceRMSThreshold, 0.01, accuracy: 0.000001, "порог тишины из окружения")
        XCTAssertEqual(config.requiredSilenceDuration, 3.0, "длительность остаётся дефолтной")
    }

    /// Некорректные значения ключей игнорируются — остаётся дефолт (спасательный
    /// люк не стреляет мимо: опечатка не ломает ни включённость, ни границы).
    @objc func testFromEnvironmentInvalidValuesIgnored() {
        let config = AutoStopConfig.fromEnvironment([
            "DICTATION_AUTOSTOP_DURATION": "abc",
            "DICTATION_AUTOSTOP_DURATION_EXTRA": "5", // другое имя не читается
            "DICTATION_AUTOSTOP_RMS": "-0.5", // порог должен быть > 0
        ])
        XCTAssertEqual(config, .defaults, "некорректные значения — конфигурация по умолчанию")
    }

    /// В комбинации ключи складываются; отключение имеет приоритет над
    /// длительностью/порогом (параметры не важны, когда фича выключена).
    @objc func testFromEnvironmentCombined() {
        let config = AutoStopConfig.fromEnvironment([
            "DICTATION_AUTOSTOP_DURATION": "2",
            "DICTATION_AUTOSTOP_RMS": "0.005",
            "DICTATION_AUTOSTOP_DISABLED": "1",
        ])
        XCTAssertFalse(config.enabled, "рубильник выключил фичу")
        XCTAssertEqual(config.requiredSilenceDuration, 2.0, accuracy: 0.000001)
        XCTAssertEqual(config.silenceRMSThreshold, 0.005, accuracy: 0.000001)
    }

    /// Превращение сконфигурированного порога в рабочий детектор: AudioService
    /// строит детектор из полей конфига — они доезжают до feed() нетронутыми.
    @objc func testConfigFieldsReachDetector() {
        let config = AutoStopConfig.fromEnvironment([
            "DICTATION_AUTOSTOP_DURATION": "1",
            "DICTATION_AUTOSTOP_RMS": "0.01",
        ])
        var detector = SilenceAutoStopDetector(
            silenceRMSThreshold: config.silenceRMSThreshold,
            requiredSilenceDuration: config.requiredSilenceDuration
        )
        XCTAssertTrue(detector.feed(rms: 0.005, duration: 1.0), "rms<порог и ровно 1.0 c → сработало")
        XCTAssertFalse(detector.feed(rms: 0.02, duration: 1.0), "речь сбрасывает")
    }
}