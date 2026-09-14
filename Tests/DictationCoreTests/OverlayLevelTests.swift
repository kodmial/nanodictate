import Foundation
@testable import DictationCore

/// Тесты чистой VU-логики оверлея «Halo»: dB-ремап RMS→метр 0…1, баллистика
/// (attack/release), следящий пик и толщина штриха кольца-дуги.
///
/// Всё это — чистые функции/структуры без SwiftUI и I/O (Sources/DictationCore/
/// OverlayLevel.swift), поэтому покрываются юнит-тестами напрямую.
final class OverlayLevelTests: XCTestCase {

    // MARK: - dB-ремап (RMS → метр 0…1, шкала −50…0 dBFS)

    @objc func testMeter_ZeroAndNegativeRMS_IsZero() {
        XCTAssertEqual(OverlayLevel.meter(fromRMS: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(OverlayLevel.meter(fromRMS: -1), 0, accuracy: 0.0001)
        XCTAssertEqual(OverlayLevel.meter(fromRMS: -0.5), 0, accuracy: 0.0001)
    }

    @objc func testMeter_FullScaleIsOne() {
        // 1.0 → 0 dBFS → метр 1.
        XCTAssertEqual(OverlayLevel.meter(fromRMS: 1), 1, accuracy: 0.0001)
    }

    @objc func testMeter_MapsDBScale() {
        // −20 dBFS (0.1) → (20·log10(0.1)+50)/50 = 0.6
        XCTAssertEqual(OverlayLevel.meter(fromRMS: 0.1), 0.6, accuracy: 0.001)
        // −40 dBFS (0.01) → 0.2
        XCTAssertEqual(OverlayLevel.meter(fromRMS: 0.01), 0.2, accuracy: 0.001)
        // ≈ порог «около-тишины» (−50 dBFS ≈ 0.00316) → метр ≈ 0
        XCTAssertEqual(OverlayLevel.meter(fromRMS: 0.00316), 0, accuracy: 0.01)
        // −50 dBFS ровно → 0
        XCTAssertEqual(OverlayLevel.meter(fromRMS: 0.00001), 0, accuracy: 0.0001)
    }

    @objc func testMeter_ClampsAboveOneAndBelowZero() {
        // rms > 1 → dB > 0 → метр выше 1, клампится в 1.
        XCTAssertEqual(OverlayLevel.meter(fromRMS: 100), 1, accuracy: 0.0001)
        // rms очень маленький → dB много ниже −50 → клампится в 0.
        XCTAssertEqual(OverlayLevel.meter(fromRMS: 1e-9), 0, accuracy: 0.0001)
    }

    @objc func testMeter_ConsistentWithAudioMetricsDbfs() {
        // Сверка с уже существующей шкалой AudioMetrics.dbfs: метр для 0.001
        // считается через ту же формулу.
        let rms: Float = 0.05
        let db = AudioMetrics.dbfs(rms)
        let expected = min(max((db + 50) / 50, 0), 1)
        XCTAssertEqual(OverlayLevel.meter(fromRMS: rms), expected, accuracy: 0.0001)
    }

    // MARK: - Обратная шкала и порог «горячей» зоны

    @objc func testDbfs_InverseOfMeterScale() {
        XCTAssertEqual(OverlayLevel.dbfs(forMeter: 0), -50, accuracy: 0.001)
        XCTAssertEqual(OverlayLevel.dbfs(forMeter: 1), 0, accuracy: 0.001)
        XCTAssertEqual(OverlayLevel.dbfs(forMeter: 0.5), -25, accuracy: 0.001)
        // Клампинг метр за пределами [0,1]
        XCTAssertEqual(OverlayLevel.dbfs(forMeter: 2), 0, accuracy: 0.001)
        XCTAssertEqual(OverlayLevel.dbfs(forMeter: -1), -50, accuracy: 0.001)
    }

    @objc func testHotMeterThreshold_CorrespondsToMinus6DB() {
        // Порог горячей зоны выведен из −6 dBFS: 0.88 м.
        XCTAssertEqual(OverlayLevel.hotMeterThreshold, 0.88, accuracy: 0.001)
        XCTAssertEqual(OverlayLevel.dbfs(forMeter: OverlayLevel.hotMeterThreshold),
                       OverlayLevel.hotThresholddB,
                       accuracy: 0.001)
    }

    @objc func testIsHot_OnlyAboveMinus6DB() {
        XCTAssertFalse(OverlayLevel.isHot(meter: 0), "тишина — холодная зона")
        XCTAssertFalse(OverlayLevel.isHot(meter: 0.5), "−25 dBFS — холодная зона")
        XCTAssertFalse(OverlayLevel.isHot(meter: 0.88), "ровно на пороге — не горячая (строго больше)")
        XCTAssertTrue(OverlayLevel.isHot(meter: 0.9), "выше порога — горячая")
        XCTAssertTrue(OverlayLevel.isHot(meter: 1), "0 dBFS — горячая")
    }

    // MARK: - Envelope (баллистика attack/release)

    @objc func testEnvelope_AttackReachesTargetWithinAttackTime() {
        // За один шаг attackTime (70 мс) метр догоняет цель с нуля.
        XCTAssertEqual(
            OverlayLevel.enveloped(current: 0, target: 1, dt: OverlayLevel.attackTime),
            1, accuracy: 0.0001
        )
        XCTAssertEqual(
            OverlayLevel.enveloped(current: 0, target: 0.5, dt: OverlayLevel.attackTime),
            0.5, accuracy: 0.0001
        )
    }

    @objc func testEnvelope_AttackPartialStep() {
        // Шаг в половину attackTime даёт половину пути к цели.
        XCTAssertEqual(
            OverlayLevel.enveloped(current: 0, target: 1, dt: OverlayLevel.attackTime / 2),
            0.5, accuracy: 0.0001
        )
        // Из ненулевого старта — пропорция к цели, не абсолютная прибавка.
        XCTAssertEqual(
            OverlayLevel.enveloped(current: 0.8, target: 1, dt: OverlayLevel.attackTime / 2),
            0.9, accuracy: 0.0001
        )
    }

    @objc func testEnvelope_AttackNeverExceedsTarget() {
        // Даже огромный dt не «перелетает» цель.
        XCTAssertEqual(
            OverlayLevel.enveloped(current: 0.4, target: 0.7, dt: 5),
            0.7, accuracy: 0.0001
        )
    }

    @objc func testEnvelope_ReleaseIsExponential() {
        // Спад экспоненциальный: за dt=releaseTime множитель exp(−1) ≈ 0.3679.
        let expected: Float = 1 * Float(exp(-Double(1)))
        XCTAssertEqual(
            OverlayLevel.enveloped(current: 1, target: 0, dt: OverlayLevel.releaseTime),
            expected, accuracy: 0.001
        )
    }

    @objc func testEnvelope_ReleasePerTick_RoughlyPoint85ToPoint9() {
        // Тик ~11 Гц (dt ≈ 0.09 с) → ×0.83…0.92 за тик («×~0.9/тик» из спеки).
        var meter: Float = 1
        meter = OverlayLevel.enveloped(current: meter, target: 0, dt: 0.09)
        XCTAssertGreaterThanOrEqual(meter, 0.80, accuracy: 0.001)
        XCTAssertLessThanOrEqual(meter, 0.92)
    }

    @objc func testEnvelope_ReleaseDoesNotGoBelowTarget() {
        // Release идёт к цели, но не ниже неё.
        XCTAssertEqual(
            OverlayLevel.enveloped(current: 1, target: 0.3, dt: 100), 0.3, accuracy: 0.0001
        )
        XCTAssertEqual(
            OverlayLevel.enveloped(current: 0.5, target: 0.5, dt: 100), 0.5, accuracy: 0.0001
        )
    }

    @objc func testEnvelope_ZeroDtKeepsCurrent() {
        XCTAssertEqual(
            OverlayLevel.enveloped(current: 0.42, target: 0.9, dt: 0), 0.42, accuracy: 0.0001
        )
    }

    @objc func testEnvelope_ClampsInputsToUnitInterval() {
        // current: 5 → 1, target: -1 → 0: клампинг действует, но баллистика
        // остаётся — экспоненциальный release от 1 за 0.05 с даёт exp(−0.1).
        let expected = 1 * Float(exp(-Double(0.05 / OverlayLevel.releaseTime)))
        XCTAssertEqual(
            OverlayLevel.enveloped(current: 5, target: -1, dt: 0.05),
            expected, accuracy: 0.0001
        )
        XCTAssertEqual(
            OverlayLevel.enveloped(current: -2, target: 3, dt: OverlayLevel.attackTime),
            1, accuracy: 0.0001
        )
    }

    // MARK: - Толщина штриха кольца (растёт 3→9 с уровнем)

    @objc func testStrokeWidth_GrowsThreeToNine() {
        XCTAssertEqual(OverlayLevel.strokeWidth(forMeter: 0), 3, accuracy: 0.001)
        XCTAssertEqual(OverlayLevel.strokeWidth(forMeter: 0.5), 6, accuracy: 0.001)
        XCTAssertEqual(OverlayLevel.strokeWidth(forMeter: 1), 9, accuracy: 0.001)
    }

    @objc func testStrokeWidth_ClampsOutOfRangeMeter() {
        XCTAssertEqual(OverlayLevel.strokeWidth(forMeter: -1), 3, accuracy: 0.001)
        XCTAssertEqual(OverlayLevel.strokeWidth(forMeter: 2), 9, accuracy: 0.001)
    }

    // MARK: - Следящий пик (держит максимум ~0.8 с, затем спадает)

    @objc func testPeak_StartsZero() {
        let peak = OverlayPeak()
        XCTAssertEqual(peak.value, 0, accuracy: 0.001)
    }

    @objc func testPeak_HoldsMaximumDuringHoldTime() {
        var peak = OverlayPeak()
        _ = peak.update(level: 0.5, dt: 0)
        // Уровень ниже пика, но удержание ещё идёт — пик держится.
        _ = peak.update(level: 0.3, dt: 0.4)
        XCTAssertEqual(peak.value, 0.5, accuracy: 0.001)
        _ = peak.update(level: 0.3, dt: 0.4)
        XCTAssertEqual(peak.value, 0.5, accuracy: 0.001, "0.8 с удержания — пик ещё на максимуме")
    }

    @objc func testPeak_FallsAfterHoldExpires() {
        var peak = OverlayPeak()
        _ = peak.update(level: 0.5, dt: 0)
        _ = peak.update(level: 0.3, dt: OverlayPeak.holdTime) // удержание истекло
        // Плавный спад после удержания: 0.5 − 0.7 · 0.5 = 0.15
        let after = peak.update(level: 0.3, dt: 0.5)
        XCTAssertEqual(after, 0.15, accuracy: 0.001)
        XCTAssertEqual(peak.value, 0.15, accuracy: 0.001)
    }

    @objc func testPeak_NewMaximumResetsHold() {
        var peak = OverlayPeak()
        _ = peak.update(level: 0.5, dt: 0)
        // Новый максимум → удержание перезапускается с полного holdTime.
        _ = peak.update(level: 0.6, dt: 0.4)
        XCTAssertEqual(peak.value, 0.6, accuracy: 0.001)
        _ = peak.update(level: 0.2, dt: 0.79)
        XCTAssertEqual(peak.value, 0.6, accuracy: 0.001, "после нового пика удержание полное")
    }

    @objc func testPeak_NeverBelowZero() {
        var peak = OverlayPeak()
        _ = peak.update(level: 0.5, dt: 0)
        _ = peak.update(level: 0, dt: OverlayPeak.holdTime)
        let after = peak.update(level: 0, dt: 10)
        XCTAssertEqual(after, 0, accuracy: 0.001)
    }

    @objc func testPeak_ClampsLevelToUnitInterval() {
        var peak = OverlayPeak()
        _ = peak.update(level: 5, dt: 0)
        XCTAssertEqual(peak.value, 1, accuracy: 0.001)
    }

    @objc func testPeak_ResetClears() {
        var peak = OverlayPeak()
        _ = peak.update(level: 0.8, dt: 0)
        peak.reset()
        XCTAssertEqual(peak.value, 0, accuracy: 0.001)
        // После reset — снова удержание с нуля.
        _ = peak.update(level: 0.4, dt: 0)
        XCTAssertEqual(peak.value, 0.4, accuracy: 0.001)
    }
}