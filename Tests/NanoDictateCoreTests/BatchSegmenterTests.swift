import Foundation
@testable import NanoDictateCore

// MARK: - Тесты BatchSegmenter (нарезка на чанки с оверлэпом)

final class BatchSegmenterTests: XCTestCase {

    /// Constant-value samples: unique marker per second.
    private func tone(_ seconds: Double, value: Int16, sampleRate: Int = 16000) -> [Int16] {
        Array(repeating: value, count: max(0, Int((seconds * Double(sampleRate)).rounded())))
    }

    // MARK: Пустой вход

    @objc func testEmptySamplesGiveEmptyChunks() {
        let chunks = BatchSegmenter.segments(samples: [], sampleRate: 16000)
        XCTAssertTrue(chunks.isEmpty, "пустые сэмплы — пустой результат")
    }

    // MARK: Один чанк для короткого файла

    @objc func testShortFileSingleChunk() {
        let samples = tone(5, value: 100)
        let chunks = BatchSegmenter.segments(samples: samples, sampleRate: 16000, maxSegment: 30, overlap: 2.5)
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].index, 0)
        XCTAssertEqual(chunks[0].bodyStart, 0, accuracy: 0.001)
        XCTAssertEqual(chunks[0].bodyEnd, 5, accuracy: 0.001)
        XCTAssertEqual(chunks[0].samples, samples, "первый чанк — только тело, без оверлэпа")
    }

    // MARK: Покрытие: тела идут подряд, весь файл покрыт

    @objc func testBodiesCoverFileWithoutGapsOrOverlaps() {
        let duration: Double = 100
        let samples = tone(duration, value: 50)
        let chunks = BatchSegmenter.segments(samples: samples, sampleRate: 16000, maxSegment: 30, overlap: 2.5)

        // 100 s / 30 s = 4 chunks (last shorter).
        XCTAssertEqual(chunks.count, 4)
        XCTAssertEqual(chunks[0].bodyStart, 0, accuracy: 0.001)
        XCTAssertEqual(chunks.last!.bodyEnd, 100, accuracy: 0.001)
        for i in 1..<chunks.count {
            XCTAssertEqual(chunks[i].bodyStart, chunks[i - 1].bodyEnd, accuracy: 0.001,
                           "тела чанков идут подряд без пропусков и перекрытий")
        }
        // Overlap makes every chunk (except first) longer than bare body.
        XCTAssertGreaterThanOrEqual(chunks[1].samples.count, 480_000,
                                    "оверлэп добавляет контекст предыдущего тела")
    }

    // MARK: Оверлэп: голова следующего = хвост тела предыдущего

    @objc func testOverlapPrependsTailOfPreviousBody() {
        let bodySize = 480_000 // 30 s * 16000
        let overlapCount = 40_000 // 2.5 s * 16000
        var samples = tone(30, value: 1)
        samples += tone(30, value: 2)

        let chunks = BatchSegmenter.segments(samples: samples, sampleRate: 16000, maxSegment: 30, overlap: 2.5)
        XCTAssertEqual(chunks.count, 2)
        let expectedHead = Array(samples[(bodySize - overlapCount)..<bodySize])
        XCTAssertEqual(Array(chunks[1].samples.prefix(overlapCount)), expectedHead,
                       "оверлэп — последние overlap секунд ТЕЛА предыдущего чанка")
        XCTAssertEqual(chunks[1].samples.count, bodySize + overlapCount)
    }

    @objc func testOverlapZeroMeansPureBodies() {
        let samples = tone(60, value: 7)
        let chunks = BatchSegmenter.segments(samples: samples, sampleRate: 16000, maxSegment: 30, overlap: 0)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[1].samples.count, 480_000, "без оверлэпа чанк = тело")
        XCTAssertEqual(chunks[1].samples, Array(samples[480_000...]))
    }

    @objc func testOverlapLimitedToFileLength() {
        // Overlap wider than file: head = full previous body.
        let samples = tone(4, value: 3, sampleRate: 1000)
        let chunks = BatchSegmenter.segments(samples: samples, sampleRate: 1000, maxSegment: 2, overlap: 10)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks[1].samples, samples, "голова не может выйти за начало файла")
    }

    // MARK: Параметры

    @objc func testBodySizeRoundsMaxSegment() {
        let samples = tone(30, value: 9)
        let chunks = BatchSegmenter.segments(samples: samples, sampleRate: 16000, maxSegment: 30, overlap: 2.5)
        XCTAssertEqual(chunks[0].samples.count, Int((30.0 * 16000).rounded()))
        XCTAssertEqual(chunks[0].bodyEnd, 30, accuracy: 0.001)
    }

    @objc func testIndexesAreSequential() {
        let samples = tone(90, value: 4)
        let chunks = BatchSegmenter.segments(samples: samples, sampleRate: 16000, maxSegment: 30, overlap: 2.5)
        XCTAssertEqual(chunks.map(\.index), [0, 1, 2])
    }

    // MARK: plan() — cutAtPauses

    @objc func testPlanCutAtPausesShiftsBoundaryToSilenceStart() throws {
        let sr = 1000
        // speech(6s loud), silence(1.2s), speech(6s), silence(1.2s), speech(6s)
        var samples = tone(6, value: 500, sampleRate: sr)
        samples += tone(1.2, value: 0, sampleRate: sr)
        samples += tone(6, value: 500, sampleRate: sr)
        samples += tone(1.2, value: 0, sampleRate: sr)
        samples += tone(6, value: 500, sampleRate: sr)
        XCTAssertEqual(samples.count, 20_400)

        let content = ArrayPCMBatchContent(samples: samples, sampleRate: sr)
        let specs = try BatchSegmenter.plan(
            content: content,
            maxSegment: 10,
            overlap: 1.0,
            cutAtPauses: true,
            pauseDuration: 1.0,
            maxDrift: 5.0
        )

        XCTAssertEqual(specs.count, 2, "два чанка: [0, ~13.2s) и [~13.2s, 20.4s)")

        // Chunk 0: boundary shifted to second pause start (13200), within RMS
        // scan window (0.085 s * sr = 85 samples): first silent window at 13245.
        XCTAssertEqual(specs[0].bodyStart, 0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(specs[0].bodyEnd, 13.2,
                                    "граница не раньше начала паузы (13200 = 13.2s)")
        XCTAssertLessThanOrEqual(specs[0].bodyEnd, 13.2 + 0.1,
                                 "граница не дальше одного окна RMS от начала паузы")
        XCTAssertEqual(specs[0].bodyRange.lowerBound, 0)
        XCTAssertTrue(specs[0].bodyRange.upperBound >= 13_200
                        && specs[0].bodyRange.upperBound <= 13_200 + 85,
                      "тело чанка 0 заканчивается на паузе (13200±окно), было: \(specs[0].bodyRange)")
        XCTAssertNil(specs[0].overlapRange, "первый чанк без оверлэпа")

        // Chunk 1: last chunk not trimmed (bodyEnd = totalSamples).
        XCTAssertEqual(specs[1].bodyEnd, 20.4, accuracy: 0.001)
        XCTAssertEqual(specs[1].bodyRange.upperBound, 20_400)

        // Bodies contiguous: chunk 1 boundary = chunk 0 boundary.
        XCTAssertEqual(specs[1].bodyStart, specs[0].bodyEnd, accuracy: 0.001,
                       "тела чанков идут подряд — общая граница = граница паузы")
        XCTAssertEqual(specs[1].bodyRange.lowerBound, specs[0].bodyRange.upperBound,
                       "read-окна тел смежны")
        XCTAssertEqual(specs[1].overlapRange?.upperBound, specs[0].bodyRange.upperBound,
                       "оверлэп чанка 1 = хвост тела чанка 0")
    }

    // MARK: plan() дефолты — выравнивание на паузу включено (0.3 с)

    @objc func testPlanDefaultCutsAtPause() throws {
        // Speech 6 s + 0.4 s pause (≥ 0.3 s default) + 4 s speech; default
        // cutAtPauses/pauseDuration — no explicit slicing arguments.
        let sr = 1000
        var samples = tone(6, value: 500, sampleRate: sr)
        samples += tone(0.4, value: 0, sampleRate: sr)
        samples += tone(4, value: 500, sampleRate: sr)

        let content = ArrayPCMBatchContent(samples: samples, sampleRate: sr)
        let specs = try BatchSegmenter.plan(content: content, maxSegment: 10, overlap: 1.0)

        XCTAssertEqual(specs.count, 2, "пауза 0.4 с ≥ 0.3 с — граница в тишину")
        // Boundary = pause start (6000) within RMS window (0.085·sr = 85).
        XCTAssertGreaterThanOrEqual(specs[0].bodyEnd, 6.0, "граница не раньше начала паузы")
        XCTAssertLessThanOrEqual(specs[0].bodyEnd, 6.1, "граница не дальше одного окна RMS")
        XCTAssertEqual(specs[0].bodyRange.upperBound, specs[1].bodyRange.lowerBound,
                       "тела идут подряд после выравнивания")
    }

    @objc func testPlanDefaultKeepsFixedBoundaryWhenPauseTooShort() throws {
        // Pause 0.2 s < 0.3 s default — boundary not shifted: chunk stays fixed
        // 10.0 s (pause below threshold, speech continues inside chunk).
        let sr = 1000
        var samples = tone(6, value: 500, sampleRate: sr)
        samples += tone(0.2, value: 0, sampleRate: sr)
        samples += tone(4, value: 500, sampleRate: sr)

        let content = ArrayPCMBatchContent(samples: samples, sampleRate: sr)
        let specs = try BatchSegmenter.plan(content: content, maxSegment: 10, overlap: 1.0)

        XCTAssertEqual(specs.count, 2)
        XCTAssertEqual(specs[0].bodyEnd, 10.0, accuracy: 0.001,
                       "пауза 0.2 с < 0.3 с — фиксированная граница, тело чанка 10 с")
        XCTAssertEqual(specs[0].bodyRange.upperBound, 10_000)
    }

    @objc func testPlanDefaultLastChunkNeverTrimmed() throws {
        // Last chunk never aligned (bodyEnd = totalSamples) even with silence nearby.
        let sr = 1000
        var samples = tone(6, value: 500, sampleRate: sr)
        samples += tone(1.0, value: 0, sampleRate: sr)
        samples += tone(2, value: 500, sampleRate: sr)

        let content = ArrayPCMBatchContent(samples: samples, sampleRate: sr)
        let specs = try BatchSegmenter.plan(content: content, maxSegment: 10, overlap: 1.0)

        XCTAssertEqual(specs.count, 1, "файл 9 с < maxSegment 10 с — один чанк")
        XCTAssertEqual(specs[0].bodyEnd, 9.0, accuracy: 0.001, "последний чанк без обрезания")
    }

    // MARK: plan() — fail-closed: граница ≤ bodyStart не режет spec

    @objc func testPlanRejectsBoundaryAtBodyStart_KeepsFullBody() throws {
        // maxSegment 0.001 с при sr 1000 → bodySize == 1 сэмпл, поэтому
        // minBoundary == bodyStart (bodySize / 2 == 0 при целочисленном
        // делении). Сплошная тишина: pauseCut находит паузу с началом ровно
        // в bodyStart == 0 — guard boundary > bodyStart обязан отклонить рез,
        // spec сохраняет полное тело (fail-closed), пустой bodyRange
        // (bodyStart..<bodyStart) не создаётся.
        let sr = 1000
        let samples = tone(0.3, value: 0, sampleRate: sr) // ≥ minPauseSamples (0.3 с)

        let content = ArrayPCMBatchContent(samples: samples, sampleRate: sr)
        let specs = try BatchSegmenter.plan(content: content, maxSegment: 0.001, overlap: 0)

        XCTAssertFalse(specs.isEmpty)
        XCTAssertEqual(specs[0].bodyStart, 0, accuracy: 0.001)
        XCTAssertEqual(specs[0].bodyEnd, 0.001, accuracy: 0.001,
                       "boundary == bodyStart отклоняется — тело сохраняется целиком (fail-closed)")
        XCTAssertEqual(specs[0].bodyRange, 0..<1, "spec не пуст: bodyRange шириной 1 сэмпл")
    }

    // MARK: WAV-заголовок: стерео отсекается (моно-only)

    @objc func testStereoWAVRejectedAsInvalid() throws {
        var wav = WAVEncoder.encode(samples: [Int16](repeating: 100, count: 1600))
        // fmt-чанк: numChannels (Int16 LE) на смещении 22 — патчим в 2 (стерео).
        wav.replaceSubrange(22..<24, with: [2, 0])

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dct-test-stereo-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try wav.write(to: url)

        XCTAssertThrowsError(try WAVFilePCMBatchContent(wavURL: url)) { error in
            XCTAssertEqual(error as? WAVFilePCMBatchContent.WAVFileError, .invalidWAV,
                           "стерео WAV должен отклоняться stereo-guard'ом")
        }
    }
}