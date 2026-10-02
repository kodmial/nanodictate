import Foundation
@testable import NanoDictateCore

// MARK: - AudioTransportTests
//
// Provider-aware audio transport formats (WAV/FLAC, experimental Opus):
// capability matrix, capability-gated selection, pure-Swift FLAC round-trip,
// request-builder wiring, config parsing, and WAV vs FLAC benchmarks.

final class AudioTransportTests: XCTestCase {

    // MARK: - Format metadata

    @objc func testUploadFormatMetadata() {
        XCTAssertEqual(STTUploadFormat.wav.fileExtension, "wav")
        XCTAssertEqual(STTUploadFormat.flac.fileExtension, "flac")
        XCTAssertEqual(STTUploadFormat.opus.fileExtension, "ogg")
        XCTAssertEqual(STTUploadFormat.wav.contentType, "audio/wav")
        XCTAssertEqual(STTUploadFormat.flac.contentType, "audio/flac")
        XCTAssertEqual(STTUploadFormat.opus.contentType, "audio/ogg")
        XCTAssertTrue(STTUploadFormat.wav.isLossless)
        XCTAssertTrue(STTUploadFormat.flac.isLossless)
        XCTAssertFalse(STTUploadFormat.opus.isLossless)
        XCTAssertFalse(STTUploadFormat.wav.isExperimental)
        XCTAssertFalse(STTUploadFormat.flac.isExperimental)
        XCTAssertTrue(STTUploadFormat.opus.isExperimental)
    }

    @objc func testUploadPreferenceParsing() {
        XCTAssertEqual(STTUploadPreference.parse(nil), .auto)
        XCTAssertEqual(STTUploadPreference.parse(""), .auto)
        XCTAssertEqual(STTUploadPreference.parse("auto"), .auto)
        XCTAssertEqual(STTUploadPreference.parse("WAV"), .wav)
        XCTAssertEqual(STTUploadPreference.parse(" flac "), .flac)
        XCTAssertEqual(STTUploadPreference.parse("opus"), .opusExperimental)
        XCTAssertEqual(STTUploadPreference.parse("opus-experimental"), .opusExperimental)
        XCTAssertEqual(STTUploadPreference.parse("OPUS-Experimental"), .opusExperimental)
        XCTAssertNil(STTUploadPreference.parse("mp3"))
        XCTAssertNil(STTUploadPreference.parse("ogg"))
    }

    // MARK: - Capability matrix

    @objc func testFlacSupportMatrix() {
        for (adapter, model) in [
            ("openai", "whisper-1"),
            ("openai", "gpt-transcribe"),
            ("openai", "gpt-transcribe-2026-01-01"),
            ("openai", "gpt-4o-transcribe"),
            ("groq", "whisper-large-v3"),
            ("groq", "whisper-large-v3-turbo"),
            ("groq", "distil-whisper-large-v3-en"),
        ] as [(String, String)] {
            let audio = STTModelRegistry.audioProfile(adapterID: adapter, model: model)
            XCTAssertEqual(audio.uploadFormat, .wav, "\(adapter)/\(model) default stays WAV")
            XCTAssertEqual(
                audio.supportedUploadFormats, [.wav, .flac], "\(adapter)/\(model) accepts FLAC")
        }
        // Conservative profiles: WAV only (never assume an undeclared codec).
        for (adapter, model) in [
            ("openai", "some-future-model-xyz"),
            ("groq", "future-groq-model-xyz"),
            ("cloudflare", ""),
            ("airubiz", "gigaam-v3-ctc-sherpa"),
            ("custom", "m"),
        ] as [(String, String)] {
            let audio = STTModelRegistry.audioProfile(adapterID: adapter, model: model)
            XCTAssertEqual(audio.uploadFormat, .wav, "\(adapter)/\(model)")
            XCTAssertEqual(audio.supportedUploadFormats, [.wav], "\(adapter)/\(model) WAV only")
        }
    }

    // MARK: - Selection never chooses an unsupported codec

