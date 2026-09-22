import Foundation
import AVFoundation
@testable import NanoDictateCore

/// Unit tests for digital input gain (AGC) — see InputGain.swift.
///
/// Feature task: speech input sits at −55…−40 dBFS, dictation records quiet
/// signal; AGC drives current buffer RMS to `targetRmsDb` (−20 dBFS), capped
/// at `maxGainDb` (+30 dB). Requirements checked on pure math, no audio hardware:
///
///   (а) quiet input (RMS ≈ −49…−50 dBFS) amplified to ≈ −20 dBFS (±3 dB);
///   (б) loud input (RMS −15 dBFS) NOT amplified — gain 0, buffer untouched;
///   (в) silence (RMS ≤ −50 dBFS, nearSilenceThreshold) not amplified —
///       mic noise not pulled up;
///   (г) clip: post-gain peak clamps to [−1.0, 1.0] — Int16 conversion below
///       does not clip;
///   (д) smoothing: two calls in row — gain changes smoothly (one-pole,
///       attack 25 ms / release 300 ms), not in a jump;
///   (е) env config: NANODICTATE_GAIN_DISABLED=1 disables (gain 0),
///       NANODICTATE_GAIN_TARGET_DB / NANODICTATE_GAIN_MAX_DB parse and
///       reach apply.
///
/// Time unit: 1 sample @ sampleRate 16000 = 1/16000 s.
/// Smoothing constant: α = 1 − e^(−1/τ), τ = τ_sec × 16000.
final class InputGainTests: XCTestCase {

    private let sampleRate = 16000

    /// Amplitude giving exactly `rmsDb` dBFS RMS on constant buffer.
    private func amplitude(forRmsDb rmsDb: Float) -> Float {
        return powf(10, rmsDb / 20)
    }

    private func dbfs(_ linear: Float) -> Float {
        return AudioMetrics.dbfs(linear)
    }

    /// Constant-amplitude buffer; no sine — flat RMS tracks gain cleanly.
    private func constantBuffer(_ amplitude: Float, frames: Int) -> [Float] {
        return [Float](repeating: amplitude, count: frames)
    }

    /// RMS of Float buffer — local copy; AudioMetrics.rms takes [Int16],
    /// buffer not converted yet.
    private func rmsOf(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        return sqrt(sum / Float(samples.count))
    }

    // MARK: - (а) тихий вход усиливается до цели

