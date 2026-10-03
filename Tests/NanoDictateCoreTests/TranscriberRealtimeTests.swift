import Foundation
@testable import NanoDictateCore

// Focused coverage for the ordinary dictation realtime route:
// `.streamingSession` profiles (e.g. `gpt-live-transcribe`) run one
// `RealtimeTranscriptionSession` per `Transcriber.transcribe` call instead of
// the batch multipart path, and failures stay fail-closed (no batch fallback).

final class TranscriberRealtimeTests: XCTestCase {
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

    @objc func testRealtimeProfileRoutesThroughSessionNotBatch() {
        runAsync("realtime routes through session") {
            let wav = WAVEncoder.encode(samples: [0, 1000, 2000, 3000])
            let realtime = MockRealtimeTransport(incoming: [
                self.json(["type": "session.updated"]),
                self.json([
                    "type": "conversation.item.input_audio_transcription.completed",
                    "item_id": "item_1", "content_index": 0,
                    "transcript": "hello realtime",
                ]),
            ])
            let http = MockTransport(status: 200, body: Data(#"{"text":"batch"}"#.utf8))
            let transcriber = Transcriber(
                baseURL: "https://api.openai.com/v1/audio/transcriptions",
                model: "gpt-live-transcribe",
                apiKey: "test-key",
                transport: http,
                networkChecker: { true },
                adapterID: "openai",
                retrySleep: { _ in },
                realtimeTransportFactory: { realtime })
            let result = try await transcriber.transcribe(wav: wav)
            XCTAssertEqual(result.text, "hello realtime")
            XCTAssertEqual(http.requestCount, 0)
            XCTAssertTrue(realtime.sent.first?.contains("session.update") ?? false)
            XCTAssertTrue(realtime.sent.contains(where: { $0.contains("input_audio_buffer.append") }))
            XCTAssertTrue(realtime.sent.contains(where: { $0.contains("input_audio_buffer.commit") }))
        }
    }

    @objc func testRealtimeFailureIsFailClosedWithoutBatchFallback() {
        let outer = expectation(description: "realtime fail closed")
        Task {
            let wav = WAVEncoder.encode(samples: [0, 1000, 2000, 3000])
            let realtime = MockRealtimeTransport(incoming: [
                self.json(["type": "session.updated"]),
                self.json(["type": "error", "error": ["message": "invalid api key"]] as [String: Any]),
            ])
            let http = MockTransport(status: 200, body: Data(#"{"text":"batch"}"#.utf8))
            let transcriber = Transcriber(
                baseURL: "https://api.openai.com/v1/audio/transcriptions",
                model: "gpt-live-transcribe",
                apiKey: "bad-key",
                transport: http,
                networkChecker: { true },
                adapterID: "openai",
                retrySleep: { _ in },
                realtimeTransportFactory: { realtime })
            do {
                _ = try await transcriber.transcribe(wav: wav)
                XCTFail("realtime failure must throw, not batch-fallback")
            } catch let error as TranscribeError {
                guard case .network = error else {
                    XCTFail("Expected .network, got \(error)")
                    outer.fulfill()
                    return
                }
            } catch {
                XCTFail("Unexpected error type: \(error)")
            }
            XCTAssertEqual(http.requestCount, 0)
            outer.fulfill()
        }
        wait(for: [outer], timeout: 15)
    }

    @objc func testBatchProfileStillUsesHTTPTransport() {
        runAsync("batch still uses http") {
            let wav = WAVEncoder.encode(samples: [0, 1000, 2000, 3000])
            let http = MockTransport(status: 200, body: Data(#"{"text":"batch ok"}"#.utf8))
            let transcriber = Transcriber(
                baseURL: "https://api.openai.com/v1/audio/transcriptions",
                model: "gpt-transcribe",
                apiKey: "test-key",
                transport: http,
                networkChecker: { true },
                adapterID: "openai",
                retrySleep: { _ in })
            let result = try await transcriber.transcribe(wav: wav)
            XCTAssertEqual(result.text, "batch ok")
            XCTAssertEqual(http.requestCount, 1)
        }
    }

    @objc func testRealtimeForwardsVocabularyAsSessionKeywords() {
        runAsync("realtime forwards vocabulary") {
            let wav = WAVEncoder.encode(samples: [0, 1000, 2000, 3000])
            let realtime = MockRealtimeTransport(incoming: [
                self.json(["type": "session.updated"]),
                self.json([
                    "type": "conversation.item.input_audio_transcription.completed",
                    "item_id": "item_1", "content_index": 0,
                    "transcript": "hello realtime",
                ]),
            ])
            let http = MockTransport(status: 200, body: Data(#"{"text":"batch"}"#.utf8))
            let transcriber = Transcriber(
                baseURL: "https://api.openai.com/v1/audio/transcriptions",
                model: "gpt-live-transcribe",
                apiKey: "test-key",
                transport: http,
                networkChecker: { true },
                adapterID: "openai",
                contextualBias: STTContextualBias(
                    vocabulary: ["Kubernetes", "Whisper"], extraLanguages: []),
                retrySleep: { _ in },
                realtimeTransportFactory: { realtime })
            let result = try await transcriber.transcribe(wav: wav)
            XCTAssertEqual(result.text, "hello realtime")
            XCTAssertEqual(http.requestCount, 0)
            guard let update = realtime.sent.first else {
                XCTFail("session.update must be sent")
                return
            }
            XCTAssertTrue(update.contains("session.update"))
            XCTAssertTrue(update.contains("Kubernetes"))
            XCTAssertTrue(update.contains("Whisper"))
            XCTAssertTrue(update.contains("keywords"))
        }
    }

    @objc func testRealtimeForwardsExtraLanguagesAsSessionLanguages() {
        runAsync("realtime forwards extra languages") {
            let wav = WAVEncoder.encode(samples: [0, 1000, 2000, 3000])
            let realtime = MockRealtimeTransport(incoming: [
                self.json(["type": "session.updated"]),
                self.json([
                    "type": "conversation.item.input_audio_transcription.completed",
                    "item_id": "item_1", "content_index": 0,
                    "transcript": "hello realtime",
                ]),
            ])
            let http = MockTransport(status: 200, body: Data(#"{"text":"batch"}"#.utf8))
            let transcriber = Transcriber(
                baseURL: "https://api.openai.com/v1/audio/transcriptions",
                model: "gpt-live-transcribe",
                apiKey: "test-key",
                language: "en",
                transport: http,
                networkChecker: { true },
                adapterID: "openai",
                contextualBias: STTContextualBias(
                    vocabulary: [], extraLanguages: ["ru", "EN"]),
                retrySleep: { _ in },
                realtimeTransportFactory: { realtime })
            let result = try await transcriber.transcribe(wav: wav)
            XCTAssertEqual(result.text, "hello realtime")
            guard let update = realtime.sent.first else {
                XCTFail("session.update must be sent")
                return
            }
            guard let data = update.data(using: .utf8),
                let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let session = event["session"] as? [String: Any],
                let audio = session["audio"] as? [String: Any],
                let input = audio["input"] as? [String: Any],
                let transcription = input["transcription"] as? [String: Any]
            else {
                XCTFail("session.update payload malformed: \(update)")
                return
            }
            // Primary hint first, extras merged (EN duplicate collapses).
            XCTAssertEqual(transcription["languages"] as? [String], ["en", "ru"])
        }
    }
}
