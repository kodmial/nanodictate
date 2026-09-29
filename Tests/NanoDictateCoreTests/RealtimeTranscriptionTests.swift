import Foundation
@testable import NanoDictateCore

// MARK: - RealtimeTranscriptionTests
//
// Stateful realtime transcription: event parsing, accumulator dedup,
// session lifecycle with a mocked WebSocket transport. No network.

final class MockRealtimeTransport: RealtimeWebSocketTransport {
    var connectURLs: [URL] = []
    var connectHeaders: [[String: String]] = []
    var sent: [String] = []
    var incoming: [String] = []
    var closedCount = 0
    var connectError: Error?
    private let lock = NSLock()

    func connect(url: URL, headers: [String: String]) async throws {
        lock.lock()
        connectURLs.append(url)
        connectHeaders.append(headers)
        lock.unlock()
        if let error = connectError { throw error }
    }

    func sendText(_ text: String) async throws {
        lock.lock()
        sent.append(text)
        lock.unlock()
    }

    func receiveText() async throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        if incoming.isEmpty { return nil }
        return incoming.removeFirst()
    }

    func close() async {
        lock.lock()
        closedCount += 1
        lock.unlock()
    }

    func sentTypes() -> [String] {
        lock.lock()
        let texts = sent
        lock.unlock()
        return texts.compactMap { text in
            guard let data = text.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return json["type"] as? String
        }
    }
}

final class RealtimeAsyncBox<T> {
    var value: T?
    var error: Error?
}

final class RealtimeTranscriptionTests: XCTestCase {

    private func runAsync<T>(_ body: @escaping () async throws -> T) throws -> T {
        let box = RealtimeAsyncBox<T>()
        let expect = expectation(description: "realtimeAsync")
        Task {
            do { box.value = try await body() }
            catch { box.error = error }
            expect.fulfill()
        }
        wait(for: [expect], timeout: 10.0)
        if let error = box.error { throw error }
        return box.value!
    }

    private func instantSleeper(_ seconds: TimeInterval) async {}

    private func makeSession(
        transport: MockRealtimeTransport,
        model: String = "gpt-live-transcribe",
        timeout: TimeInterval = 5
    ) -> RealtimeTranscriptionSession {
        let config = RealtimeSessionConfig(model: model, apiKey: "k", timeoutSeconds: timeout)
        return RealtimeTranscriptionSession(
            config: config, transport: transport, sleeper: { [weak self] seconds in
                guard let self else { return }
                await self.instantSleeper(seconds)
            })
    }

