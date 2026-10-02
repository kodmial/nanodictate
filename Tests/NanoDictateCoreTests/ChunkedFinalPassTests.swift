import Foundation
@testable import NanoDictateCore

// MARK: - ChunkedFinalPass policy tests (no network)

final class ChunkedFinalPassTests: XCTestCase {
  private func makeSamples(_ blocks: [(amplitude: Float, seconds: Double)]) -> [Int16] {
    var out: [Int16] = []
    for block in blocks {
      let count = Int((block.seconds * 16000.0).rounded())
      let step = 2 * Double.pi * 440.0 / 16000.0
      for i in 0..<count {
        out.append(Int16(block.amplitude * Float(sin(step * Double(i))) * 32767))
      }
    }
    return out
  }

  private func twoSegments() -> [Int16] {
    makeSamples([(0.1, 2.0), (0.0, 1.5), (0.1, 2.0)])
  }

  private final class MockSTT {
    let results: [ChunkedPipeline.SttResult]
    var calls: [String] = []
    private var index = 0
    init(results: [ChunkedPipeline.SttResult]) { self.results = results }
    init(texts: [String]) {
      self.results = texts.map { ChunkedPipeline.SttResult(text: $0) }
    }
    func call(_ wav: Data, _ filename: String, _ prompt: String?) async throws
      -> ChunkedPipeline.SttResult
    {
      calls.append(filename)
      guard index < results.count else { throw NSError(domain: "MockSTT", code: 1) }
      let result = results[index]
      index += 1
      return result
    }
  }

  private let segConfig = AudioSegmenterConfig(
    pauseDuration: 1.0, minSegment: 1.0, maxSegment: 45.0, overlap: 0.0)

  private func run(
    samples: [Int16], mock: MockSTT, policy: ChunkedFinalPassPolicy
  ) throws -> (ChunkedPipeline.Outcome, [String]) {
    let box = ResultBox<(ChunkedPipeline.Outcome, [String])>()
    let expect = expectation(description: "run")
    Task {
      do {
        let pipeline = ChunkedPipeline(
          sampleRate: 16000, segmenterConfig: self.segConfig, finalPassPolicy: policy)
        var phases: [String] = []
        let outcome = try await pipeline.run(
          samples: samples,
          stt: { wav, filename, prompt in try await mock.call(wav, filename, prompt) },
          insert: { _ in },
          onPhase: { phase in
            switch phase {
            case .segment(let i): phases.append("segment-\(i)")
            case .finalizing: phases.append("finalizing")
            }
          })
        box.value = (outcome, phases)
      } catch {
        box.error = error
      }
      expect.fulfill()
    }
    wait(for: [expect], timeout: 10.0)
    if let error = box.error { throw error }
    return box.value!
  }

  private final class ResultBox<T> {
    var value: T?
    var error: Error?
  }

  @objc func testPolicyParsing() throws {
    XCTAssertEqual(ChunkedFinalPassPolicy(configString: "always"), .always)
    XCTAssertEqual(ChunkedFinalPassPolicy(configString: "on-uncertainty"), .onUncertainty)
    XCTAssertEqual(ChunkedFinalPassPolicy(configString: "on_uncertainty"), .onUncertainty)
    XCTAssertEqual(ChunkedFinalPassPolicy(configString: "never"), .never)
    XCTAssertEqual(ChunkedFinalPassPolicy.default, .onUncertainty)
    XCTAssertNil(ChunkedFinalPassPolicy(configString: "sometimes"))
    XCTAssertEqual(ChunkedFinalPassPolicy.always.configValue, "always")
    XCTAssertEqual(ChunkedFinalPassPolicy.onUncertainty.configValue, "on-uncertainty")
    XCTAssertEqual(ChunkedFinalPassPolicy.never.configValue, "never")
  }

