import Foundation

// MARK: - WAV vs FLAC transport comparison (BenchmarkRunner extension)
//
// Transport-comparison helpers moved out of STTBenchmark.swift so that file
// stays under the SwiftLint file_length limit (1000 lines).

extension BenchmarkRunner {
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
    // Policy from the shared engine (canonical profile); FLAC encoding
    // itself stays a native capability check.
    let profile = ProviderRequestBuilder.profile(adapterID: config.adapterID, model: config.model)
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

// MARK: - Request-body memory comparison (issue #32)
//
// Near-60-second benchmark for transient request-body memory: audio bytes,
// full body bytes, multipart overhead, the upload strategy production would
// use (file-backed at or above `Transcriber.fileBackedUploadThresholdBytes`
// on the real network path, in-memory below it) and peak-transient estimates
// for both strategies (see `STTRequestMemoryReport`).

/// Per-fixture request-body memory accounting (Codable for machine output
/// alongside `BenchmarkReport`).
public struct STTRequestMemoryRow: Codable, Equatable {
  public var fixtureID: String
  public var durationBucket: String
  public var durationSeconds: Double
  public var audioBytes: Int
  public var bodyBytes: Int
  public var overheadBytes: Int
  public var duplicationRatio: Double
  public var strategy: String
  public var peakInMemoryBytes: Int
  public var peakFileBackedBytes: Int

  public init(
    fixtureID: String,
    durationBucket: String,
    durationSeconds: Double,
    audioBytes: Int,
    bodyBytes: Int,
    overheadBytes: Int,
    duplicationRatio: Double,
    strategy: String,
    peakInMemoryBytes: Int,
    peakFileBackedBytes: Int
  ) {
    self.fixtureID = fixtureID
    self.durationBucket = durationBucket
    self.durationSeconds = durationSeconds
    self.audioBytes = audioBytes
    self.bodyBytes = bodyBytes
    self.overheadBytes = overheadBytes
    self.duplicationRatio = duplicationRatio
    self.strategy = strategy
    self.peakInMemoryBytes = peakInMemoryBytes
    self.peakFileBackedBytes = peakFileBackedBytes
  }

  public static func markdown(_ rows: [STTRequestMemoryRow]) -> String {
    var lines: [String] = []
    lines.append("## Request memory (audio vs body, in-memory vs file-backed)")
    lines.append("")
    lines.append(
      "| fixture | audio | body | overhead | dup | strategy | peak in-mem | peak file |")
    lines.append("| --- | --- | --- | --- | --- | --- | --- | --- |")
    for row in rows {
      lines.append(
        "| \(row.fixtureID) | \(row.audioBytes)B | \(row.bodyBytes)B"
          + " | \(row.overheadBytes)B"
          + " | \(String(format: "%.3f", row.duplicationRatio))"
          + " | \(row.strategy)"
          + " | \(row.peakInMemoryBytes)B | \(row.peakFileBackedBytes)B |")
    }
    return lines.joined(separator: "\n") + "\n"
  }
}

extension BenchmarkRunner {
  /// Request-body memory accounting for one fixture set: exact body bytes
  /// come from the request the adapter would send (multipart framing
  /// included). The payload is prepared exactly as production prepares it
  /// (`Transcriber.prepareUpload`: capability-gated FLAC encoding with WAV
  /// fallback), and the strategy mirrors production (`fileBacked` at or
  /// above the threshold on the real network path for batch-multipart
  /// profiles, else `inMemory`); both peak estimates are reported so the
  /// before/after is visible in one row.
  public static func requestMemoryRows(
    fixtures: [BenchmarkFixture],
    config: BenchmarkSTTConfig,
    audioFormat: STTUploadFormat = .wav
  ) -> [STTRequestMemoryRow] {
    fixtures.map { fixture in
      let wav = WAVEncoder.encode(samples: fixture.samples, sampleRate: fixture.sampleRate)
      // Encode the requested upload container before measuring it, exactly
      // as production does: the byte counts below describe the payload that
      // is actually uploaded (FLAC bytes for FLAC profiles, WAV otherwise),
      // never WAV bytes mislabelled as FLAC.
      let prepared = Transcriber.prepareUpload(
        wav: wav, filename: "audio.wav", audioFormat: audioFormat,
        adapterID: config.adapterID, model: config.model)
      let bodyBytes = uploadBytes(
        config: config, wav: prepared.data, audioFormat: prepared.effectiveFormat)
      let inMemory = STTRequestMemoryReport(
        audioBytes: prepared.data.count, bodyBytes: bodyBytes, strategy: .inMemory)
      let fileBacked = STTRequestMemoryReport(
        audioBytes: prepared.data.count, bodyBytes: bodyBytes, strategy: .fileBacked)
      // Mirror the production file-backed condition (prepared audio bytes
      // plus framing estimate against the threshold). Only batch-multipart
      // profiles have a file-backed representation: raw-audio and realtime
      // profiles fall back to the in-memory spec in production, so the label
      // stays `inMemory` for them regardless of size.
      let supportsFileBacked = ProviderRequestBuilder.profile(
        adapterID: config.adapterID, model: config.model
      ).capabilities.transport == .batchMultipart
      let strategy: STTUploadStrategy =
        supportsFileBacked
        && prepared.data.count + STTRequestMemoryReport.framingOverheadEstimate
          >= Transcriber.fileBackedUploadThresholdBytes ? .fileBacked : .inMemory
      return STTRequestMemoryRow(
        fixtureID: fixture.id,
        durationBucket: fixture.durationBucket.rawValue,
        durationSeconds: fixture.durationSeconds,
        audioBytes: prepared.data.count,
        bodyBytes: bodyBytes,
        overheadBytes: inMemory.overheadBytes,
        duplicationRatio: inMemory.duplicationRatio,
        strategy: strategy.rawValue,
        peakInMemoryBytes: inMemory.peakTransientBytes,
        peakFileBackedBytes: fileBacked.peakTransientBytes)
    }
  }
}