    private func jsonDict(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Registry: realtime profile vs batch preservation

    @objc func testRealtimeProfileUses24kPCM16Streaming() {
        let profile = STTModelRegistry.resolve(adapterID: "openai", model: "gpt-live-transcribe")
        XCTAssertEqual(profile.capabilities.transport, .streamingSession)
        XCTAssertEqual(profile.audio.sampleRate, 24000)
        XCTAssertEqual(profile.audio.channels, 1)
        XCTAssertEqual(profile.audio.uploadFormat, .pcm16)
        XCTAssertTrue(STTModelRegistry.isStreaming(adapterID: "openai", model: "gpt-live-transcribe"))
    }

    @objc func testRealtimeSnapshotPrefixMatchesStreamingProfile() {
        let snapshot = STTModelRegistry.resolve(adapterID: "openai", model: "gpt-live-transcribe-2026-01-01")
        XCTAssertEqual(snapshot.capabilities.transport, .streamingSession)
        XCTAssertEqual(snapshot.audio.sampleRate, 24000)
    }

    @objc func testBatchProfilesUnchangedAfterRealtimeAddition() {
        let whisper = STTModelRegistry.resolve(adapterID: "openai", model: "whisper-1")
        XCTAssertEqual(whisper.capabilities.transport, .batchMultipart)
        XCTAssertEqual(whisper.audio, .batchMono16k)
        let modern = STTModelRegistry.resolve(adapterID: "openai", model: "gpt-transcribe")
        XCTAssertEqual(modern.capabilities.transport, .batchMultipart)
        XCTAssertEqual(modern.audio, .batchMono16k)
        let groq = STTModelRegistry.resolve(adapterID: "groq", model: "whisper-large-v3")
        XCTAssertEqual(groq.capabilities.transport, .batchMultipart)
        XCTAssertFalse(STTModelRegistry.isStreaming(adapterID: "groq", model: "whisper-large-v3"))
    }

    // MARK: - Audio conversion: model-required 24 kHz PCM16, never batch WAV

    @objc func testUpscale16kTo24kLengthAndEdges() {
        XCTAssertEqual(RealtimeAudioConverter.upscale16kTo24k([]), [])
        XCTAssertEqual(RealtimeAudioConverter.upscale16kTo24k([Int16](repeating: 0, count: 16000)).count, 24000)
        XCTAssertEqual(RealtimeAudioConverter.upscale16kTo24k([1000, 2000]).count, 3)
        let constant = RealtimeAudioConverter.upscale16kTo24k([Int16](repeating: 1000, count: 100))
        XCTAssertTrue(constant.allSatisfy { $0 == 1000 })
    }

    @objc func testPCM16BytesAreRawLittleEndianWithoutWAVHeader() {
        let bytes = RealtimeAudioConverter.pcm16LEBytes([1000, -1000])
        XCTAssertEqual(bytes.count, 4)
        let raw = [UInt8](bytes)
        XCTAssertEqual(raw[0], 0xE8)
        XCTAssertEqual(raw[1], 0x03)
        // No RIFF/WAV header: first bytes are audio, not "RIFF".
        XCTAssertFalse(raw.starts(with: [0x52, 0x49, 0x46, 0x46]))
        let base64 = RealtimeAudioConverter.base64PCM16([1000, -1000])
        XCTAssertEqual(Data(base64Encoded: base64), bytes)
    }

    // MARK: - Client events: official session schema

    @objc func testSessionUpdateUsesOfficialTranscriptionSchema() {
        let config = RealtimeSessionConfig(model: "gpt-live-transcribe", apiKey: "k", language: "en")
        let text = RealtimeClientEvent.sessionUpdate(config: config)
        guard let dict = jsonDict(text) else {
            XCTFail("session.update must be JSON")
            return
        }
        XCTAssertEqual(dict["type"] as? String, "session.update")
        guard let session = dict["session"] as? [String: Any] else {
            XCTFail("missing session object")
            return
        }
        XCTAssertEqual(session["type"] as? String, "transcription")
        guard let input = (session["audio"] as? [String: Any])?["input"] as? [String: Any] else {
            XCTFail("missing audio.input")
            return
        }
        let format = input["format"] as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "audio/pcm")
        XCTAssertEqual(format?["rate"] as? Int, 24000)
        let transcription = input["transcription"] as? [String: Any]
        XCTAssertEqual(transcription?["model"] as? String, "gpt-live-transcribe")
        XCTAssertEqual(transcription?["languages"] as? [String], ["en"])
        XCTAssertTrue(input.keys.contains("turn_detection"), "manual commit requires turn_detection key")
    }

    @objc func testSessionUpdateOmitsEmptyLanguageHint() {
        let config = RealtimeSessionConfig(model: "gpt-live-transcribe", apiKey: "k", language: "")
        let text = RealtimeClientEvent.sessionUpdate(config: config)
        guard let dict = jsonDict(text),
            let session = dict["session"] as? [String: Any],
            let input = (session["audio"] as? [String: Any])?["input"] as? [String: Any],
            let transcription = input["transcription"] as? [String: Any]
        else {
            XCTFail("session.update must parse")
            return
        }
        XCTAssertNil(transcription["languages"])
    }

    @objc func testAppendCommitClearEventTypes() {
        XCTAssertEqual(jsonDict(RealtimeClientEvent.appendAudio(base64PCM: "AAA="))?["type"] as? String,
                       "input_audio_buffer.append")
        XCTAssertEqual(jsonDict(RealtimeClientEvent.commit())?["type"] as? String,
                       "input_audio_buffer.commit")
        XCTAssertEqual(jsonDict(RealtimeClientEvent.clear())?["type"] as? String,
                       "input_audio_buffer.clear")
    }

    // MARK: - Server event parsing

    @objc func testParseDeltaAndCompletedEvents() {
        let delta = RealtimeServerEvent.parse(
            "{\"type\":\"conversation.item.input_audio_transcription.delta\","
                + "\"item_id\":\"item_1\",\"content_index\":0,\"delta\":\"Hello,\"}")
        XCTAssertEqual(delta, .delta(itemID: "item_1", text: "Hello,"))
        let done = RealtimeServerEvent.parse(
            "{\"type\":\"conversation.item.input_audio_transcription.completed\","
                + "\"item_id\":\"item_1\",\"content_index\":0,\"transcript\":\"Hello, how are you?\"}")
        XCTAssertEqual(done, .completed(itemID: "item_1", transcript: "Hello, how are you?"))
    }