    @objc func testSelectionNeverChoosesUnsupportedCodec() {
        let profiles: [(String, String)] = [
            ("openai", "whisper-1"),
            ("openai", "gpt-transcribe"),
            ("openai", "gpt-4o-transcribe"),
            ("openai", "some-future-model-xyz"),
            ("groq", "whisper-large-v3"),
            ("groq", "future-groq-model-xyz"),
            ("cloudflare", ""),
            ("airubiz", "gigaam-v3-ctc-sherpa"),
            ("custom", "m"),
        ]
        for (adapter, model) in profiles {
            let profile = STTModelRegistry.resolve(adapterID: adapter, model: model).audio
            let supported = profile.supportedUploadFormats
            for preference in STTUploadPreference.allCases {
                let selected = AudioTransportSelection.resolve(
                    preference: preference, profile: profile)
                XCTAssertTrue(
                    supported.contains(selected),
                    "\(adapter)/\(model) + \(preference): \(selected) not in \(supported)")
                XCTAssertFalse(selected == STTUploadFormat.opus, "Opus is never selected")
            }
            XCTAssertEqual(
                AudioTransportSelection.resolve(preference: .auto, profile: profile), .wav,
                "\(adapter)/\(model): auto stays WAV")
        }
    }

    @objc func testSelectionFlacWhereDeclaredWavElsewhere() {
        let openai = STTModelRegistry.audioProfile(adapterID: "openai", model: "whisper-1")
        XCTAssertEqual(
            AudioTransportSelection.resolve(preference: .flac, profile: openai), .flac)
        let cloudflare = STTModelRegistry.audioProfile(adapterID: "cloudflare", model: "")
        XCTAssertEqual(
            AudioTransportSelection.resolve(preference: .flac, profile: cloudflare), .wav,
            "WAV-only profile falls back to WAV")
        XCTAssertEqual(
            AudioTransportSelection.resolve(preference: .opusExperimental, profile: openai), .wav,
            "experimental Opus resolves to WAV")
        XCTAssertEqual(
            AudioTransportSelection.resolve(rawPreference: "bogus", profile: openai), .wav)
    }

    // MARK: - FLAC round-trip (lossless)

    @objc func testFlacRoundTripEmptyAndSingleSample() throws {
        let empty = FLACEncoder.encode(samples: [], sampleRate: 16000, channels: 1)
        XCTAssertNotNil(empty)
        let decodedEmpty = try FLACDecoder.decode(empty!)
        XCTAssertEqual(decodedEmpty.samples, [])
        let single = FLACEncoder.encode(samples: [1234], sampleRate: 16000, channels: 1)
        XCTAssertNotNil(single)
        let decodedSingle = try FLACDecoder.decode(single!)
        XCTAssertEqual(decodedSingle.samples, [1234])
    }

    @objc func testFlacRoundTripShortFixtures() throws {
        for fixture in BenchmarkFixtures.builtins().filter({ $0.durationBucket == .short }) {
            guard let flac = FLACEncoder.encode(
                samples: fixture.samples, sampleRate: fixture.sampleRate, channels: 1)
            else {
                XCTFail("FLAC encode failed for \(fixture.id)")
                continue
            }
            XCTAssertEqual([UInt8](flac.prefix(4)), [0x66, 0x4C, 0x61, 0x43], "fLaC magic")
            let decoded = try FLACDecoder.decode(flac)
            XCTAssertEqual(decoded.samples, fixture.samples, "\(fixture.id) lossless")
            XCTAssertEqual(decoded.sampleRate, fixture.sampleRate)
            XCTAssertEqual(decoded.channels, 1)
            let wav = WAVEncoder.encode(samples: fixture.samples, sampleRate: fixture.sampleRate)
            XCTAssertLessThan(flac.count, wav.count, "\(fixture.id): FLAC compacts tonal audio")
        }
    }

    @objc func testFlacRoundTripNear60SecondFixture() throws {
        guard let long = BenchmarkFixtures.builtins().first(where: { $0.durationBucket == .long })
        else {
            XCTFail("long fixture missing")
            return
        }
        XCTAssertGreaterThanOrEqual(long.durationSeconds, 50)
        guard let flac = FLACEncoder.encode(
            samples: long.samples, sampleRate: long.sampleRate, channels: 1)
        else {
            XCTFail("FLAC encode failed for near-60-second fixture")
            return
        }
        let decodedLong = try FLACDecoder.decode(flac)
        XCTAssertEqual(decodedLong.samples, long.samples, "long lossless")
        let wav = WAVEncoder.encode(samples: long.samples, sampleRate: long.sampleRate)
        XCTAssertLessThan(flac.count, wav.count, "FLAC compacts near-60-second audio")
    }

