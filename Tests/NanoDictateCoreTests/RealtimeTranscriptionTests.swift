import Foundation
@testable import NanoDictateCore

// MARK: - Mock transport

final class MockRealtimeTransport: RealtimeTransport {
    var sent: [String] = []
    var incoming: [String?]
    var closedCount = 0
    var sendError: Error?
    /// When non-empty, thrown (in order) from `receive()` before `incoming`
    /// is consulted. Lets tests script transport and generic failures.
    var receiveErrors: [Error] = []

    init(incoming: [String?] = []) {
        self.incoming = incoming
    }

    func send(text: String) async throws {
        if let error = sendError {
            throw error
        }
        sent.append(text)
    }

    func receive() async throws -> String? {
        if !receiveErrors.isEmpty {
            throw receiveErrors.removeFirst()
        }
        if incoming.isEmpty {
            // Park briefly so wait loops can observe cancellation/timeout
            // without hot-spinning; then report no message yet via nil only
            // when explicitly scripted (nil element), else keep waiting by
            // throwing a transient error the session treats as "keep waiting".
            try await Task.sleep(nanoseconds: 5_000_000)
            throw RealtimeTranscriptionError.transport("no scripted message")
        }
        return incoming.removeFirst()
    }

    func close() async {
        closedCount += 1
    }
}

/// Transport whose `receive()` is slower than the session's per-poll stream
/// wait (0.2s). Proves a message consumed after a poll timeout is buffered
/// for the next wait instead of being discarded.
final class DelayedRealtimeTransport: RealtimeTransport {
    var sent: [String] = []
    var messages: [String?]
    var delayNanoseconds: UInt64
    var closedCount = 0

    init(messages: [String?], delayNanoseconds: UInt64 = 300_000_000) {
        self.messages = messages
        self.delayNanoseconds = delayNanoseconds
    }

    func send(text: String) async throws {
        sent.append(text)
    }

    func receive() async throws -> String? {
        try await Task.sleep(nanoseconds: delayNanoseconds)
        if messages.isEmpty {
            return nil
        }
        return messages.removeFirst()
    }

    func close() async {
        closedCount += 1
    }
}

/// Transport with per-message receive delays. Lets tests script a slow
/// completion (longer than the 0.2s per-poll wait, so at least one poll
/// expiry happens) immediately followed by an instant EOF, which is the
/// exact ordering the timeout-recovery requeue must preserve.
final class SequenceRealtimeTransport: RealtimeTransport {
    var sent: [String] = []
    var steps: [(message: String?, delayNanoseconds: UInt64)]
    var closedCount = 0

    init(steps: [(String?, UInt64)]) {
        self.steps = steps.map { (message: $0.0, delayNanoseconds: $0.1) }
    }

    func send(text: String) async throws {
        sent.append(text)
    }

    func receive() async throws -> String? {
        guard !steps.isEmpty else {
            try await Task.sleep(nanoseconds: 5_000_000)
            return nil
        }
        let step = steps.removeFirst()
        if step.delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: step.delayNanoseconds)
        }
        return step.message
    }

    func close() async {
        closedCount += 1
    }
}

