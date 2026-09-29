import Foundation
@testable import NanoDictateCore

// MARK: - STTBenchmarkTests (deterministic, no network)

final class STTBenchmarkTests: XCTestCase {
  @objc func testNormalizeStripsPunctuationAndCase() {
    XCTAssertEqual(BenchmarkText.normalize("Hello,  WORLD!"), "hello world")
    XCTAssertEqual(BenchmarkText.normalize("  deploy   whisper\tlarge\n"), "deploy whisper large")
    XCTAssertEqual(BenchmarkText.normalize("Привет, МИР!"), "привет мир")
  }

  @objc func testWerIdenticalIsZero() {
    XCTAssertEqual(BenchmarkText.wer(reference: "hello world", hypothesis: "hello world"), 0)
    XCTAssertEqual(
      BenchmarkText.wer(reference: "Hello, world!", hypothesis: "hello world"), 0,
      "normalization makes punctuation/case free")
  }

  @objc func testWerSubstitutionDeletionInsertion() {
    // 1 substitution / 3 words.
    XCTAssertEqual(
      BenchmarkText.wer(reference: "a b c", hypothesis: "a x c"), 1.0 / 3.0, accuracy: 1e-9)
    // 1 deletion / 3 words.
    XCTAssertEqual(
      BenchmarkText.wer(reference: "a b c", hypothesis: "a c"), 1.0 / 3.0, accuracy: 1e-9)
    // 1 insertion / 2 words.
    XCTAssertEqual(
      BenchmarkText.wer(reference: "a b", hypothesis: "a b c"), 1.0 / 2.0, accuracy: 1e-9)
  }

  @objc func testWerEmptyReference() {
    XCTAssertEqual(BenchmarkText.wer(reference: "", hypothesis: ""), 0)
    XCTAssertEqual(BenchmarkText.wer(reference: "   ", hypothesis: "hello"), 1)
  }

  @objc func testCerKnownValues() {
    XCTAssertEqual(BenchmarkText.cer(reference: "abc", hypothesis: "abc"), 0)
    XCTAssertEqual(
      BenchmarkText.cer(reference: "abc", hypothesis: "adc"), 1.0 / 3.0, accuracy: 1e-9)
    XCTAssertEqual(BenchmarkText.cer(reference: "", hypothesis: ""), 0)
    XCTAssertEqual(BenchmarkText.cer(reference: "", hypothesis: "x"), 1)
  }

  @objc func testLevenshtein() {
    XCTAssertEqual(BenchmarkText.levenshtein(["a", "b"], ["a", "b"]), 0)
    XCTAssertEqual(BenchmarkText.levenshtein(["a"], []), 1)
    XCTAssertEqual(BenchmarkText.levenshtein([], ["a", "b"]), 2)
    XCTAssertEqual(BenchmarkText.levenshtein(["a", "b", "c"], ["a", "c"]), 1)
  }

  @objc func testBuiltinFixturesCoverRequiredScenarios() {
    let fixtures = BenchmarkFixtures.builtins()
    let categories = Set(fixtures.map(\.category))
    XCTAssertTrue(categories.contains(.quiet))
    XCTAssertTrue(categories.contains(.normal))
    XCTAssertTrue(categories.contains(.noisy))
    XCTAssertTrue(categories.contains(.technical))
    XCTAssertTrue(fixtures.contains { $0.durationBucket == .short })
    XCTAssertTrue(fixtures.contains { $0.durationBucket == .long })
    let long = fixtures.first { $0.durationBucket == .long }
    XCTAssertNotNil(long)
    XCTAssertGreaterThanOrEqual(long?.durationSeconds ?? 0, 50)
    XCTAssertLessThanOrEqual(long?.durationSeconds ?? 0, 65)
    for fixture in fixtures {
      XCTAssertFalse(fixture.transcript.isEmpty)
      XCTAssertFalse(fixture.samples.isEmpty)
    }
  }

