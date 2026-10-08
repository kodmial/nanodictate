import Foundation
@testable import NanoDictateCore

/// Hard recording limit (60 s / 960 000 samples): pure logic —
/// AVAudioEngine/AVAudioConverter don't run in mini-XCTest.
final class RecordingLimitTests: XCTestCase {

    // MARK: - Максимальная длительность 60.0 с

    @objc func testNotStoppedBefore60Seconds() {
        var limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
        XCTAssertFalse(limit.shouldStop(elapsed: 0, totalSamples: 0))
        XCTAssertFalse(limit.shouldStop(elapsed: 0.5, totalSamples: 0))
        XCTAssertFalse(limit.shouldStop(elapsed: 59.0, totalSamples: 0))
        XCTAssertFalse(limit.shouldStop(elapsed: 59.999, totalSamples: 0))
        XCTAssertFalse(limit.isExhausted)
    }

    @objc func testStoppedExactlyAt60Seconds() {
        var limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
        XCTAssertFalse(limit.shouldStop(elapsed: 59.999, totalSamples: 0))
        XCTAssertTrue(limit.shouldStop(elapsed: 60.0, totalSamples: 0))
        XCTAssertTrue(limit.isExhausted)
    }

    @objc func testStoppedAfter60Seconds() {
        var limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
        XCTAssertTrue(limit.shouldStop(elapsed: 60.001, totalSamples: 0))
        XCTAssertTrue(limit.shouldStop(elapsed: 120.0, totalSamples: 0))
    }

    // MARK: - Вычисление лимита по сэмплам (память)

    @objc func testMaxSamplesIs960000() {
        // 16 kHz × 60 s = 960 000 samples — exactly, no headroom.
        let limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
        XCTAssertEqual(limit.maxSamples, 960_000)
    }

    @objc func testCustomSampleRateComputesSamples() {
        let limit = RecordingLimit(maxDuration: 2.0, sampleRate: 8000)
        XCTAssertEqual(limit.maxSamples, 16_000)
    }

    @objc func testNotStoppedBeforeSampleCap() {
        var limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
        XCTAssertFalse(limit.shouldStop(elapsed: 0, totalSamples: 0))
        XCTAssertFalse(limit.shouldStop(elapsed: 0, totalSamples: 959_999))
        XCTAssertFalse(limit.isExhausted)
    }

    @objc func testStoppedExactlyAtSampleCap() {
        var limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
        XCTAssertFalse(limit.shouldStop(elapsed: 0, totalSamples: 959_999))
        XCTAssertTrue(limit.shouldStop(elapsed: 0, totalSamples: 960_000))
        XCTAssertTrue(limit.isExhausted)
    }

    @objc func testStoppedOverSampleCap() {
        var limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
        XCTAssertTrue(limit.shouldStop(elapsed: 0, totalSamples: 960_001))
        XCTAssertTrue(limit.shouldStop(elapsed: 0, totalSamples: 1_000_000))
    }

    // MARK: - Время и сэмплы работают независимо

    @objc func testTimeLimitTriggersWithTinyBuffer() {
        var limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
        // Near-empty buffer does not lift the time limit.
        XCTAssertFalse(limit.shouldStop(elapsed: 59.999, totalSamples: 10))
        XCTAssertTrue(limit.shouldStop(elapsed: 60.0, totalSamples: 10))
    }

    @objc func testSampleCapTriggersWithLittleElapsedTime() {
        var limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
        // Sample cap triggers even with zero elapsed time.
        XCTAssertTrue(limit.shouldStop(elapsed: 0.0, totalSamples: 960_000))
    }

    // MARK: - Ограничение памяти: буфер не растёт за предел

    @objc func testRemainingSamplesNeverNegative() {
        let limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
        XCTAssertEqual(limit.remainingSamples(after: 0), 960_000)
        XCTAssertEqual(limit.remainingSamples(after: 100), 959_900)
        XCTAssertEqual(limit.remainingSamples(after: 959_999), 1)
        XCTAssertEqual(limit.remainingSamples(after: 960_000), 0)
        XCTAssertEqual(limit.remainingSamples(after: 960_001), 0)
        XCTAssertEqual(limit.remainingSamples(after: 2_000_000), 0)
    }

    // MARK: - После принудительного стопа «хвост» не возобновляется

    @objc func testStopIsLatchingByTime() {
        var limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
        XCTAssertTrue(limit.shouldStop(elapsed: 60.0, totalSamples: 800_000))
        XCTAssertTrue(limit.isExhausted)
        // Latch holds until a new session; reset time/samples won't reopen.
        XCTAssertTrue(limit.shouldStop(elapsed: 0, totalSamples: 0))
        XCTAssertTrue(limit.shouldStop(elapsed: 1.0, totalSamples: 1))
        XCTAssertTrue(limit.isExhausted)
    }

    @objc func testStopIsLatchingBySamples() {
        var limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
        XCTAssertTrue(limit.shouldStop(elapsed: 0, totalSamples: 960_000))
        XCTAssertTrue(limit.shouldStop(elapsed: 0, totalSamples: 0))
        XCTAssertTrue(limit.isExhausted)
    }