  @objc func testDefaultSkipsFinalWhenConfident() throws {
    // No overlap, non-empty texts, timestamps irrelevant: confident.
    let mock = MockSTT(texts: ["One two.", "Three four."])
    let (outcome, phases) = try run(
      samples: twoSegments(), mock: mock, policy: .onUncertainty)
    XCTAssertFalse(outcome.finalized)
    XCTAssertEqual(outcome.reason, .confidentSkip)
    XCTAssertEqual(outcome.policy, .onUncertainty)
    XCTAssertTrue(outcome.uncertainSegments.isEmpty)
    XCTAssertEqual(mock.calls, ["segment-1.wav", "segment-2.wav"])
    XCTAssertFalse(phases.contains("finalizing"))
    XCTAssertEqual(outcome.insertedText, "One two. Three four.")
  }

  @objc func testDefaultRunsFinalOnEmptySegment() throws {
    let mock = MockSTT(texts: ["One two.", "", "One two three four."])
    let (outcome, _) = try run(
      samples: twoSegments(), mock: mock, policy: .onUncertainty)
    XCTAssertTrue(outcome.finalized)
    XCTAssertEqual(outcome.reason, .uncertainEmptySegment)
    XCTAssertEqual(outcome.uncertainSegments, [1])
    XCTAssertEqual(mock.calls, ["segment-1.wav", "segment-2.wav", "final.wav"])
  }

  @objc func testDefaultRunsFinalOnMissingTimestampsWithOverlap() throws {
    let samples = makeSamples([(0.1, 4.0), (0.0, 1.5), (0.1, 4.0)])
    let mock = MockSTT(results: [
      ChunkedPipeline.SttResult(text: "One two."),
      ChunkedPipeline.SttResult(text: "Two three four."),
      ChunkedPipeline.SttResult(text: "One two three four."),
    ])
    let box = ResultBox<ChunkedPipeline.Outcome>()
    let expect = expectation(description: "overlap run")
    Task {
      do {
        // Production overlap: second segment has glued audio but no timestamps.
        let pipeline = ChunkedPipeline(finalPassPolicy: .onUncertainty)
        let outcome = try await pipeline.run(
          samples: samples,
          stt: { wav, filename, prompt in try await mock.call(wav, filename, prompt) },
          insert: { _ in })
        box.value = outcome
      } catch {
        box.error = error
      }
      expect.fulfill()
    }
    wait(for: [expect], timeout: 10.0)
    if let error = box.error { throw error }
    let outcome = box.value!
    XCTAssertTrue(outcome.finalized)
    XCTAssertEqual(outcome.reason, .uncertainMissingTimestamps)
    XCTAssertEqual(outcome.uncertainSegments, [1])
    XCTAssertEqual(mock.calls.count, 3)
  }

  @objc func testDefaultSkipsFinalWhenTimestampsVerifySeam() throws {
    let samples = makeSamples([(0.1, 4.0), (0.0, 1.5), (0.1, 4.0)])
    let mock = MockSTT(results: [
      ChunkedPipeline.SttResult(text: "One two."),
      ChunkedPipeline.SttResult(
        text: "Two three four.",
        words: [
          TimedWord(word: "Two", start: 0.2, end: 0.9),
          TimedWord(word: "three", start: 1.2, end: 1.6),
          TimedWord(word: "four", start: 1.7, end: 2.1),
        ]),
    ])
    let box = ResultBox<ChunkedPipeline.Outcome>()
    let expect = expectation(description: "confident overlap run")
    Task {
      do {
        let pipeline = ChunkedPipeline(finalPassPolicy: .onUncertainty)
        let outcome = try await pipeline.run(
          samples: samples,
          stt: { wav, filename, prompt in try await mock.call(wav, filename, prompt) },
          insert: { _ in })
        box.value = outcome
      } catch {
        box.error = error
      }
      expect.fulfill()
    }
    wait(for: [expect], timeout: 10.0)
    if let error = box.error { throw error }
    let outcome = box.value!
    XCTAssertFalse(outcome.finalized, "timestamps verify the seam, no replay needed")
    XCTAssertEqual(outcome.reason, .confidentSkip)
    XCTAssertEqual(mock.calls.count, 2)
    // No duplication at the boundary: seam word deduped by timestamps.
    XCTAssertEqual(outcome.insertedText, "One two. Three four.")
  }