    @objc func testFlacRejectsMultichannel() {
        XCTAssertNil(FLACEncoder.encode(samples: [1, 2, 3, 4], sampleRate: 16000, channels: 2))
        XCTAssertFalse(FLACEncoder.canEncode(profile: STTAudioProfile(
            sampleRate: 16000, channels: 2, uploadFormat: .wav,
            supportedUploadFormats: [.wav])))
        XCTAssertTrue(FLACEncoder.canEncode(profile: .batchMono16kFLACCapable))
    }

    @objc func testFlacConstantAndSilenceRoundTrip() throws {
        for samples in [[Int16](repeating: 0, count: 5000), [Int16](repeating: -321, count: 9000)] {
            let flac = FLACEncoder.encode(samples: samples, sampleRate: 16000, channels: 1)
            XCTAssertNotNil(flac)
            let decoded = try FLACDecoder.decode(flac!)
            XCTAssertEqual(decoded.samples, samples)
        }
    }

    @objc func testFlacDecoderRejectsGarbage() {
        XCTAssertThrowsError(try FLACDecoder.decode(Data("not flac".utf8))) { _ in }
        XCTAssertThrowsError(try FLACDecoder.decode(Data([0x66, 0x4C, 0x61]))) { _ in }
    }

    // MARK: - Encoder payload + filename coercion

    @objc func testAudioTransportEncoderPayload() throws {
        let samples = BenchmarkSynth.samples(seed: 9, durationSeconds: 1, kind: .normal)
        let flacCapable = STTModelRegistry.audioProfile(adapterID: "openai", model: "whisper-1")
        let flacPayload = AudioTransportEncoder.encode(
            samples: samples, profile: flacCapable, preference: .flac)
        XCTAssertEqual(flacPayload.format, .flac)
        XCTAssertEqual(flacPayload.contentType, "audio/flac")
        XCTAssertEqual(flacPayload.filename, "audio.flac")
        let decodedPayload = try FLACDecoder.decode(flacPayload.data)
        XCTAssertEqual(decodedPayload.samples, samples)

        let wavOnly = STTModelRegistry.audioProfile(adapterID: "cloudflare", model: "")
        let fallback = AudioTransportEncoder.encode(
            samples: samples, profile: wavOnly, preference: .flac)
        XCTAssertEqual(fallback.format, .wav, "unsupported FLAC falls back to WAV")

        let opus = AudioTransportEncoder.encode(
            samples: samples, profile: flacCapable, preference: .opusExperimental)
        XCTAssertEqual(opus.format, .wav, "experimental Opus resolves to WAV")
    }

    @objc func testCoercedFilename() {
        XCTAssertEqual(
            AudioTransportEncoder.coercedFilename("segment-1.wav", for: .flac), "segment-1.flac")
        XCTAssertEqual(
            AudioTransportEncoder.coercedFilename("audio.flac", for: .wav), "audio.wav")
        XCTAssertEqual(
            AudioTransportEncoder.coercedFilename("recording", for: .flac), "recording")
    }

    // MARK: - Request builder wiring

