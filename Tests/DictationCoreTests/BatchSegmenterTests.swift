import Foundation
@testable import DictationCore

// MARK: - Тесты BatchSegmenter (нарезка на чанки с оверлэпом)

final class BatchSegmenterTests: XCTestCase {

    /// Сэмплы с постоянным значением `value` (уникальный маркер на секунду).
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

        // 100 с / 30 с = 4 чанка (последний короче).
        XCTAssertEqual(chunks.count, 4)
        XCTAssertEqual(chunks[0].bodyStart, 0, accuracy: 0.001)
        XCTAssertEqual(chunks.last!.bodyEnd, 100, accuracy: 0.001)
        for i in 1..<chunks.count {
            XCTAssertEqual(chunks[i].bodyStart, chunks[i - 1].bodyEnd, accuracy: 0.001,
                           "тела чанков идут подряд без пропусков и перекрытий")
        }
        // Каждый чанк (кроме первого) длиннее чистого тела за счёт оверлэпа.
        XCTAssertGreaterThanOrEqual(chunks[1].samples.count, 480_000,
                                    "оверлэп добавляет контекст предыдущего тела")
    }

    // MARK: Оверлэп: голова следующего = хвост тела предыдущего

    @objc func testOverlapPrependsTailOfPreviousBody() {
        let bodySize = 480_000 // 30 с * 16000
        let overlapCount = 40_000 // 2.5 с * 16000
        // Файл: 2 полных тела.
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
        // Короткий файл, оверлэп больше всего файла — голова = всё предыдущее тело.
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

        // Chunk 0: boundary сдвинут к началу ВТОРОЙ паузы (13200) — с точностью
        // до окна RMS-сканирования (windowSize = 0.085s * sr = 85 сэмплов):
        // первое полностью тихое окно начинается в 13245 (13.245s).
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

        // Chunk 1: последний чанк — без обрезания (bodyEnd = totalSamples).
        XCTAssertEqual(specs[1].bodyEnd, 20.4, accuracy: 0.001)
        XCTAssertEqual(specs[1].bodyRange.upperBound, 20_400)

        // Bodies andдут подряд: граница чанка 1 = граница чанка 0.
        XCTAssertEqual(specs[1].bodyStart, specs[0].bodyEnd, accuracy: 0.001,
                       "тела чанков идут подряд — общая граница = граница паузы")
        XCTAssertEqual(specs[1].bodyRange.lowerBound, specs[0].bodyRange.upperBound,
                       "read-окна тел смежны")
        XCTAssertEqual(specs[1].overlapRange?.upperBound, specs[0].bodyRange.upperBound,
                       "оверлэп чанка 1 = хвост тела чанка 0")
    }
}