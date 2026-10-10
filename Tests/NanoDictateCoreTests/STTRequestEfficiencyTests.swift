import Foundation
@testable import NanoDictateCore

// MARK: - STTRequestEfficiencyTests (issue #32)
//
// Timestamp on/off, response-format capability gating, single-parse response
// decoding, copy-minimized/file-backed multipart bodies, retry determinism
// and near-60-second request-body memory accounting. Deterministic, no
// network.

// Records every request body for retry-determinism checks. The production
// file-backed path only triggers without an injected transport, so mock
// requests always carry the in-memory `httpBody` asserted here.
final class STTEfficiencyRecordingTransport: HTTPTransport, @unchecked Sendable {
    var status: Int
    var body: Data
    var sendError: Error?
    var failCount: Int = 0
    private(set) var bodies: [Data] = []
    private(set) var requestCount = 0

    init(status: Int, body: Data, sendError: Error? = nil) {
        self.status = status
        self.body = body
        self.sendError = sendError
    }

    func send(request: URLRequest) async throws -> (status: Int, body: Data, headers: [String: String]) {
        requestCount += 1
        bodies.append(request.httpBody ?? Data())
        if failCount > 0 {
            failCount -= 1
            if let err = sendError {
                if failCount == 0 { sendError = nil }
                throw err
            }
        } else if let sendError = sendError {
            throw sendError
        }
        return (status, body, [:])
    }
}

final class STTRequestEfficiencyTests: XCTestCase {

    private let wav = Data([0x52, 0x49, 0x46, 0x46, 0x01, 0x02, 0x03, 0x04])

    private func runAsync(_ name: String, _ body: @escaping () async throws -> Void) {
        let expectation = expectation(description: name)
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

    private func readAll(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            out.append(contentsOf: buffer.prefix(count))
        }
        return out
    }

    // MARK: - Timestamp decision (single-request plain, segments gated)

    @objc func testTimestampDecisionDefaultsToPlain() {
        let caps = ProviderRequestBuilder.capabilities(adapterID: "openai", model: "whisper-1")
        XCTAssertTrue(caps.supportsVerboseJSON)
        XCTAssertTrue(caps.supportsWordTimestamps)
        let decision = STTTimestampRequest.resolve(needsWordTimestamps: false, capabilities: caps)
        XCTAssertNil(decision.responseFormat)
        XCTAssertTrue(decision.granularities.isEmpty)
    }

    @objc func testTimestampDecisionWhisperRequestsVerboseAndWord() {
        let caps = ProviderRequestBuilder.capabilities(adapterID: "openai", model: "whisper-1")
        let decision = STTTimestampRequest.resolve(needsWordTimestamps: true, capabilities: caps)
        XCTAssertEqual(decision.responseFormat, "verbose_json")
        XCTAssertEqual(decision.granularities, ["word"])
    }

    @objc func testTimestampDecisionGroqOmitsWordGranularities() {
        // Groq accepts verbose_json but rejects timestamp_granularities[]
        // with HTTP 400: the two flags stay independent.
        let caps = ProviderRequestBuilder.capabilities(adapterID: "groq", model: "whisper-large-v3")
        XCTAssertTrue(caps.supportsVerboseJSON)
        XCTAssertFalse(caps.supportsWordTimestamps)
        let decision = STTTimestampRequest.resolve(needsWordTimestamps: true, capabilities: caps)
        XCTAssertEqual(decision.responseFormat, "verbose_json")
        XCTAssertTrue(decision.granularities.isEmpty)
    }

    @objc func testTimestampDecisionModernAndFallbackRequestNothing() {
        for (adapterID, model) in [
            ("openai", "gpt-transcribe"),
            ("openai", "some-future-model"),
            ("groq", "some-future-model"),
            ("my-endpoint", "some-model"),
            ("cloudflare", "whisper-large-v3-turbo"),
        ] as [(String, String)] {
            let caps = ProviderRequestBuilder.capabilities(adapterID: adapterID, model: model)
            let decision = STTTimestampRequest.resolve(needsWordTimestamps: true, capabilities: caps)
            XCTAssertNil(decision.responseFormat, "\(adapterID)/\(model) must not receive verbose_json")
            XCTAssertTrue(decision.granularities.isEmpty, "\(adapterID)/\(model) must not receive granularities")
        }
    }

    // MARK: - Plan-level gating for every built-in backend

