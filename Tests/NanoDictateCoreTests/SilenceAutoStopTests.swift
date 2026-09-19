import Foundation
@testable import NanoDictateCore

// MARK: - Автоостановка по непрерывной тишине: гистерезис, grace, гейт «речь была»

/// Detector model — hysteresis threshold pair −45/−58 dBFS, grace after
/// recording start, 'speech was' gate and minimum recording duration (see
/// AutoStopConfig in SilenceAutoStop.swift). Here — pure buffers with
/// controlled timing: config built explicitly, buffer duration set in
/// seconds directly (callback rate does not affect numbers).
///
/// Conditional levels (linear RMS):
///   • confident speech     0.5      (≫ speech threshold 0.00562)
///   • speech boundary      0.00562  (≥ threshold → speech)
///   • gray zone            0.00251  (−52 dBFS: quiet speech — between thresholds)
///   • silence boundary     0.00126  (strictly below → silence)
///   • real silence         0.0001   (noise floor −80 dBFS)
///
/// Model consequence: ANY speech buffer returns false (speech breaks the
/// silence run — 'silence ≥ threshold' impossible that moment); gate is
/// checked via `speechGatePassed`, not via feed result.
final class SilenceAutoStopTests: XCTestCase {

    // MARK: - Дефолты и гистерезисная пара порогов

    /// Defaults: switch on, threshold pair −45/−58 dBFS, required silence
    /// 3 c, grace 2 c, gate 0.3 c, recording floor 3 c. Silence threshold
    /// DELIBERATELY STRICTER than AudioMetrics.nearSilenceThreshold (−50
    /// dBFS): the latter lies INSIDE quiet-speech dynamics (−48.6…−55 dBFS) —
    /// which used to cut recordings; autostop silence = honest noise floor.
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

    /// Hysteresis invariant also wired into detector: speech cannot be
    /// recognized 'quieter' than silence — whatever config arrives, speech
    /// threshold clamps up to silence threshold.
    @objc func testDetectorInvariantClampsSpeechBelowSilence() {
        let detector = SilenceAutoStopDetector(silenceRMSThreshold: 0.05, speechRMSThreshold: 0.02)
        XCTAssertEqual(detector.speechRMSThreshold, 0.05, "порог речи поднят до порога тишины")
        XCTAssertEqual(detector.silenceRMSThreshold, 0.05)
    }

    /// Same invariant in config: AutoStopConfig.init clamps speech threshold
    /// to silence threshold (protection from manual config assembly in code).
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

    /// Empty env = exactly `.defaults` (compat with run without env).
    @objc func testFromEnvironmentDefaultsWhenEmpty() {
        XCTAssertEqual(AutoStopConfig.fromEnvironment([:]), .defaults)
    }

    /// Feature master switch.
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

    /// Override of required silence duration.
    @objc func testFromEnvironmentDurationOverride() {
        var env = [String: String]()
        env["NANODICTATE_AUTOSTOP_DURATION"] = "5.5"
        let config = AutoStopConfig.fromEnvironment(env)
        XCTAssertEqual(config.requiredSilenceDuration, 5.5)
        XCTAssertEqual(config.speechRMSThreshold, AutoStopConfig.defaultSpeechRMSThreshold, "остальные поля — дефолты")
    }

    /// Silence threshold override: speech threshold clamps up to keep
    /// hysteresis invariant ('loud silence' and 'quiet speech' must not
    /// invert).
    @objc func testFromEnvironmentSilenceRMSOverride() {
        var env = [String: String]()
        env["NANODICTATE_AUTOSTOP_RMS"] = "0.01"
        let config = AutoStopConfig.fromEnvironment(env)
        XCTAssertEqual(config.silenceRMSThreshold, 0.01)
        XCTAssertEqual(config.speechRMSThreshold, 0.01, "порог речи поднят до порога тишины")
    }

    /// Speech threshold override (new key; silence threshold untouched while
    /// speech not 'fallen' below silence).
    @objc func testFromEnvironmentSpeechRMSOverride() {
        var env = [String: String]()
        env["NANODICTATE_AUTOSTOP_SPEECH_RMS"] = "0.02"
        let config = AutoStopConfig.fromEnvironment(env)
        XCTAssertEqual(config.speechRMSThreshold, 0.02)
        XCTAssertEqual(config.silenceRMSThreshold, AutoStopConfig.defaultSilenceRMSThreshold)
    }