    private func multipartText(_ spec: STTRequestSpec) -> String? {
        guard case .multipart(let data, _) = spec.body else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// ASCII-safe stand-in payload: plan() never inspects audio bytes, and
    /// real PCM/FLAC bytes are not valid UTF-8 for String assertions.
    private let fakeAudio = Data("FAKEAUDIO".utf8)

    @objc func testBuilderFlacMultipartForSupportedProfile() {
        let spec = ProviderRequestBuilder.plan(
            adapterID: "openai", baseURL: "", model: "whisper-1", apiKey: "k",
            language: "ru", wav: fakeAudio, audioFormat: .flac)
        guard let text = multipartText(spec) else {
            XCTFail("openai must be multipart")
            return
        }
        XCTAssertTrue(text.contains("filename=\"audio.flac\""))
        XCTAssertTrue(text.contains("Content-Type: audio/flac"))
        XCTAssertEqual(spec.contentType.split(separator: ";").first.map(String.init), "multipart/form-data")
    }

    @objc func testBuilderCarriesRealFlacBytes() {
        // End to end with real encoder output: the exact FLAC payload lands
        // in the multipart body with the FLAC filename/content type.
        let samples = BenchmarkSynth.samples(seed: 9, durationSeconds: 1, kind: .normal)
        let payload = AudioTransportEncoder.encode(
            samples: samples,
            profile: STTModelRegistry.audioProfile(adapterID: "openai", model: "whisper-1"),
            preference: .flac)
        XCTAssertEqual(payload.format, .flac)
        let spec = ProviderRequestBuilder.plan(
            adapterID: "openai", baseURL: "", model: "whisper-1", apiKey: "k",
            language: "", wav: payload.data, filename: payload.filename, audioFormat: payload.format)
        XCTAssertNotNil(spec.bodyData.range(of: payload.data), "FLAC bytes in body")
        XCTAssertNotNil(spec.bodyData.range(of: Data("audio.flac".utf8)))
        XCTAssertNotNil(spec.bodyData.range(of: Data("audio/flac".utf8)))
    }

    @objc func testBuilderDefaultWavByteIdentical() {
        let implicit = ProviderRequestBuilder.plan(
            adapterID: "openai", baseURL: "", model: "whisper-1", apiKey: "k",
            language: "ru", wav: fakeAudio)
        let explicit = ProviderRequestBuilder.plan(
            adapterID: "openai", baseURL: "", model: "whisper-1", apiKey: "k",
            language: "ru", wav: fakeAudio, audioFormat: .wav)
        // Boundaries embed a UUID, so bodies differ by exactly that token:
        // normalize via each spec's own content-type boundary first.
        func normalized(_ spec: STTRequestSpec) -> String? {
            guard var text = multipartText(spec) else { return nil }
            let boundary = spec.contentType.split(separator: "=").last.map(String.init) ?? ""
            XCTAssertFalse(boundary.isEmpty)
            text = text.replacingOccurrences(of: boundary, with: "BOUNDARY")
            return text
        }
        XCTAssertEqual(normalized(implicit), normalized(explicit), "default stays WAV")
        XCTAssertTrue(multipartText(implicit)?.contains("Content-Type: audio/wav") ?? false)
        XCTAssertTrue(multipartText(implicit)?.contains("filename=\"audio.wav\"") ?? false)
    }

    @objc func testBuilderFlacFallsBackOnWavOnlyProfiles() {
        // Cloudflare raw audio: WAV-only profile coerces FLAC to WAV.
        let cloudflare = ProviderRequestBuilder.plan(
            adapterID: "cloudflare",
            baseURL: "https://api.cloudflare.com/client/v4/accounts/a/ai/run/@cf/openai/whisper-large-v3-turbo",
            model: "", apiKey: "k", language: "ru", wav: fakeAudio, audioFormat: .flac)
        guard case .rawAudio(_, let contentType) = cloudflare.body else {
            XCTFail("cloudflare must be raw audio")
            return
        }
        XCTAssertEqual(contentType, "audio/wav")
        // Conservative custom endpoint: same fallback in multipart.
        let custom = ProviderRequestBuilder.plan(
            adapterID: "my-custom", baseURL: "https://stt.example/v1", model: "m",
            apiKey: "k", language: "ru", wav: fakeAudio, filename: "audio.wav", audioFormat: .flac)
        XCTAssertTrue(multipartText(custom)?.contains("filename=\"audio.wav\"") ?? false)
        XCTAssertTrue(multipartText(custom)?.contains("Content-Type: audio/wav") ?? false)
    }

    @objc func testBuilderGroqFlacMultipart() {
        let spec = ProviderRequestBuilder.plan(
            adapterID: "groq", baseURL: "", model: "whisper-large-v3", apiKey: "k",
            language: "", wav: fakeAudio, audioFormat: .flac)
        XCTAssertTrue(multipartText(spec)?.contains("audio/flac") ?? false)
    }

    // MARK: - Config parsing

    @objc func testConfigUploadFormatTopLevel() throws {
        let config = try AppConfig.parse("upload_format = \"flac\"\n")
        XCTAssertEqual(config.uploadFormat, .flac)
        XCTAssertEqual(
            config.effectiveUploadFormat(adapterID: "openai", model: "whisper-1"), .flac)
        XCTAssertEqual(
            config.effectiveUploadFormat(adapterID: "cloudflare", model: ""), .wav,
            "WAV-only profile falls back despite config")
    }

    @objc func testConfigUploadFormatDefaultAuto() throws {
        let config = try AppConfig.parse("")
        XCTAssertEqual(config.uploadFormat, .auto)
        XCTAssertEqual(
            config.effectiveUploadFormat(adapterID: "openai", model: "whisper-1"), .wav)
    }

    @objc func testConfigUploadFormatInvalidThrows() {
        XCTAssertThrowsError(try AppConfig.parse("upload_format = \"mp3\"\n")) { _ in }
    }

    @objc func testConfigUploadFormatProviderOverride() throws {
        let config = try AppConfig.parse(
            """
            active_provider = "openai"
            upload_format = "wav"
            [providers.groq]
            model = "whisper-large-v3"
            upload_format = "flac"
            [providers.openai]
            model = "whisper-1"
            """)
        XCTAssertEqual(config.effectiveUploadPreference(providerID: "groq"), .flac)
        XCTAssertEqual(
            config.effectiveUploadPreference(providerID: "openai"), .wav, "inherits top level")
        XCTAssertEqual(
            config.effectiveUploadFormat(adapterID: "groq", model: "whisper-large-v3",
                                         providerID: "groq"), .flac)
    }

    @objc func testConfigUploadFormatActiveOverrideDoesNotLeakToOtherProviders() throws {
        // Top level wav, active groq overrides to flac: a provider without its
        // own override (openai, e.g. routing final_provider) must still
        // inherit the top level, not the active provider's section value.
        let config = try AppConfig.parse(
            """
            active_provider = "groq"
            upload_format = "wav"
            [providers.groq]
            model = "whisper-large-v3"
            upload_format = "flac"
            [providers.openai]
            model = "whisper-1"
            """)
        XCTAssertEqual(config.uploadFormat, .wav, "top level stays intact")
        XCTAssertEqual(config.effectiveUploadPreference(providerID: "groq"), .flac)
        XCTAssertEqual(
            config.effectiveUploadPreference(providerID: "openai"), .wav,
            "provider without override inherits top level")
    }

    @objc func testFlacFrameNumbersBeyond2048RoundTrip() throws {
        // RFC 9639 Table 18 boundary values: byte count comes from the value
        // range, not the 6-bit group count (frame 2048+ used to emit an
        // invalid 0xFF lead byte).
        for value in [0, 0x7F, 0x80, 0x7FF, 0x800, 0xFFF, 0x1000, 0xFFFF, 0x10000, 0x1FFFFF] {
            var writer = FLACBitWriter()
            FLACEncoder.writeUTF8(&writer, value: value)
            writer.flush()
            var reader = FLACBitReader(bytes: writer.bytes, bitPos: 0)
            let decodedValue = try FLACDecoder.readUTF8(&reader)
            XCTAssertEqual(decodedValue, value, "UTF-8 round trip \(value)")
        }
        // More than 2048 x 4096 samples: frame 2048+ headers must decode.
        // Constant signal keeps the long encode fast.
        let count = 2048 * 4096 + 100
        let samples = [Int16](repeating: 100, count: count)
        guard let flac = FLACEncoder.encode(samples: samples, sampleRate: 16000, channels: 1)
        else {
            XCTFail("FLAC encode failed for long recording")
            return
        }
        let decoded = try FLACDecoder.decode(flac)
        XCTAssertEqual(decoded.samples, samples, "long recording lossless")
    }

    // MARK: - Benchmark WAV vs FLAC

    @objc func testBenchmarkTransportComparisonShortAndLong() {
        let fixtures = BenchmarkFixtures.builtins()
        XCTAssertTrue(fixtures.contains { $0.durationBucket == .short })
        XCTAssertTrue(fixtures.contains { $0.durationBucket == .long })
        let config = BenchmarkSTTConfig(name: "t", adapterID: "openai", model: "whisper-1")
        let rows = BenchmarkRunner.compareTransportFormats(fixtures: fixtures, config: config)
        XCTAssertEqual(rows.count, fixtures.count)
        for row in rows {
            XCTAssertTrue(row.lossless, "\(row.fixtureID) FLAC lossless")
            XCTAssertTrue(row.flacSupported, "\(row.fixtureID) FLAC supported")
            XCTAssertGreaterThan(row.wavBytes, 0)
            XCTAssertGreaterThan(row.flacBytes, 0)
            XCTAssertLessThan(row.flacBytes, row.wavBytes, "\(row.fixtureID) compacts")
            XCTAssertLessThan(row.uploadFlacBytes, row.uploadWavBytes, "\(row.fixtureID) uploads less")
            XCTAssertGreaterThanOrEqual(row.wavEncodeMs, 0)
            XCTAssertGreaterThanOrEqual(row.flacEncodeMs, 0)
            XCTAssertNil(row.wavWER, "no provider means recognition unmeasured")
            XCTAssertNil(row.flacWER, "no provider means recognition unmeasured")
        }
        let markdown = BenchmarkTransportComparison.markdown(rows)
        XCTAssertTrue(markdown.contains("normal-long"))
        XCTAssertTrue(markdown.contains("WAV vs FLAC"))
        XCTAssertTrue(markdown.contains("wav upload"), "upload sizes are visible")
        XCTAssertTrue(markdown.contains("flac upload"), "upload sizes are visible")
    }

    @objc func testBenchmarkTransportExcludesUnsupportedFlac() {
        // WAV-only profile (Cloudflare raw audio): FLAC must be reported as
        // unsupported instead of a WAV-metadata/FLAC-body hybrid request.
        let config = BenchmarkSTTConfig(name: "t", adapterID: "cloudflare", model: "")
        XCTAssertFalse(BenchmarkRunner.supportsFLAC(config: config))
        let fixtures = BenchmarkFixtures.builtins().filter { $0.durationBucket == .short }
        let rows = BenchmarkRunner.compareTransportFormats(
            fixtures: fixtures, config: config,
            provider: { fixture, _, format, _ in
                BenchmarkHypothesis(text: fixture.transcript, requestSeconds: 0)
            })
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            XCTAssertFalse(row.flacSupported)
            XCTAssertEqual(row.uploadFlacBytes, 0, "unsupported FLAC has no valid upload sample")
            XCTAssertNotNil(row.wavWER, "WAV recognition still measured")
            XCTAssertNil(row.flacWER, "unsupported FLAC recognition unmeasured")
        }
        let markdown = BenchmarkTransportComparison.markdown(rows)
        XCTAssertTrue(markdown.contains("n/a"), "unsupported FLAC shown as n/a")
    }