    @objc func testPlanTimestampGatingPerBackend() {
        // (adapterID, model, expectsVerbose, expectsWordGranularity)
        let cases: [(String, String, Bool, Bool)] = [
            ("openai", "whisper-1", true, true),
            ("openai", "gpt-transcribe", false, false),
            ("openai", "gpt-4o-transcribe", false, false),
            ("openai", "some-future-model", false, false),
            ("groq", "whisper-large-v3", true, false),
            ("groq", "some-future-model", false, false),
            ("my-endpoint", "some-model", false, false),
        ]
        for (adapterID, model, verbose, word) in cases {
            let plain = ProviderRequestBuilder.plan(
                adapterID: adapterID, baseURL: "https://example.test/v1/audio/transcriptions",
                model: model, apiKey: "k", language: "ru", wav: wav,
                needsWordTimestamps: false)
            guard case .multipart(let plainData, _) = plain.body else {
                XCTFail("\(adapterID)/\(model) must be multipart")
                continue
            }
            let plainText = String(data: plainData, encoding: .utf8) ?? ""
            XCTAssertFalse(
                plainText.contains("response_format"),
                "normal single-request \(adapterID)/\(model) sends plain transcription")
            XCTAssertFalse(
                plainText.contains("timestamp_granularities"),
                "normal single-request \(adapterID)/\(model) sends plain transcription")

            let stamped = ProviderRequestBuilder.plan(
                adapterID: adapterID, baseURL: "https://example.test/v1/audio/transcriptions",
                model: model, apiKey: "k", language: "ru", wav: wav,
                needsWordTimestamps: true)
            guard case .multipart(let stampedData, _) = stamped.body else {
                XCTFail("\(adapterID)/\(model) must be multipart")
                continue
            }
            let stampedText = String(data: stampedData, encoding: .utf8) ?? ""
            XCTAssertEqual(
                stampedText.contains("name=\"response_format\"\r\n\r\nverbose_json\r\n"), verbose,
                "\(adapterID)/\(model) verbose_json gating")
            XCTAssertEqual(
                stampedText.contains("name=\"timestamp_granularities[]\"\r\n\r\nword\r\n"), word,
                "\(adapterID)/\(model) word granularity gating")
        }
    }

    @objc func testPlanCloudflareStaysRawAudio() {
        let spec = ProviderRequestBuilder.plan(
            adapterID: "cloudflare",
            baseURL: "https://example.test/ai/run/@cf/openai/whisper-large-v3-turbo",
            model: "", apiKey: "k", language: "ru", wav: wav, needsWordTimestamps: true)
        guard case .rawAudio(let data, _) = spec.body else {
            XCTFail("cloudflare must stay raw audio")
            return
        }
        XCTAssertEqual(data, wav, "raw audio body holds the payload once, no duplication")
        XCTAssertNil(ProviderRequestBuilder.planFileBacked(
            adapterID: "cloudflare",
            baseURL: "https://example.test/ai/run/@cf/openai/whisper-large-v3-turbo",
            model: "", apiKey: "k", language: "ru", wav: wav, needsWordTimestamps: true),
            "raw-audio profiles have no file-backed multipart representation")
    }

    @objc func testPlanRealtimeHasNoBatchRepresentation() {
        let spec = ProviderRequestBuilder.plan(
            adapterID: "openai", baseURL: "", model: "gpt-live-transcribe",
            apiKey: "k", language: "", wav: wav, needsWordTimestamps: true)
        XCTAssertNil(spec.url)
        XCTAssertNil(ProviderRequestBuilder.planFileBacked(
            adapterID: "openai", baseURL: "", model: "gpt-live-transcribe",
            apiKey: "k", language: "", wav: wav, needsWordTimestamps: true),
            "streaming profiles have no batch upload representation")
    }

    // MARK: - Single-parse response decoding

