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

  // MARK: - Live audio overlay (BenchmarkLiveAudio)

  @objc func testLiveAudioFileNameAppendsWavExtension() {
    XCTAssertEqual(BenchmarkLiveAudio.fileName(for: "quiet-short"), "quiet-short.wav")
  }

  @objc func testLiveAudioNilDirectoryKeepsSyntheticFixtures() {
    let fallback = Array(BenchmarkFixtures.builtins().prefix(2))
    let resolved = BenchmarkLiveAudio.resolvedLiveFixtures(fromDirectory: nil, fallback: fallback)
    XCTAssertEqual(resolved.count, fallback.count)
    for (index, resolution) in resolved.enumerated() {
      XCTAssertFalse(resolution.isSpeech, "nil directory keeps synthetic non-speech")
      XCTAssertNil(resolution.sourceURL)
      XCTAssertEqual(resolution.fixture, fallback[index])
    }
  }

  @objc func testLiveAudioEmptyAndNilPathKeepSynthetic() {
    let fallback = Array(BenchmarkFixtures.builtins().prefix(1))
    for path in [nil, "", ] as [String?] {
      let resolved = BenchmarkLiveAudio.resolvedLiveFixtures(fromDirectoryPath: path, fallback: fallback)
      XCTAssertEqual(resolved.count, 1)
      XCTAssertFalse(resolved[0].isSpeech)
      XCTAssertNil(resolved[0].sourceURL)
      XCTAssertEqual(resolved[0].fixture, fallback[0])
    }
    let live = BenchmarkLiveAudio.liveFixtures(fromDirectoryPath: nil, fallback: fallback)
    XCTAssertEqual(live, fallback)
  }

  private func makeLiveFixtureDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("live-audio-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  @objc func testLiveAudioMissingFileIsNonSpeechWithSourceURL() throws {
    let dir = try makeLiveFixtureDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fallback = Array(BenchmarkFixtures.builtins().prefix(1))
    let resolved = BenchmarkLiveAudio.resolvedLiveFixtures(fromDirectory: dir, fallback: fallback)
    XCTAssertEqual(resolved.count, 1)
    XCTAssertFalse(resolved[0].isSpeech)
    XCTAssertEqual(resolved[0].sourceURL, dir.appendingPathComponent(BenchmarkLiveAudio.fileName(for: fallback[0].id)))
    XCTAssertEqual(resolved[0].fixture, fallback[0])
    // Path-based overload resolves through the same directory logic.
    let viaPath = BenchmarkLiveAudio.resolvedLiveFixtures(fromDirectoryPath: dir.path, fallback: fallback)
    XCTAssertEqual(viaPath, resolved)
  }

  @objc func testLiveAudioInvalidWavIsNonSpeech() throws {
    let dir = try makeLiveFixtureDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fallback = Array(BenchmarkFixtures.builtins().prefix(1))
    let url = dir.appendingPathComponent(BenchmarkLiveAudio.fileName(for: fallback[0].id))
    try Data("not a wav file".utf8).write(to: url)
    let resolved = BenchmarkLiveAudio.resolvedLiveFixtures(fromDirectory: dir, fallback: fallback)
    XCTAssertFalse(resolved[0].isSpeech, "undecodable WAV keeps synthetic samples")
    XCTAssertEqual(resolved[0].sourceURL, url)
    XCTAssertEqual(resolved[0].fixture.samples, fallback[0].samples)
  }

  @objc func testLiveAudioValidMonoWavResolvesToSpeech() throws {
    let dir = try makeLiveFixtureDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    var fallback = Array(BenchmarkFixtures.builtins().prefix(1))
    fallback[0].samples = [1, 2, 3]
    let speech: [Int16] = [0, 1000, -1000, 32767, -32768]
    let url = dir.appendingPathComponent(BenchmarkLiveAudio.fileName(for: fallback[0].id))
    try WAVEncoder.encode(samples: speech, sampleRate: 16000, channels: 1).write(to: url)
    let resolved = BenchmarkLiveAudio.resolvedLiveFixtures(fromDirectory: dir, fallback: fallback)
    XCTAssertTrue(resolved[0].isSpeech)
    XCTAssertEqual(resolved[0].sourceURL, url)
    XCTAssertEqual(resolved[0].fixture.sampleRate, 16000)
    XCTAssertEqual(resolved[0].fixture.samples, speech, "mono WAV passes through unchanged")
    XCTAssertEqual(resolved[0].fixture.transcript, fallback[0].transcript, "transcript stays ground truth")
    // liveFixtures wrapper maps resolved fixtures.
    XCTAssertEqual(BenchmarkLiveAudio.liveFixtures(fromDirectory: dir, fallback: fallback), [resolved[0].fixture])
    XCTAssertEqual(
      BenchmarkLiveAudio.liveFixtures(fromDirectoryPath: dir.path, fallback: fallback),
      [resolved[0].fixture])
  }

  @objc func testLiveAudioStereoWavMixedDownToMono() throws {
    let dir = try makeLiveFixtureDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let fallback = Array(BenchmarkFixtures.builtins().prefix(1))
    // Interleaved stereo frames: (1000, 3000) and (2000, 4000).
    let stereo: [Int16] = [1000, 3000, 2000, 4000]
    let url = dir.appendingPathComponent(BenchmarkLiveAudio.fileName(for: fallback[0].id))
    try WAVEncoder.encode(samples: stereo, sampleRate: 16000, channels: 2).write(to: url)
    let resolved = BenchmarkLiveAudio.resolvedLiveFixtures(fromDirectory: dir, fallback: fallback)
    XCTAssertTrue(resolved[0].isSpeech)
    XCTAssertEqual(resolved[0].fixture.samples, [2000, 3000], "stereo averages per frame")
  }

  @objc func testToMonoEdgeCases() {
    XCTAssertEqual(BenchmarkLiveAudio.toMono(samples: [1, 2, 3], channels: 1), [1, 2, 3])
    XCTAssertEqual(BenchmarkLiveAudio.toMono(samples: [], channels: 2), [])
    XCTAssertEqual(BenchmarkLiveAudio.toMono(samples: [10, 20], channels: 2), [15])
    XCTAssertEqual(BenchmarkLiveAudio.toMono(samples: [1000, 3000, 2000, 4000], channels: 2), [2000, 3000])
  }

  @objc func testLiveFixtureResolutionInitAndPeakRSS() {
    let fixture = BenchmarkFixtures.builtins()[0]
    let implicit = LiveFixtureResolution(fixture: fixture, isSpeech: false)
    XCTAssertNil(implicit.sourceURL)
    XCTAssertEqual(implicit, LiveFixtureResolution(fixture: fixture, isSpeech: false, sourceURL: nil))
    XCTAssertGreaterThanOrEqual(BenchmarkResources.peakRSSKilobytes(), 0)
  }
}
