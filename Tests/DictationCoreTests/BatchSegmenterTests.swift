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
}