  @objc func testSynthIsDeterministic() {
    let first = BenchmarkSynth.samples(seed: 7, durationSeconds: 1, kind: .normal)
    let second = BenchmarkSynth.samples(seed: 7, durationSeconds: 1, kind: .normal)
    XCTAssertEqual(first, second)
    let other = BenchmarkSynth.samples(seed: 8, durationSeconds: 1, kind: .normal)
    XCTAssertFalse(first == other)
  }

  @objc func testUploadBytesIncludesMultipartOverhead() throws {
    let fixture = BenchmarkFixtures.builtins()[0]
    let wav = WAVEncoder.encode(samples: fixture.samples, sampleRate: fixture.sampleRate)
    let config = BenchmarkSTTConfig(name: "openai", adapterID: "openai", model: "whisper-1")
    let upload = BenchmarkRunner.uploadBytes(config: config, wav: wav)
    XCTAssertGreaterThanOrEqual(upload, wav.count)
    XCTAssertGreaterThan(upload, 0)
  }

  @objc func testRunnerComparesTwoConfigsAndReportsTimings() throws {
    let fixtures = Array(BenchmarkFixtures.builtins().prefix(2))
    let configs = [
      BenchmarkSTTConfig(name: "cfg-a", adapterID: "openai", model: "whisper-1"),
      BenchmarkSTTConfig(name: "cfg-b", adapterID: "groq", model: "whisper-large-v3"),
    ]
    var hypotheses: [String: [String: String]] = [:]
    for config in configs {
      var perFixture: [String: String] = [:]
      for fixture in fixtures {
        perFixture[fixture.id] =
          config.name == "cfg-a" ? fixture.transcript : fixture.transcript + " extra wrong words"
      }
      hypotheses[config.name] = perFixture
    }
    let report = try BenchmarkRunner.run(
      fixtures: fixtures, configs: configs,
      provider: BenchmarkRunner.scriptedProvider(hypotheses: hypotheses))
    XCTAssertEqual(report.results.count, 4)
    XCTAssertEqual(report.summaries.count, 2)
    for result in report.results {
      XCTAssertGreaterThanOrEqual(result.uploadBytes, result.wavBytes)
      XCTAssertGreaterThanOrEqual(result.encodeMs, 0)
      XCTAssertGreaterThanOrEqual(result.requestMs, 0)
      XCTAssertGreaterThanOrEqual(result.endToEndMs, 0)
      XCTAssertGreaterThanOrEqual(result.wer, 0)
      XCTAssertGreaterThanOrEqual(result.cer, 0)
    }
    let good = report.summaries.first { $0.configName == "cfg-a" }
    let bad = report.summaries.first { $0.configName == "cfg-b" }
    XCTAssertNotNil(good)
    XCTAssertNotNil(bad)
    XCTAssertEqual(good?.meanWER ?? -1, 0)
    XCTAssertGreaterThan(bad?.meanWER ?? 0, 0)
    // Machine-readable JSON round-trips.
    let data = try report.jsonData()
    XCTAssertFalse(data.isEmpty)
    let decoded = try JSONDecoder().decode(BenchmarkReport.self, from: data)
    XCTAssertEqual(decoded, report)
    // Human-readable markdown mentions both configs.
    let markdown = report.markdown()
    XCTAssertTrue(markdown.contains("cfg-a"))
    XCTAssertTrue(markdown.contains("cfg-b"))
    XCTAssertTrue(markdown.contains("WER"))
  }

  @objc func testReportJsonIsMachineReadable() throws {
    let fixtures = Array(BenchmarkFixtures.builtins().prefix(1))
    let configs = [BenchmarkSTTConfig(name: "solo", adapterID: "openai", model: "whisper-1")]
    let report = try BenchmarkRunner.run(
      fixtures: fixtures, configs: configs,
      provider: BenchmarkRunner.scriptedProvider(hypotheses: [:]))
    let data = try report.jsonData()
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    XCTAssertNotNil(json?["results"])
    XCTAssertNotNil(json?["summaries"])
  }
}