    @objc func testBenchmarkTransportRecognitionMeasuredPerFormat() {
        let fixtures = BenchmarkFixtures.builtins().filter { $0.durationBucket == .short }
        let config = BenchmarkSTTConfig(name: "t", adapterID: "openai", model: "whisper-1")
        XCTAssertTrue(BenchmarkRunner.supportsFLAC(config: config))
        // Perfect WAV hypothesis, degraded FLAC hypothesis: per-format WER
        // must be recorded separately, not inferred from lossless round-trip.
        let rows = BenchmarkRunner.compareTransportFormats(
            fixtures: fixtures, config: config,
            provider: { fixture, _, format, _ in
                if format == .wav {
                    return BenchmarkHypothesis(text: fixture.transcript, requestSeconds: 0)
                }
                return BenchmarkHypothesis(
                    text: fixture.transcript + " extra", requestSeconds: 0)
            })
        XCTAssertFalse(rows.isEmpty)
        for row in rows {
            XCTAssertTrue(row.flacSupported)
            XCTAssertEqual(row.wavWER, 0, "\(row.fixtureID) WAV perfect")
            XCTAssertGreaterThan(row.flacWER ?? 0, 0, "\(row.fixtureID) FLAC degraded")
            XCTAssertEqual(row.wavHypothesis, fixtures.first { $0.id == row.fixtureID }?.transcript)
        }
        let markdown = BenchmarkTransportComparison.markdown(rows)
        XCTAssertTrue(markdown.contains("wav WER"), "recognition columns shown when measured")
        XCTAssertTrue(markdown.contains("flac WER"), "recognition columns shown when measured")
    }

    @objc func testBenchmarkRecognitionIdenticalAcrossLosslessTransports() throws {
        // Lossless FLAC must score identically on a deterministic provider:
        // recognition regression is measured, not assumed.
        let fixtures = BenchmarkFixtures.builtins()
        let configs = [BenchmarkSTTConfig(name: "cfg", adapterID: "openai", model: "whisper-1")]
        let hypotheses = Dictionary(
            uniqueKeysWithValues: fixtures.map { ($0.id, $0.transcript) })
        let report = try BenchmarkRunner.run(
            fixtures: fixtures, configs: configs,
            provider: BenchmarkRunner.scriptedProvider(hypotheses: ["cfg": hypotheses]))
        for result in report.results {
            XCTAssertEqual(result.wer, 0, "\(result.fixtureID)")
            XCTAssertEqual(result.cer, 0, "\(result.fixtureID)")
        }
    }
}
