import Foundation
@testable import NanoDictateCore

/// Тесты жёсткого лимита записи (60 с / 960 000 сэмплов).
/// Чистая логика `RecordingLimit` — без реального аудио-устройства,
/// AVAudioEngine/AVAudioConverter в мини-XCTest не запускается.
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
        // 59.999 с — ещё работает; ровно 60.0 с — обязательная остановка.
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
        // 16 кГц × 60 с = 960 000 сэмплов — ровно по требованию, без запаса.
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
        // Тишина (почти пустой буфер) не отменяет лимит по времени.
        XCTAssertFalse(limit.shouldStop(elapsed: 59.999, totalSamples: 10))
        XCTAssertTrue(limit.shouldStop(elapsed: 60.0, totalSamples: 10))
    }

    @objc func testSampleCapTriggersWithLittleElapsedTime() {
        var limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
        // Мгновенный переполняющий ввод останавливает запись и до 60 с.
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
        // Даже «сброшенные» время/объём не отменяют остановку: защёлка держит,
        // пока не начат новый сеанс (новый экземпляр лимита).
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
        // 960 000 занято — свободных сэмплов нет, буфер дальше не растёт.
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

        // В AudioService.start() создаётся НОВЫЙ RecordingLimit — как здесь:
        // предыдущая защёлка не переносится в новый сеанс.
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
        XCTAssertTrue(limit.shouldStop(elapsed: 0.5, totalSamples: 7_999))   // время
        XCTAssertTrue(limit.shouldStop(elapsed: 0.1, totalSamples: 8_000))   // объём
        XCTAssertEqual(limit.remainingSamples(after: 8_000), 0)
        XCTAssertTrue(limit.isExhausted)
    }
}