  @objc func testAlwaysRunsFinalEvenWhenConfident() throws {
    let mock = MockSTT(texts: ["One two.", "Three four.", "One two. Three four."])
    let (outcome, _) = try run(samples: twoSegments(), mock: mock, policy: .always)
    XCTAssertTrue(outcome.finalized)
    XCTAssertEqual(outcome.reason, .policyAlways)
    XCTAssertEqual(mock.calls.count, 3)
  }

  @objc func testNeverSkipsFinalEvenWhenUncertain() throws {
    let mock = MockSTT(texts: ["One two.", ""])
    let (outcome, _) = try run(samples: twoSegments(), mock: mock, policy: .never)
    XCTAssertFalse(outcome.finalized)
    XCTAssertEqual(outcome.reason, .policyNever)
    XCTAssertEqual(outcome.uncertainSegments, [1])
    XCTAssertEqual(mock.calls.count, 2)
  }

  @objc func testSingleSegmentSkipsUnderAlways() throws {
    let mock = MockSTT(texts: ["Hello world."])
    let single = makeSamples([(0.1, 2.0)])
    let (outcome, _) = try run(samples: single, mock: mock, policy: .always)
    XCTAssertFalse(outcome.finalized)
    XCTAssertEqual(outcome.reason, .singleSegment)
    XCTAssertEqual(mock.calls.count, 1)
  }

  @objc func testConfigParsesChunkedFinalPass() throws {
    let config = try AppConfig.parse("chunked_final_pass = \"never\"\n")
    XCTAssertEqual(config.chunkedFinalPass, .never)
    let fallback = try AppConfig.parse("chunked = false\n")
    XCTAssertEqual(fallback.chunkedFinalPass, .default)
  }

  @objc func testConfigRejectsUnknownPolicy() throws {
    XCTAssertThrowsError(try AppConfig.parse("chunked_final_pass = \"sometimes\"\n")) { _ in }
  }

  @objc func testChunkedBenchmarkAlwaysVsDefault() throws {
    let fixture = BenchmarkFixtures.builtins().first { $0.durationBucket == .long }!
    let config = BenchmarkSTTConfig(name: "a", adapterID: "openai", model: "whisper-1")
    let segments = AudioSegmenter.segments(samples: fixture.samples, sampleRate: fixture.sampleRate)
    XCTAssertGreaterThanOrEqual(segments.count, 1)
    let words = BenchmarkText.words(fixture.transcript)
    let perSegment = max(1, words.count / max(1, segments.count))
    var segmentTexts: [String] = []
    for index in 0..<segments.count {
      let start = index * perSegment
      let end = index == segments.count - 1 ? words.count : min(words.count, start + perSegment)
      segmentTexts.append(start < end ? words[start..<end].joined(separator: " ") : "")
    }
    let rows = ChunkedBenchmark.compare(
      fixture: fixture, config: config,
      segmentTexts: segmentTexts,
      segmentHasTimestamps: Array(repeating: true, count: segments.count),
      finalText: fixture.transcript)
    XCTAssertEqual(rows.count, 3)
    let always = rows.first { $0.policy == "always" }!
    let def = rows.first { $0.policy == ChunkedFinalPassPolicy.default.configValue }!
    let never = rows.first { $0.policy == "never" }!
    XCTAssertTrue(always.finalRan)
    XCTAssertGreaterThan(always.totalUploadBytes, 0)
    // Default skips the final upload when confident: fewer bytes, same WER.
    XCTAssertFalse(def.finalRan)
    XCTAssertLessThan(def.totalUploadBytes, always.totalUploadBytes)
    XCTAssertEqual(def.wer, 0)
    XCTAssertEqual(always.wer, 0)
    XCTAssertFalse(never.finalRan)
    let md = ChunkedBenchmark.markdown(fixtureID: fixture.id, rows: rows)
    XCTAssertTrue(md.contains("always"))
    XCTAssertTrue(md.contains(fixture.id))
  }

