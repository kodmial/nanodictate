#if canImport(Darwin)
  import Darwin
#endif
import Foundation

// MARK: - STT benchmark harness (local, deterministic + opt-in live)
//
// Reproducible quality/latency/bandwidth comparison for NanoDictate STT
// configurations. Deterministic pieces run without network or secrets:
// synthetic in-memory fixtures, WER/CER scoring, upload-byte accounting via
// ProviderRequestBuilder, and wall-clock timing of encode + request + end
// to end. Live provider runs are opt-in (explicit provider object) and never
// part of CI pass/fail.

/// Acoustic scenario covered by a benchmark fixture.
public enum BenchmarkCategory: String, Codable, Equatable, CaseIterable {
  case quiet
  case normal
  case noisy
  case technical
}

/// Duration bucket of a fixture utterance.
public enum BenchmarkDurationBucket: String, Codable, Equatable {
  case short
  case long
}

/// One benchmark fixture: synthetic audio plus ground-truth transcript.
///
/// Audio is generated deterministically in memory (no recordings or secrets
/// in the repository). `samples` are 16 kHz mono PCM; `transcript` is the
/// ground truth used for WER/CER scoring.
public struct BenchmarkFixture: Equatable {
  public var id: String
  public var category: BenchmarkCategory
  public var durationBucket: BenchmarkDurationBucket
  public var description: String
  public var transcript: String
  public var sampleRate: Int
  public var samples: [Int16]

  public init(
    id: String,
    category: BenchmarkCategory,
    durationBucket: BenchmarkDurationBucket,
    description: String,
    transcript: String,
    sampleRate: Int = 16_000,
    samples: [Int16]
  ) {
    self.id = id
    self.category = category
    self.durationBucket = durationBucket
    self.description = description
    self.transcript = transcript
    self.sampleRate = sampleRate
    self.samples = samples
  }

  public var durationSeconds: Double {
    guard sampleRate > 0 else { return 0 }
    return Double(samples.count) / Double(sampleRate)
  }
}

/// One STT configuration under comparison.
public struct BenchmarkSTTConfig: Equatable {
  public var name: String
  public var adapterID: String
  public var model: String
  public var language: String
  /// Contextual bias under comparison (technical vocabulary / code-switch
  /// hints). Empty = no biasing; byte accounting includes the bias fields.
  public var bias: STTContextualBias

  public init(
    name: String,
    adapterID: String,
    model: String,
    language: String = "",
    bias: STTContextualBias = .none
  ) {
    self.name = name
    self.adapterID = adapterID
    self.model = model
    self.language = language
    self.bias = bias
  }
}

/// Hypothesis returned by a benchmarked provider for one fixture.
public struct BenchmarkHypothesis: Equatable {
  public var text: String
  /// Time spent inside the provider call (network/request), seconds.
  public var requestSeconds: Double

  public init(text: String, requestSeconds: Double = 0) {
    self.text = text
    self.requestSeconds = requestSeconds
  }
}

/// Provider run hook. Local deterministic runs use a scripted provider;
/// live runs wrap a real Transcriber. Kept as a closure type so tests do
/// not need network or async fixtures on disk.
public typealias BenchmarkProviderRun = (
  BenchmarkFixture, BenchmarkSTTConfig
) throws -> BenchmarkHypothesis

/// Per-fixture, per-config benchmark result (Codable for machine output).
public struct BenchmarkCaseResult: Codable, Equatable {
  public var fixtureID: String
  public var category: String
  public var durationBucket: String
  public var configName: String
  public var adapterID: String
  public var model: String
  public var wer: Double
  public var cer: Double
  public var referenceWords: Int
  public var hypothesisWords: Int
  public var wavBytes: Int
  public var uploadBytes: Int
  public var encodeMs: Double
  public var requestMs: Double
  public var endToEndMs: Double
  public var peakRSSKB: Int
  public var hypothesis: String

  public init(
    fixtureID: String,
    category: String,
    durationBucket: String,
    configName: String,
    adapterID: String,
    model: String,
    wer: Double,
    cer: Double,
    referenceWords: Int,
    hypothesisWords: Int,
    wavBytes: Int,
    uploadBytes: Int,
    encodeMs: Double,
    requestMs: Double,
    endToEndMs: Double,
    peakRSSKB: Int,
    hypothesis: String
  ) {
    self.fixtureID = fixtureID
    self.category = category
    self.durationBucket = durationBucket
    self.configName = configName
    self.adapterID = adapterID
    self.model = model
    self.wer = wer
    self.cer = cer
    self.referenceWords = referenceWords
    self.hypothesisWords = hypothesisWords
    self.wavBytes = wavBytes
    self.uploadBytes = uploadBytes
    self.encodeMs = encodeMs
    self.requestMs = requestMs
    self.endToEndMs = endToEndMs
    self.peakRSSKB = peakRSSKB
    self.hypothesis = hypothesis
  }
}

