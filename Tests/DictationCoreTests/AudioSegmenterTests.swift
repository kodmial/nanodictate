import Foundation
@testable import DictationCore

// MARK: - Тесты VAD-сегментации (AudioSegmenter)
//
// Синтетические RMS-таймлайны (окно = 1 с) и сэмплы. Никакой сети и I/O.

final class AudioSegmenterTests: XCTestCase {

    private let speech: Float = 0.05   // выше порога тишины
    private let silence: Float = 0.001 // ниже порога тишины

    private func cfg(
        pause: TimeInterval = 1.0,
        min: TimeInterval = 3.0,
        max: TimeInterval = 45.0,
        overlap: TimeInterval = 1.0
    ) -> AudioSegmenterConfig {
        AudioSegmenterConfig(
            pauseDuration: pause,
            minSegment: min,
            maxSegment: max,
            overlap: overlap
        )
    }

    // MARK: - RMS-таймлайн (окно = 1 c)

    @objc func testPauseBoundarySplits() {
        let rms: [Float] = [speech, speech, speech, silence, speech, speech, speech]
        let ranges = AudioSegmenter.splitRanges(
            rms: rms, windowDuration: 1.0, config: cfg(min: 1.0)
        )
        XCTAssertEqual(ranges, [0..<3, 4..<7])
    }

    @objc func testShortSegmentIsMerged() {
        // Пауза после первого слова есть, но сегмент короче minSegment — не режем.
        let rms: [Float] = [speech, silence, speech, speech, speech]
        let ranges = AudioSegmenter.splitRanges(
            rms: rms, windowDuration: 1.0, config: cfg(min: 3.0)
        )
        XCTAssertEqual(ranges, [0..<5])
    }

    @objc func testHardMaxBoundary() {
        // Непрерывная речь 50 окон; maxSegment = 10 c → пять сегментов по 10.
        let rms = Array(repeating: speech, count: 50)
        let ranges = AudioSegmenter.splitRanges(
            rms: rms, windowDuration: 1.0, config: cfg(min: 1.0, max: 10.0)
        )
        XCTAssertEqual(ranges, [0..<10, 10..<20, 20..<30, 30..<40, 40..<50])
    }

    @objc func testPauseShorterThanRequiredDoesNotSplit() {
        // pauseDuration = 2 c, пауза всего 1 окно — границы нет.
        let rms: [Float] = [speech, speech, silence, speech, speech, speech]
        let ranges = AudioSegmenter.splitRanges(
            rms: rms, windowDuration: 1.0, config: cfg(pause: 2.0, min: 1.0)
        )
        XCTAssertEqual(ranges, [0..<6])
    }

    @objc func testSingleSpeechBlockIsOneSegment() {
        let rms: [Float] = [speech, speech, speech]
        let ranges = AudioSegmenter.splitRanges(
            rms: rms, windowDuration: 1.0, config: cfg(min: 1.0)
        )
        XCTAssertEqual(ranges, [0..<3])
    }

    @objc func testEmptyRMSNoSegments() {
        let ranges = AudioSegmenter.splitRanges(rms: [], windowDuration: 1.0)
        XCTAssertTrue(ranges.isEmpty)
    }

    // MARK: - Сэмплы (16 кГц) + оверлэп

    /// Синтез записи: блоки (амплитуда синуса, секунды) подряд.
    private func makeSamples(_ blocks: [(amplitude: Float, seconds: Double)], sampleRate: Int = 16000) -> [Int16] {
        var out: [Int16] = []
        for block in blocks {
            let count = Int((block.seconds * Double(sampleRate)).rounded())
            let phaseStep = 2 * Double.pi * 440.0 / Double(sampleRate)
            for i in 0..<count {
                let v = block.amplitude * Float(sin(phaseStep * Double(i)))
                out.append(Int16(v * 32767))
            }
        }
        return out
    }

    @objc func testSamplesOverlapPrependToNextSegment() {
        // Речь 2 с, пауза 1.5 с, речь 2 с → два сегмента; к началу второго
        // приклеена последняя секунда первого (оверлэп).
        let samples = makeSamples([
            (amplitude: 0.1, seconds: 2.0),
            (amplitude: 0.0, seconds: 1.5),
            (amplitude: 0.1, seconds: 2.0)
        ])
        let segments = AudioSegmenter.segments(
            samples: samples,
            sampleRate: 16000,
            config: cfg(pause: 1.0, min: 1.0, overlap: 1.0)
        )

        XCTAssertEqual(segments.count, 2)

        let first = segments[0]
        XCTAssertEqual(first.start, 0)
        let firstEnd = Int((first.end * 16000).rounded())
        XCTAssertEqual(first.samples.count, firstEnd) // без оверлэпа у первого

        let second = segments[1]
        let bodyStart = Int((second.start * 16000).rounded())
        let bodyEnd = Int((second.end * 16000).rounded())
        XCTAssertEqual(second.samples.count, bodyEnd - bodyStart + 16000) // тело + 1 c оверлэпа
        XCTAssertEqual(
            Array(second.samples[0..<16000]),
            Array(samples[(bodyStart - 16000)..<bodyStart])
        )
    }

    @objc func testSamplesNoSegmentsWhenAllSilent() {
        let samples = makeSamples([(amplitude: 0.0, seconds: 3.0)])
        let segments = AudioSegmenter.segments(samples: samples, sampleRate: 16000)
        XCTAssertTrue(segments.isEmpty)
    }
}