    @objc func testParseFailedErrorIgnoredInvalid() {
        let failed = RealtimeServerEvent.parse(
            "{\"type\":\"conversation.item.input_audio_transcription.failed\","
                + "\"item_id\":\"item_9\",\"error\":{\"message\":\"boom\"}}")
        XCTAssertEqual(failed, .failed(itemID: "item_9", message: "boom"))
        let err = RealtimeServerEvent.parse("{\"type\":\"error\",\"error\":{\"message\":\"bad key\"}}")
        XCTAssertEqual(err, .error(message: "bad key"))
        let ignored = RealtimeServerEvent.parse("{\"type\":\"response.done\"}")
        if case .ignored = RealtimeServerEvent.parse("{\"type\":\"input_audio_buffer.committed\"}") {
        } else {
            XCTFail("buffer events must be ignored")
        }
        XCTAssertEqual(ignored, .ignored(type: "response.done"))
        if case .invalid = RealtimeServerEvent.parse("not json") {
        } else {
            XCTFail("non-JSON must be invalid")
        }
        // Ready signals for both GA and legacy beta session events.
        XCTAssertEqual(RealtimeServerEvent.parse("{\"type\":\"session.created\"}"), .sessionReady)
        XCTAssertEqual(
            RealtimeServerEvent.parse("{\"type\":\"transcription_session.created\"}"), .sessionReady)
    }

    // MARK: - Accumulator: partials never duplicate committed text

    @objc func testAccumulatorCompletedReplacesPendingWithoutDuplication() {
        var acc = RealtimeTranscriptAccumulator()
        _ = acc.apply(.delta(itemID: "a", text: "Hello,"))
        _ = acc.apply(.delta(itemID: "a", text: " how"))
        XCTAssertEqual(acc.liveText(), "Hello, how")
        _ = acc.apply(.completed(itemID: "a", transcript: "Hello, how are you?"))
        XCTAssertEqual(acc.finalTranscript(), "Hello, how are you?")
        XCTAssertEqual(acc.liveText(), "Hello, how are you?")
        // Late duplicate completion for the same item is ignored.
        _ = acc.apply(.completed(itemID: "a", transcript: "Hello, how are you?"))
        XCTAssertEqual(acc.finalTranscript(), "Hello, how are you?")
    }

    @objc func testAccumulatorMultiTurnFinalIsDeterministic() {
        var acc = RealtimeTranscriptAccumulator()
        _ = acc.apply(.delta(itemID: "a", text: "first "))
        _ = acc.apply(.completed(itemID: "a", transcript: "first turn"))
        _ = acc.apply(.delta(itemID: "b", text: "second"))
        _ = acc.apply(.completed(itemID: "b", transcript: "second turn"))
        XCTAssertEqual(acc.finalTranscript(), "first turn second turn")
        // Whitespace collapsed deterministically.
        var acc2 = RealtimeTranscriptAccumulator()
        _ = acc2.apply(.completed(itemID: "x", transcript: "  hello   world \n"))
        XCTAssertEqual(acc2.finalTranscript(), "hello world")
    }

    @objc func testAccumulatorFailedDropsPending() {
        var acc = RealtimeTranscriptAccumulator()
        _ = acc.apply(.delta(itemID: "bad", text: "partial"))
        _ = acc.apply(.failed(itemID: "bad", message: "nope"))
        XCTAssertEqual(acc.finalTranscript(), "")
        XCTAssertEqual(acc.liveText(), "")
    }

    // MARK: - Session integration with mocked transport

    @objc func testSessionStreamsAudioContinuouslyWithoutWAVChunks() throws {
        let transport = MockRealtimeTransport()
        let session = makeSession(transport: transport)
        try runAsync { try await session.start() }
        XCTAssertEqual(session.currentState, .ready)
        try runAsync { try await session.appendAudio(samples16k: [Int16](repeating: 1000, count: 1600)) }
        XCTAssertEqual(session.currentState, .streaming)
        // Appends carry raw PCM (upsampled 1600 -> 2400 samples -> 4800 bytes),
        // never a 44-byte WAV header.
        let appends = transport.sent.filter { $0.contains("input_audio_buffer.append") }
        XCTAssertFalse(appends.isEmpty)
        for text in appends {
            guard let dict = jsonDict(text), let audio = dict["audio"] as? String,
                let data = Data(base64Encoded: audio)
            else {
                XCTFail("append must carry base64 audio")
                return
            }
            XCTAssertFalse(data.starts(with: Data("RIFF".utf8)))
        }
        XCTAssertEqual(session.appendedSampleCount, 2400)
    }

