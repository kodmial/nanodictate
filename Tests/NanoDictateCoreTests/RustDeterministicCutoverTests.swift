import Foundation
@testable import NanoDictateCore

// MARK: - Production-path proof for the deterministic Rust cutover (#132)
//
// Unlike RustParityTests (which calls the bridge directly), every test here
// drives the SHIPPING call site — the same function the application uses —
// and asserts the outcome produced through the shared engine. The Swift
// reference implementations stay intact as parity oracles: several tests
// require the production result to equal the reference output, so a silent
// drift in either implementation fails loudly.

final class RustDeterministicCutoverTests: XCTestCase {

    // MARK: - Helpers

    private func runAsync(_ testName: String, _ body: @escaping () async throws -> Void) {
        let expectation = expectation(description: testName)
        Task {
            do {
                try await body()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
    }

    private func makeProvider(id: String) -> AppConfig.Provider {
        AppConfig.Provider(
            id: id, name: id, baseURL: "https://\(id).test", model: "m",
            apiKey: "key", apiKeyFile: nil, proxyKey: "")
    }

    // MARK: - Word diff on the final pass

    /// ChunkedPipeline.finalize diffs through the engine: the inserted tail
    /// is replaced in one action with engine-computed spans.
    @objc func testFinalizeWordDiffThroughEngine() {
        runAsync("testFinalizeWordDiffThroughEngine") {
            var ops: [ChunkedPipeline.Operation] = []
            let stt: ChunkedPipeline.STTHandler = { _, _, _ in
                ChunkedPipeline.SttResult(text: "Hello brave new world.")
            }
            let samples = [Int16](repeating: 100, count: 1600)
            let outcome = try await ChunkedPipeline.finalize(
                samples: samples,
                insertedText: "Hello brave world.",
                stt: stt,
                insert: { ops.append($0) }
            )
            XCTAssertTrue(outcome.changed)
            XCTAssertEqual(outcome.finalText, "Hello brave new world.")
            // Engine spans: common prefix "Hello brave", changed "new".
            XCTAssertEqual(ops, [.replaceTail(old: " world.", new: " new world.")])
        }
    }

    /// Identical texts produce no change (engine `change == false`).
    @objc func testFinalizeNoChangeThroughEngine() {
        runAsync("testFinalizeNoChangeThroughEngine") {
            var ops: [ChunkedPipeline.Operation] = []
            let stt: ChunkedPipeline.STTHandler = { _, _, _ in
                ChunkedPipeline.SttResult(text: "Same words here.")
            }
            let outcome = try await ChunkedPipeline.finalize(
                samples: [Int16](repeating: 1, count: 16),
                insertedText: "Same words here.",
                stt: stt,
                insert: { ops.append($0) }
            )
            XCTAssertFalse(outcome.changed)
            XCTAssertTrue(ops.isEmpty)
        }
    }

    /// Engine word-diff offsets arrive as Unicode scalar counts; the typed
    /// change maps them to Swift character boundaries so tails stay valid
    /// when the common prefix holds a multi-scalar grapheme cluster.
    @objc func testWordDiffChangeConvertsScalarOffsetsForCombiningMarks() {
        let old = "e\u{301} foo bar."
        let new = "e\u{301} foo baz."
        let change: WordDiff.Change?
        do {
            change = try RustEngine.wordDiffChange(old: old, new: new)
        } catch {
            XCTFail("wordDiffChange threw: \(error)")
            return
        }
        guard let change else {
            XCTFail("expected a word diff change")
            return
        }
        let expected = WordDiff.change(old: old, new: new)
        XCTAssertNotNil(expected)
        XCTAssertEqual(change.spanOld, "bar.")
        XCTAssertEqual(change.spanNew, "baz.")
        XCTAssertEqual(change.spanStartOld, expected?.spanStartOld)
        XCTAssertEqual(change.spanStartNew, expected?.spanStartNew)
        XCTAssertEqual(change.tailOld, " bar.")
        XCTAssertEqual(change.tailNew, " baz.")
    }

    /// Segment WAV bytes on the wire are engine-encoded (byte-identical to
    /// the reference encoder).
    @objc func testRecognizeSegmentEncodesThroughEngine() {
        runAsync("testRecognizeSegmentEncodesThroughEngine") {
            var captured: Data?
            let stt: ChunkedPipeline.STTHandler = { wav, _, _ in
                captured = wav
                return ChunkedPipeline.SttResult(text: "hi")
            }
            let samples: [Int16] = [0, 1, -1, 32767, -32768]
            _ = try await ChunkedPipeline.recognizeSegment(
                samples: samples,
                index: 0,
                insertedText: "",
                prompt: nil,
                stt: stt
            )
            let reference = WAVEncoder.encode(samples: samples, sampleRate: 16000)
            guard let captured else {
                XCTFail("segment WAV must reach STT")
                return
            }
            XCTAssertEqual(captured, reference, "shipping bytes must equal the reference encoding")
            XCTAssertFalse(captured.isEmpty)
        }
    }

    // MARK: - Chunk text joining on the batch path

    /// BatchTranscriber joins chunk texts through the engine, including the
    /// boundary-overlap dedup and the skipped-chunk placeholder rule.
    @objc func testBatchJoinThroughEngine() {
        runAsync("testBatchJoinThroughEngine") {
            // 12 s of steady tone, 5 s segments without pause alignment:
            // three chunks regardless of content.
            let samples = [Int16](repeating: 1000, count: 16000 * 12)
            let texts = ["hello brave world", "brave world again", "again and more"]
            var index = 0
            let outcome = try await BatchTranscriber.run(
                samples: samples,
                maxSegment: 5,
                overlap: 0,
                providerID: "p",
                sourceFile: "cutover.wav",
                sendOne: { _, _, _, _ in
                    let text = texts[index]
                    index += 1
                    return text
                },
                delay: { _ in },
                maxConcurrent: 1,
                cutAtPauses: false
            )
            XCTAssertEqual(outcome.totalSegments, 3)
            XCTAssertEqual(outcome.text, "hello brave world again and more")
            XCTAssertEqual(outcome.text, BatchTextJoiner.join(texts))
        }
    }

    // MARK: - Transcript parsing on the STT path

    private func makeTranscriber(
        transport: MockTransport, adapterID: String?, baseURL: String = "https://example.test/v1"
    ) -> Transcriber {
        Transcriber(
            baseURL: baseURL,
            model: "m",
            apiKey: "k",
            transport: transport,
            networkChecker: { true },
            adapterID: adapterID)
    }

    /// Flat responses parse through the engine, words included.
    @objc func testTranscriberFlatResponseThroughEngine() {
        let json = #"{"text":"hi there","words":[{"word":"hi","start":0.0,"end":0.2},{"word":"there","start":0.2,"end":0.5}]}"#
        let transport = MockTransport(status: 200, body: Data(json.utf8))
        let transcriber = makeTranscriber(transport: transport, adapterID: "openai")
        runAsync("testTranscriberFlatResponseThroughEngine") {
            let result = try await transcriber.transcribe(wav: Data([0x52, 0x49, 0x46, 0x46]))
            XCTAssertEqual(result.text, "hi there")
            XCTAssertEqual(result.words.count, 2)
            XCTAssertEqual(result.words[0], TimedWord(word: "hi", start: 0.0, end: 0.2))
        }
    }

    /// Nested (Cloudflare-style) responses read text and sibling words
    /// through the engine with the same path contract as the reference.
    @objc func testTranscriberNestedResponseThroughEngine() {
        let json = #"{"result":{"text":"nested ok","words":[{"word":"nested","start":0.0,"end":0.4}]}}"#
        let transport = MockTransport(status: 200, body: Data(json.utf8))
        let transcriber = makeTranscriber(
            transport: transport,
            adapterID: "cloudflare",
            baseURL: "https://api.cloudflare.com/client/v4/accounts/a/ai/run/@cf/openai/whisper")
        runAsync("testTranscriberNestedResponseThroughEngine") {
            let result = try await transcriber.transcribe(wav: Data([0x01, 0x02]))
            XCTAssertEqual(result.text, "nested ok")
            XCTAssertEqual(result.words.count, 1)
            XCTAssertEqual(result.words[0].word, "nested")
        }
    }

    /// Missing text keeps the exact reference error on the shipping path.
    @objc func testTranscriberMissingTextErrorThroughEngine() {
        let transport = MockTransport(status: 200, body: Data(#"{"no_text":"x"}"#.utf8))
        let transcriber = makeTranscriber(transport: transport, adapterID: "openai")
        let expectation = expectation(description: "missing text")
        Task {
            do {
                _ = try await transcriber.transcribe(wav: Data([0x01]))
                XCTFail("Expected invalidResponse")
            } catch let error as TranscribeError {
                if case .invalidResponse(let message) = error {
                    XCTAssertEqual(message, "Missing 'text' field")
                } else {
                    XCTFail("Expected invalidResponse, got \(error)")
                }
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
    }

    // MARK: - Failover ordering and retry/backoff policy

    /// Sequential failover orders through the engine: the last-failed
    /// provider moves to the end with auto-failover on.
    @objc func testFailoverOrderThroughEngine() {
        runAsync("testFailoverOrderThroughEngine") {
            var calls: [String] = []
            let rp = RetryProvider { _, provider in
                calls.append(provider.id)
                if calls.count == 1 {
                    throw TranscribeError.network("fail")
                }
                return TranscriptionResult(text: "recovered", rawData: Data())
            }
            rp.lastFailedProviderID = "a"
            let outcome = try await rp.transcribeWithFailover(
                wav: Data("wav".utf8),
                order: [self.makeProvider(id: "a"), self.makeProvider(id: "b")],
                autoFailover: true
            )
            XCTAssertEqual(calls, ["b", "a"], "engine moves the last-failed provider to the end")
            XCTAssertEqual(outcome.providerID, "a")
        }
    }

    /// Without auto-failover only the first candidate runs (engine count).
    @objc func testFailoverSingleCandidateWithoutAutoFailover() {
        runAsync("testFailoverSingleCandidateWithoutAutoFailover") {
            var calls = 0
            let rp = RetryProvider { _, _ in
                calls += 1
                throw TranscribeError.network("down")
            }
            do {
                _ = try await rp.transcribeWithFailover(
                    wav: Data("wav".utf8),
                    order: [self.makeProvider(id: "a"), self.makeProvider(id: "b")],
                    autoFailover: false
                )
                XCTFail("Expected failure")
            } catch let error as TranscribeError {
                XCTAssertEqual(error, .network("down"))
            }
            XCTAssertEqual(calls, 1, "engine allows exactly one candidate without auto-failover")
        }
    }

    /// Non-provider errors never fail over (engine classification).
    @objc func testFailoverSkipsNonTranscribeErrors() {
        struct MicFailure: Error {}
        runAsync("testFailoverSkipsNonTranscribeErrors") {
            var calls = 0
            let rp = RetryProvider { _, _ in
                calls += 1
                throw MicFailure()
            }
            do {
                _ = try await rp.transcribeWithFailover(
                    wav: Data("wav".utf8),
                    order: [self.makeProvider(id: "a"), self.makeProvider(id: "b")],
                    autoFailover: true
                )
                XCTFail("Expected rethrow")
            } catch is MicFailure {
                // Expected: engine classifies mic errors as non-failover.
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(calls, 1)
        }
    }

    /// The deterministic backoff base matches the engine table; jitter is
    /// the only native addition on top.
    @objc func testBackoffBaseMatchesEngine() {
        for attempt in 0...6 {
            let expected = Double(RustEngine.retryBackoffBaseMs(attempt: UInt32(attempt))) / 1000.0
            XCTAssertEqual(
                Transcriber.backoffDelay(beforeRetry: attempt, jitter: 0), expected,
                "deterministic base for attempt \(attempt)")
        }
        XCTAssertEqual(Transcriber.backoffDelay(beforeRetry: 1, jitter: 0), 1.0)
        XCTAssertEqual(Transcriber.backoffDelay(beforeRetry: 2, jitter: 0), 2.0)
        XCTAssertEqual(
            RustEngine.retryBackoffBaseMs(attempt: 4, baseMs: 500, capMs: 8000), 8000)
    }

    // MARK: - Review decision

    /// ReviewGate.confirm decides through the engine for every input class.
    @objc func testReviewConfirmThroughEngine() {
        let vectors: [(line: String?, expected: ReviewGate.Decision)] = [
            ("", .insert), ("  ", .insert), ("y", .insert), ("Y", .insert),
            ("n", .cancel), ("nope", .cancel), (nil, .cancel),
        ]
        for vector in vectors {
            ReviewGate.readLineFunction = { vector.line }
            XCTAssertEqual(
                ReviewGate.confirm(text: "cutover"),
                vector.expected,
                "review decision for \(String(describing: vector.line))")
        }
        ReviewGate.readLineFunction = { readLine() }
    }

    // MARK: - Model/profile resolution and portable defaults

    /// The shipping request-planning entry points resolve through the
    /// engine with the same semantics as the reference registry.
    @objc func testProfileResolutionThroughEngine() {
        let modern = ProviderRequestBuilder.profile(adapterID: "openai", model: "gpt-transcribe")
        XCTAssertEqual(modern.capabilities.languageHint, .multi)
        XCTAssertFalse(modern.capabilities.supportsTemperature)
        XCTAssertTrue(modern.capabilities.supportsPrompt)
        XCTAssertTrue(modern.audio.supportedUploadFormats.contains(.flac))

        let whisper = ProviderRequestBuilder.profile(adapterID: "openai", model: "whisper-1")
        XCTAssertTrue(whisper.capabilities.supportsWordTimestamps)
        XCTAssertEqual(whisper.capabilities.languageHint, .single)

        let groq = ProviderRequestBuilder.profile(
            adapterID: "groq", model: "whisper-large-v3-turbo")
        XCTAssertTrue(groq.capabilities.supportsVadFilter)
        XCTAssertTrue(groq.capabilities.supportsServerVAD)

        let cloudflare = ProviderRequestBuilder.profile(adapterID: "cloudflare", model: "")
        XCTAssertEqual(cloudflare.capabilities.transport, .batchRawAudio)
        XCTAssertEqual(cloudflare.transcriptPath, ["result", "text"])

        // Portable configuration defaults shared with the Windows host.
        XCTAssertEqual(ProviderRequestBuilder.resolveModel("", for: "openai"), "gpt-transcribe")
        XCTAssertEqual(
            ProviderRequestBuilder.resolveBaseURL("", for: "openai"),
            "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(ProviderRequestBuilder.resolveModel("", for: "cloudflare"), "")
        XCTAssertEqual(ProviderRequestBuilder.resolveModel("custom-m", for: "openai"), "custom-m")
    }

    /// Engine-resolved profiles equal the reference registry on the full
    /// vector (parity retained on the production entry point).
    @objc func testEngineProfilesMatchReferenceRegistry() {
        let vectors: [(adapter: String, model: String)] = [
            ("openai", "whisper-1"),
            ("openai", "gpt-transcribe"),
            ("openai", "  GPT-TRANSCRIBE-2026-01-01 "),
            ("openai", "gpt-4o-mini-transcribe"),
            ("openai", "some-future-model"),
            ("openai", ""),
            ("groq", "whisper-large-v3-turbo"),
            ("groq", "some-future-model"),
            ("cloudflare", "anything"),
            ("my-custom-provider", "my-model"),
        ]
        for vector in vectors {
            let resolved = ProviderRequestBuilder.resolveModel(
                vector.model, for: vector.adapter)
            let engine = RustEngine.requireSTTProfile(
                adapterID: vector.adapter, model: resolved)
            let reference = STTModelRegistry.resolve(
                adapterID: vector.adapter, model: resolved)
            XCTAssertEqual(engine, reference, "profile parity for \(vector)")
        }
    }

    // MARK: - WAV file source header

    /// The file-backed batch source parses its header through the engine.
    @objc func testBatchFileSourceHeaderThroughEngine() {
        let samples: [Int16] = [0, 1000, -1000, 32767, -32768]
        let wav = RustEngine.requireWAVEncode(samples: samples)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cutover-\(UUID().uuidString).wav")
        do {
            try wav.write(to: url)
            let content = try WAVFilePCMBatchContent(wavURL: url)
            XCTAssertEqual(content.sampleRate, 16000)
            XCTAssertEqual(content.sampleCount, samples.count)
            let decoded = try content.readSamples(0..<samples.count)
            XCTAssertEqual(decoded, samples)
            try? FileManager.default.removeItem(at: url)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    /// Non-WAV input stays a product-level invalidWAV on the shipping path.
    @objc func testBatchFileSourceRejectsNonWAVThroughEngine() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cutover-\(UUID().uuidString).wav")
        do {
            try Data("definitely not a wav file, far too short!!".utf8).write(to: url)
            XCTAssertThrowsError(try WAVFilePCMBatchContent(wavURL: url)) { error in
                guard let wavError = error as? WAVFilePCMBatchContent.WAVFileError else {
                    XCTFail("expected WAVFileError, got \(error)")
                    return
                }
                XCTAssertEqual(wavError, .invalidWAV)
            }
            try? FileManager.default.removeItem(at: url)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }
}