    @objc func testDecodeParsesOnceIntoTextAndWords() {
        let body = Data(#"{"text":"hello world","words":[{"word":"hello","start":0.0,"end":0.4},{"word":"world","start":0.4,"end":0.9}]}"#.utf8)
        guard let decoded = try? STTResponseDecoder.decode(body: body, path: nil) else {
            XCTFail("decode must succeed")
            return
        }
        XCTAssertEqual(decoded.text, "hello world")
        XCTAssertEqual(decoded.words, [
            TimedWord(word: "hello", start: 0.0, end: 0.4),
            TimedWord(word: "world", start: 0.4, end: 0.9),
        ])
        // Legacy entry points agree with the single-parse result.
        XCTAssertEqual(
            try? ProviderRequestBuilder.extractText(from: body, path: nil), Optional(decoded.text))
        XCTAssertEqual(ProviderRequestBuilder.extractWords(from: body, path: nil), decoded.words)
    }

    @objc func testDecodeErrorMessagesMatchLegacyContract() {
        XCTAssertThrowsError(try STTResponseDecoder.decode(body: Data("not json".utf8), path: nil)) { error in
            guard case TranscribeError.invalidResponse(let message) = error else {
                XCTFail("expected invalidResponse, got \(error)")
                return
            }
            XCTAssertEqual(message, "Response is not a JSON object")
        }
        XCTAssertThrowsError(try STTResponseDecoder.decode(body: Data(#"{"words":[]}"#.utf8), path: nil)) { error in
            guard case TranscribeError.invalidResponse(let message) = error else {
                XCTFail("expected invalidResponse, got \(error)")
                return
            }
            XCTAssertEqual(message, "Missing 'text' field")
        }
        let cf = Data(#"{"result":{}}"#.utf8)
        XCTAssertThrowsError(try STTResponseDecoder.decode(body: cf, path: ["result", "text"])) { error in
            guard case TranscribeError.invalidResponse(let message) = error else {
                XCTFail("expected invalidResponse, got \(error)")
                return
            }
            XCTAssertEqual(message, "Missing 'result.text' field")
        }
        // Cloudflare path decodes text next to the words array in one parse.
        let cfBody = Data(#"{"result":{"text":"hi","words":[{"word":"hi","start":0.0,"end":0.2}]}}"#.utf8)
        guard let decoded = try? STTResponseDecoder.decode(body: cfBody, path: ["result", "text"]) else {
            XCTFail("cloudflare decode must succeed")
            return
        }
        XCTAssertEqual(decoded.text, "hi")
        XCTAssertEqual(decoded.words, [TimedWord(word: "hi", start: 0.0, end: 0.2)])
    }

    @objc func testDecodeSkipsBrokenWordEntries() {
        let body = Data(#"{"text":"a b","words":[{"word":"a","start":0.0,"end":0.1},{"punctuated_word":"b!","start":0.1,"end":0.2},{"word":"broken"}]}"#.utf8)
        guard let decoded = try? STTResponseDecoder.decode(body: body, path: nil) else {
            XCTFail("decode must succeed")
            return
        }
        XCTAssertEqual(decoded.words.map { $0.word }, ["a", "b!"])
    }

    // MARK: - Copy-minimized multipart is byte-identical to file-backed

    @objc func testFileBackedBodyMatchesInMemoryBody() {
        let boundary = "Boundary-test-issue-32"
        let audio = Data("RIFF-audio-payload".utf8)
        let stable = BatchStableMultipartFields(temperature: 0)
        let memory = ProviderRequestBuilder.multipartBody(
            wav: audio, filename: "audio.wav", model: "whisper-1", language: "ru",
            prompt: "context", boundary: boundary, languages: [],
            responseFormat: "verbose_json", timestampGranularities: ["word"],
            stable: stable, audioContentType: STTUploadFormat.wav.contentType)
        guard let file = try? MultipartFileUpload.write(
            audio: audio, filename: "audio.wav", model: "whisper-1", language: "ru",
            prompt: "context", boundary: boundary, languages: [],
            responseFormat: "verbose_json", timestampGranularities: ["word"],
            stable: stable, audioContentType: STTUploadFormat.wav.contentType)
        else {
            XCTFail("file-backed write must succeed")
            return
        }
        defer { MultipartFileUpload.cleanup(fileURL: file.fileURL) }
        XCTAssertEqual(file.byteCount, memory.count)
        XCTAssertEqual(file.contentType, "multipart/form-data; boundary=\(boundary)")
        guard let fileBody = try? MultipartFileUpload.readBody(fileURL: file.fileURL) else {
            XCTFail("file-backed read must succeed")
            return
        }
        XCTAssertEqual(fileBody, memory, "streaming write must be byte-identical to the Data builder")
        // Repeatable streams: two fresh streams read identical bytes.
        guard let first = MultipartFileUpload.makeBodyStream(fileURL: file.fileURL),
              let second = MultipartFileUpload.makeBodyStream(fileURL: file.fileURL)
        else {
            XCTFail("body streams must open")
            return
        }
        XCTAssertEqual(readAll(first), memory)
        XCTAssertEqual(readAll(second), memory)
        MultipartFileUpload.cleanup(fileURL: file.fileURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.fileURL.path), "cleanup removes the temp file")
    }

    @objc func testPlanFileBackedMirrorsPlanMetadata() {
        let baseURL = "https://example.test/v1/audio/transcriptions"
        let spec = ProviderRequestBuilder.plan(
            adapterID: "openai", baseURL: baseURL, model: "whisper-1", apiKey: "k",
            language: "ru", wav: wav, filename: "audio.wav", prompt: "context",
            needsWordTimestamps: true)
        guard let fileBacked = ProviderRequestBuilder.planFileBacked(
            adapterID: "openai", baseURL: baseURL, model: "whisper-1", apiKey: "k",
            language: "ru", wav: wav, filename: "audio.wav", prompt: "context",
            needsWordTimestamps: true)
        else {
            XCTFail("file-backed plan must succeed for batch multipart profiles")
            return
        }
        defer { MultipartFileUpload.cleanup(fileURL: fileBacked.upload.fileURL) }
        XCTAssertEqual(fileBacked.url, spec.url)
        XCTAssertEqual(fileBacked.headers.map { $0.0 }, spec.headers.map { $0.0 })
        XCTAssertEqual(fileBacked.transcriptPath, spec.transcriptPath)
        XCTAssertEqual(fileBacked.filePartFilename, spec.filePartFilename)
        XCTAssertEqual(fileBacked.filePartContentType, spec.filePartContentType)
        XCTAssertEqual(fileBacked.filePartByteCount, wav.count)
        guard let fileBody = try? MultipartFileUpload.readBody(fileURL: fileBacked.upload.fileURL) else {
            XCTFail("file-backed read must succeed")
            return
        }
        let fileText = String(data: fileBody, encoding: .utf8) ?? ""
        XCTAssertTrue(fileText.contains("name=\"response_format\"\r\n\r\nverbose_json\r\n"))
        XCTAssertTrue(fileText.contains("name=\"timestamp_granularities[]\"\r\n\r\nword\r\n"))
        XCTAssertEqual(
            fileBacked.memoryReport(audioBytes: wav.count).strategy, STTUploadStrategy.fileBacked)
        XCTAssertEqual(
            spec.memoryReport(audioBytes: wav.count).strategy, STTUploadStrategy.inMemory)
    }

    // MARK: - Retry determinism (repeatable bodies)

    @objc func testRetryResendsIdenticalBody() {
        let transport = STTEfficiencyRecordingTransport(
            status: 200, body: Data(#"{"text":"ok"}"#.utf8),
            sendError: URLError(.cannotConnectToHost))
        transport.failCount = 1
        let transcriber = Transcriber(
            baseURL: "https://example.test/v1/audio/transcriptions",
            model: "whisper-1", apiKey: "k", transport: transport,
            networkChecker: { true }, adapterID: "openai",
            retrySleep: { _ in })
        runAsync("testRetryResendsIdenticalBody") {
            let result = try await transcriber.transcribe(wav: self.wav)
            XCTAssertEqual(result.text, "ok")
        }
        XCTAssertEqual(transport.requestCount, 2, "one retry after the transport failure")
        XCTAssertEqual(transport.bodies.count, 2)
        if transport.bodies.count == 2 {
            XCTAssertEqual(transport.bodies[0], transport.bodies[1], "retry repeats the identical body")
            XCTAssertFalse(transport.bodies[0].isEmpty)
        }
    }

    @objc func testMockTransportKeepsInMemoryBodyAboveThreshold() {
        // Even a body larger than the file-backed threshold stays in-memory
        // when a transport is injected: mocks assert on httpBody, and only
        // the real network path streams from disk.
        let large = Data(repeating: 0x41, count: 300_000)
        XCTAssertGreaterThan(
            large.count, Transcriber.fileBackedUploadThresholdBytes / 2,
            "fixture must be large enough to be meaningful")
        let transport = STTEfficiencyRecordingTransport(
            status: 200, body: Data(#"{"text":"ok"}"#.utf8))
        let transcriber = Transcriber(
            baseURL: "https://example.test/v1/audio/transcriptions",
            model: "whisper-1", apiKey: "k", transport: transport,
            networkChecker: { true }, adapterID: "openai",
            retrySleep: { _ in })
        runAsync("testMockTransportKeepsInMemoryBodyAboveThreshold") {
            _ = try await transcriber.transcribe(wav: large)
        }
        XCTAssertEqual(transport.requestCount, 1)
        XCTAssertEqual(transport.bodies.first?.count ?? 0,
                       ProviderRequestBuilder.plan(
                           adapterID: "openai",
                           baseURL: "https://example.test/v1/audio/transcriptions",
                           model: "whisper-1", apiKey: "k", language: "",
                           wav: large).bodyData.count)
        let bodyText = String(data: transport.bodies.first ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(bodyText.contains("response_format"), "single request stays plain")
    }

    // MARK: - Memory accounting

    @objc func testMemoryReportStrategies() {
        let inMemory = STTRequestMemoryReport(audioBytes: 100, bodyBytes: 150, strategy: .inMemory)
        XCTAssertEqual(inMemory.overheadBytes, 50)
        XCTAssertEqual(inMemory.duplicationRatio, 1.5)
        XCTAssertEqual(inMemory.peakTransientBytes, 250)
        let fileBacked = STTRequestMemoryReport(audioBytes: 100, bodyBytes: 150, strategy: .fileBacked)
        XCTAssertEqual(fileBacked.peakTransientBytes, 100 + 64 * 1_024)
        // The 64 KiB streaming buffer dominates tiny payloads by design, so
        // small bodies stay in-memory below the production file-backed
        // threshold (no temp-file churn). At production scale (at or above
        // the threshold) the file-backed peak is strictly smaller.
        let largeAudio = Transcriber.fileBackedUploadThresholdBytes * 4
        let largeBody = largeAudio + 512
        let largeInMemory = STTRequestMemoryReport(
            audioBytes: largeAudio, bodyBytes: largeBody, strategy: .inMemory)
        let largeFileBacked = STTRequestMemoryReport(
            audioBytes: largeAudio, bodyBytes: largeBody, strategy: .fileBacked)
        XCTAssertEqual(largeInMemory.peakTransientBytes, largeAudio + largeBody)
        XCTAssertEqual(largeFileBacked.peakTransientBytes, largeAudio + 64 * 1_024)
        XCTAssertTrue(largeFileBacked.peakTransientBytes < largeInMemory.peakTransientBytes)
    }

    @objc func testNear60SecondRequestMemory() {
        guard let long = BenchmarkFixtures.builtins().first(where: { $0.durationBucket == .long }) else {
            XCTFail("long fixture required")
            return
        }
        XCTAssertGreaterThanOrEqual(long.durationSeconds, 50)
        XCTAssertLessThanOrEqual(long.durationSeconds, 65)
        let config = BenchmarkSTTConfig(name: "memory", adapterID: "openai", model: "whisper-1")
        let rows = BenchmarkRunner.requestMemoryRows(fixtures: [long], config: config)
        XCTAssertEqual(rows.count, 1)
        guard let row = rows.first else { return }
        XCTAssertEqual(row.audioBytes, 55 * 16_000 * 2 + 44, "55 s 16 kHz mono PCM16 WAV")
        XCTAssertGreaterThan(row.bodyBytes, row.audioBytes)
        XCTAssertLessThan(row.overheadBytes, 8 * 1_024, "multipart framing stays small")
        XCTAssertLessThan(row.duplicationRatio, 1.01, "no meaningful audio-body duplication")
        XCTAssertEqual(row.strategy, STTUploadStrategy.fileBacked.rawValue,
                       "near-60-second production request uploads file-backed")
        XCTAssertGreaterThan(row.peakInMemoryBytes, row.peakFileBackedBytes)
        XCTAssertTrue(STTRequestMemoryRow.markdown([row]).contains(long.id))
        // Short fixtures stay in-memory: no temp-file churn per utterance.
        let short = BenchmarkFixtures.builtins().filter { $0.durationBucket == .short }
        let shortRows = BenchmarkRunner.requestMemoryRows(fixtures: short, config: config)
        XCTAssertFalse(shortRows.isEmpty)
        for shortRow in shortRows {
            XCTAssertEqual(shortRow.strategy, STTUploadStrategy.inMemory.rawValue)
            XCTAssertLessThan(shortRow.duplicationRatio, 1.5)
        }
    }
}
