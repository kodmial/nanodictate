import AVFoundation
import Foundation
@testable import DictationCore

// MARK: - AudioMetricsTests

/// Тесты чистых функций диагностики аудио: строковое представление статуса
/// доступа к микрофону (TCC) и метрики уровня записи (min/avg/max RMS,
/// порог «около-тишины»). Аудио-устройства не используются — только математика.
final class AudioMetricsTests: XCTestCase {

    // MARK: - 1. Статус доступа к микрофону

    @objc func testMicrophoneStatusTextGranted() {
        XCTAssertEqual(MicrophoneAuth.statusText(.authorized), "granted")
    }

    @objc func testMicrophoneStatusTextDenied() {
        XCTAssertEqual(MicrophoneAuth.statusText(.denied), "denied")
    }

    @objc func testMicrophoneStatusTextNotDetermined() {
        XCTAssertEqual(MicrophoneAuth.statusText(.notDetermined), "notDetermined")
    }

    @objc func testMicrophoneStatusTextRestricted() {
        XCTAssertEqual(MicrophoneAuth.statusText(.restricted), "restricted")
    }

    // MARK: - 2. dBFS

    @objc func testDbfsFullScaleIsZero() {
        XCTAssertEqual(AudioMetrics.dbfs(1.0), 0, accuracy: 1e-3)
    }

    @objc func testDbfsTenPercentIsMinus20() {
        XCTAssertEqual(AudioMetrics.dbfs(0.1), -20, accuracy: 1e-3)
    }

    @objc func testDbfsZeroIsFloor() {
        // 0 амплитуда → −120 dBFS (пол), не −∞: безопасно для интерполяции в лог.
        XCTAssertEqual(AudioMetrics.dbfs(0.0), -120)
    }

    // MARK: - 3. Сводные метрики по истории RMS

    @objc func testSummarizeEmptyHistory() {
        let m = AudioMetrics.summarize(rmsValues: [])
        XCTAssertEqual(m.minRMS, 0, accuracy: 1e-6)
        XCTAssertEqual(m.avgRMS, 0, accuracy: 1e-6)
        XCTAssertEqual(m.maxRMS, 0, accuracy: 1e-6)
        XCTAssertFalse(m.nearSilence, "пустая запись — нечего судить о тишине")
    }

    @objc func testSummarizeComputesMinAvgMax() {
        let m = AudioMetrics.summarize(rmsValues: [0.1, 0.3, 0.2])
        XCTAssertEqual(m.minRMS, 0.1, accuracy: 1e-6)
        XCTAssertEqual(m.avgRMS, 0.2, accuracy: 1e-6)
        XCTAssertEqual(m.maxRMS, 0.3, accuracy: 1e-6)
    }

    @objc func testSummarizeSingleValue() {
        let m = AudioMetrics.summarize(rmsValues: [0.25])
        XCTAssertEqual(m.minRMS, 0.25, accuracy: 1e-6)
        XCTAssertEqual(m.avgRMS, 0.25, accuracy: 1e-6)
        XCTAssertEqual(m.maxRMS, 0.25, accuracy: 1e-6)
    }

    @objc func testSummarizeQuietIsNearSilence() {
        // Все буферы заметно ниже порога (−50 dBFS ≈ 0.00316) — тишина.
        let m = AudioMetrics.summarize(rmsValues: [0.001, 0.002, 0.001])
        XCTAssertTrue(m.nearSilence)
    }

    @objc func testSummarizeLoudIsNotNearSilence() {
        // Обычная речь: RMS порядка 0.05...0.3 — не тишина.
        let m = AudioMetrics.summarize(rmsValues: [0.05, 0.2, 0.1])
        XCTAssertFalse(m.nearSilence)
    }

    @objc func testSummarizeMixedDecidedByAverage() {
        // Среднее (0.01) всё ещё выше порога → к тишине не относится.
        let m = AudioMetrics.summarize(rmsValues: [0.001, 0.019])
        XCTAssertEqual(m.avgRMS, 0.01, accuracy: 1e-6)
        XCTAssertFalse(m.nearSilence)
    }

    @objc func testSummarizeCustomThreshold() {
        // Свой порог: тот же набор буферов при пороге 0.005 — тишина.
        let m = AudioMetrics.summarize(rmsValues: [0.001, 0.002], threshold: 0.005)
        XCTAssertTrue(m.nearSilence)
    }

    // MARK: - 4. RMS по Int16 PCM-сэмплам

    @objc func testRmsEmptySamplesIsZero() {
        XCTAssertEqual(AudioMetrics.rms(samples: []), 0)
    }

    @objc func testRmsSilenceIsZero() {
        XCTAssertEqual(AudioMetrics.rms(samples: [0, 0, 0, 0]), 0, accuracy: 1e-6)
    }

    @objc func testRmsFullScaleIsOne() {
        // Все сэмплы на полной шкале Int16 (32767) → RMS 1.0 (0 dBFS).
        let samples = [Int16](repeating: 32767, count: 4)
        XCTAssertEqual(AudioMetrics.rms(samples: samples), 1.0, accuracy: 1e-3)
    }

    @objc func testRmsHalfScaleIsAboutHalf() {
        // 16384/32767 ≈ 0.5 → RMS ≈ 0.5.
        let samples = [Int16](repeating: 16384, count: 4)
        XCTAssertEqual(AudioMetrics.rms(samples: samples), 0.5, accuracy: 1e-2)
    }

    @objc func testRmsQuietSamplesBelowThreshold() {
        // Уровень «мурашек» (±64 из 32767) — заметно ниже порога тишины.
        let samples: [Int16] = [64, -64, 64, -64]
        let rms = AudioMetrics.rms(samples: samples)
        XCTAssertTrue(rms < AudioMetrics.nearSilenceThreshold, "rms \(rms) должен быть ниже порога тишины")
    }

    // MARK: - 5. Границы «около-тишины»

    @objc func testNearSilenceStrictlyBelowThreshold() {
        XCTAssertTrue(AudioMetrics.isNearSilence(avgRMS: 0.001))
        // Чуть-чуть ниже порога — всё ещё тишина.
        XCTAssertTrue(AudioMetrics.isNearSilence(avgRMS: AudioMetrics.nearSilenceThreshold * 0.999))
    }

    @objc func testNearSilenceExactThresholdIsNotSilence() {
        // Ровно на пороге — не тишина (строгое сравнение <).
        XCTAssertFalse(AudioMetrics.isNearSilence(avgRMS: AudioMetrics.nearSilenceThreshold))
    }

    @objc func testNearSilenceAboveThresholdIsNotSilence() {
        XCTAssertFalse(AudioMetrics.isNearSilence(avgRMS: 0.1))
        XCTAssertFalse(AudioMetrics.isNearSilence(avgRMS: AudioMetrics.nearSilenceThreshold * 1.001))
    }

    @objc func testNearSilenceCustomThreshold() {
        XCTAssertTrue(AudioMetrics.isNearSilence(avgRMS: 0.01, threshold: 0.02))
        XCTAssertFalse(AudioMetrics.isNearSilence(avgRMS: 0.01, threshold: 0.005))
    }
}