    /// Speech clamping on 'inverted' combination: silence 0.03, speech
    /// 0.01 → speech raised to 0.03.
    @objc func testFromEnvironmentSpeechClampedToSilence() {
        var env = [String: String]()
        env["NANODICTATE_AUTOSTOP_RMS"] = "0.03"
        env["NANODICTATE_AUTOSTOP_SPEECH_RMS"] = "0.01"
        let config = AutoStopConfig.fromEnvironment(env)
        XCTAssertEqual(config.silenceRMSThreshold, 0.03)
        XCTAssertEqual(config.speechRMSThreshold, 0.03)
    }

    /// Invalid values ignored (strictly > 0 only, broken strings miss),
    /// config stays on defaults.
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

    /// Combined env reaches detector: config → detector constructor (same
    /// wiring as AudioService.init) → behavior. Single end-to-end plumbing
    /// test without AudioService.
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
        // Speech 0.5 c → gate (0.5 ≥ 0.1), silence 1.0 c → exactly required → stop.
        XCTAssertFalse(detector.feed(rms: 0.2, duration: 0.5), "речь не останавливает")
        XCTAssertTrue(detector.speechGatePassed)
        XCTAssertTrue(detector.feed(rms: 0.001, duration: 1.0), "тишина ≥ required + гейт + пол пройден")
    }

    // MARK: - Гейт «речь была» и grace

    /// MAIN regression of the bug: QUIET speech (center of 'gray zone',
    /// −52 dBFS — exactly the level that used to cut recordings) does NOT
    /// accumulate silence nor stop the recording, however long. Hysteresis
    /// keeps such buffer in 'no change': below speech threshold ≠ silence.
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

    /// End-to-end 'calm dictation → end of speech → autostop': 2 c confident
    /// speech (gate), 3 c quiet speech in gray zone (NOT silence!), and only
    /// then real silence ≥ 3 c stops the recording. Cuts pause after
    /// dictation, not the dictation itself.
    @objc func testQuietTalkThenRealSilenceFiresAtThreeSeconds() {
        var detector = SilenceAutoStopDetector() // defaults: grace 2, gate 0.3, floor 3, silence 3
        // Speech 4 × 0.5 = 2.0 c (gate ≥ 0.3 latched) — silence does not accumulate.
        for _ in 0..<4 {
            XCTAssertFalse(detector.feed(rms: 0.3, duration: 0.5), "речь не останавливает")
        }
        XCTAssertTrue(detector.speechGatePassed)
        // Quiet speech 6 × 0.5 = 3.0 c in gray zone — silence not accumulated.
        for _ in 0..<6 {
            XCTAssertFalse(detector.feed(rms: 0.00251, duration: 0.5), "тихая диктовка не режется")
        }
        XCTAssertEqual(detector.silenceDuration, 0)
        // Real silence: buffers after grace window accumulate, stop at 3.0 c.
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

    /// 'Speech was' gate: without confident speech autostop is impossible AT
    /// ALL — even if silence (after grace) exceeded 3 c. Pure silence from
    /// start does not stop an empty recording.
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

    /// Gate passed ONLY by continuous speech run ≥ 0.3 c; gray zone freezes
    /// the run (does not zero it — quiet syllables do not 'rattle' and break
    /// speech), real silence zeroes it.
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

    /// Gate latches forever within session: silence after speech does not
    /// revoke it — else a 'thinking' pause would defeat autostop.
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

    /// Grace period: buffers starting before its end do NOT accumulate to
    /// silence (set-up, breath, keyboard after start — not 'end of
    /// dictation'); accumulation starts with the buffer starting exactly at
    /// grace end.
    @objc func testGracePeriodSkipsInitialSilence() {
        var detector = SilenceAutoStopDetector(
            requiredSilenceDuration: 1.0,
            gracePeriod: 2.0,
            minSpeechRun: 0,
            minRecordingDuration: 0
        )
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.5), "речь: гейт (minSpeechRun 0) защёлкнут")
        XCTAssertTrue(detector.speechGatePassed)
        // Silence buffers start at 0.5, 1.0, 1.5 (inside grace) → not accumulated.
        XCTAssertFalse(detector.feed(rms: 0.0001, duration: 0.5))
        XCTAssertFalse(detector.feed(rms: 0.0001, duration: 0.5))
        XCTAssertFalse(detector.feed(rms: 0.0001, duration: 0.5))
        XCTAssertEqual(detector.silenceDuration, 0, "тишина внутри grace не накапливается")
        // Buffer starting exactly at 2.0 (grace end) — already counts: 0.5 → 1.0.
        XCTAssertFalse(detector.feed(rms: 0.0001, duration: 0.5), "0.5 c после grace")
        XCTAssertEqual(detector.silenceDuration, 0.5)
        XCTAssertTrue(detector.feed(rms: 0.0001, duration: 0.5), "1.0 c ≥ required → стоп")
        XCTAssertEqual(detector.silenceDuration, 1.0)
    }

    /// Speech inside grace window works as usual (gate accumulates) — grace
    /// limits only silence accumulation, not speech.
    @objc func testGraceDoesNotBlockSpeechGate() {
        var detector = SilenceAutoStopDetector() // grace 2.0, gate 0.3
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.5), "речь в grace: гейт растёт, стопа нет")
        XCTAssertTrue(detector.speechGatePassed, "0.5 ≥ 0.3 → гейт защёлкнут и в grace")
    }

    // MARK: - Накопление тишины: непрерывность, границы, пол записи

    /// Real silence stops the recording exactly after required 3 c of
    /// continuous silence (counted from end of speech, not recording start).
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
        // Silence: 5 × 0.5 (2.5 c) — silence present, but required 3 c not reached.
        for _ in 0..<5 {
            XCTAssertFalse(detector.feed(rms: 0.0001, duration: 0.5), "2.5 c тишины < 3.0 c")
        }
        XCTAssertEqual(detector.silenceDuration, 2.5)
        XCTAssertTrue(detector.feed(rms: 0.0001, duration: 0.5), "ровно 3.0 c → стоп")
        XCTAssertEqual(detector.silenceDuration, 3.0, "стоп — ровно на границе, не раньше")
    }

    /// Silence counter — ONLY contiguous run: inter-word pauses < 3 c do not
    /// sum up (0.5 c + 0.5 c ≠ 1 c of continuity).
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
        // Final word: silence reset — inter-word pauses < 3 c never summed
        // into a contiguous run.
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.5), "слово")
        XCTAssertEqual(detector.silenceDuration, 0, "после последнего слова тишина сброшена")
    }

    /// Speech zeroes accumulated silence: 2 c pause + word + 1 c pause is NOT
    /// 3 c of contiguous silence; stop only after full 3 c after the word.
    @objc func testSpeechResetsAccumulatedSilence() {
        var detector = SilenceAutoStopDetector(
            requiredSilenceDuration: 3.0,
            gracePeriod: 0,
            minSpeechRun: 0.3,
            minRecordingDuration: 0
        )
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.4), "речь не останавливает")
        XCTAssertTrue(detector.speechGatePassed)
        for _ in 0..<4 { _ = detector.feed(rms: 0.0001, duration: 0.5) } // 2.0 c silence
        XCTAssertEqual(detector.silenceDuration, 2.0)
        XCTAssertFalse(detector.feed(rms: 0.9, duration: 0.2), "слово обнуляет накопленную тишину")
        XCTAssertEqual(detector.silenceDuration, 0)
        for _ in 0..<2 { _ = detector.feed(rms: 0.0001, duration: 0.5) } // 1.0 c
        XCTAssertFalse(detector.feed(rms: 0.0001, duration: 0.5), "1.5 c после слова — ещё не 3")
        XCTAssertEqual(detector.silenceDuration, 1.5, "суммирования с прошлой паузой нет: 1.5, не 3.5")
        // Reach 3.0 c: 1.5 → 2.0 → 2.5 → 3.0.
        XCTAssertFalse(detector.feed(rms: 0.0001, duration: 0.5), "2.0 c")
        XCTAssertFalse(detector.feed(rms: 0.0001, duration: 0.5), "2.5 c")
        XCTAssertTrue(detector.feed(rms: 0.0001, duration: 0.5), "3.0 c непрерывной тишины после слова → стоп")
        XCTAssertEqual(detector.silenceDuration, 3.0)
    }

    /// Hysteresis band between thresholds does not 'rattle': accumulated 2 c
    /// of silence is not written off by a quiet syllable, but also does not
    /// grow while level in gray zone; speech is the only reset.
    @objc func testHysteresisBandFreezesState() {
        var detector = SilenceAutoStopDetector(
            requiredSilenceDuration: 3.0,
            gracePeriod: 0,
            minSpeechRun: 0.3,
            minRecordingDuration: 0
        )
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.4), "речь: гейт")
        XCTAssertTrue(detector.speechGatePassed)
        for _ in 0..<4 { _ = detector.feed(rms: 0.0001, duration: 0.5) } // 2.0 c silence
        var fired = false
        for _ in 0..<6 {
            if detector.feed(rms: 0.00251, duration: 0.5) { fired = true } // gray zone ×6
        }
        XCTAssertFalse(fired, "серая зона не добирает тишину до срабатывания")
        XCTAssertEqual(detector.silenceDuration, 2.0, "серая зона замораживает накопление, не обнуляет")
        XCTAssertEqual(detector.speechRun, 0, "и речи не накапливает")
        // Speech — silence reset, then again 3.0 c → stop.
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.5), "речь сбрасывает тишину")
        XCTAssertEqual(detector.silenceDuration, 0)
        var fires: [Bool] = []
        for _ in 0..<6 { fires.append(detector.feed(rms: 0.0001, duration: 0.5)) }
        XCTAssertFalse(fires[4], "2.5 c")
        XCTAssertTrue(fires[5], "3.0 c после речи → стоп")
    }

    /// Strict classification boundaries: RMS EXACTLY at speech threshold —
    /// already speech; EXACTLY at silence threshold — still NOT silence
    /// (boundary in favor of sound, like AudioMetrics.isNearSilence). One
    /// iota below silence threshold — silence.
    @objc func testThresholdBoundarySemantics() {
        var detector = SilenceAutoStopDetector(
            requiredSilenceDuration: 3.0,
            gracePeriod: 0,
            minSpeechRun: 0.3,
            minRecordingDuration: 0
        )
        XCTAssertFalse(detector.feed(rms: 0.5, duration: 0.4), "речь: гейт")
        for _ in 0..<2 { _ = detector.feed(rms: 0.0001, duration: 0.5) } // 1.0 c тишины
        // RMS == speech threshold → speech buffer: silence reset.
        XCTAssertFalse(detector.feed(rms: 0.00562, duration: 0.5))
        XCTAssertEqual(detector.silenceDuration, 0, "буфер на пороге речи = речь")
        // RMS == silence threshold → gray zone (silence — STRICTLY below).
        XCTAssertFalse(detector.feed(rms: 0.00126, duration: 0.5))
        XCTAssertEqual(detector.silenceDuration, 0, "ровно порог тишины ещё не тишина (гистерезисная зона)")
        // One iota below — accumulation starts.
        XCTAssertFalse(detector.feed(rms: 0.00125, duration: 0.5))
        XCTAssertEqual(detector.silenceDuration, 0.5)
    }

    /// Minimum recording duration — hard floor: even with tiny required,
    /// recording does not stop before it lived minRecordingDuration from
    /// start. Protection from pathological configs.
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
        // Silence ≥ 1.0 c from 1.0 c of recording, but floor 3.0 c → stop only on
        // 5th quiet buffer (elapsed exactly 3.0).
        XCTAssertFalse(fires[1], "тишина 1.0 c есть, а записи всего 1.5 c — пол не пройден")
        XCTAssertFalse(fires[2], "2.0 c записи")
        XCTAssertFalse(fires[3], "2.5 c записи")
        XCTAssertTrue(fires[4], "elapsed ровно 3.0 c → пол пройден, тишина 2.5 ≥ 1.0 → стоп")
    }

    /// Fired state holds while silence continues (outer layer plans the stop
    /// and drops buffers); accumulator keeps growing.
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

    /// One long quiet buffer (no split into ~85-ms chunks) after speech stops
    /// the recording exactly at 3.0 c — accumulation measures AUDIO TIME, not
    /// buffer count (hardware callback rate drifts).
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

    /// Protection from negative/zero duration: garbage duration clamps to 0 —
    /// accumulation cannot go faster or backwards.
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

    /// reset() fully clears session state: accumulated silence, recording
    /// duration, speech run AND gate (new session requires new speech).
    /// Post-reset silence without new gate does not stop.
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