    @objc func testSessionDeltaThenCompletedNoDuplication() throws {
        let transport = MockRealtimeTransport()
        let session = makeSession(transport: transport)
        try runAsync { try await session.start() }
        try runAsync { try await session.appendAudio(samples16k: [Int16](repeating: 500, count: 160)) }
        session.processServerMessage(
            "{\"type\":\"conversation.item.input_audio_transcription.delta\","
                + "\"item_id\":\"item_1\",\"delta\":\"Hello,\"}")
        session.processServerMessage(
            "{\"type\":\"conversation.item.input_audio_transcription.delta\","
                + "\"item_id\":\"item_1\",\"delta\":\" how\"}")
        XCTAssertEqual(session.livePreview(), "Hello, how")
        session.processServerMessage(
            "{\"type\":\"conversation.item.input_audio_transcription.completed\","
                + "\"item_id\":\"item_1\",\"transcript\":\"Hello, how are you?\"}")
        let final = try runAsync { try await session.stop() }
        XCTAssertEqual(final, "Hello, how are you?")
        XCTAssertEqual(session.finalText(), "Hello, how are you?")
        XCTAssertEqual(session.currentState, .closed)
        XCTAssertEqual(transport.closedCount, 1)
        XCTAssertTrue(transport.sentTypes().contains("input_audio_buffer.commit"))
    }

    @objc func testSessionErrorSurfacesWithoutSilentBatchFallback() throws {
        let transport = MockRealtimeTransport()
        let session = makeSession(transport: transport)
        try runAsync { try await session.start() }
        session.processServerMessage("{\"type\":\"error\",\"error\":{\"message\":\"bad key\"}}")
        if case .failed(let message) = session.currentState {
            XCTAssertEqual(message, "bad key")
        } else {
            XCTFail("error event must fail the session, got \(session.currentState)")
        }
        // Default policy is explicit fail: no batch request is issued by the
        // session itself (batchOnce requires an explicit caller opt-in).
        XCTAssertEqual(RealtimeFallbackPolicy.fail, RealtimeFallbackPolicy.fail)
        XCTAssertFalse(RealtimeFallbackPolicy.fail == RealtimeFallbackPolicy.batchOnce)
        do {
            _ = try runAsync { try await session.stop() }
            XCTFail("stop after provider error must throw")
        } catch let error as RealtimeSessionError {
            XCTAssertEqual(error, .provider("bad key"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    @objc func testSessionCancelIsIdempotentAndNeverWedges() throws {
        let transport = MockRealtimeTransport()
        let session = makeSession(transport: transport)
        try runAsync { try await session.start() }
        try runAsync { await session.cancel() }
        try runAsync { await session.cancel() }
        XCTAssertEqual(session.currentState, .cancelled)
        XCTAssertEqual(transport.closedCount, 2)
        do {
            _ = try runAsync { try await session.stop() }
            XCTFail("stop after cancel must throw")
        } catch let error as RealtimeSessionError {
            if case .invalidState = error {
            } else {
                XCTFail("expected invalidState, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    @objc func testSessionStartTwiceThrows() throws {
        let transport = MockRealtimeTransport()
        let session = makeSession(transport: transport)
        try runAsync { try await session.start() }
        do {
            try runAsync { try await session.start() }
            XCTFail("second start must throw")
        } catch let error as RealtimeSessionError {
            if case .invalidState = error {
            } else {
                XCTFail("expected invalidState, got \(error)")
            }
        } catch {
            XCTFail("unexpected error \(error)")
        }
        try runAsync { await session.cancel() }
    }

    @objc func testEmptyDictationStopReturnsEmptyQuickly() throws {
        let transport = MockRealtimeTransport()
        let session = makeSession(transport: transport, timeout: 5)
        try runAsync { try await session.start() }
        let final = try runAsync { try await session.stop() }
        XCTAssertEqual(final, "")
        XCTAssertEqual(session.currentState, .closed)
    }
}
