import Foundation
@testable import NanoDictateCore

// MARK: - Тесты VAD-сегментации (AudioSegmenter)
//
// Synthetic RMS timelines and samples; no network or I/O.

final class AudioSegmenterTests: XCTestCase {

    private let speech: Float = 0.05   // above silence threshold
    private let silence: Float = 0.001 // below silence threshold

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
        // Pause exists but segment < minSegment — no split.
        let rms: [Float] = [speech, silence, speech, speech, speech]
        let ranges = AudioSegmenter.splitRanges(
            rms: rms, windowDuration: 1.0, config: cfg(min: 3.0)
        )
        XCTAssertEqual(ranges, [0..<5])
    }

    @objc func testTrailingShortSpeechMerges_WhenCombinedWithinMax() {
        // Pause splits [0..<5] (pause 2s, min 3s); trailing 1s of speech
        // < minSegment merges back into the last segment because combined
        // length (8s) <= maxSegment (9s).
        let rms: [Float] = [speech, speech, speech, speech, speech, silence, silence, speech]
        let ranges = AudioSegmenter.splitRanges(
            rms: rms, windowDuration: 1.0, config: cfg(pause: 2.0, min: 3.0, max: 9.0)
        )
        XCTAssertEqual(ranges, [0..<8])
    }

    @objc func testTrailingShortSpeechNotMerged_WhenCombinedExceedsMax() {
        // Hard-cap cut at 4s (max 4s); trailing 1s of speech < minSegment,
        // but combined length (5s) > maxSegment (4s) — merge condition
        // fails, trail stays its own segment.
        let rms: [Float] = [speech, speech, speech, speech, speech]
        let ranges = AudioSegmenter.splitRanges(
            rms: rms, windowDuration: 1.0, config: cfg(min: 3.0, max: 4.0)
        )
        XCTAssertEqual(ranges, [0..<4, 4..<5])
    }

    @objc func testHardMaxBoundary() {
        // 50 speech windows, maxSegment 10s → five segments.
        let rms = Array(repeating: speech, count: 50)
        let ranges = AudioSegmenter.splitRanges(
            rms: rms, windowDuration: 1.0, config: cfg(min: 1.0, max: 10.0)
        )
        XCTAssertEqual(ranges, [0..<10, 10..<20, 20..<30, 30..<40, 40..<50])
    }

    @objc func testPauseShorterThanRequiredDoesNotSplit() {
        // Pause of 1 window < pauseDuration 2s — no split.
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

    /// Voiceless timeline below the adaptive enter threshold emits nothing —
    /// neither via the hard cap nor via the trailing segment. Regression for
    /// exit-threshold checks emitting `0..<3` for `[0.001, 0.002, 0.002]`
    /// (enter ≈ 0.00251, exit ≈ 0.00158): hysteresis never enters speech.
    @objc func testVoicelessTimelineBelowEnterYieldsNoSegments() {
        let rms: [Float] = [0.001, 0.002, 0.002]
        let hardCap = AudioSegmenter.splitRanges(
            rms: rms, windowDuration: 1.0, config: cfg(pause: 1.0, min: 1.0, max: 3.0)
        )
        XCTAssertTrue(hardCap.isEmpty, "hard cap must not emit a voiceless segment")
        let trailing = AudioSegmenter.splitRanges(
            rms: rms, windowDuration: 1.0, config: cfg(pause: 1.0, min: 1.0, max: 45.0)
        )
        XCTAssertTrue(trailing.isEmpty, "trailing voiceless tail must not emit a segment")
    }

    // MARK: - Сэмплы (16 кГц) + оверлэп

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
        // Speech 2s, pause 1.5s, speech 2s → 2 segments, 1s overlap prepended.
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
        XCTAssertEqual(first.samples.count, firstEnd) // no overlap on first segment

        let second = segments[1]
        let bodyStart = Int((second.start * 16000).rounded())
        let bodyEnd = Int((second.end * 16000).rounded())
        XCTAssertEqual(second.samples.count, bodyEnd - bodyStart + 16000) // body + 1s overlap
        // Overlap is tail of previous body (speech), not pause silence.
        XCTAssertEqual(
            Array(second.samples[0..<16000]),
            Array(samples[(firstEnd - 16000)..<firstEnd])
        )
        XCTAssertTrue(second.samples[0..<16000].contains { abs($0) > 0 })
    }

    @objc func testSamplesNoSegmentsWhenAllSilent() {
        let samples = makeSamples([(amplitude: 0.0, seconds: 3.0)])
        let segments = AudioSegmenter.segments(samples: samples, sampleRate: 16000)
        XCTAssertTrue(segments.isEmpty)
    }

    // MARK: - F4: запись обрывается посреди паузы

    @objc func testRecordingCutsMidPause() {
        // Speech 2s, silence 0.7s (< minSegment), recording cut → one segment.
        let rms: [Float] = [speech, speech, silence]
        let ranges = AudioSegmenter.splitRanges(
            rms: rms, windowDuration: 1.0, config: cfg(pause: 1.0, min: 1.0)
        )
        XCTAssertEqual(ranges.count, 1)
        XCTAssertEqual(ranges[0], 0..<3)
    }

    // MARK: - Single-pass plan (range-based, no per-window copies)

    @objc func testPlanEmptyGivesNoSpecs() {
        let specs = AudioSegmenter.plan(samples: [], sampleRate: 16000)
        XCTAssertTrue(specs.isEmpty)
        XCTAssertEqual(AudioSegmenter.requestCount(for: specs), 0)
        XCTAssertEqual(AudioSegmenter.watchdogRequestCount(for: specs), 1)
    }

    @objc func testPlanAllSilenceGivesNoSpecs() {
        let samples = makeSamples([(amplitude: 0.0, seconds: 3.0)])
        let specs = AudioSegmenter.plan(samples: samples, sampleRate: 16000)
        XCTAssertTrue(specs.isEmpty, "voiceless recording emits no specs and no STT request")
        XCTAssertEqual(AudioSegmenter.requestCount(for: specs), 0)
    }

    @objc func testPlanContinuousSpeechSingleSpec() {
        let samples = makeSamples([(amplitude: 0.1, seconds: 4.0)])
        let specs = AudioSegmenter.plan(samples: samples, sampleRate: 16000, config: cfg(pause: 1.0, min: 1.0, overlap: 1.0))
        XCTAssertEqual(specs.count, 1)
        XCTAssertEqual(specs[0].index, 0)
        XCTAssertNil(specs[0].overlapRange)
        XCTAssertEqual(specs[0].overlapSeconds, 0)
        XCTAssertEqual(specs[0].bodyRange.lowerBound, 0)
        XCTAssertEqual(specs[0].bodyRange.upperBound, samples.count)
        XCTAssertEqual(AudioSegmenter.requestCount(for: specs), 1, "single segment needs no final pass")
        XCTAssertEqual(AudioSegmenter.watchdogRequestCount(for: specs), 1)
    }

    @objc func testPlanMultipleSegmentsWithOverlap() {
        // Speech 2s, pause 1.5s, speech 2s → 2 specs, 1s overlap from previous body tail.
        let samples = makeSamples([
            (amplitude: 0.1, seconds: 2.0),
            (amplitude: 0.0, seconds: 1.5),
            (amplitude: 0.1, seconds: 2.0)
        ])
        let config = cfg(pause: 1.0, min: 1.0, overlap: 1.0)
        let specs = AudioSegmenter.plan(samples: samples, sampleRate: 16000, config: config)
        XCTAssertEqual(specs.count, 2)
        // Bodies ordered, non-overlapping; pause gap sits between them.
        XCTAssertLessThanOrEqual(specs[0].bodyRange.upperBound, specs[1].bodyRange.lowerBound)
        XCTAssertEqual(specs[0].overlapRange, nil)
        XCTAssertNotNil(specs[1].overlapRange)
        // Overlap is tail of previous BODY (speech), capped at 1s = 16000 samples.
        let prevEnd = specs[0].bodyRange.upperBound
        XCTAssertEqual(specs[1].overlapRange?.upperBound, prevEnd)
        XCTAssertEqual((specs[1].overlapRange!.upperBound - specs[1].overlapRange!.lowerBound), 16000)
        XCTAssertEqual(specs[1].overlapSeconds, 1.0, accuracy: 0.001)
        XCTAssertEqual(AudioSegmenter.requestCount(for: specs), 3, "2 segments + final pass")
        XCTAssertEqual(AudioSegmenter.watchdogRequestCount(for: specs), 3)
        // Lazy materialization matches legacy owned-PCM wrapper byte-for-byte.
        let legacy = AudioSegmenter.segments(samples: samples, sampleRate: 16000, config: config)
        XCTAssertEqual(legacy.count, specs.count)
        for (spec, seg) in zip(specs, legacy) {
            XCTAssertEqual(spec.start, seg.start, accuracy: 0.0001)
            XCTAssertEqual(spec.end, seg.end, accuracy: 0.0001)
            XCTAssertEqual(spec.overlapSeconds, seg.overlapSeconds, accuracy: 0.0001)
            XCTAssertEqual(spec.samples(from: samples), seg.samples)
        }
    }

    @objc func testPlanOverlapCappedByPreviousBody() {
        // Overlap 5s > previous body ~2s → capped at body length.
        let samples = makeSamples([
            (amplitude: 0.1, seconds: 2.0),
            (amplitude: 0.0, seconds: 1.5),
            (amplitude: 0.1, seconds: 4.0)
        ])
        let config = AudioSegmenterConfig(pauseDuration: 1.0, minSegment: 1.0, maxSegment: 45.0, overlap: 5.0)
        let specs = AudioSegmenter.plan(samples: samples, sampleRate: 16000, config: config)
        XCTAssertEqual(specs.count, 2)
        let prevLen = specs[0].bodyRange.count
        XCTAssertEqual(specs[1].overlapRange?.count, prevLen)
        XCTAssertEqual(specs[1].overlapSeconds, TimeInterval(prevLen) / 16000.0, accuracy: 0.001)
        XCTAssertTrue(specs[1].overlapSeconds < 3.0)
    }

    @objc func testRmsSliceAndBufferMatchArray() {
        let samples: [Int16] = [1000, -1000, 2000, -2000, 0, 32767, -32768, 123]
        let expected = AudioMetrics.rms(samples: samples)
        let slice = samples[1..<6]
        XCTAssertEqual(AudioMetrics.rms(samples: slice), AudioMetrics.rms(samples: Array(slice)), accuracy: 1e-6)
        let buffered: Float = samples.withUnsafeBufferPointer { AudioMetrics.rms(buffer: $0) }
        XCTAssertEqual(buffered, expected, accuracy: 1e-6)
        // Empty views are zero, never NaN.
        XCTAssertEqual(AudioMetrics.rms(samples: Array(samples[0..<0])), 0)
        XCTAssertEqual(samples[0..<0].withUnsafeBufferPointer { AudioMetrics.rms(buffer: $0) }, 0)
    }

    @objc func testRmsTimelineMatchesWindowedArrayRms() {
        let samples = makeSamples([(amplitude: 0.1, seconds: 1.0)])
        let timeline = AudioSegmenter.rmsTimeline(samples: samples, sampleRate: 16000)
        let windowSize = Int((AudioSegmenter.defaultWindowDuration * 16000).rounded())
        XCTAssertEqual(timeline.count, (samples.count + windowSize - 1) / windowSize)
        let firstWindow = Array(samples[0..<windowSize])
        XCTAssertEqual(timeline[0], AudioMetrics.rms(samples: firstWindow), accuracy: 1e-6)
    }

    @objc func testEncodeSegmentMatchesEncodeCombined() {
        let samples = makeSamples([
            (amplitude: 0.1, seconds: 2.0),
            (amplitude: 0.0, seconds: 1.5),
            (amplitude: 0.1, seconds: 2.0)
        ])
        let specs = AudioSegmenter.plan(samples: samples, sampleRate: 16000, config: cfg(pause: 1.0, min: 1.0, overlap: 1.0))
        XCTAssertEqual(specs.count, 2)
        for spec in specs {
            let combined = spec.samples(from: samples)
            let viaCombined = WAVEncoder.encode(samples: combined, sampleRate: 16000)
            let direct = WAVEncoder.encodeSegment(
                source: samples, bodyRange: spec.bodyRange, overlapRange: spec.overlapRange, sampleRate: 16000)
            XCTAssertEqual(direct, viaCombined, "direct range encode must be byte-identical")
        }
    }

    @objc func testLongFixtureSinglePassPeakCopies() {
        // Near-60-second fixture: alternating speech/silence gives several segments.
        // Legacy `segments` holds ALL segment PCM at once; the plan holds only
        // ranges, and lazy materialization peaks at the largest single segment.
        var samples: [Int16] = []
        for _ in 0..<9 {
            samples += makeSamples([(amplitude: 0.1, seconds: 4.0)])
            samples += makeSamples([(amplitude: 0.0, seconds: 1.5)])
        }
        samples += makeSamples([(amplitude: 0.1, seconds: 4.0)])
        let duration = Double(samples.count) / 16000.0
        XCTAssertGreaterThanOrEqual(duration, 50)
        XCTAssertLessThanOrEqual(duration, 65)
        let config = cfg(pause: 1.0, min: 1.0, overlap: 1.0)
        let specs = AudioSegmenter.plan(samples: samples, sampleRate: 16000, config: config)
        XCTAssertGreaterThanOrEqual(specs.count, 2, "long fixture must yield multiple segments")
        // Specs reference the source buffer: bodies ordered and bounded.
        for spec in specs {
            XCTAssertTrue(spec.bodyRange.lowerBound >= 0 && spec.bodyRange.upperBound <= samples.count)
        }
        for i in 1..<specs.count {
            XCTAssertLessThanOrEqual(specs[i - 1].bodyRange.upperBound, specs[i].bodyRange.lowerBound)
            XCTAssertEqual(specs[i].index, i)
        }
        // Peak lazy PCM (largest single materialized segment) is strictly
        // smaller than the legacy all-at-once footprint.
        let legacyTotal = AudioSegmenter.segments(samples: samples, sampleRate: 16000, config: config)
            .reduce(0) { $0 + $1.samples.count }
        let peakLazy = specs.map { spec in
            (spec.overlapRange?.count ?? 0) + spec.bodyRange.count
        }.max() ?? 0
        XCTAssertGreaterThan(legacyTotal, 0)
        XCTAssertGreaterThan(peakLazy, 0)
        XCTAssertLessThan(peakLazy, legacyTotal, "single-pass peak must stay below all-at-once total")
        // Each lazy segment encodes to the same bytes as the legacy wrapper.
        for spec in specs {
            let direct = WAVEncoder.encodeSegment(
                source: samples, bodyRange: spec.bodyRange, overlapRange: spec.overlapRange, sampleRate: 16000)
            let viaCombined = WAVEncoder.encode(samples: spec.samples(from: samples), sampleRate: 16000)
            XCTAssertEqual(direct, viaCombined)
        }
    }
}