  @objc func testChunkedBenchmarkUncertainFallsBack() throws {
    let fixture = BenchmarkFixtures.builtins()[1]
    let config = BenchmarkSTTConfig(name: "a", adapterID: "openai", model: "whisper-1")
    let segments = AudioSegmenter.segments(samples: fixture.samples, sampleRate: fixture.sampleRate)
    // Force uncertainty: empty second segment text when multi-segment,
    // else missing timestamps with overlap via direct decision check.
    if segments.count > 1 {
      var texts = Array(repeating: "hello", count: segments.count)
      texts[1] = ""
      let rows = ChunkedBenchmark.compare(
        fixture: fixture, config: config, segmentTexts: texts,
        segmentHasTimestamps: Array(repeating: true, count: segments.count),
        finalText: fixture.transcript)
      let def = rows.first { $0.policy == ChunkedFinalPassPolicy.default.configValue }!
      XCTAssertTrue(def.finalRan, "empty segment forces fallback")
      XCTAssertEqual(def.reason, ChunkedFinalReason.uncertainEmptySegment.rawValue)
    } else {
      let decision = ChunkedFinalDecision.shouldRunFinalPass(
        segmentCount: 2,
        reports: [
          ChunkedSegmentReport(index: 0, isEmpty: false, hasTimestamps: false, overlapSeconds: 0),
          ChunkedSegmentReport(index: 1, isEmpty: false, hasTimestamps: false, overlapSeconds: 1.0),
        ],
        policy: .onUncertainty)
      XCTAssertTrue(decision.run)
      XCTAssertEqual(decision.reason, .uncertainMissingTimestamps)
    }
  }

  @objc func testChunkedBenchmarkStitchedUsesProductionDedupe() throws {
    // Seam duplicate inside the glued overlap must be excluded from scoring,
    // mirroring ChunkedPipeline.recognizeWAV (dedupeOverlap + finalize).
    let samples = twoSegments()
    let fixture = BenchmarkFixture(
      id: "dedupe-check", category: .normal, durationBucket: .short,
      description: "Seam duplicate check.",
      transcript: "hello world again",
      samples: samples)
    let config = BenchmarkSTTConfig(name: "a", adapterID: "openai", model: "whisper-1")
    let segments = AudioSegmenter.segments(
      samples: samples, sampleRate: 16000, config: .defaults)
    XCTAssertGreaterThanOrEqual(segments.count, 2, "needs a glued overlap to test dedupe")
    let overlap = segments.count > 1 ? segments[1].overlapSeconds : 0
    XCTAssertGreaterThan(overlap, 0, "second segment must carry glued overlap")
    let texts = ["hello world", "world again"]
    let words: [[TimedWord]] = [
      [
        TimedWord(word: "hello", start: 0.1, end: 0.4),
        TimedWord(word: "world", start: 0.5, end: 0.9),
      ],
      [
        // Seam repeat ends inside the glued overlap: production drops it.
        TimedWord(word: "world", start: 0.1, end: min(0.5, max(0.1, overlap - 0.1))),
        TimedWord(word: "again", start: overlap + 0.1, end: overlap + 0.5),
      ],
    ]
    let rows = ChunkedBenchmark.compare(
      fixture: fixture, config: config,
      segmentTexts: texts,
      segmentHasTimestamps: [true, true],
      segmentWords: words,
      finalText: "hello world again")
    let def = rows.first { $0.policy == ChunkedFinalPassPolicy.default.configValue }!
    XCTAssertFalse(def.finalRan, "timestamps verify the seam, no replay needed")
    XCTAssertEqual(
      BenchmarkText.words(def.hypothesis), ["hello", "world", "again"],
      "stitched hypothesis must exclude the seam duplicate")
    XCTAssertEqual(def.wer, 0)
  }