    @objc func testAppendPastCapAddsNothingThroughBudget() {
        var limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
        XCTAssertFalse(limit.shouldStop(elapsed: 0, totalSamples: 959_000))
        XCTAssertGreaterThanOrEqual(limit.remainingSamples(after: 959_000), 1_000)
        _ = limit.shouldStop(elapsed: 0, totalSamples: 960_000)
        XCTAssertEqual(limit.remainingSamples(after: 960_000), 0)
    }

    // MARK: - Новый сеанс записи стартует с чистого лимита

    @objc func testFreshSessionStartsClean() {
        var finished = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
        _ = finished.shouldStop(elapsed: 60.0, totalSamples: 960_000)
        XCTAssertTrue(finished.isExhausted)

        // AudioService.start() makes a fresh limit — latch not carried over.
        var next = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
        XCTAssertFalse(next.isExhausted)
        XCTAssertFalse(next.shouldStop(elapsed: 0, totalSamples: 0))
        XCTAssertEqual(next.maxSamples, 960_000)
    }

    // MARK: - Кастомный лимит (переиспользование единицы)

    @objc func testCompactLimit() {
        var limit = RecordingLimit(maxDuration: 0.5, sampleRate: 16000)
        XCTAssertEqual(limit.maxSamples, 8_000)
        XCTAssertFalse(limit.shouldStop(elapsed: 0.499, totalSamples: 7_999))
        XCTAssertTrue(limit.shouldStop(elapsed: 0.5, totalSamples: 7_999))   // time
        XCTAssertTrue(limit.shouldStop(elapsed: 0.1, totalSamples: 8_000))   // samples
        XCTAssertEqual(limit.remainingSamples(after: 8_000), 0)
        XCTAssertTrue(limit.isExhausted)
    }

    // MARK: - Fail-safe на некорректной длительности (аудит #156, пункт 5)

    @objc func testNaNDurationFallsBackTo60Seconds() {
        let limit = RecordingLimit(maxDuration: .nan, sampleRate: 16000)
        XCTAssertEqual(limit.maxDuration, 60.0)
        XCTAssertEqual(limit.maxSamples, 960_000)
    }

    @objc func testInfiniteDurationFallsBackTo60Seconds() {
        for invalid in [Double.infinity, -Double.infinity] {
            let limit = RecordingLimit(maxDuration: invalid, sampleRate: 16000)
            XCTAssertEqual(limit.maxDuration, 60.0)
            XCTAssertEqual(limit.maxSamples, 960_000)
        }
    }

    @objc func testNonPositiveDurationFallsBackTo60Seconds() {
        for invalid in [0.0, -1.0, -60.0] {
            let limit = RecordingLimit(maxDuration: invalid, sampleRate: 16000)
            XCTAssertEqual(limit.maxDuration, 60.0)
            XCTAssertEqual(limit.maxSamples, 960_000)
        }
    }

    @objc func testFallbackLimitKeepsNormal60SecondBehavior() {
        var limit = RecordingLimit(maxDuration: .nan, sampleRate: 16000)
        XCTAssertFalse(limit.shouldStop(elapsed: 59.999, totalSamples: 0))
        XCTAssertTrue(limit.shouldStop(elapsed: 60.0, totalSamples: 0))
        XCTAssertTrue(limit.isExhausted)
    }

    @objc func testAbsurdSampleRateCannotTrap() {
        // Int(Double) conversion traps out of range — absurd rates must fall
        // back (or clamp) instead of crashing the process.
        let huge = RecordingLimit(maxDuration: 60.0, sampleRate: Int.max)
        XCTAssertGreaterThanOrEqual(huge.maxSamples, 1)
        // Degenerate rates collapse to the minimum per-second budget (a tiny
        // but bounded recording), never to an unbounded session.
        let zero = RecordingLimit(maxDuration: 60.0, sampleRate: 0)
        XCTAssertEqual(zero.maxSamples, 60)
        let negative = RecordingLimit(maxDuration: 60.0, sampleRate: -44100)
        XCTAssertEqual(negative.maxSamples, 60)
    }

    // MARK: - Fail-safe на некорректном elapsed (аудит #156, пункт 5)

    @objc func testNaNElapsedNeverStopsNorLatches() {
        var limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
        XCTAssertFalse(limit.shouldStop(elapsed: .nan, totalSamples: 0))
        XCTAssertFalse(limit.isExhausted)
        // The limit still works afterwards — NaN left no latch behind.
        XCTAssertFalse(limit.shouldStop(elapsed: 59.0, totalSamples: 0))
        XCTAssertTrue(limit.shouldStop(elapsed: 60.0, totalSamples: 0))
    }

    @objc func testInfiniteElapsedStops() {
        var limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
        XCTAssertTrue(limit.shouldStop(elapsed: .infinity, totalSamples: 0))
        XCTAssertTrue(limit.isExhausted)
    }

    @objc func testNegativeElapsedDoesNotStop() {
        var limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
        XCTAssertFalse(limit.shouldStop(elapsed: -5.0, totalSamples: 0))
        XCTAssertFalse(limit.shouldStop(elapsed: -.infinity, totalSamples: 0))
        XCTAssertFalse(limit.isExhausted)
    }

    @objc func testNegativeSampleCountDoesNotStop() {
        var limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
        XCTAssertFalse(limit.shouldStop(elapsed: 0, totalSamples: -1))
        XCTAssertFalse(limit.isExhausted)
    }

    @objc func testRemainingSamplesClampedForNegativeInput() {
        let limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
        XCTAssertEqual(limit.remainingSamples(after: -100), 960_000)
    }
}