final class RealtimeTranscriptionTests: XCTestCase {
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
        wait(for: [expectation], timeout: 15)
    }

    private func json(_ dict: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: dict), encoding: .utf8)!
    }

    // MARK: - Event parsing (official schema)

    @objc func testParseDeltaEvent() {
        let text = json([
            "type": "conversation.item.input_audio_transcription.delta",
            "item_id": "item_003",
            "content_index": 0,
            "delta": "Hello,",
        ])
        let event = RealtimeEventParser.parse(text)
        XCTAssertEqual(event, .delta(itemID: "item_003", contentIndex: 0, delta: "Hello,"))
    }

    @objc func testParseCompletedEventWithLanguages() {
        let text = json([
            "type": "conversation.item.input_audio_transcription.completed",
            "item_id": "item_003",
            "content_index": 0,
            "transcript": "Bonjour, pouvez-vous m'entendre ?",
            "languages": [["code": "fr"]],
        ] as [String: Any])
        let event = RealtimeEventParser.parse(text)
        XCTAssertEqual(
            event,
            .completed(
                itemID: "item_003", contentIndex: 0,
                transcript: "Bonjour, pouvez-vous m'entendre ?",
                languages: ["fr"]))
    }

    @objc func testParseFailedAndErrorEvents() {
        let failed = json([
            "type": "conversation.item.input_audio_transcription.failed",
            "item_id": "item_1",
            "error": ["message": "too much audio"],
        ] as [String: Any])
        XCTAssertEqual(
            RealtimeEventParser.parse(failed), .failed(itemID: "item_1", message: "too much audio"))
        let error = json(["type": "error", "error": ["message": "bad session"]] as [String: Any])
        XCTAssertEqual(RealtimeEventParser.parse(error), .errorMessage("bad session"))
    }

    @objc func testParseInvalidJSONIsUnknown() {
        XCTAssertEqual(RealtimeEventParser.parse("not json"), .unknown("not json"))
        XCTAssertEqual(
            RealtimeEventParser.parse(json(["type": "something.else"])),
            .unknown("something.else"))
    }

    // MARK: - Accumulator: no duplication, deterministic final

    @objc func testAccumulatorDeltasAppendWithoutDuplication() {
        var acc = RealtimeTranscriptAccumulator()
        _ = acc.apply(.delta(itemID: "a", contentIndex: 0, delta: "Hello,"))
        _ = acc.apply(.delta(itemID: "a", contentIndex: 0, delta: " how are"))
        XCTAssertEqual(acc.partialText, "Hello, how are")
        XCTAssertNil(acc.finalText)
        // Completed replaces the delta buffer (authoritative, no duplication).
        _ = acc.apply(.completed(
            itemID: "a", contentIndex: 0, transcript: "Hello, how are you?", languages: []))
        XCTAssertEqual(acc.partialText, "Hello, how are you?")
        XCTAssertEqual(acc.finalText, "Hello, how are you?")
        // Late duplicate delta after completion is ignored.
        _ = acc.apply(.delta(itemID: "a", contentIndex: 0, delta: " how are"))
        XCTAssertEqual(acc.partialText, "Hello, how are you?")
    }

    @objc func testAccumulatorMultiItemJoinsInOrder() {
        var acc = RealtimeTranscriptAccumulator()
        _ = acc.apply(.delta(itemID: "a", contentIndex: 0, delta: "first"))
        _ = acc.apply(.completed(itemID: "a", contentIndex: 0, transcript: "first done", languages: []))
        _ = acc.apply(.delta(itemID: "b", contentIndex: 0, delta: "second"))
        XCTAssertEqual(acc.partialText, "first done second")
        _ = acc.apply(.completed(itemID: "b", contentIndex: 0, transcript: "second done", languages: []))
        XCTAssertEqual(acc.finalText, "first done second done")
    }

    // MARK: - Client builders use the official 24 kHz PCM session shape

    @objc func testSessionUpdatePayloadUses24kPCMTranscription() {
        let text = RealtimeClientEvents.sessionUpdate(
            model: "gpt-live-transcribe", language: "en",
            prompt: "support call", keywords: ["AC-42"], delay: .low)
        guard let data = text.data(using: .utf8),
            let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let session = event["session"] as? [String: Any],
            let audio = session["audio"] as? [String: Any],
            let input = audio["input"] as? [String: Any],
            let format = input["format"] as? [String: Any],
            let transcription = input["transcription"] as? [String: Any]
        else {
            XCTFail("session.update payload malformed: \(text)")
            return
        }
        XCTAssertEqual(event["type"] as? String, "session.update")
        XCTAssertEqual(session["type"] as? String, "transcription")
        XCTAssertEqual(format["type"] as? String, "audio/pcm")
        XCTAssertEqual((format["rate"] as? NSNumber)?.intValue, 24000)
        XCTAssertEqual(transcription["model"] as? String, "gpt-live-transcribe")
        XCTAssertEqual(transcription["prompt"] as? String, "support call")
        XCTAssertEqual(transcription["keywords"] as? [String], ["AC-42"])
        XCTAssertEqual(transcription["languages"] as? [String], ["en"])
        XCTAssertEqual(transcription["delay"] as? String, "low")
        XCTAssertTrue(input["turn_detection"] is NSNull)
    }

    @objc func testAppendEventCarriesBase64PCM() {
        let b64 = RealtimePCMConverter.base64PCM(from: [1, -2, 300])
        let text = RealtimeClientEvents.appendAudio(base64PCM: b64)
        guard let data = text.data(using: .utf8),
            let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            XCTFail("append payload malformed")
            return
        }
        XCTAssertEqual(event["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(event["audio"] as? String, b64)
        XCTAssertEqual(RealtimeClientEvents.commit(), "{\"type\":\"input_audio_buffer.commit\"}")
    }

    // MARK: - Audio profile: realtime models use 24 kHz PCM16, not batch WAV

    @objc func testRealtimeProfileUses24kPCM16Streaming() {
        let profile = STTModelRegistry.resolve(adapterID: "openai", model: "gpt-live-transcribe")
        XCTAssertEqual(profile.capabilities.transport, .streamingSession)
        XCTAssertEqual(profile.audio.sampleRate, 24000)
        XCTAssertEqual(profile.audio.channels, 1)
        XCTAssertEqual(profile.audio.uploadFormat, .pcm16)
        XCTAssertTrue(STTModelRegistry.isRealtime(adapterID: "openai", model: "gpt-live-transcribe"))
        XCTAssertTrue(ProviderRequestBuilder.isRealtime(adapterID: "openai", model: "gpt-live-transcribe"))
        // Snapshot prefix keeps the streaming profile.
        XCTAssertTrue(STTModelRegistry.isRealtime(adapterID: "openai", model: "gpt-live-transcribe-2026-09-01"))
        // Batch models are untouched.
        XCTAssertFalse(STTModelRegistry.isRealtime(adapterID: "openai", model: "gpt-transcribe"))
        XCTAssertFalse(STTModelRegistry.isRealtime(adapterID: "openai", model: "whisper-1"))
        XCTAssertEqual(
            ProviderRequestBuilder.audioProfile(adapterID: "openai", model: "gpt-live-transcribe").sampleRate,
            24000)
    }

    @objc func testBatchPlanForStreamingProfileIsInvalidNotSilentFallback() {
        let spec = ProviderRequestBuilder.plan(
            adapterID: "openai", baseURL: "", model: "gpt-live-transcribe", apiKey: "k",
            language: "en", wav: Data([1, 2, 3]))
        XCTAssertNil(spec.url)
    }

    // MARK: - Resampling 16 kHz mic -> 24 kHz realtime

    @objc func testResample16kTo24kUpsamplesDeterministically() {
        XCTAssertEqual(RealtimePCMConverter.resample([100, 200], fromRate: 24000, toRate: 24000), [100, 200])
        XCTAssertEqual(RealtimePCMConverter.resample([], fromRate: 16000, toRate: 24000), [])
        let out = RealtimePCMConverter.resample([0, 1000, 2000, 3000], fromRate: 16000, toRate: 24000)
        XCTAssertEqual(out.count, 6)
        XCTAssertEqual(out.first, 0)
        XCTAssertEqual(out.last, 3000)
        // Monotonic ramp resamples to a monotonic ramp (no aliasing jumps).
        for i in 1..<out.count {
            XCTAssertTrue(out[i] >= out[i - 1], "index \(i): \(out)")
        }
    }

    @objc func testChunkingPreservesOrder() {
        let chunks = RealtimePCMConverter.chunk([1, 2, 3, 4, 5], maxSamples: 2)
        XCTAssertEqual(chunks, [[1, 2], [3, 4], [5]])
    }

    // MARK: - Session state with mocked transport

    @objc func testSessionConnectStreamsCommitCompletesDeterministically() {
        runAsync("realtime connect/stream/commit") {
            let transport = MockRealtimeTransport(incoming: [
                self.json(["type": "session.updated"]),
                self.json([
                    "type": "conversation.item.input_audio_transcription.delta",
                    "item_id": "item_1", "content_index": 0, "delta": "Hello,",
                ]),
                self.json([
                    "type": "conversation.item.input_audio_transcription.completed",
                    "item_id": "item_1", "content_index": 0,
                    "transcript": "Hello, how are you?",
                ]),
            ])
            let session = RealtimeTranscriptionSession(
                transport: transport,
                config: RealtimeSessionConfig(model: "gpt-live-transcribe", sourceSampleRate: 16000),
                policy: RealtimeSessionPolicy(
                    connectTimeout: 5, commitTimeout: 5, maxSamplesPerAppend: 2))
            try await session.connect()
            let readyState = await session.currentState
            XCTAssertEqual(readyState, .ready)
            // One stateful session: first message is session.update.
            XCTAssertTrue(transport.sent.first?.contains("session.update") ?? false)
            XCTAssertTrue(transport.sent.first?.contains("gpt-live-transcribe") ?? false)
            // Continuous PCM streaming: no WAV/RIFF header in append payloads.
            try await session.appendAudio([0, 1000, 2000, 3000], sourceSampleRate: 16000)
            let appends = transport.sent.filter { $0.contains("input_audio_buffer.append") }
            XCTAssertFalse(appends.isEmpty)
            XCTAssertFalse(appends.joined().contains("RIFF"))
            try await session.commit()
            XCTAssertTrue(transport.sent.contains(where: { $0.contains("input_audio_buffer.commit") }))
            let final = try await session.waitForFinal()
            XCTAssertEqual(final, "Hello, how are you?")
            // Partial never duplicated the committed text.
            let partial = await session.partialText
            XCTAssertEqual(partial, "Hello, how are you?")
            await session.close()
            let closedState = await session.currentState
            XCTAssertEqual(closedState, .closed)
            XCTAssertEqual(transport.closedCount, 1)
        }
    }

    @objc func testSessionCancelIsDeterministicAndClosesTransportOnce() {
        runAsync("realtime cancel") {
            let transport = MockRealtimeTransport(incoming: [self.json(["type": "session.updated"])])
            let session = RealtimeTranscriptionSession(
                transport: transport,
                config: RealtimeSessionConfig(),
                policy: RealtimeSessionPolicy(connectTimeout: 5, commitTimeout: 2))
            try await session.connect()
            await session.cancel()
            let cancelledState = await session.currentState
            XCTAssertEqual(cancelledState, .cancelled)
            await session.close(cancelled: true)
            XCTAssertEqual(transport.closedCount, 1)
            do {
                try await session.appendAudio([1, 2], sourceSampleRate: 16000)
                XCTFail("append after cancel must throw")
            } catch let error as RealtimeTranscriptionError {
                XCTAssertEqual(error, .notConnected)
            }
        }
    }

    @objc func testSessionProviderErrorFailsClosedWithoutBatchFallback() {
        runAsync("realtime provider error") {
            let transport = MockRealtimeTransport(incoming: [
                self.json(["type": "session.updated"]),
                self.json(["type": "error", "error": ["message": "invalid api key"]] as [String: Any]),
            ])
            let session = RealtimeTranscriptionSession(
                transport: transport,
                config: RealtimeSessionConfig(),
                policy: RealtimeSessionPolicy(connectTimeout: 5, commitTimeout: 5),
                fallback: .failClosed)
            try await session.connect()
            try await session.appendAudio([1, 2, 3], sourceSampleRate: 24000)
            try await session.commit()
            // Feed the error into the session state.
            _ = await session.handleMessage(
                self.json(["type": "error", "error": ["message": "invalid api key"]] as [String: Any]))
            let failedState = await session.currentState
            XCTAssertEqual(failedState, .failed)
            let fallback = await session.fallbackPolicy
            XCTAssertEqual(fallback, .failClosed)
            do {
                _ = try await session.waitForFinal()
                XCTFail("failed session must throw, not silently batch-fallback")
            } catch let error as RealtimeTranscriptionError {
                XCTAssertTrue(
                    error == .sessionFailed("invalid api key") || error == .timeout("no completion within commit timeout"),
                    "unexpected: \(error)")
            }
            await session.close()
        }
    }

    @objc func testReconnectPolicyBackoffIsBounded() {
        let policy = RealtimeSessionPolicy(reconnectBaseDelay: 0.5)
        XCTAssertEqual(policy.reconnectDelay(forAttempt: 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(policy.reconnectDelay(forAttempt: 1), 1.0, accuracy: 1e-9)
        XCTAssertEqual(policy.reconnectDelay(forAttempt: 2), 2.0, accuracy: 1e-9)
    }

    @objc func testConnectTimeoutFailsClosedInsteadOfReady() {
        runAsync("realtime connect timeout fails closed") {
            let transport = MockRealtimeTransport(incoming: [])
            let session = RealtimeTranscriptionSession(
                transport: transport,
                config: RealtimeSessionConfig(),
                policy: RealtimeSessionPolicy(connectTimeout: 0.3, commitTimeout: 1))
            do {
                try await session.connect()
                XCTFail("connect without ack must throw")
            } catch let error as RealtimeTranscriptionError {
                XCTAssertEqual(error, .timeout("no session ack"))
            } catch {
                XCTFail("unexpected error: \(error)")
            }
            let state = await session.currentState
            XCTAssertEqual(state, .failed)
            let lastError = await session.lastErrorMessage
            XCTAssertEqual(lastError, "no session ack")
        }
    }

    @objc func testWaitForFinalTransportDropFailsClosed() {
        runAsync("realtime waitForFinal transport drop") {
            let transport = MockRealtimeTransport(incoming: [
                self.json(["type": "session.updated"]),
                nil,
            ])
            let session = RealtimeTranscriptionSession(
                transport: transport,
                config: RealtimeSessionConfig(),
                policy: RealtimeSessionPolicy(connectTimeout: 5, commitTimeout: 5))
            try await session.connect()
            try await session.appendAudio([1, 2, 3], sourceSampleRate: 24000)
            try await session.commit()
            do {
                _ = try await session.waitForFinal()
                XCTFail("transport drop must throw")
            } catch let error as RealtimeTranscriptionError {
                XCTAssertEqual(error, .transport("transport closed before completion"))
            } catch {
                XCTFail("unexpected error: \(error)")
            }
            let state = await session.currentState
            XCTAssertEqual(state, .failed)
            let lastError = await session.lastErrorMessage
            XCTAssertEqual(lastError, "transport closed before completion")
        }
    }

    @objc func testRunToCompletionTransportDropFailsClosed() {
        runAsync("realtime runToCompletion transport drop") {
            let transport = MockRealtimeTransport(incoming: [
                self.json(["type": "session.updated"]),
                nil,
            ])
            let session = RealtimeTranscriptionSession(
                transport: transport,
                config: RealtimeSessionConfig(),
                policy: RealtimeSessionPolicy(connectTimeout: 5, commitTimeout: 5))
            try await session.connect()
            try await session.appendAudio([1, 2, 3], sourceSampleRate: 24000)
            try await session.commit()
            do {
                _ = try await session.runToCompletion()
                XCTFail("transport drop must throw")
            } catch let error as RealtimeTranscriptionError {
                XCTAssertEqual(error, .transport("transport closed before completion"))
            } catch {
                XCTFail("unexpected error: \(error)")
            }
            let state = await session.currentState
            XCTAssertEqual(state, .failed)
            let lastError = await session.lastErrorMessage
            XCTAssertEqual(lastError, "transport closed before completion")
        }
    }

    @objc func testWaitForFinalReturnsBufferedPartialOnTransportError() {
        runAsync("realtime waitForFinal returns buffered partial on transport error") {
            let transport = MockRealtimeTransport(incoming: [
                self.json(["type": "session.updated"])
            ])
            let session = RealtimeTranscriptionSession(
                transport: transport,
                config: RealtimeSessionConfig(),
                policy: RealtimeSessionPolicy(connectTimeout: 5, commitTimeout: 5))
            try await session.connect()
            transport.receiveErrors = [RealtimeTranscriptionError.transport("socket reset")]
            try await session.appendAudio([1, 2, 3], sourceSampleRate: 24000)
            try await session.commit()
            _ = await session.handleMessage(
                self.json([
                    "type": "conversation.item.input_audio_transcription.delta",
                    "item_id": "item_1", "content_index": 0, "delta": "Hello,",
                ]))
            let text = try await session.waitForFinal()
            XCTAssertEqual(text, "Hello,")
            // Buffered close-out does not fail the session.
            let state = await session.currentState
            XCTAssertFalse(state == .failed)
        }
    }

    @objc func testRunToCompletionReturnsBufferedPartialOnTransportError() {
        runAsync("realtime runToCompletion returns buffered partial on transport error") {
            let transport = MockRealtimeTransport(incoming: [
                self.json(["type": "session.updated"])
            ])
            let session = RealtimeTranscriptionSession(
                transport: transport,
                config: RealtimeSessionConfig(),
                policy: RealtimeSessionPolicy(connectTimeout: 5, commitTimeout: 5))
            try await session.connect()
            transport.receiveErrors = [RealtimeTranscriptionError.transport("socket reset")]
            try await session.appendAudio([1, 2, 3], sourceSampleRate: 24000)
            try await session.commit()
            _ = await session.handleMessage(
                self.json([
                    "type": "conversation.item.input_audio_transcription.delta",
                    "item_id": "item_1", "content_index": 0, "delta": "Hello,",
                ]))
            let text = try await session.runToCompletion()
            XCTAssertEqual(text, "Hello,")
            let state = await session.currentState
            XCTAssertFalse(state == .failed)
        }
    }

    @objc func testWaitForFinalUnknownReceiveErrorFailsClosed() {
        struct Boom: Error {}
        return runAsync("realtime waitForFinal unknown error fails closed") {
            let transport = MockRealtimeTransport(incoming: [
                self.json(["type": "session.updated"])
            ])
            let session = RealtimeTranscriptionSession(
                transport: transport,
                config: RealtimeSessionConfig(),
                policy: RealtimeSessionPolicy(connectTimeout: 5, commitTimeout: 5))
            try await session.connect()
            transport.receiveErrors = [Boom()]
            try await session.appendAudio([1, 2, 3], sourceSampleRate: 24000)
            try await session.commit()
            do {
                _ = try await session.waitForFinal()
                XCTFail("unknown receive error must throw")
            } catch let error as RealtimeTranscriptionError {
                if case .transport = error {
                } else {
                    XCTFail("expected transport error, got \(error)")
                }
            } catch {
                XCTFail("unexpected error: \(error)")
            }
            let state = await session.currentState
            XCTAssertEqual(state, .failed)
            let lastError = await session.lastErrorMessage
            XCTAssertNotNil(lastError)
        }
    }

    @objc func testAckSurvivesMultipleEmptyPollsBeforeArrival() {
        runAsync("realtime ack survives multiple empty polls") {
            // Each receive takes 0.7s while the session polls every 0.2s, so
            // connect() observes several per-poll timeouts with zero messages
            // before the ack arrives. Timed-out waiters must cancel only
            // themselves: the later ack must still be delivered, not lost.
            let transport = DelayedRealtimeTransport(
                messages: [
                    self.json(["type": "session.updated"]),
                    self.json([
                        "type": "conversation.item.input_audio_transcription.completed",
                        "item_id": "item_1", "content_index": 0,
                        "transcript": "late ack win",
                    ]),
                ],
                delayNanoseconds: 700_000_000)
            let session = RealtimeTranscriptionSession(
                transport: transport,
                config: RealtimeSessionConfig(),
                policy: RealtimeSessionPolicy(connectTimeout: 5, commitTimeout: 5))
            try await session.connect()
            let readyState = await session.currentState
            XCTAssertEqual(readyState, .ready)
            try await session.appendAudio([1, 2, 3], sourceSampleRate: 24000)
            try await session.commit()
            let final = try await session.waitForFinal()
            XCTAssertEqual(final, "late ack win")
            await session.close()
        }
    }

    @objc func testSlowReceiveIsBufferedAcrossPollTimeout() {
        runAsync("realtime slow receive buffered across poll timeout") {
            let transport = DelayedRealtimeTransport(messages: [
                self.json(["type": "session.updated"]),
                self.json([
                    "type": "conversation.item.input_audio_transcription.completed",
                    "item_id": "item_1", "content_index": 0,
                    "transcript": "late win",
                ]),
            ])
            let session = RealtimeTranscriptionSession(
                transport: transport,
                config: RealtimeSessionConfig(),
                policy: RealtimeSessionPolicy(connectTimeout: 5, commitTimeout: 5))
            // Each receive takes 0.3s, longer than the 0.2s per-poll stream
            // wait. The ack and the completion each arrive after a poll
            // expiry and must still be delivered (never discarded).
            try await session.connect()
            try await session.appendAudio([1, 2, 3], sourceSampleRate: 24000)
            try await session.commit()
            let final = try await session.waitForFinal()
            XCTAssertEqual(final, "late win")
            await session.close()
        }
    }

    @objc func testWaitForFinalCompletionImmediatelyFollowedByEOFReturnsFinal() {
        runAsync("realtime completion followed by EOF returns final") {
            // Regression coverage for the timeout-recovery ordering race:
            // a `.completed` that arrives around a per-poll expiry must be
            // processed before a buffered EOF that follows it. EOF must never
            // jump ahead of an earlier completion.
            let transport = MockRealtimeTransport(incoming: [
                self.json(["type": "session.updated"]),
                self.json([
                    "type": "conversation.item.input_audio_transcription.completed",
                    "item_id": "item_1", "content_index": 0,
                    "transcript": "hello world",
                ]),
                nil,
            ])
            let session = RealtimeTranscriptionSession(
                transport: transport,
                config: RealtimeSessionConfig(),
                policy: RealtimeSessionPolicy(connectTimeout: 5, commitTimeout: 5))
            try await session.connect()
            try await session.appendAudio([1, 2, 3], sourceSampleRate: 24000)
            try await session.commit()
            let final = try await session.waitForFinal()
            XCTAssertEqual(final, "hello world")
            await session.close()
        }
    }

    @objc func testWaitForFinalSlowCompletionFollowedByEOFReturnsFinal() {
        runAsync("realtime slow completion followed by EOF returns final") {
            // Same ordering guarantee under per-poll timeouts: the completion
            // arrives after at least one 0.2s poll expiry and EOF follows
            // immediately, so a timeout-recovery requeue must preserve
            // receive order (completion before EOF).
            let transport = SequenceRealtimeTransport(steps: [
                (self.json(["type": "session.updated"]), 0),
                (self.json([
                    "type": "conversation.item.input_audio_transcription.completed",
                    "item_id": "item_1", "content_index": 0,
                    "transcript": "slow win",
                ]), 300_000_000),
                (nil, 0),
            ])
            let session = RealtimeTranscriptionSession(
                transport: transport,
                config: RealtimeSessionConfig(),
                policy: RealtimeSessionPolicy(connectTimeout: 5, commitTimeout: 8))
            try await session.connect()
            try await session.appendAudio([1, 2, 3], sourceSampleRate: 24000)
            try await session.commit()
            let final = try await session.waitForFinal()
            XCTAssertEqual(final, "slow win")
            await session.close()
        }
    }
}