  @objc func testChunkedBenchmarkLiveComparisonWithActualResults() throws {
    // Live quality evidence shape: actual (imperfect) segment/final STT
    // results on transcript-bearing speech, not transcript-derived slices.
    let samples = twoSegments()
    let fixture = BenchmarkFixture(
      id: "live-check", category: .normal, durationBucket: .short,
      description: "Actual STT results comparison.",
      transcript: "hello world again",
      samples: samples)
    let config = BenchmarkSTTConfig(name: "a", adapterID: "openai", model: "whisper-1")
    let segments = AudioSegmenter.segments(
      samples: samples, sampleRate: 16000, config: .defaults)
    XCTAssertGreaterThanOrEqual(segments.count, 2)
    let overlap = segments.count > 1 ? segments[1].overlapSeconds : 0
    XCTAssertGreaterThan(overlap, 0)
    // Simulated provider output: second segment repeats the seam word with
    // timestamps inside the glued overlap; final pass heard the full audio.
    let segmentTexts = ["hello world", "world again"]
    let segmentWords: [[TimedWord]] = [
      [
        TimedWord(word: "hello", start: 0.1, end: 0.4),
        TimedWord(word: "world", start: 0.5, end: 0.9),
      ],
      [
        TimedWord(word: "world", start: 0.1, end: max(0.1, overlap - 0.1)),
        TimedWord(word: "again", start: overlap + 0.1, end: overlap + 0.5),
      ],
    ]
    let rows = ChunkedBenchmark.compare(
      fixture: fixture, config: config,
      segmentTexts: segmentTexts,
      segmentHasTimestamps: [true, true],
      segmentWords: segmentWords,
      finalText: "hello world again")
    let always = rows.first { $0.policy == "always" }!
    let def = rows.first { $0.policy == ChunkedFinalPassPolicy.default.configValue }!
    XCTAssertTrue(always.finalRan)
    XCTAssertFalse(def.finalRan)
    // Both policies score real WER/CER against the transcript.
    XCTAssertEqual(always.wer, 0)
    XCTAssertEqual(def.wer, 0)
    XCTAssertTrue(ChunkedBenchmark.defaultMatchesAlways(rows: rows))
    XCTAssertTrue(
      ChunkedBenchmark.boundaryDiagnostics(stitched: def.hypothesis, final: always.hypothesis)
        .hasPrefix("match:"))
  }

  @objc func testChunkedBenchmarkBoundaryDiagnosticsFlagsSeams() throws {
    XCTAssertTrue(
      ChunkedBenchmark.boundaryDiagnostics(stitched: "hello world", final: "hello world")
        .hasPrefix("match:"))
    let dup = ChunkedBenchmark.boundaryDiagnostics(
      stitched: "hello world world again", final: "hello world again")
    XCTAssertTrue(dup.hasPrefix("diff:"))
    XCTAssertTrue(dup.contains("duplication"))
    let omit = ChunkedBenchmark.boundaryDiagnostics(stitched: "hello again", final: "hello world again")
    XCTAssertTrue(omit.hasPrefix("diff:"))
    XCTAssertTrue(omit.contains("omission"))
    // Default vs always mismatch is a boundary regression signal.
    let rows = [
      ChunkedPolicyComparison(
        policy: "always", requests: 3, segmentUploadBytes: 10, finalUploadBytes: 5,
        totalUploadBytes: 15, finalLatencyMs: 800, wer: 0, cer: 0,
        hypothesis: "hello world again", finalRan: true, reason: "policyAlways"),
      ChunkedPolicyComparison(
        policy: "on-uncertainty", requests: 2, segmentUploadBytes: 10, finalUploadBytes: 0,
        totalUploadBytes: 10, finalLatencyMs: 0, wer: 0.33, cer: 0.1,
        hypothesis: "hello again", finalRan: false, reason: "confidentSkip"),
      ChunkedPolicyComparison(
        policy: "never", requests: 2, segmentUploadBytes: 10, finalUploadBytes: 0,
        totalUploadBytes: 10, finalLatencyMs: 0, wer: 0.33, cer: 0.1,
        hypothesis: "hello again", finalRan: false, reason: "policyNever"),
    ]
    XCTAssertFalse(ChunkedBenchmark.defaultMatchesAlways(rows: rows))
  }
}
