import Foundation
@testable import NanoDictateCore

// MARK: - Автоостановка по непрерывной тишине: гистерезис, grace, гейт «речь была»

/// Модель детектора — гистерезисная пара порогов −45/−58 дБФС, grace после
/// старта записи, гейт «речь была» и минимальная длительность записи (см.
/// AutoStopConfig в SilenceAutoStop.swift). Здесь — чистые буферы с
/// контролируемым временем: конфиг строится явно, длительность буфера задаётся
/// в секундах напрямую (частота колбэков на числа не влияет).
///
/// Условные уровни (линейный RMS):
///   • уверенная речь     0.5      (≫ порога речи 0.00562)
///   • граница речи       0.00562  (≥ порога → речь)
///   • серая зона         0.00251  (−52 дБФС: тихая речь — между порогами)
///   • граница тишины     0.00126  (строго ниже → тишина)
///   • реальная тишина    0.0001   (шумовой фон −80 дБФС)
///
/// Важное следствие модели: ЛЮБОЙ речевой буфер возвращает false (речь рвёт
/// непрерывность тишины, значит «тишина ≥ порога» в этот момент невозможна);
/// гейт проверяется через `speechGatePassed`, а не через результат feed.
final class SilenceAutoStopTests: XCTestCase {

    // MARK: - Дефолты и гистерезисная пара порогов