/// Aggregated per-config summary.
public struct BenchmarkConfigSummary: Codable, Equatable {
  public var configName: String
  public var cases: Int
  public var meanWER: Double
  public var meanCER: Double
  public var totalUploadBytes: Int
  public var meanEndToEndMs: Double
  public var meanRequestMs: Double
  public var meanEncodeMs: Double

  public init(
    configName: String,
    cases: Int,
    meanWER: Double,
    meanCER: Double,
    totalUploadBytes: Int,
    meanEndToEndMs: Double,
    meanRequestMs: Double,
    meanEncodeMs: Double
  ) {
    self.configName = configName
    self.cases = cases
    self.meanWER = meanWER
    self.meanCER = meanCER
    self.totalUploadBytes = totalUploadBytes
    self.meanEndToEndMs = meanEndToEndMs
    self.meanRequestMs = meanRequestMs
    self.meanEncodeMs = meanEncodeMs
  }
}

/// Full benchmark report: machine-readable (JSON) plus human summary.
public struct BenchmarkReport: Codable, Equatable {
  public var results: [BenchmarkCaseResult]
  public var summaries: [BenchmarkConfigSummary]

  public init(results: [BenchmarkCaseResult], summaries: [BenchmarkConfigSummary]) {
    self.results = results
    self.summaries = summaries
  }