    /// Quiet −49 dBFS input (typical speech): after apply RMS ≈ −20 dBFS
    /// (target ±3 dB), gain reached ~+29 dB — speech audible.
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
        // Post-gain level > 10× input (≈ +20 dB) — signal really louder.
        XCTAssertGreaterThanOrEqual(dbfs(outRms), dbfs(inRms) + 20)
    }

    /// Input at exactly silence threshold (−50 dBFS): gain still 0 (threshold
    /// strictly below — "not silence" starts above); one step up (−49) works.
    @objc func testQuietAtSilenceThresholdGainZero() {
        let gain = InputGain()
        var buffer = constantBuffer(AudioMetrics.nearSilenceThreshold, frames: sampleRate)
        XCTAssertEqual(dbfs(buffer[0]), AudioMetrics.dbfs(AudioMetrics.nearSilenceThreshold), accuracy: 0.1)

        let outRms = gain.apply(to: &buffer, rms: AudioMetrics.nearSilenceThreshold, sampleRate: sampleRate)

        XCTAssertEqual(gain.currentGainDb, 0, accuracy: 0.000001, "ровно на пороге тишины — gain 0 (порог строго ниже)")
        XCTAssertEqual(outRms, AudioMetrics.nearSilenceThreshold, accuracy: 0.000001, "буфер не тронут")
    }

    // MARK: - (б) громкий вход не усиливается

    /// −15 dBFS input: louder than target, gain 0, buffer untouched.
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

    /// Silence −60 dBFS (RMS 0.001, below threshold −50): gain 0, buffer
    /// passes as-is — mic noise not pulled to speech level.
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

    /// One 0.9 peak in quiet buffer: RMS ~ −41 dBFS → target gain ~ +21 dB;
    /// post-gain peak ≈ 0.9 × 11.5 ≈ 10.4 → clamps to 1.0; no sample exceeds 1.0.
    @objc func testPeakIsClampedAfterGain() {
        let gain = InputGain()
        var buffer = constantBuffer(0.005, frames: sampleRate)
        buffer[sampleRate - 1] = 0.9 // peak at very end, gain already converged
        let inRms = rmsOf(buffer)
        XCTAssertEqual(dbfs(inRms), -41, accuracy: 1.0, "предусловие: RMS ниже цели, усиление нужно")

        gain.apply(to: &buffer, rms: inRms, sampleRate: sampleRate)

        let maxAbs = buffer.map { abs($0) }.max() ?? 0
        XCTAssertEqual(maxAbs, 1.0, "пик после усиления клампится ровно в 1.0")
        XCTAssertLessThanOrEqual(maxAbs, 1.0, "ни один сэмпл не выходит из [−1, 1]")
        XCTAssertEqual(gain.currentGainDb, 21.2, accuracy: 0.5, "gain ~ +21 дБ — до клампа пик был ~10.4")
        // Clamp hit peak only: buffer tail still amplified, not clipping — < 1.0.
        XCTAssertLessThanOrEqual(buffer[sampleRate / 2], 0.2, "середина буфера не на клампе")
        XCTAssertGreaterThanOrEqual(buffer[sampleRate / 2], 0.03, "середина буфера усилена")
    }

    // MARK: - (д) плавное сглаживание

    /// Two calls in row (160 samples = 10 ms @16 kHz) on quiet input: gain
    /// after first ≈ 33% of way to target, after second ≈ 33% of rest.
    /// No jump to full target in one buffer (else breathing/clicks per buffer).
    @objc func testGainSmoothsAcrossBuffers() {
        let gain = InputGain()
        // α = 1 − e^(−1/400); one-pole closed form after N steps:
        // target·(1 − (1−α)^N), (1−α)^N = e^(−N/400) — matches recursion.
        let tauAttack = 0.025 * Double(sampleRate) // 400 samples = 25 ms
        let target: Float = 29 // −49 → −20 дБ
        let framesPerCall = sampleRate / 100 // 160 samples = 10 ms
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

    /// Release (300 ms) smooth too: gain raised on quiet buffer, then loud
    /// buffer (target 0) — gain decays gradually, not zeroed instantly
    /// (else click at quiet→loud edge).
    @objc func testGainReleasesSmoothly() {
        let gain = InputGain()
        // Ran gain up to full target with quiet buffer.
        var quiet = constantBuffer(amplitude(forRmsDb: -49), frames: sampleRate)
        let quietRms = rmsOf(quiet)
        gain.apply(to: &quiet, rms: quietRms, sampleRate: sampleRate)
        XCTAssertEqual(gain.currentGainDb, 29, accuracy: 0.5, "предусловие: gain на цели")

        // Loud buffer: target 0, release 300 ms — 1600 samples (100 ms) bring
        // gain only to ~72% (no instant drop).
        let decayPerStep = Float(exp(-Double(sampleRate / 10) / (0.300 * Double(sampleRate))))
        let gainBefore = gain.currentGainDb
        var loud = constantBuffer(amplitude(forRmsDb: -15), frames: sampleRate / 10)
        let loudRms = rmsOf(loud)
        gain.apply(to: &loud, rms: loudRms, sampleRate: sampleRate)

        let gainAfter100ms = gain.currentGainDb
        XCTAssertLessThanOrEqual(gainAfter100ms, gainBefore - 0.01, "gain пошёл вниз")
        XCTAssertEqual(gainAfter100ms, gainBefore * decayPerStep, accuracy: 1.0, "за 100 мс ушло ~28%, а не всё")

        // Keeps decaying to 0: 3 more 1600-sample buffers (6400 ≈ 0.4 s,
        // e^(−6400/4800) ≈ 0.26 of rest).
        for _ in 0..<3 {
            gain.apply(to: &loud, rms: loudRms, sampleRate: sampleRate)
        }
        XCTAssertLessThanOrEqual(gain.currentGainDb, gainAfter100ms * 0.9, "release прогрессирует к нулю")
        XCTAssertGreaterThanOrEqual(gain.currentGainDb, 0.1, "и пока не добил до нуля (ещё остаток)")
    }

    /// Same buffer (gain already accumulated): repeated apply on quiet input
    /// does not blow up — asymptote to target, not unbounded growth
    /// (stability under steady quiet speech).
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

    /// Defaults per task: enabled, −20 dBFS, max +30 dB, attack 25 ms,
    /// release 300 ms.
    @objc func testDefaultsMatchTask() {
        let config = InputGainConfig.defaults
        XCTAssertTrue(config.enabled, "дефолт — фича включена")
        XCTAssertEqual(config.targetRmsDb, -20, "целевой RMS речи −20 dBFS")
        XCTAssertEqual(config.maxGainDb, 30, "потолок +30 дБ")
        XCTAssertEqual(config.attackTime, 0.025, accuracy: 0.0000001, "attack ~25 мс")
        XCTAssertEqual(config.releaseTime, 0.300, accuracy: 0.0000001, "release ~300 мс")
        XCTAssertEqual(InputGainConfig(), config, "init по умолчанию == .defaults")
    }

    /// Empty environment gives exactly `.defaults` (as AutoStopConfig).
    @objc func testFromEnvironmentDefaultsWhenEmpty() {
        let config = InputGainConfig.fromEnvironment([:])
        XCTAssertEqual(config, .defaults)
    }

    /// Switch: NANODICTATE_GAIN_DISABLED=1/true/TRUE disables feature;
    /// unrecognized value ignored (fail-closed).
    @objc func testFromEnvironmentDisabledSwitch() {
        for value in ["1", "true", "TRUE"] {
            let config = InputGainConfig.fromEnvironment(["NANODICTATE_GAIN_DISABLED": value])
            XCTAssertFalse(config.enabled, "NANODICTATE_GAIN_DISABLED=\(value) выключает фичу")
        }
        let config = InputGainConfig.fromEnvironment(["NANODICTATE_GAIN_DISABLED": "maybe"])
        XCTAssertTrue(config.enabled, "некорректное значение рубильника игнорируется")
    }

    /// Target and cap from environment reach apply().
    @objc func testFromEnvironmentTargetAndMaxParse() {
        let config = InputGainConfig.fromEnvironment([
            "NANODICTATE_GAIN_TARGET_DB": "-25",
            "NANODICTATE_GAIN_MAX_DB": "40",
        ])
        XCTAssertEqual(config.targetRmsDb, -25, accuracy: 0.000001)
        XCTAssertEqual(config.maxGainDb, 40, accuracy: 0.000001, "потолок из окружения")
        XCTAssertTrue(config.enabled, "параметры не трогают рубильник")
        XCTAssertEqual(config.attackTime, InputGainConfig.defaults.attackTime, "постоянные времени — дефолтные")

        // Apply: custom target −25 dB — same math works.
        let gain = InputGain(config: config)
        var buffer = constantBuffer(amplitude(forRmsDb: -49), frames: sampleRate)
        let inRms = rmsOf(buffer)
        let outRms = gain.apply(to: &buffer, rms: inRms, sampleRate: sampleRate)
        XCTAssertEqual(dbfs(outRms), -25, accuracy: 3.0, "кастомная цель ±25 dBFS")
    }

    /// Invalid values ignored — defaults stay (typo breaks neither enabled
    /// nor bounds).
    @objc func testFromEnvironmentInvalidValuesIgnored() {
        let config = InputGainConfig.fromEnvironment([
            "NANODICTATE_GAIN_TARGET_DB": "abc",   // not a number
            "NANODICTATE_GAIN_TARGET_DBX": "-25",  // different name not read
            "NANODICTATE_GAIN_TARGET_DB2": "10",   // target must be below 0 dBFS
            "NANODICTATE_GAIN_MAX_DB": "-5",       // cap must be > 0
            "NANODICTATE_GAIN_MAX_DBX": "70",      // cap ≤ 60
        ])
        XCTAssertEqual(config, .defaults, "некорректные значения — конфигурация по умолчанию")
    }

    /// Env values that passed validation still go through init clamp
    /// (−120…−1 and 1…60): env cannot break config invariants
    /// (`MAX_DB=0.5` below init min, `TARGET_DB=-0.5` near full scale).
    @objc func testFromEnvironmentValuesAreClampedByInit() {
        let config = InputGainConfig.fromEnvironment([
            "NANODICTATE_GAIN_TARGET_DB": "-0.5",
            "NANODICTATE_GAIN_MAX_DB": "0.5",
        ])
        XCTAssertEqual(config.targetRmsDb, -1, accuracy: 0.000001, "init-кламп цели")
        XCTAssertEqual(config.maxGainDb, 1, accuracy: 0.000001, "init-кламп потолка")
    }

    // MARK: - Отключённая фича: буфер проходит без изменений

    /// NANODICTATE_GAIN_DISABLED → InputGain with enabled=false: apply
    /// leaves buffer untouched (loud or quiet), returns original RMS.
    @objc func testDisabledGainPassesBufferThrough() {
        let config = InputGainConfig.fromEnvironment(["NANODICTATE_GAIN_DISABLED": "1"])
        XCTAssertFalse(config.enabled)
        let gain = InputGain(config: config)

        var buffer = constantBuffer(amplitude(forRmsDb: -49), frames: sampleRate)
        let original = buffer
        let inRms = rmsOf(buffer)

        let outRms = gain.apply(to: &buffer, rms: inRms, sampleRate: sampleRate)

        XCTAssertEqual(outRms, inRms, accuracy: 0.000001)
        XCTAssertEqual(buffer, original, "выключенная фича — буфер без изменений")
        XCTAssertEqual(gain.currentGainDb, 0)
        // targetGainDb also returns 0 when disabled.
        XCTAssertEqual(gain.targetGainDb(forRms: 0.000001), 0)
    }

    /// reset() zeroes accumulated gain — new recording session starts clean.
    @objc func testResetClearsAccumulatedGain() {
        let gain = InputGain()
        var buffer = constantBuffer(amplitude(forRmsDb: -49), frames: sampleRate)
        let inRms = rmsOf(buffer)
        gain.apply(to: &buffer, rms: inRms, sampleRate: sampleRate)
        XCTAssertGreaterThanOrEqual(gain.currentGainDb, 20, "предусловие: gain накоплен")
        gain.reset()
        XCTAssertEqual(gain.currentGainDb, 0)
    }

    /// Empty buffer: apply returns rms as-is, touches nothing.
    @objc func testEmptyBufferPassesThrough() {
        let gain = InputGain()
        var buffer: [Float] = []
        let outRms = gain.apply(to: &buffer, rms: 0.2, sampleRate: sampleRate)
        XCTAssertEqual(outRms, 0.2, accuracy: 0.000001)
        XCTAssertTrue(buffer.isEmpty)
        XCTAssertEqual(gain.currentGainDb, 0)
    }

    /// Silence after amplified speech passes UNCHANGED and resets gain:
    /// without guard, release tail (~0.3 s) would leak into silence, pull
    /// it up, break VAD/auto-stop (regression of AudioServiceVADTests chunks).
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

    /// End-to-end wiring: AudioService.process applies gain to buffer,
    /// levelDelegate gets AMPLIFIED RMS, stop() returns amplified Int16
    /// samples (input −46 dBFS, recorded peaks ~ +26 dB).
    @objc func testAudioServiceAmplifiesLevelAndSamples() {
        let engine = GainFakeEngine()
        // Explicit config (not fromEnvironment): test must not depend on
        // NANODICTATE_GAIN_DISABLED in run environment.
        let service = AudioService(logLevel: "info", engine: engine, gainConfig: InputGainConfig.defaults)
        let delegate = LevelBox()
        service.levelDelegate = delegate

        let result = runStart(service)
        guard case .success = result else {
            XCTFail("старт не удался: \(result)")
            return
        }

        // One quiet constant-speech buffer: −46 dBFS → compensation needed.
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

/// Engine fake: tap stores callback, emit() invokes it synchronously (as in
/// lifecycle tests); conversion via real AVAudioConverter.
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

    /// Emits one PCM buffer into processing (prod audio thread does this).
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

/// Level container received by live delegate (weak by contract).
private final class LevelBox: AudioLevelDelegate {
    var lastRms: Float?
    func audioLevelChanged(rms: Float) {
        lastRms = rms
    }
}

// MARK: - Хелперы ожидания

private extension InputGainTests {
    typealias StartResult = Result<Void, Error>

    /// Waits async start completion (RunLoop spins — main thread in prod).
    /// Returns start result.
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

    /// Constant-amplitude PCM buffer for tap emission.
    func constantBuffer(_ amplitude: Float, frames: Int, sampleRate: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        let data = buf.floatChannelData![0]
        for i in 0..<frames { data[i] = amplitude }
        return buf
    }
}