    /// Дефолты: рубильник включён, пара порогов −45/−58 дБФС (речь ≥ тишина),
    /// непрерывная тишина 3 c, grace 2 c, гейт 0.3 c, пол записи 3 c.
    /// Порог ТИШИНЫ намеренно СТРОЖЕ общего AudioMetrics.nearSilenceThreshold
    /// (−50 дБФС): тот лежит ВНУТРИ динамики тихой речи (−48.6…−55 дБФС) — из-за
    /// чего и обрывалась запись; у автоостановки тишина = честный шумовой фон.
    @objc func testDefaultsModel() {
        let config = AutoStopConfig.defaults
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.speechRMSThreshold, 0.00562, "речь ≥ −45 дБФС")
        XCTAssertEqual(config.silenceRMSThreshold, 0.00126, "тишина < −58 дБФС")
        XCTAssertGreaterThanOrEqual(config.speechRMSThreshold, config.silenceRMSThreshold, "инвариант гистерезиса")
        XCTAssertLessThanOrEqual(config.silenceRMSThreshold, AudioMetrics.nearSilenceThreshold, "тишина автоостановки строже общего порога −50 дБФС")
        XCTAssertFalse(config.silenceRMSThreshold == AudioMetrics.nearSilenceThreshold, "пороги намеренно разные: общий −50 дБФС лежит внутри динамики тихой речи")
        XCTAssertEqual(config.requiredSilenceDuration, 3.0)
        XCTAssertEqual(config.gracePeriod, 2.0)
        XCTAssertEqual(config.minSpeechRun, 0.3)
        XCTAssertEqual(config.minRecordingDuration, 3.0)
        let detector = SilenceAutoStopDetector()
        XCTAssertEqual(detector.speechRMSThreshold, config.speechRMSThreshold)
        XCTAssertEqual(detector.silenceRMSThreshold, config.silenceRMSThreshold)
        XCTAssertEqual(detector.gracePeriod, config.gracePeriod)
        XCTAssertEqual(detector.minSpeechRun, config.minSpeechRun)
        XCTAssertEqual(detector.minRecordingDuration, config.minRecordingDuration)
    }

    /// Инвариант гистерезиса зашит и в детектор: речь не может распознаваться
    /// «тише», чем тишина, — какой бы конфиг ни пришёл, порог речи клампится
    /// вверх до порога тишины.
    @objc func testDetectorInvariantClampsSpeechBelowSilence() {
        let detector = SilenceAutoStopDetector(silenceRMSThreshold: 0.05, speechRMSThreshold: 0.02)
        XCTAssertEqual(detector.speechRMSThreshold, 0.05, "порог речи поднят до порога тишины")
        XCTAssertEqual(detector.silenceRMSThreshold, 0.05)
    }

    /// Тот же инвариант в конфиге: AutoStopConfig.init клампит порог речи
    /// до порога тишины (защита от ручной сборки конфига в коде).
    @objc func testConfigInitClampsSpeechBelowSilence() {
        let config = AutoStopConfig(speechRMSThreshold: 0.01, silenceRMSThreshold: 0.02)
        XCTAssertEqual(config.speechRMSThreshold, 0.02, "порог речи поднят до порога тишины")
        XCTAssertEqual(config.silenceRMSThreshold, 0.02)
        XCTAssertTrue(config.enabled, "остальные поля конфига — дефолты")
        XCTAssertEqual(config.requiredSilenceDuration, 3.0)
        XCTAssertEqual(config.gracePeriod, 2.0)
        XCTAssertEqual(config.minSpeechRun, 0.3)
        XCTAssertEqual(config.minRecordingDuration, 3.0)
    }

    // MARK: - Env-переопределения

    /// Пустое окружение = ровно `.defaults` (совместимость с прогоном без env).
    @objc func testFromEnvironmentDefaultsWhenEmpty() {
        XCTAssertEqual(AutoStopConfig.fromEnvironment([:]), .defaults)
    }

    /// Рубильник выключения фичи.
    @objc func testFromEnvironmentDisabledSwitch() {
        var env = [String: String]()
        env["NANODICTATE_AUTOSTOP_DISABLED"] = "1"
        XCTAssertFalse(AutoStopConfig.fromEnvironment(env).enabled)
        env["NANODICTATE_AUTOSTOP_DISABLED"] = "true"
        XCTAssertFalse(AutoStopConfig.fromEnvironment(env).enabled)
        env["NANODICTATE_AUTOSTOP_DISABLED"] = "TRUE"
        XCTAssertFalse(AutoStopConfig.fromEnvironment(env).enabled)
        env["NANODICTATE_AUTOSTOP_DISABLED"] = "0"
        XCTAssertTrue(AutoStopConfig.fromEnvironment(env).enabled, "0 — не признак выключения")
    }

    /// Переопределение длительности непрерывной тишины.
    @objc func testFromEnvironmentDurationOverride() {
        var env = [String: String]()
        env["NANODICTATE_AUTOSTOP_DURATION"] = "5.5"
        let config = AutoStopConfig.fromEnvironment(env)
        XCTAssertEqual(config.requiredSilenceDuration, 5.5)
        XCTAssertEqual(config.speechRMSThreshold, AutoStopConfig.defaultSpeechRMSThreshold, "остальные поля — дефолты")
    }

    /// Переопределение порога ТИШИНЫ: порог речи клампится вверх, чтобы не
    /// нарушить инвариант гистерезиса («громкая тишина» и «тихая речь» не могут
    /// инвертироваться).
    @objc func testFromEnvironmentSilenceRMSOverride() {
        var env = [String: String]()
        env["NANODICTATE_AUTOSTOP_RMS"] = "0.01"
        let config = AutoStopConfig.fromEnvironment(env)
        XCTAssertEqual(config.silenceRMSThreshold, 0.01)
        XCTAssertEqual(config.speechRMSThreshold, 0.01, "порог речи поднят до порога тишины")
    }

    /// Переопределение порога РЕЧИ (новый ключ; порог тишины не трогается,
    /// пока речь не «провалилась» ниже тишины).
    @objc func testFromEnvironmentSpeechRMSOverride() {
        var env = [String: String]()
        env["NANODICTATE_AUTOSTOP_SPEECH_RMS"] = "0.02"
        let config = AutoStopConfig.fromEnvironment(env)
        XCTAssertEqual(config.speechRMSThreshold, 0.02)
        XCTAssertEqual(config.silenceRMSThreshold, AutoStopConfig.defaultSilenceRMSThreshold)
    }

    /// Клампинг речи при «перевёрнутой» комбинации: тишина 0.03, речь 0.01 →
    /// речь поднята до 0.03.
    @objc func testFromEnvironmentSpeechClampedToSilence() {
        var env = [String: String]()
        env["NANODICTATE_AUTOSTOP_RMS"] = "0.03"
        env["NANODICTATE_AUTOSTOP_SPEECH_RMS"] = "0.01"
        let config = AutoStopConfig.fromEnvironment(env)
        XCTAssertEqual(config.silenceRMSThreshold, 0.03)
        XCTAssertEqual(config.speechRMSThreshold, 0.03)
    }

    /// Некорректные значения игнорируются (строго > 0, битые строки — мимо),
    /// конфиг остаётся на дефолтах.
    @objc func testFromEnvironmentInvalidValuesIgnored() {
        var env = [String: String]()
        env["NANODICTATE_AUTOSTOP_DURATION"] = "abc"
        env["NANODICTATE_AUTOSTOP_RMS"] = "x"
        env["NANODICTATE_AUTOSTOP_SPEECH_RMS"] = ""
        XCTAssertEqual(AutoStopConfig.fromEnvironment(env), .defaults)
        env["NANODICTATE_AUTOSTOP_DURATION"] = "-1"
        env["NANODICTATE_AUTOSTOP_RMS"] = "0"
        env["NANODICTATE_AUTOSTOP_SPEECH_RMS"] = "-2"
        XCTAssertEqual(AutoStopConfig.fromEnvironment(env), .defaults)
    }

    /// Комбинированный env доезжает до детектора: конфиг → конструктор
    /// детектора (та же передача, что в AudioService.init) → поведение.
    /// Единый «сквозной» тест пломбинга без AudioService.
    @objc func testConfigurationReachesDetector() {
        let config = AutoStopConfig(
            speechRMSThreshold: 0.03,
            silenceRMSThreshold: 0.02,
            requiredSilenceDuration: 1.0,
            gracePeriod: 0,
            minSpeechRun: 0.1,
            minRecordingDuration: 0
        )
        var detector = SilenceAutoStopDetector(
            silenceRMSThreshold: config.silenceRMSThreshold,
            speechRMSThreshold: config.speechRMSThreshold,
            requiredSilenceDuration: config.requiredSilenceDuration,
            gracePeriod: config.gracePeriod,
            minSpeechRun: config.minSpeechRun,
            minRecordingDuration: config.minRecordingDuration
        )
        // Речь 0.5 c → гейт (0.5 ≥ 0.1), тишина 1.0 c → ровно required → стоп.
        XCTAssertFalse(detector.feed(rms: 0.2, duration: 0.5), "речь не останавливает")
        XCTAssertTrue(detector.speechGatePassed)
        XCTAssertTrue(detector.feed(rms: 0.001, duration: 1.0), "тишина ≥ required + гейт + пол пройден")
    }

    // MARK: - Гейт «речь была» и grace

    /// Главный регрессионный сценарий бага: ТИХАЯ речь (самый центр «серой
    /// зоны», −52 дБФС — ровно тот уровень, что раньше обрывал запись) НЕ копит
    /// молчание и НЕ останавливает запись сколько угодно долго. Гистерезис
    /// держит такой буфер в «без изменения»: ниже порога речи ≠ тишина.
    @objc func testQuietSpeechAtMinus52DoesNotFire() {
        var detector = SilenceAutoStopDetector()
        var fired = false
        for _ in 0..<20 {
            if detector.feed(rms: 0.00251, duration: 0.5) { fired = true }
        }
        XCTAssertFalse(fired, "тихая речь −52 дБФС не останавливает запись")
        XCTAssertEqual(detector.silenceDuration, 0, "серая зона не накапливается")
        XCTAssertEqual(detector.elapsed, 10.0)
        XCTAssertFalse(detector.speechGatePassed, "в серой зоне речь (для гейта) не накапливается")
    }

    /// Сквозной сценарий «спокойная диктовка → конец речи → автостоп»: 2 c
    /// уверенной речи (гейт), 3 c тихой речи в серой зоне (не тишина!), и
    /// только после этого настоящая тишина ≥ 3 c останавливает запись. Режет
    /// паузу после окончания диктовки, а не диктовку.
    @objc func testQuietTalkThenRealSilenceFiresAtThreeSeconds() {
        var detector = SilenceAutoStopDetector() // дефолты: grace 2, гейт 0.3, пол 3, тишина 3
        // Речь 4 × 0.5 = 2.0 c (гейт ≥ 0.3 защёлкнут) — тишина не копится.
        for _ in 0..<4 {
            XCTAssertFalse(detector.feed(rms: 0.3, duration: 0.5), "речь не останавливает")
        }
        XCTAssertTrue(detector.speechGatePassed)
        // Тихая речь 6 × 0.5 = 3.0 c в серой зоне — молчание не копится.
        for _ in 0..<6 {
            XCTAssertFalse(detector.feed(rms: 0.00251, duration: 0.5), "тихая диктовка не режется")
        }
        XCTAssertEqual(detector.silenceDuration, 0)
        // Настоящая тишина: буферы позже grace-окна копятся, стоп на 3.0 c.
        var silenceRun: [Bool] = []
        for _ in 0..<8 {
            silenceRun.append(detector.feed(rms: 0.0001, duration: 0.5))
        }
        XCTAssertFalse(silenceRun[0], "0.5 c тишины — ещё не молчание ≥ 3 c")
        XCTAssertFalse(silenceRun[1])
        XCTAssertFalse(silenceRun[2])
        XCTAssertFalse(silenceRun[3])
        XCTAssertFalse(silenceRun[4], "2.5 c")
        XCTAssertTrue(silenceRun[5], "ровно 3.0 c непрерывной тишины → стоп")
        XCTAssertTrue(silenceRun[6] && silenceRun[7], "пока тишина длится, сработавшее состояние держится")
        XCTAssertEqual(detector.silenceDuration, 4.0, "все 8 тихих буферов накопились непрерывным отрезком")
    }

    /// Гейт «речь была»: без уверенной речи автостоп невозможен ВООБЩЕ —
    /// даже если тишина (после grace) превысила 3 c. Чистая тишина с самого
    /// старта не останавливает пустую запись.
    @objc func testSilenceWithoutSpeechNeverFires() {
        var detector = SilenceAutoStopDetector()
        var fired = false
        for _ in 0..<14 { // 7.0 c, из них ~5.0 c вне grace — много больше 3 c
            if detector.feed(rms: 0.0001, duration: 0.5) { fired = true }
        }
        XCTAssertFalse(fired, "без гейта «речь была» автостоп не срабатывает")
        XCTAssertEqual(detector.silenceDuration, 5.0, "тишина скопилась, но гейт блокирует стоп")
        XCTAssertFalse(detector.speechGatePassed)
    }

    /// Гейт пройден ТОЛЬКО непрерывным отрезком речи ≥ 0.3 c; серая зона
    /// замораживает отрезок (не обнуляет — тихие слоги «дребезгом» не рвут
    /// речь), реальная тишина — обнуляет.
    @objc func testSpeechGateRequiresMinSpeechRun() {
        var detector = SilenceAutoStopDetector(
            requiredSilenceDuration: 3.0,
            gracePeriod: 0,
            minSpeechRun: 0.3,
            minRecordingDuration: 0
        )
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.2), "речь не останавливает")
        XCTAssertFalse(detector.speechGatePassed, "0.2 c < 0.3 c — гейт ещё не открыт")
        XCTAssertFalse(detector.feed(rms: 0.00251, duration: 0.2), "серая зона: состояние заморожено")
        XCTAssertEqual(detector.speechRun, 0.2, "серая зона не рвёт и не докапливает отрезок речи")
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.2), "речь сбрасывает тишину → feed false")
        XCTAssertTrue(detector.speechGatePassed, "0.2 + 0.2 = 0.4 ≥ 0.3 → защёлкнут")
    }

    /// Гейт защёлкивается навсегда в рамках сеанса: обрыв речи тишиной гейт
    /// не отзывает — иначе пауза «на подумать» лишила бы автостоп смысла.
    @objc func testSpeechGateLatchesOncePassed() {
        var detector = SilenceAutoStopDetector(
            requiredSilenceDuration: 3.0,
            gracePeriod: 0,
            minSpeechRun: 0.3,
            minRecordingDuration: 0
        )
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.4), "речь не останавливает")
        XCTAssertTrue(detector.speechGatePassed)
        XCTAssertFalse(detector.feed(rms: 0.0001, duration: 0.5))
        XCTAssertTrue(detector.speechGatePassed, "тишина после гейта его не отзывает")
        XCTAssertEqual(detector.silenceDuration, 0.5)
    }

    /// Grace-период: буферы, начавшиеся до его конца, в тишину НЕ накапливаются
    /// (обустройство, вдох, клавиатура после старта — не «конец диктовки»);
    /// накопление начинается с буфера, стартующего ровно в конце grace.
    @objc func testGracePeriodSkipsInitialSilence() {
        var detector = SilenceAutoStopDetector(
            requiredSilenceDuration: 1.0,
            gracePeriod: 2.0,
            minSpeechRun: 0,
            minRecordingDuration: 0
        )
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.5), "речь: гейт (minSpeechRun 0) защёлкнут")
        XCTAssertTrue(detector.speechGatePassed)
        // Буферы тишины стартуют в 0.5, 1.0, 1.5 (внутри grace) → не копятся.
        XCTAssertFalse(detector.feed(rms: 0.0001, duration: 0.5))
        XCTAssertFalse(detector.feed(rms: 0.0001, duration: 0.5))
        XCTAssertFalse(detector.feed(rms: 0.0001, duration: 0.5))
        XCTAssertEqual(detector.silenceDuration, 0, "тишина внутри grace не накапливается")
        // Буфер с началом ровно в 2.0 (конец grace) — уже копится: 0.5 → 1.0.
        XCTAssertFalse(detector.feed(rms: 0.0001, duration: 0.5), "0.5 c после grace")
        XCTAssertEqual(detector.silenceDuration, 0.5)
        XCTAssertTrue(detector.feed(rms: 0.0001, duration: 0.5), "1.0 c ≥ required → стоп")
        XCTAssertEqual(detector.silenceDuration, 1.0)
    }

    /// Речь внутри grace-окна работает как обычно (гейт копится) — grace
    /// ограничивает только накопление тишины, не речь.
    @objc func testGraceDoesNotBlockSpeechGate() {
        var detector = SilenceAutoStopDetector() // grace 2.0, гейт 0.3
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.5), "речь в grace: гейт растёт, стопа нет")
        XCTAssertTrue(detector.speechGatePassed, "0.5 ≥ 0.3 → гейт защёлкнут и в grace")
    }

    // MARK: - Накопление тишины: непрерывность, границы, пол записи

    /// Реальная тишина останавливает запись ровно по истечении требуемых 3 c
    /// непрерывного молчания (отсчёт от конца речи, не от старта записи).
    @objc func testRealSilenceFiresAtExactlyRequiredDuration() {
        var detector = SilenceAutoStopDetector(
            requiredSilenceDuration: 3.0,
            gracePeriod: 0,
            minSpeechRun: 0.3,
            minRecordingDuration: 0
        )
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.2))
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.2), "речь: 0.4 c → гейт")
        XCTAssertTrue(detector.speechGatePassed)
        // Тишина: 5 × 0.5 (2.5 c) — молчание есть, но требуемых 3 c нет.
        for _ in 0..<5 {
            XCTAssertFalse(detector.feed(rms: 0.0001, duration: 0.5), "2.5 c тишины < 3.0 c")
        }
        XCTAssertEqual(detector.silenceDuration, 2.5)
        XCTAssertTrue(detector.feed(rms: 0.0001, duration: 0.5), "ровно 3.0 c → стоп")
        XCTAssertEqual(detector.silenceDuration, 3.0, "стоп — ровно на границе, не раньше")
    }

    /// Счётчик тишины — ТОЛЬКО по непрерывному отрезку: межсловные паузы
    /// < 3 c не суммируются (0.5 c + 0.5 c ≠ 1 c непрерывности).
    @objc func testInterWordPausesDoNotAccumulate() {
        var detector = SilenceAutoStopDetector(
            requiredSilenceDuration: 3.0,
            gracePeriod: 0,
            minSpeechRun: 0.1,
            minRecordingDuration: 0
        )
        for _ in 0..<3 {
            XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.5), "слово")
            XCTAssertFalse(detector.feed(rms: 0.0001, duration: 0.5), "межсловная пауза")
            XCTAssertEqual(detector.silenceDuration, 0.5, "пауза начинается с нуля после слова")
        }
        // Финальное слово: тишина сброшена — межсловные паузы < 3 c нигде
        // не суммировались в непрерывный отрезок.
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.5), "слово")
        XCTAssertEqual(detector.silenceDuration, 0, "после последнего слова тишина сброшена")
    }

    /// Речь обнуляет накопленную тишину: 2 c паузы + слово + 1 c паузы — это
    /// НЕ 3 c непрерывной тишины; стоп только после полных 3 c после слова.
    @objc func testSpeechResetsAccumulatedSilence() {
        var detector = SilenceAutoStopDetector(
            requiredSilenceDuration: 3.0,
            gracePeriod: 0,
            minSpeechRun: 0.3,
            minRecordingDuration: 0
        )
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.4), "речь не останавливает")
        XCTAssertTrue(detector.speechGatePassed)
        for _ in 0..<4 { _ = detector.feed(rms: 0.0001, duration: 0.5) } // 2.0 c тишины
        XCTAssertEqual(detector.silenceDuration, 2.0)
        XCTAssertFalse(detector.feed(rms: 0.9, duration: 0.2), "слово обнуляет накопленную тишину")
        XCTAssertEqual(detector.silenceDuration, 0)
        for _ in 0..<2 { _ = detector.feed(rms: 0.0001, duration: 0.5) } // 1.0 c
        XCTAssertFalse(detector.feed(rms: 0.0001, duration: 0.5), "1.5 c после слова — ещё не 3")
        XCTAssertEqual(detector.silenceDuration, 1.5, "суммирования с прошлой паузой нет: 1.5, не 3.5")
        // Добираем до 3.0 c: 1.5 → 2.0 → 2.5 → 3.0.
        XCTAssertFalse(detector.feed(rms: 0.0001, duration: 0.5), "2.0 c")
        XCTAssertFalse(detector.feed(rms: 0.0001, duration: 0.5), "2.5 c")
        XCTAssertTrue(detector.feed(rms: 0.0001, duration: 0.5), "3.0 c непрерывной тишины после слова → стоп")
        XCTAssertEqual(detector.silenceDuration, 3.0)
    }

    /// Гистерезис-зона между порогами не «дребезжит»: накопленные 2 c тишины
    /// не списываются тихим слогом, но и не растут, пока уровень в серой зоне;
    /// речь — единственный сброс.
    @objc func testHysteresisBandFreezesState() {
        var detector = SilenceAutoStopDetector(
            requiredSilenceDuration: 3.0,
            gracePeriod: 0,
            minSpeechRun: 0.3,
            minRecordingDuration: 0
        )
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.4), "речь: гейт")
        XCTAssertTrue(detector.speechGatePassed)
        for _ in 0..<4 { _ = detector.feed(rms: 0.0001, duration: 0.5) } // 2.0 c тишины
        var fired = false
        for _ in 0..<6 {
            if detector.feed(rms: 0.00251, duration: 0.5) { fired = true } // серая зона ×6
        }
        XCTAssertFalse(fired, "серая зона не добирает тишину до срабатывания")
        XCTAssertEqual(detector.silenceDuration, 2.0, "серая зона замораживает накопление, не обнуляет")
        XCTAssertEqual(detector.speechRun, 0, "и речи не накапливает")
        // Речь — сброс тишины, после неё заново 3.0 c → стоп.
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.5), "речь сбрасывает тишину")
        XCTAssertEqual(detector.silenceDuration, 0)
        var fires: [Bool] = []
        for _ in 0..<6 { fires.append(detector.feed(rms: 0.0001, duration: 0.5)) }
        XCTAssertFalse(fires[4], "2.5 c")
        XCTAssertTrue(fires[5], "3.0 c после речи → стоп")
    }

    /// Строгие границы классификации: RMS РОВНО на пороге речи — уже речь;
    /// РОВНО на пороге тишины — ещё НЕ тишина (граница «в пользу звука», как
    /// у AudioMetrics.isNearSilence). Шаг на йоту ниже порога тишины — тишина.
    @objc func testThresholdBoundarySemantics() {
        var detector = SilenceAutoStopDetector(
            requiredSilenceDuration: 3.0,
            gracePeriod: 0,
            minSpeechRun: 0.3,
            minRecordingDuration: 0
        )
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.4), "речь: гейт")
        for _ in 0..<2 { _ = detector.feed(rms: 0.0001, duration: 0.5) } // 1.0 c тишины
        // RMS == порог речи → речевой буфер: тишина сброшена.
        XCTAssertFalse(detector.feed(rms: 0.00562, duration: 0.5))
        XCTAssertEqual(detector.silenceDuration, 0, "буфер на пороге речи = речь")
        // RMS == порог тишины → серая зона (тишина — СТРОГО ниже порога).
        XCTAssertFalse(detector.feed(rms: 0.00126, duration: 0.5))
        XCTAssertEqual(detector.silenceDuration, 0, "ровно порог тишины ещё не тишина (гистерезисная зона)")
        // На йоту ниже — накопление пошло.
        XCTAssertFalse(detector.feed(rms: 0.00125, duration: 0.5))
        XCTAssertEqual(detector.silenceDuration, 0.5)
    }

    /// Минимальная длительность записи — жёсткий пол: даже при крошечном
    /// required запись не останавливается, пока не прожила minRecordingDuration
    /// от старта. Защита от патологических конфигов.
    @objc func testMinimumRecordingDurationBlocksEarlyFire() {
        var detector = SilenceAutoStopDetector(
            requiredSilenceDuration: 1.0,
            gracePeriod: 0,
            minSpeechRun: 0.1,
            minRecordingDuration: 3.0
        )
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.5), "речь: гейт (0.5 ≥ 0.1)")
        var fires: [Bool] = []
        for _ in 0..<5 { fires.append(detector.feed(rms: 0.0001, duration: 0.5)) }
        // Тишина ≥ 1.0 c уже с 1.0 c записи, но пол 3.0 c → стоп только на
        // 5-м тихом буфере (elapsed ровно 3.0).
        XCTAssertFalse(fires[1], "тишина 1.0 c есть, а записи всего 1.5 c — пол не пройден")
        XCTAssertFalse(fires[2], "2.0 c записи")
        XCTAssertFalse(fires[3], "2.5 c записи")
        XCTAssertTrue(fires[4], "elapsed ровно 3.0 c → пол пройден, тишина 2.5 ≥ 1.0 → стоп")
    }

    /// Сработавшее состояние держится, пока тишина продолжается (внешний слой
    /// сам планирует остановку и отбрасывает буферы); накопитель растёт.
    @objc func testFiresStaysWhileSilenceContinues() {
        var detector = SilenceAutoStopDetector(
            requiredSilenceDuration: 3.0,
            gracePeriod: 0,
            minSpeechRun: 0.3,
            minRecordingDuration: 0
        )
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.4), "речь: гейт")
        var fires: [Bool] = []
        for _ in 0..<8 { fires.append(detector.feed(rms: 0.0001, duration: 0.5)) }
        XCTAssertFalse(fires[0])
        XCTAssertFalse(fires[4], "2.5 c")
        XCTAssertTrue(fires[5], "3.0 c → стоп")
        XCTAssertTrue(fires[6] && fires[7], "сработано продолжает держаться")
        XCTAssertEqual(detector.silenceDuration, 4.0, "накопитель не замер после срабатывания")
    }

    /// Один длинный тихий буфер (без дробления на ~85-мс куски) после речи
    /// останавливает запись ровно в 3.0 c — накопление меряется ВРЕМЕНЕМ аудио,
    /// а не числом буферов (частота колбэков железа плавает).
    @objc func testSingleLongSilenceBufferFires() {
        var detector = SilenceAutoStopDetector(
            requiredSilenceDuration: 3.0,
            gracePeriod: 0,
            minSpeechRun: 0.3,
            minRecordingDuration: 0
        )
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.4), "речь: гейт")
        XCTAssertTrue(detector.feed(rms: 0.0001, duration: 3.0), "один буфер 3.0 c тишины → стоп")
        XCTAssertEqual(detector.silenceDuration, 3.0)
    }

    /// Защита от отрицательной/нулевой длительности: мусорный duration
    /// клампится в 0 — накопление не может пойти быстрее или назад.
    @objc func testNegativeAndZeroDurationClampedToZero() {
        var detector = SilenceAutoStopDetector()
        XCTAssertFalse(detector.feed(rms: 0.5, duration: -5), "отрицательная длительность клампится в 0")
        XCTAssertEqual(detector.elapsed, 0)
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0))
        XCTAssertEqual(detector.elapsed, 0)
        XCTAssertEqual(detector.speechRun, 0, "нулевой буфер не даёт гейту (0 < 0.3)")
        XCTAssertFalse(detector.feed(rms: 0.0001, duration: 0))
        XCTAssertEqual(detector.silenceDuration, 0)
    }

    /// reset() полностью стирает состояние сеанса: накопленную тишину,
    /// длительность записи, отрезок речи И гейт (новый сеанс требует новую
    /// речь). Тишина после reset без нового гейта не останавливает.
    @objc func testResetClearsStateAfterFire() {
        var detector = SilenceAutoStopDetector(
            requiredSilenceDuration: 3.0,
            gracePeriod: 0,
            minSpeechRun: 0.3,
            minRecordingDuration: 0
        )
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.4), "речь: гейт")
        XCTAssertTrue(detector.speechGatePassed)
        XCTAssertTrue(detector.feed(rms: 0.0001, duration: 3.0), "стоп")
        detector.reset()
        XCTAssertEqual(detector.silenceDuration, 0)
        XCTAssertEqual(detector.elapsed, 0)
        XCTAssertEqual(detector.speechRun, 0)
        XCTAssertFalse(detector.speechGatePassed, "reset отзывает и гейт")
        XCTAssertFalse(detector.feed(rms: 0.0001, duration: 3.0), "без новой речи тишина после reset не останавливает")
    }
}