  public func jsonData(pretty: Bool = true) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys] : [.sortedKeys]
    return try encoder.encode(self)
  }

  /// Human-readable markdown table (one row per case + per-config summary).
  public func markdown() -> String {
    var lines: [String] = []
    lines.append("# STT benchmark")
    lines.append("")
    lines.append("| fixture | config | WER | CER | upload | encode | request | e2e |")
    lines.append("| --- | --- | --- | --- | --- | --- | --- | --- |")
    for result in results {
      lines.append(
        "| \(result.fixtureID) | \(result.configName) | \(BenchmarkFormat.ratio(result.wer))"
          + " | \(BenchmarkFormat.ratio(result.cer)) | \(result.uploadBytes)B"
          + " | \(BenchmarkFormat.ms(result.encodeMs)) | \(BenchmarkFormat.ms(result.requestMs))"
          + " | \(BenchmarkFormat.ms(result.endToEndMs)) |"
      )
    }
    lines.append("")
    lines.append("## Summary")
    lines.append("")
    for summary in summaries {
      lines.append(
        "- \(summary.configName): mean WER \(BenchmarkFormat.ratio(summary.meanWER)),"
          + " mean CER \(BenchmarkFormat.ratio(summary.meanCER)),"
          + " total upload \(summary.totalUploadBytes)B,"
          + " mean e2e \(BenchmarkFormat.ms(summary.meanEndToEndMs))"
      )
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

public enum BenchmarkFormat {
  public static func ratio(_ value: Double) -> String {
    String(format: "%.3f", value)
  }

  public static func ms(_ value: Double) -> String {
    String(format: "%.1fms", value)
  }
}

// MARK: - Text scoring (WER/CER)

/// Word/character error rate scoring with deterministic normalization.
public enum BenchmarkText {
  /// Lowercase, strip punctuation (keep letters/digits/whitespace), collapse
  /// whitespace. Unicode-aware so English and Russian score the same way.
  public static func normalize(_ text: String) -> String {
    let lowered = text.lowercased()
    let mapped = lowered.map { char -> Character in
      if char.isLetter || char.isNumber || char.isWhitespace {
        return char
      }
      return " "
    }
    let collapsed = String(mapped).split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return collapsed
  }

  public static func words(_ text: String) -> [String] {
    let normalized = normalize(text)
    guard !normalized.isEmpty else { return [] }
    return normalized.split(separator: " ").map(String.init)
  }

  public static func characters(_ text: String) -> [String] {
    normalize(text).map { String($0) }
  }

  /// Word error rate: Levenshtein(words) / max(1, reference words).
  /// Empty reference + empty hypothesis = 0; empty reference + non-empty = 1.
  public static func wer(reference: String, hypothesis: String) -> Double {
    let ref = words(reference)
    let hyp = words(hypothesis)
    guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
    return Double(levenshtein(ref, hyp)) / Double(ref.count)
  }

  /// Character error rate over normalized text including spaces.
  public static func cer(reference: String, hypothesis: String) -> Double {
    let ref = characters(reference)
    let hyp = characters(hypothesis)
    guard !ref.isEmpty else { return hyp.isEmpty ? 0 : 1 }
    return Double(levenshtein(ref, hyp)) / Double(ref.count)
  }

  /// Classic dynamic-programming Levenshtein distance over equatable tokens.
  public static func levenshtein<T: Equatable>(_ lhs: [T], _ rhs: [T]) -> Int {
    if lhs.isEmpty { return rhs.count }
    if rhs.isEmpty { return lhs.count }
    var previous = Array(0...rhs.count)
    var current = [Int](repeating: 0, count: rhs.count + 1)
    for row in 1...lhs.count {
      current[0] = row
      for col in 1...rhs.count {
        let cost = lhs[row - 1] == rhs[col - 1] ? 0 : 1
        let deletion = previous[col] + 1
        let insertion = current[col - 1] + 1
        let substitution = previous[col - 1] + cost
        current[col] = min(deletion, min(insertion, substitution))
      }
      previous = current
    }
    return previous[rhs.count]
  }
}

// MARK: - Synthetic fixtures (no recordings in repo)

/// Deterministic synthetic PCM generator: seeded pseudo-speech so fixtures
/// are reproducible without committing audio. Not real speech: amplitude and
/// spectral content vary per category (quiet = low gain, noisy = added
/// deterministic noise, technical = wider pitch variation).
public enum BenchmarkSynth {
  public static func samples(
    seed: UInt64,
    durationSeconds: Double,
    sampleRate: Int = 16_000,
    kind: BenchmarkCategory = .normal
  ) -> [Int16] {
    let count = max(1, Int((durationSeconds * Double(sampleRate)).rounded()))
    var state = seed == 0 ? 0x9E37_79B9_7F4A_7C15 : seed
    func next() -> UInt64 {
      state ^= state << 13
      state ^= state >> 7
      state ^= state << 17
      return state
    }
    let gain: Double
    let noise: Double
    switch kind {
    case .quiet:
      gain = 0.08
      noise = 0.004
    case .normal:
      gain = 0.3
      noise = 0.008
    case .noisy:
      gain = 0.3
      noise = 0.12
    case .technical:
      gain = 0.28
      noise = 0.02
    }
    var samples: [Int16] = []
    samples.reserveCapacity(count)
    for i in 0..<count {
      let time = Double(i) / Double(sampleRate)
      let wobble = Double(next() % 1_000) / 1_000.0
      let drift = 140.0 + 90.0 * sin(2.0 * .pi * 1.7 * time)
      let extra = kind == .technical ? 60.0 * wobble : 0
      let freq = drift + extra
      let tone = sin(2.0 * .pi * freq * time) * gain
      let hiss = (Double(next() % 2_000) / 1_000.0 - 1.0) * noise
      let envelope = 0.6 + 0.4 * sin(2.0 * .pi * 2.3 * time + wobble)
      let value = max(-1.0, min(1.0, (tone + hiss) * envelope))
      samples.append(Int16((value * 32_000.0).rounded()))
    }
    return samples
  }
}

/// Built-in fixture corpus covering the required scenarios. Ground-truth
/// transcripts are short redistributable sentences written for this repo
/// (no third-party text, no user recordings).
public enum BenchmarkFixtures {
  public static func builtins() -> [BenchmarkFixture] {
    [
      BenchmarkFixture(
        id: "quiet-short",
        category: .quiet,
        durationBucket: .short,
        description: "Quiet speech: low-gain synthetic utterance, 3 seconds.",
        transcript: "please turn the volume up a little",
        samples: BenchmarkSynth.samples(seed: 11, durationSeconds: 3, kind: .quiet)
      ),
      BenchmarkFixture(
        id: "normal-short",
        category: .normal,
        durationBucket: .short,
        description: "Normal speech: clean synthetic utterance, 4 seconds.",
        transcript: "type the meeting notes into the open document",
        samples: BenchmarkSynth.samples(seed: 22, durationSeconds: 4, kind: .normal)
      ),
      BenchmarkFixture(
        id: "noisy-short",
        category: .noisy,
        durationBucket: .short,
        description: "Speech over steady background noise, 4 seconds.",
        transcript: "send the invoice before friday afternoon",
        samples: BenchmarkSynth.samples(seed: 33, durationSeconds: 4, kind: .noisy)
      ),
      BenchmarkFixture(
        id: "technical-short",
        category: .technical,
        durationBucket: .short,
        description: "Technical and code-switching vocabulary, 5 seconds.",
        transcript: "deploy the whisper large v3 turbo endpoint with verbose json",
        samples: BenchmarkSynth.samples(seed: 44, durationSeconds: 5, kind: .technical)
      ),
      BenchmarkFixture(
        id: "technical-codeswitch-short",
        category: .technical,
        durationBucket: .short,
        description: "Mixed Russian/English technical dictation, 6 seconds.",
        transcript: "создай пул реквест для whisper large v3 turbo эндпоинта с verbose json",
        samples: BenchmarkSynth.samples(seed: 45, durationSeconds: 6, kind: .technical)
      ),
      BenchmarkFixture(
        id: "technical-codeswitch-long",
        category: .technical,
        durationBucket: .long,
        description: "Mixed Russian/English API dictation with identifiers, 55 seconds.",
        transcript: String(
          repeating: "открой терминал запусти nanodictate transcribe с моделью gpt transcribe ",
          count: 20
        ).trimmingCharacters(in: .whitespaces),
        samples: BenchmarkSynth.samples(seed: 46, durationSeconds: 55, kind: .technical)
      ),
      BenchmarkFixture(
        id: "normal-long",
        category: .normal,
        durationBucket: .long,
        description: "Near-60-second normal utterance for long-form timing.",
        transcript: String(
          repeating: "the quick brown fox jumps over the lazy dog near the river bank ",
          count: 20
        ).trimmingCharacters(in: .whitespaces),
        samples: BenchmarkSynth.samples(seed: 55, durationSeconds: 55, kind: .normal)
      ),
    ]
  }
}

// MARK: - Live audio overlay (transcript-bearing WAVs, opt-in)

/// `BenchmarkSynth` tones are not intelligible speech, so scoring live
/// provider output against fixture transcripts only measures STT quality
/// when the audio actually speaks the transcript. This helper overlays
/// user-supplied WAV files (`<fixture-id>.wav` in a directory) onto the
/// synthetic fixtures, keeping transcripts as ground truth. Fixtures with
/// no readable file keep their synthetic samples; live callers must not
/// score those fixtures (skip them or abort) because their WER/CER would
/// measure non-speech responses, not recognition quality.
public struct LiveFixtureResolution: Equatable {
  public var fixture: BenchmarkFixture
  /// True when `fixture` carries user-supplied transcript-bearing speech.
  public var isSpeech: Bool
  public var sourceURL: URL?

  public init(fixture: BenchmarkFixture, isSpeech: Bool, sourceURL: URL? = nil) {
    self.fixture = fixture
    self.isSpeech = isSpeech
    self.sourceURL = sourceURL
  }
}

public enum BenchmarkLiveAudio {
  public static func fileName(for fixtureID: String) -> String {
    "\(fixtureID).wav"
  }

  /// Resolve each fallback fixture to speech audio when a readable WAV
  /// exists, otherwise keep the synthetic samples marked as non-speech.
  /// Missing files and unreadable/invalid WAVs both resolve to
  /// `isSpeech == false`; callers distinguish them via file existence
  /// when reporting diagnostics.
  public static func resolvedLiveFixtures(
    fromDirectory directory: URL?,
    fallback: [BenchmarkFixture] = BenchmarkFixtures.builtins()
  ) -> [LiveFixtureResolution] {
    guard let directory else {
      return fallback.map { LiveFixtureResolution(fixture: $0, isSpeech: false) }
    }
    return fallback.map { fixture in
      let url = directory.appendingPathComponent(fileName(for: fixture.id))
      guard let data = try? Data(contentsOf: url),
        let info = WAVDecoder.decodePCM16(data),
        !info.samples.isEmpty
      else { return LiveFixtureResolution(fixture: fixture, isSpeech: false, sourceURL: url) }
      var copy = fixture
      copy.sampleRate = info.sampleRate
      copy.samples = toMono(samples: info.samples, channels: info.channels)
      return LiveFixtureResolution(fixture: copy, isSpeech: true, sourceURL: url)
    }
  }

  public static func resolvedLiveFixtures(
    fromDirectoryPath path: String?,
    fallback: [BenchmarkFixture] = BenchmarkFixtures.builtins()
  ) -> [LiveFixtureResolution] {
    guard let path, !path.isEmpty else {
      return fallback.map { LiveFixtureResolution(fixture: $0, isSpeech: false) }
    }
    return resolvedLiveFixtures(
      fromDirectory: URL(fileURLWithPath: path), fallback: fallback)
  }

  public static func liveFixtures(
    fromDirectory directory: URL?,
    fallback: [BenchmarkFixture] = BenchmarkFixtures.builtins()
  ) -> [BenchmarkFixture] {
    resolvedLiveFixtures(fromDirectory: directory, fallback: fallback).map(\.fixture)
  }

  public static func liveFixtures(
    fromDirectoryPath path: String?,
    fallback: [BenchmarkFixture] = BenchmarkFixtures.builtins()
  ) -> [BenchmarkFixture] {
    resolvedLiveFixtures(fromDirectoryPath: path, fallback: fallback).map(\.fixture)
  }

  static func toMono(samples: [Int16], channels: Int) -> [Int16] {
    guard channels > 1, !samples.isEmpty else { return samples }
    let frames = samples.count / channels
    var mono: [Int16] = []
    mono.reserveCapacity(frames)
    for frame in 0..<frames {
      var sum = 0
      for channel in 0..<channels {
        sum += Int(samples[frame * channels + channel])
      }
      mono.append(Int16(sum / channels))
    }
    return mono
  }
}

// MARK: - Resource sampling (best effort)

/// Peak RSS snapshot for the current process, kilobytes. Best effort:
/// returns 0 when the platform query is unavailable. Used as a
/// representative local-preprocessing figure, not a CI threshold.
public enum BenchmarkResources {
  public static func peakRSSKilobytes() -> Int {
#if canImport(Darwin)
    var usage = rusage()
    let result = getrusage(RUSAGE_SELF, &usage)
    guard result == 0 else { return 0 }
    // macOS ru_maxrss is bytes; Linux is kilobytes. Normalize to KB.
    #if os(macOS)
      return Int(usage.ru_maxrss / 1_024)
    #else
      return Int(usage.ru_maxrss)
    #endif
#else
    return 0
#endif
  }
}

// MARK: - Runner

/// Runs every fixture against every config with one provider hook and
/// records quality + bandwidth + timing. All timing uses wall clock so the
/// same code works for scripted (deterministic) and live providers.
public enum BenchmarkRunner {
  /// Upload byte count for a config: exact request body the adapter would
  /// send for this audio payload (multipart overhead included, bias fields
  /// included).
  /// Default format is WAV (byte-identical to historic behavior); pass
  /// `.flac` to account the FLAC transport for the same config.
  public static func uploadBytes(
    config: BenchmarkSTTConfig, wav: Data, audioFormat: STTUploadFormat = .wav
  ) -> Int {
    let spec = ProviderRequestBuilder.plan(
      adapterID: config.adapterID,
      baseURL: "https://benchmark.invalid/v1/audio/transcriptions",
      model: config.model,
      apiKey: "",
      language: config.language,
      wav: wav,
      audioFormat: audioFormat,
      bias: config.bias
    )
    return spec.bodyData.count
  }

  public static func run(
    fixtures: [BenchmarkFixture],
    configs: [BenchmarkSTTConfig],
    provider: BenchmarkProviderRun
  ) throws -> BenchmarkReport {
    var results: [BenchmarkCaseResult] = []
    for fixture in fixtures {
      for config in configs {
        let caseStart = Date()
        let encodeStart = Date()
        let wav = WAVEncoder.encode(samples: fixture.samples, sampleRate: fixture.sampleRate)
        let encodeSeconds = Date().timeIntervalSince(encodeStart)
        let upload = uploadBytes(config: config, wav: wav)
        let requestStart = Date()
        let hypothesis = try provider(fixture, config)
        let requestSeconds = Date().timeIntervalSince(requestStart)
        let endToEndSeconds = Date().timeIntervalSince(caseStart)
        let reportedRequestMs =
          hypothesis.requestSeconds > 0
          ? hypothesis.requestSeconds * 1_000.0 : requestSeconds * 1_000.0
        results.append(
          BenchmarkCaseResult(
            fixtureID: fixture.id,
            category: fixture.category.rawValue,
            durationBucket: fixture.durationBucket.rawValue,
            configName: config.name,
            adapterID: config.adapterID,
            model: config.model,
            wer: BenchmarkText.wer(reference: fixture.transcript, hypothesis: hypothesis.text),
            cer: BenchmarkText.cer(reference: fixture.transcript, hypothesis: hypothesis.text),
            referenceWords: BenchmarkText.words(fixture.transcript).count,
            hypothesisWords: BenchmarkText.words(hypothesis.text).count,
            wavBytes: wav.count,
            uploadBytes: upload,
            encodeMs: encodeSeconds * 1_000.0,
            requestMs: reportedRequestMs,
            endToEndMs: endToEndSeconds * 1_000.0,
            peakRSSKB: BenchmarkResources.peakRSSKilobytes(),
            hypothesis: hypothesis.text
          ))
      }
    }
    return BenchmarkReport(results: results, summaries: summarize(results: results))
  }

  public static func summarize(results: [BenchmarkCaseResult]) -> [BenchmarkConfigSummary] {
    var grouped: [String: [BenchmarkCaseResult]] = [:]
    for result in results {
      grouped[result.configName, default: []].append(result)
    }
    return grouped.map { name, cases in
      let count = Double(max(1, cases.count))
      let meanWER = cases.reduce(0) { $0 + $1.wer } / count
      let meanCER = cases.reduce(0) { $0 + $1.cer } / count
      let totalUpload = cases.reduce(0) { $0 + $1.uploadBytes }
      let meanE2E = cases.reduce(0) { $0 + $1.endToEndMs } / count
      let meanReq = cases.reduce(0) { $0 + $1.requestMs } / count
      let meanEnc = cases.reduce(0) { $0 + $1.encodeMs } / count
      return BenchmarkConfigSummary(
        configName: name,
        cases: cases.count,
        meanWER: meanWER,
        meanCER: meanCER,
        totalUploadBytes: totalUpload,
        meanEndToEndMs: meanE2E,
        meanRequestMs: meanReq,
        meanEncodeMs: meanEnc
      )
    }.sorted { $0.configName < $1.configName }
  }

  /// Scripted deterministic provider for local runs and tests: returns a
  /// fixed hypothesis per config name with zero simulated latency.
  public static func scriptedProvider(
    hypotheses: [String: [String: String]]
  ) -> BenchmarkProviderRun {
    { fixture, config in
      let text = hypotheses[config.name]?[fixture.id] ?? fixture.transcript
      return BenchmarkHypothesis(text: text, requestSeconds: 0)
    }
  }

  // MARK: - WAV vs FLAC transport comparison

  /// Per-format recognition provider for transport comparison: receives the
  /// fixture, the benchmark config, the upload container under test and the
  /// encoded payload that would be uploaded, and returns the hypothesis.
  /// Local deterministic runs use a scripted closure; live runs wrap a real
  /// `Transcriber` (WAV payload with `.wav`, FLAC payload with `.flac`).
  public typealias TransportProviderRun = (
    BenchmarkFixture, BenchmarkSTTConfig, STTUploadFormat, Data
  ) throws -> BenchmarkHypothesis

  /// True when the config's model profile accepts a FLAC upload body.
  /// `ProviderRequestBuilder.plan` coerces unsupported FLAC requests to WAV
  /// metadata, so measuring such a request as `uploadFlacBytes` would present
  /// a WAV-metadata/FLAC-body hybrid as a valid comparison. Callers must
  /// report FLAC as unsupported for these profiles instead.
  public static func supportsFLAC(config: BenchmarkSTTConfig) -> Bool {
    let profile = STTModelRegistry.resolve(adapterID: config.adapterID, model: config.model)
    return profile.audio.supportedUploadFormats.contains(.flac)
      && FLACEncoder.canEncode(profile: profile.audio)
  }

  /// Compare upload transports for one fixture set: WAV vs FLAC bytes, local
  /// encode time, and lossless verification (FLAC decodes back to the exact
  /// source samples). Size/lossless alone do not measure recognition quality:
  /// pass `provider` to transcribe the same fixture audio in both containers
  /// and record per-format WER/CER on the row. Without a provider the
  /// recognition fields stay nil (unmeasured); lossless FLAC must still score
  /// identically on a deterministic provider.
  public static func compareTransportFormats(
    fixtures: [BenchmarkFixture],
    config: BenchmarkSTTConfig,
    provider: TransportProviderRun? = nil
  ) -> [BenchmarkTransportComparison] {
    let flacSupported = supportsFLAC(config: config)
    return fixtures.map { fixture in
      let wavStart = Date()
      let wav = WAVEncoder.encode(samples: fixture.samples, sampleRate: fixture.sampleRate)
      let wavEncodeMs = Date().timeIntervalSince(wavStart) * 1_000.0
      let flacStart = Date()
      let flac = FLACEncoder.encode(
        samples: fixture.samples, sampleRate: fixture.sampleRate, channels: 1)
      let flacEncodeMs = Date().timeIntervalSince(flacStart) * 1_000.0
      var lossless = false
      if let flac {
        lossless = (try? FLACDecoder.decode(flac))?.samples == fixture.samples
      }
      let uploadWav = uploadBytes(config: config, wav: wav, audioFormat: .wav)
      // Exclude unsupported FLAC requests from the comparison: when the
      // profile would force WAV, a FLAC body with WAV metadata is not a valid
      // transport sample. Report 0 upload bytes with flacSupported == false.
      let uploadFlac: Int
      if flacSupported, let flac {
        uploadFlac = uploadBytes(config: config, wav: flac, audioFormat: .flac)
      } else {
        uploadFlac = 0
      }
      var wavWER: Double?
      var wavCER: Double?
      var flacWER: Double?
      var flacCER: Double?
      var wavHypothesis: String?
      var flacHypothesis: String?
      if let provider {
        if let wavHyp = try? provider(fixture, config, .wav, wav) {
          wavHypothesis = wavHyp.text
          wavWER = BenchmarkText.wer(reference: fixture.transcript, hypothesis: wavHyp.text)
          wavCER = BenchmarkText.cer(reference: fixture.transcript, hypothesis: wavHyp.text)
        }
        if flacSupported, let flac {
          if let flacHyp = try? provider(fixture, config, .flac, flac) {
            flacHypothesis = flacHyp.text
            flacWER = BenchmarkText.wer(reference: fixture.transcript, hypothesis: flacHyp.text)
            flacCER = BenchmarkText.cer(reference: fixture.transcript, hypothesis: flacHyp.text)
          }
        }
      }
      return BenchmarkTransportComparison(
        fixtureID: fixture.id,
        category: fixture.category.rawValue,
        durationBucket: fixture.durationBucket.rawValue,
        durationSeconds: fixture.durationSeconds,
        wavBytes: wav.count,
        flacBytes: flac?.count ?? 0,
        wavEncodeMs: wavEncodeMs,
        flacEncodeMs: flacEncodeMs,
        uploadWavBytes: uploadWav,
        uploadFlacBytes: uploadFlac,
        lossless: lossless,
        flacSupported: flacSupported,
        wavWER: wavWER,
        wavCER: wavCER,
        flacWER: flacWER,
        flacCER: flacCER,
        wavHypothesis: wavHypothesis,
        flacHypothesis: flacHypothesis
      )
    }
  }
}

// MARK: - WAV vs FLAC transport comparison row

/// Per-fixture WAV vs FLAC comparison: size, local encode time, upload body
/// accounting (multipart overhead included) and lossless verification.
/// `flacSupported` is false when the config's model profile does not accept
/// FLAC (uploadFlacBytes is then 0, not a valid comparison sample).
/// Recognition fields (`wavWER`/`flacWER`/...) are nil unless the caller
/// supplied a transport provider: size/lossless alone never imply
/// recognition quality.
/// Codable for machine output alongside `BenchmarkReport`.
public struct BenchmarkTransportComparison: Codable, Equatable {
  public var fixtureID: String
  public var category: String
  public var durationBucket: String
  public var durationSeconds: Double
  public var wavBytes: Int
  public var flacBytes: Int
  public var wavEncodeMs: Double
  public var flacEncodeMs: Double
  public var uploadWavBytes: Int
  public var uploadFlacBytes: Int
  /// FLAC decodes back to the exact source samples (lossless transport).
  public var lossless: Bool
  /// The profile accepts a FLAC upload body. False: FLAC is unsupported and
  /// `uploadFlacBytes`/FLAC recognition are not valid comparison samples.
  public var flacSupported: Bool
  public var wavWER: Double?
  public var wavCER: Double?
  public var flacWER: Double?
  public var flacCER: Double?
  public var wavHypothesis: String?
  public var flacHypothesis: String?

  public init(
    fixtureID: String,
    category: String,
    durationBucket: String,
    durationSeconds: Double,
    wavBytes: Int,
    flacBytes: Int,
    wavEncodeMs: Double,
    flacEncodeMs: Double,
    uploadWavBytes: Int,
    uploadFlacBytes: Int,
    lossless: Bool,
    flacSupported: Bool = true,
    wavWER: Double? = nil,
    wavCER: Double? = nil,
    flacWER: Double? = nil,
    flacCER: Double? = nil,
    wavHypothesis: String? = nil,
    flacHypothesis: String? = nil
  ) {
    self.fixtureID = fixtureID
    self.category = category
    self.durationBucket = durationBucket
    self.durationSeconds = durationSeconds
    self.wavBytes = wavBytes
    self.flacBytes = flacBytes
    self.wavEncodeMs = wavEncodeMs
    self.flacEncodeMs = flacEncodeMs
    self.uploadWavBytes = uploadWavBytes
    self.uploadFlacBytes = uploadFlacBytes
    self.lossless = lossless
    self.flacSupported = flacSupported
    self.wavWER = wavWER
    self.wavCER = wavCER
    self.flacWER = flacWER
    self.flacCER = flacCER
    self.wavHypothesis = wavHypothesis
    self.flacHypothesis = flacHypothesis
  }

  private enum CodingKeys: String, CodingKey {
    case fixtureID
    case category
    case durationBucket
    case durationSeconds
    case wavBytes
    case flacBytes
    case wavEncodeMs
    case flacEncodeMs
    case uploadWavBytes
    case uploadFlacBytes
    case lossless
    case flacSupported
    case wavWER
    case wavCER
    case flacWER
    case flacCER
    case wavHypothesis
    case flacHypothesis
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    fixtureID = try container.decode(String.self, forKey: .fixtureID)
    category = try container.decode(String.self, forKey: .category)
    durationBucket = try container.decode(String.self, forKey: .durationBucket)
    durationSeconds = try container.decode(Double.self, forKey: .durationSeconds)
    wavBytes = try container.decode(Int.self, forKey: .wavBytes)
    flacBytes = try container.decode(Int.self, forKey: .flacBytes)
    wavEncodeMs = try container.decode(Double.self, forKey: .wavEncodeMs)
    flacEncodeMs = try container.decode(Double.self, forKey: .flacEncodeMs)
    uploadWavBytes = try container.decode(Int.self, forKey: .uploadWavBytes)
    uploadFlacBytes = try container.decode(Int.self, forKey: .uploadFlacBytes)
    lossless = try container.decode(Bool.self, forKey: .lossless)
    flacSupported = try container.decodeIfPresent(Bool.self, forKey: .flacSupported) ?? true
    wavWER = try container.decodeIfPresent(Double.self, forKey: .wavWER)
    wavCER = try container.decodeIfPresent(Double.self, forKey: .wavCER)
    flacWER = try container.decodeIfPresent(Double.self, forKey: .flacWER)
    flacCER = try container.decodeIfPresent(Double.self, forKey: .flacCER)
    wavHypothesis = try container.decodeIfPresent(String.self, forKey: .wavHypothesis)
    flacHypothesis = try container.decodeIfPresent(String.self, forKey: .flacHypothesis)
  }

  /// FLAC share of WAV bytes (< 1 means FLAC is smaller).
  public var sizeRatio: Double {
    guard wavBytes > 0 else { return 0 }
    return Double(flacBytes) / Double(wavBytes)
  }

  public static func markdown(_ rows: [BenchmarkTransportComparison]) -> String {
    var lines: [String] = []
    lines.append("## Transport comparison (WAV vs FLAC)")
    lines.append("")
    let showsRecognition = rows.contains { $0.wavWER != nil || $0.flacWER != nil }
    if showsRecognition {
      lines.append(
        "| fixture | wav | flac | ratio | wav upload | flac upload | wav encode | flac encode | lossless | wav WER | flac WER | wav CER | flac CER |")
      lines.append(
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    } else {
      lines.append(
        "| fixture | wav | flac | ratio | wav upload | flac upload | wav encode | flac encode | lossless |")
      lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- |")
    }
    for row in rows {
      let flacUpload = row.flacSupported ? "\(row.uploadFlacBytes)B" : "n/a"
      var line =
        "| \(row.fixtureID) | \(row.wavBytes)B | \(row.flacBytes)B"
        + " | \(String(format: "%.3f", row.sizeRatio))"
        + " | \(row.uploadWavBytes)B | \(flacUpload)"
        + " | \(BenchmarkFormat.ms(row.wavEncodeMs)) | \(BenchmarkFormat.ms(row.flacEncodeMs))"
        + " | \(row.lossless ? "yes" : "NO") |"
      if showsRecognition {
        let wavWER = row.wavWER.map { String(format: "%.3f", $0) } ?? "-"
        let flacWER: String
        if !row.flacSupported {
          flacWER = "n/a"
        } else {
          flacWER = row.flacWER.map { String(format: "%.3f", $0) } ?? "-"
        }
        let wavCER = row.wavCER.map { String(format: "%.3f", $0) } ?? "-"
        let flacCER: String
        if !row.flacSupported {
          flacCER = "n/a"
        } else {
          flacCER = row.flacCER.map { String(format: "%.3f", $0) } ?? "-"
        }
        line += " \(wavWER) | \(flacWER) | \(wavCER) | \(flacCER) |"
      }
      lines.append(line)
    }
    return lines.joined(separator: "\n") + "\n"
  }
}
