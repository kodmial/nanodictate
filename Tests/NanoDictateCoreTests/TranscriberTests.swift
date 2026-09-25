import Foundation
@testable import NanoDictateCore

// MARK: - MockTransport

final class MockTransport: HTTPTransport, @unchecked Sendable {

    var status: Int
    var body: Data
    var sendError: Error?

    /// Set → injected into response (needed for Retry-After).
    var responseHeaders: [String: String] = [:]

    /// If set, the first N calls will throw sendError; then normal behavior.
    /// Once failCount is exhausted, sendError is cleared so later calls succeed.
    var failCount: Int = 0

    private(set) var requestCount = 0
    private(set) var lastRequest: URLRequest?

    init(status: Int, body: Data = Data(), sendError: Error? = nil) {
        self.status = status
        self.body = body
        self.sendError = sendError
    }

    func send(request: URLRequest) async throws -> (status: Int, body: Data, headers: [String: String]) {
        requestCount += 1
        lastRequest = request

        // failCount mode: first N calls throw, then succeed
        if failCount > 0 {
            failCount -= 1
            let err = sendError
            if failCount == 0 { sendError = nil } // last scheduled failure — clear for subsequent calls
            if let err = err {
                throw err
            }
        } else if let sendError = sendError {
            throw sendError
        }

        return (status, body, responseHeaders)
    }
}

/// HTTP transport with status sequence: serves statuses in order, last forever
/// (5xx retry and 4xx terminal checks).
final class StatusSequenceTransport: HTTPTransport, @unchecked Sendable {
    let statuses: [Int]
    private(set) var requestCount = 0
    init(statuses: [Int]) { self.statuses = statuses }
    func send(request: URLRequest) async throws -> (status: Int, body: Data, headers: [String: String]) {
        let index = min(requestCount, statuses.count - 1)
        requestCount += 1
        return (statuses[index], Data(#"{"text":"ok after retries"}"#.utf8), [:])
    }
}

/// Records delays between retries (retrySleep injection) — thread-safe,
/// called from async context.
final class SleepRecorder {
    private let lock = NSLock()
    private var values: [TimeInterval] = []
    func record(_ delay: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        values.append(delay)
    }
    var delays: [TimeInterval] {
        lock.lock(); defer { lock.unlock() }
        return values
    }
}

// MARK: - Tests

final class TranscriberTests: XCTestCase {

    private let wavData = Data([0x52, 0x49, 0x46, 0x46]) // "RIFF"

    private func makeTranscriber(transport: MockTransport, retrySleep: ((TimeInterval) async -> Void)? = nil) -> Transcriber {
        Transcriber(baseURL: "https://example.test/v1/audio/transcriptions",
                    model: "gigaam-v3",
                    apiKey: "test-key",
                    transport: transport,
                    networkChecker: { true },
                    adapterID: "gigaam",
                    retrySleep: retrySleep ?? { _ in })
    }

    /// Runs an async closure to completion inside a synchronous test method.
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

    // MARK: Success

    @objc func testSuccessReturnsText() {
        let json = #"{"text":"привет мир"}"#
        let transport = MockTransport(status: 200, body: Data(json.utf8))
        let transcriber = makeTranscriber(transport: transport)

        runAsync("testSuccess") {
            let result = try await transcriber.transcribe(wav: self.wavData)

            XCTAssertEqual(result.text, "привет мир")
            XCTAssertEqual(result.rawData, Data(json.utf8))
        }
    }

    // MARK: HTTP error

    @objc func testHTTP500ThrowsHTTPError() {
        let transport = MockTransport(status: 500, body: Data(#"{"error":"boom"}"#.utf8))
        let transcriber = makeTranscriber(transport: transport)

        runAsync("testHTTP500") {
            do {
                _ = try await transcriber.transcribe(wav: self.wavData)
                XCTFail("Expected TranscribeError.http")
            } catch let error as TranscribeError {
                switch error {
                case .http(let code, let message):
                    XCTAssertEqual(code, 500)
                    XCTAssertTrue(message.contains("boom"))
                default:
                    XCTFail("Expected .http, got \(error)")
                }
            }
        }
    }

    // MARK: Request contents

    @objc func testRequestContainsBoundaryFileModelAndAuthorization() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"ok"}"#.utf8))
        let transcriber = makeTranscriber(transport: transport)

        runAsync("testRequest") {
            _ = try await transcriber.transcribe(wav: self.wavData, filename: "audio.wav")

            guard let request = transport.lastRequest else {
                XCTFail("No request captured")
                return
            }

            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            XCTAssertEqual(request.timeoutInterval, 20, "сетевой таймаут запроса — жёстко 20 с (networkRequestTimeout)")

            guard let contentType = request.value(forHTTPHeaderField: "Content-Type") else {
                XCTFail("No Content-Type header")
                return
            }
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="))
            let boundary = String(contentType.dropFirst("multipart/form-data; boundary=".count))
            XCTAssertFalse(boundary.isEmpty)
            XCTAssertTrue(boundary.hasPrefix("Boundary-"))

            guard let body = request.httpBody, let bodyText = String(data: body, encoding: .utf8) else {
                XCTFail("No HTTP body")
                return
            }

            // Boundary markers
            XCTAssertTrue(bodyText.contains("--\(boundary)\r\n"))
            XCTAssertTrue(bodyText.hasSuffix("--\(boundary)--\r\n"))

            // File field
            XCTAssertTrue(bodyText.contains("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n"))
            XCTAssertTrue(bodyText.contains("Content-Type: audio/wav\r\n"))

            // Model field
            XCTAssertTrue(bodyText.contains("Content-Disposition: form-data; name=\"model\"\r\n"))
            XCTAssertTrue(bodyText.contains("gigaam-v3"))

            // WAV bytes present verbatim
            // Data.contains(_:) needs macOS 13 — on 12 use range.
            XCTAssertTrue(body.range(of: self.wavData) != nil)
        }
    }

    // MARK: Retry on network error

    /// Network error retried until attempts exhausted (maxAttempts = 4):
    /// each attempt gives .cannotConnectToHost again.
    @objc func testNetworkErrorRetriesUntilExhausted() {
        let transport = MockTransport(status: 0,
                                      body: Data(),
                                      sendError: URLError(.cannotConnectToHost))
        let transcriber = makeTranscriber(transport: transport)

        runAsync("testNetworkErrorRetriesUntilExhausted") {
            do {
                _ = try await transcriber.transcribe(wav: self.wavData)
                XCTFail("Expected TranscribeError.network")
            } catch let error as TranscribeError {
                switch error {
                case .network:
                    break // expected
                default:
                    XCTFail("Expected .network, got \(error)")
                }
            }
            XCTAssertEqual(transport.requestCount, 4, "4 попытки до исчерпания ретраев")
        }
    }

    /// Inter-attempt delays: exponential backoff 0.5·2^n plus jitter
    /// (0…0.25 s). Delays grow monotonically.
    @objc func testBackoffDelaysIncreaseMonotonically() {
        let transport = MockTransport(status: 0,
                                      body: Data(),
                                      sendError: URLError(.cannotConnectToHost))
        let recorder = SleepRecorder()
        let transcriber = makeTranscriber(transport: transport,
                                          retrySleep: { recorder.record($0) })

        runAsync("testBackoffDelays") {
            do {
                _ = try await transcriber.transcribe(wav: self.wavData)
                XCTFail("Expected TranscribeError.network")
            } catch let error as TranscribeError {
                if case .network = error {} else { XCTFail("Expected .network, got \(error)") }
            }
        }

        let delays = recorder.delays
        XCTAssertEqual(delays.count, 3, "между 4 попытками — 3 паузы")
        for (i, delay) in delays.enumerated() {
            // retryIndex = i+1: 0.5*2^(i+1) + jitter(0…0.25)
            let base = Transcriber.backoffDelay(beforeRetry: i + 1, jitter: 0)
            XCTAssertGreaterThanOrEqual(delay, base, "пауза не меньше номинальной \(base) с")
            XCTAssertLessThanOrEqual(delay, base + 0.25, "джиттер не больше 0.25 с")
        }
        XCTAssertTrue(delays[0] < delays[1], "1 с < 2 с — паузы растут")
        XCTAssertTrue(delays[1] < delays[2], "2 с < 4 с — паузы растут")
    }

    // MARK: Invalid response

    @objc func testInvalidResponseThrows() {
        let transport = MockTransport(status: 200, body: Data("not json".utf8))
        let transcriber = makeTranscriber(transport: transport)

        runAsync("testInvalidResponse") {
            do {
                _ = try await transcriber.transcribe(wav: self.wavData)
                XCTFail("Expected TranscribeError.invalidResponse")
            } catch let error as TranscribeError {
                switch error {
                case .invalidResponse:
                    break // expected
                default:
                    XCTFail("Expected .invalidResponse, got \(error)")
                }
            }
            XCTAssertEqual(transport.requestCount, 1) // no retry for invalid response
        }
    }

    // MARK: - NEW: HTTP 500 with body text

    @objc func testHTTP500WithBodyContainsBodyText() {
        let bodyText = "Internal Server Error: quota exceeded"
        let transport = MockTransport(status: 500, body: Data(bodyText.utf8))
        let transcriber = makeTranscriber(transport: transport)

        runAsync("testHTTP500Body") {
            do {
                _ = try await transcriber.transcribe(wav: self.wavData)
                XCTFail("Expected .http")
            } catch let error as TranscribeError {
                if case .http(let code, let msg) = error {
                    XCTAssertEqual(code, 500)
                    XCTAssertEqual(msg, bodyText)
                } else {
                    XCTFail("Expected .http, got \(error)")
                }
            }
        }
    }

    // MARK: - NEW: describe() маскирует секреты в теле HTTP-ошибки

    @objc func testDescribeHTTPErrorMasksSecretsInBody() {
        let body = #"{"error":"auth failed","api_key":"provider-secret-123"}"#
        let desc = Transcriber.describe(TranscribeError.http(401, body))

        XCTAssertTrue(desc.hasPrefix("HTTP 401: "))
        XCTAssertTrue(desc.contains("\"api_key\": \"***\""), "api_key должен маскироваться")
        XCTAssertFalse(desc.contains("provider-secret-123"), "секрет провайдера не должен попасть в лог")
    }

    @objc func testDescribeHTTPErrorTruncatesLongBody() {
        let long = String(repeating: "a", count: 300)
        let desc = Transcriber.describe(TranscribeError.http(500, long))

        XCTAssertTrue(desc.contains(String(repeating: "a", count: 120)), "тело должно сокращаться до ~120 символов")
        XCTAssertFalse(desc.contains(String(repeating: "a", count: 121)), "хвост длинного тела не должен попадать в лог")
    }

    // MARK: - NEW: Invalid JSON → .invalidResponse

    @objc func testInvalidJSONReturnsInvalidResponse() {
        let transport = MockTransport(status: 200, body: Data("{not json at all".utf8))
        let transcriber = makeTranscriber(transport: transport)

        runAsync("testInvalidJSON") {
            do {
                _ = try await transcriber.transcribe(wav: self.wavData)
                XCTFail("Expected .invalidResponse")
            } catch let error as TranscribeError {
                if case .invalidResponse(let msg) = error {
                    XCTAssertFalse(msg.isEmpty)
                } else {
                    XCTFail("Expected .invalidResponse, got \(error)")
                }
            }
        }
    }

    // MARK: - NEW: JSON missing "text" field

    @objc func testMissingTextFieldReturnsInvalidResponse() {
        let transport = MockTransport(status: 200, body: Data(#"{"no_text":"hello"}"#.utf8))
        let transcriber = makeTranscriber(transport: transport)

        runAsync("testMissingText") {
            do {
                _ = try await transcriber.transcribe(wav: self.wavData)
                XCTFail("Expected .invalidResponse")
            } catch let error as TranscribeError {
                if case .invalidResponse(let msg) = error {
                    XCTAssertTrue(msg.contains("text"))
                } else {
                    XCTFail("Expected .invalidResponse, got \(error)")
                }
            }
        }
    }

    // MARK: - NEW: Empty text → OK

    @objc func testEmptyTextReturnsOK() {
        let json = #"{"text":""}"#
        let transport = MockTransport(status: 200, body: Data(json.utf8))
        let transcriber = makeTranscriber(transport: transport)

        runAsync("testEmptyText") {
            let result = try await transcriber.transcribe(wav: self.wavData)
            XCTAssertEqual(result.text, "")
        }
    }

    // MARK: - NEW: Success with usage field → text extracted

    @objc func testSuccessWithUsageField() {
        let json = #"{"text":"привет","usage":{"seconds":1.5}}"#
        let transport = MockTransport(status: 200, body: Data(json.utf8))
        let transcriber = makeTranscriber(transport: transport)

        runAsync("testWithUsage") {
            let result = try await transcriber.transcribe(wav: self.wavData)
            XCTAssertEqual(result.text, "привет")
        }
    }

    // MARK: - NEW: Retry: first call error → second success → return text

    @objc func testRetryFirstFailsSecondSucceeds() {
        let json = #"{"text":"ok after retry"}"#
        let transport = MockTransport(status: 200, body: Data(json.utf8))
        transport.sendError = URLError(.cannotConnectToHost)
        transport.failCount = 1 // first call fails, second succeeds
        let transcriber = makeTranscriber(transport: transport)

        runAsync("testRetryRecover") {
            let result = try await transcriber.transcribe(wav: self.wavData)
            XCTAssertEqual(result.text, "ok after retry")
            XCTAssertEqual(transport.requestCount, 2)
        }
    }

    // MARK: - NEW: 429 Retry-After из заголовка ответа

    /// 429 retried; pause taken from Retry-After header, not backoff.
    @objc func test429HonorsRetryAfterHeader() {
        let transport = MockTransport(status: 429, body: Data("rate limited".utf8))
        transport.responseHeaders = ["Retry-After": "3"]
        let recorder = SleepRecorder()
        let transcriber = makeTranscriber(transport: transport,
                                          retrySleep: { recorder.record($0) })

        runAsync("test429RetryAfter") {
            do {
                _ = try await transcriber.transcribe(wav: self.wavData)
                XCTFail("Expected .http(429)")
            } catch let error as TranscribeError {
                if case .http(let code, _) = error {
                    XCTAssertEqual(code, 429)
                } else {
                    XCTFail("Expected .http(429), got \(error)")
                }
            }
            XCTAssertEqual(transport.requestCount, 4, "429 ретраится до исчерпания попыток")
        }
        XCTAssertEqual(recorder.delays, [3, 3, 3], "каждая пауза = Retry-After 3 с")
    }

    /// Retry-After over 10 s capped at 10: total backoff bounded.
    @objc func test429RetryAfterCappedAtTenSeconds() {
        let transport = MockTransport(status: 429, body: Data("slow down".utf8))
        transport.responseHeaders = ["Retry-After": "60"]
        let recorder = SleepRecorder()
        let transcriber = makeTranscriber(transport: transport,
                                          retrySleep: { recorder.record($0) })

        runAsync("test429Cap") {
            do {
                _ = try await transcriber.transcribe(wav: self.wavData)
                XCTFail("Expected .http(429)")
            } catch let error as TranscribeError {
                if case .http(let code, _) = error {
                    XCTAssertEqual(code, 429)
                } else {
                    XCTFail("Expected .http(429), got \(error)")
                }
            }
        }
        XCTAssertEqual(recorder.delays, [10, 10, 10], "Retry-After 60 с ограничен капсом в 10 с")
    }

    // MARK: - NEW: Retry-After в формате HTTP-date (RFC 7231 §7.1.1.1)

    /// Retry-After as date (IMF-fixdate / RFC 850 / asctime):
    /// delay = (date − now) seconds, not nil.
    @objc func testRetryAfterHTTPDateParsedAsDelay() {
        let targetDelay: TimeInterval = 40
        let formats = [
            "EEE, dd MMM yyyy HH:mm:ss zzz",   // IMF-fixdate
            "EEEE, dd-MMM-yy HH:mm:ss zzz",   // obsolete RFC 850
            "EEE MMM d HH:mm:ss yyyy",        // asctime
        ]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            let dateString = formatter.string(from: Date().addingTimeInterval(targetDelay))
            let delay = Transcriber.retryAfterSeconds(from: ["Retry-After": dateString])
            XCTAssertNotNil(delay, "HTTP-date «\(dateString)» (\(format)) должен парситься")
            XCTAssertTrue(delay! > targetDelay - 5 && delay! < targetDelay + 5,
                          "задержка ≈ (дата − сейчас), got \(String(describing: delay))")
        }
    }

    /// Non-date, non-number → nil (default backoff), no crash.
    @objc func testRetryAfterGarbageReturnsNil() {
        XCTAssertNil(Transcriber.retryAfterSeconds(from: ["Retry-After": "soon!"]))
        XCTAssertNil(Transcriber.retryAfterSeconds(from: ["Retry-After": ""]))
    }

    // MARK: - NEW: отмена во время retrySleep не шлёт повторный POST

    /// Default retrySleep swallows cancel (try?) — Task.isCancelled checked at
    /// retry-loop top: after cancelAll (first parallel failover success)
    /// sibling sends no extra request.
    @objc func testCancelDuringRetrySleepSkipsRepeatRequest() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"ok"}"#.utf8))
        transport.sendError = URLError(.notConnectedToInternet)
        transport.failCount = 10 // all attempts fail if cancel not honored
        // No retrySleep injection: real sleep (first backoff ~1 s).
        let transcriber = Transcriber(baseURL: "https://example.test/v1/audio/transcriptions",
                                      model: "gigaam-v3",
                                      apiKey: "test-key",
                                      transport: transport,
                                      networkChecker: { true },
                                      adapterID: "gigaam")
        let done = expectation(description: "cancelled transcribe finished")
        let task = Task {
            _ = try? await transcriber.transcribe(wav: self.wavData)
            done.fulfill()
        }

        // Let first attempt fail into retrySleep, then cancel.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        task.cancel()
        wait(for: [done], timeout: 10)

        XCTAssertEqual(transport.requestCount, 1,
                       "после отмены во время сна повторный POST не отправляется")
    }

    // MARK: - NEW: 5xx ретраится, потом успех; 4xx (кроме 429) — терминально

    @objc func testHTTP500RetriedThenSucceeds() {
        let transport = StatusSequenceTransport(statuses: [500, 500, 200])
        // 500 → retry → 500 → retry → 200: third-attempt body is the answer.
        let transcriber = Transcriber(baseURL: "https://example.test/v1/audio/transcriptions",
                                      model: "gigaam-v3",
                                      apiKey: "test-key",
                                      transport: transport,
                                      networkChecker: { true },
                                      adapterID: "gigaam",
                                      retrySleep: { _ in })

        runAsync("test500Retried") {
            let result = try await transcriber.transcribe(wav: self.wavData)
            XCTAssertEqual(result.text, "ok after retries", "успех после ретраев 5xx")
        }
        XCTAssertEqual(transport.requestCount, 3, "две 500-попытки + успешная")
    }

    @objc func testHTTP400IsTerminalNoRetry() {
        let transport = StatusSequenceTransport(statuses: [400, 200])
        let transcriber = Transcriber(baseURL: "https://example.test/v1/audio/transcriptions",
                                      model: "gigaam-v3",
                                      apiKey: "test-key",
                                      transport: transport,
                                      networkChecker: { true },
                                      adapterID: "gigaam",
                                      retrySleep: { _ in })

        runAsync("test400Terminal") {
            do {
                _ = try await transcriber.transcribe(wav: self.wavData)
                XCTFail("Expected .http(400)")
            } catch let error as TranscribeError {
                if case .http(let code, _) = error {
                    XCTAssertEqual(code, 400)
                } else {
                    XCTFail("Expected .http(400), got \(error)")
                }
            }
        }
        XCTAssertEqual(transport.requestCount, 1, "4xx кроме 429 — терминальная ошибка, ретраев нет")
    }

    // MARK: - NEW: Word-таймстампы из verbose_json

    /// Successful verbose_json response: words[] parsed into TranscriptionResult.
    @objc func testSuccessParsesWordTimestamps() {
        let json = #"{"text":"один два","words":[{"word":"один","start":0.1,"end":0.5},{"word":"два","start":0.6,"end":1.0}]}"#
        let transport = MockTransport(status: 200, body: Data(json.utf8))
        let transcriber = makeTranscriber(transport: transport)

        runAsync("testWordsParsed") {
            let result = try await transcriber.transcribe(wav: self.wavData)
            XCTAssertEqual(result.text, "один два")
            XCTAssertEqual(result.words.count, 2)
            XCTAssertEqual(result.words[0].word, "один")
            XCTAssertEqual(result.words[0].start, 0.1, accuracy: 0.0001)
            XCTAssertEqual(result.words[0].end, 0.5, accuracy: 0.0001)
            XCTAssertEqual(result.words[1].word, "два")
            XCTAssertEqual(result.words[1].end, 1.0, accuracy: 0.0001)
        }
    }

    /// Without words[] (plain text response) — timestamp list empty.
    @objc func testSuccessWithoutWordsKeepsEmptyList() {
        let json = #"{"text":"просто текст"}"#
        let transport = MockTransport(status: 200, body: Data(json.utf8))
        let transcriber = makeTranscriber(transport: transport)

        runAsync("testEmptyWords") {
            let result = try await transcriber.transcribe(wav: self.wavData)
            XCTAssertEqual(result.text, "просто текст")
            XCTAssertTrue(result.words.isEmpty, "words по умолчанию пуст")
        }
    }

    // MARK: - Timeout error → terminal .network("Таймаут STT") WITHOUT retry

    @objc func testTimeoutErrorReturnsNetwork() {
        let transport = MockTransport(status: 0, body: Data(),
                                      sendError: URLError(.timedOut))
        let transcriber = makeTranscriber(transport: transport)

        runAsync("testTimeout") {
            do {
                _ = try await transcriber.transcribe(wav: self.wavData)
                XCTFail("Expected .network")
            } catch let error as TranscribeError {
                if case .network(let msg) = error {
                    XCTAssertEqual(msg, Transcriber.sttTimeoutMessage, "таймаут — это каноническое «Таймаут STT»")
                } else {
                    XCTFail("Expected .network, got \(error)")
                }
            }
            XCTAssertEqual(transport.requestCount, 1,
                           "сетевой таймаут терминальный — повторный запрос почти наверняка упрётся в тот же таймаут")
        }
    }

    // MARK: - NEW: Authorization header contains Bearer

    @objc func testAuthorizationBearerHeader() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"x"}"#.utf8))
        let transcriber = Transcriber(baseURL: "https://test.api/endpoint",
                                      model: "m",
                                      apiKey: "my-secret-token",
                                      transport: transport,
                                      networkChecker: { true },
                                      adapterID: "gigaam")

        runAsync("testAuthHeader") {
            _ = try await transcriber.transcribe(wav: self.wavData)
            guard let req = transport.lastRequest else {
                XCTFail("No request")
                return
            }
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer my-secret-token")
        }
    }

    // MARK: - NEW: X-Proxy-Key sent only when proxyKey is set

    @objc func testProxyKeyHeaderSentWhenSet() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"x"}"#.utf8))
        let transcriber = Transcriber(baseURL: "https://test.api/endpoint",
                                      model: "m",
                                      apiKey: "k",
                                      proxyKey: "proxy-secret",
                                      transport: transport,
                                      networkChecker: { true },
                                      adapterID: "gigaam")

        runAsync("testProxyKeySet") {
            _ = try await transcriber.transcribe(wav: self.wavData)
            guard let req = transport.lastRequest else {
                XCTFail("No request")
                return
            }
            XCTAssertEqual(req.value(forHTTPHeaderField: "X-Proxy-Key"), "proxy-secret")
        }
    }

    @objc func testProxyKeyHeaderAbsentWhenEmpty() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"x"}"#.utf8))
        let transcriber = Transcriber(baseURL: "https://test.api/endpoint",
                                      model: "m",
                                      apiKey: "k",
                                      transport: transport,
                                      networkChecker: { true },
                                      adapterID: "gigaam")

        runAsync("testProxyKeyEmpty") {
            _ = try await transcriber.transcribe(wav: self.wavData)
            guard let req = transport.lastRequest else {
                XCTFail("No request")
                return
            }
            XCTAssertNil(req.value(forHTTPHeaderField: "X-Proxy-Key"))
        }
    }

    // MARK: - NEW: Multipart body field names

    @objc func testMultipartBodyFieldNames() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"x"}"#.utf8))
        let transcriber = makeTranscriber(transport: transport)

        runAsync("testFieldNames") {
            _ = try await transcriber.transcribe(wav: self.wavData, filename: "recording.wav")
            guard let body = transport.lastRequest?.httpBody,
                  let text = String(data: body, encoding: .utf8) else {
                XCTFail("No body")
                return
            }
            XCTAssertTrue(text.contains("name=\"file\""))
            XCTAssertTrue(text.contains("filename=\"recording.wav\""))
            XCTAssertTrue(text.contains("name=\"model\""))
            XCTAssertTrue(text.contains("gigaam-v3"))
        }
    }

    // MARK: - NEW: без явного language (default) поле language в multipart НЕ шлётся
    // (авто-детект Whisper); явное language = "ru" — шлётся ровно как задано.

    @objc func testRequestOmitsLanguageFieldByDefault() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"x"}"#.utf8))
        // Default Transcriber has language = "" (авто-детект)
        let transcriber = makeTranscriber(transport: transport)

        runAsync("testDefaultNoLanguage") {
            _ = try await transcriber.transcribe(wav: self.wavData, filename: "audio.wav")
            guard let body = transport.lastRequest?.httpBody,
                  let text = String(data: body, encoding: .utf8) else {
                XCTFail("No HTTP body")
                return
            }
            XCTAssertFalse(text.contains("name=\"language\""),
                           "default: язык не задан — поле language не должно уходить в запрос (авто-детект)")
        }
    }

    @objc func testRequestContainsLanguageFieldWhenExplicit() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"x"}"#.utf8))
        let transcriber = Transcriber(baseURL: "https://test.api/endpoint",
                                      model: "m",
                                      apiKey: "k",
                                      language: "ru",
                                      transport: transport,
                                      networkChecker: { true },
                                      adapterID: "gigaam")

        runAsync("testLanguageField") {
            _ = try await transcriber.transcribe(wav: self.wavData, filename: "audio.wav")
            guard let body = transport.lastRequest?.httpBody,
                  let text = String(data: body, encoding: .utf8) else {
                XCTFail("No HTTP body")
                return
            }
            XCTAssertTrue(text.contains("Content-Disposition: form-data; name=\"language\"\r\n"),
                          "multipart должен содержать поле language")
            XCTAssertTrue(text.contains("\r\nru\r\n"), "поля language должно иметь значение ru")
        }
    }

    // MARK: - NEW: language omitted from multipart body when empty

    @objc func testLanguageFieldAbsentWhenEmpty() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"x"}"#.utf8))
        let transcriber = Transcriber(baseURL: "https://test.api/endpoint",
                                      model: "m",
                                      apiKey: "k",
                                      language: "",
                                      transport: transport,
                                      networkChecker: { true },
                                      adapterID: "gigaam")

        runAsync("testLanguageEmpty") {
            _ = try await transcriber.transcribe(wav: self.wavData, filename: "audio.wav")
            guard let body = transport.lastRequest?.httpBody,
                  let text = String(data: body, encoding: .utf8) else {
                XCTFail("No HTTP body")
                return
            }
            XCTAssertFalse(text.contains("name=\"language\""), "при пустом language поле должно отсутствовать")
        }
    }

    // MARK: - NEW: Preflight сети — сети нет → запрос НЕ отправляется вовсе

    @objc func testNoNetwork_NoRequestSent_ImmediateNoInternetError() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"не должно дойти"}"#.utf8))
        let transcriber = Transcriber(baseURL: "https://example.test/v1/audio/transcriptions",
                                      model: "gigaam-v3",
                                      apiKey: "test-key",
                                      transport: transport,
                                      networkChecker: { false },
                                      adapterID: "gigaam")

        runAsync("testPreflightBlocked") {
            do {
                _ = try await transcriber.transcribe(wav: self.wavData)
                XCTFail("Expected .network («Нет интернета»)")
            } catch let error as TranscribeError {
                if case .network(let msg) = error {
                    XCTAssertEqual(msg, Transcriber.noInternetMessage,
                                   "нет сети — каноническое сообщение для оверлея")
                } else {
                    XCTFail("Expected .network, got \(error)")
                }
            }
            XCTAssertEqual(transport.requestCount, 0,
                           "preflight зарубил запрос — HTTP-вызовов быть не должно")
        }
    }

    @objc func testNoNetworkInDebug_NoRequestSent_NoInternetError() {
        // No network, even with log_level == "debug": preflight blocks
        // request before HTTP — no outgoing calls, canonical "no internet"
        // error. Recording dump/save not tested here.
        let transport = MockTransport(status: 200, body: Data())
        let transcriber = Transcriber(baseURL: "https://example.test/v1/audio/transcriptions",
                                      model: "gigaam-v3",
                                      apiKey: "k",
                                      logLevel: "debug",
                                      transport: transport,
                                      networkChecker: { false },
                                      adapterID: "gigaam")

        runAsync("testNoNetworkInDebugNoRequestSent") {
            do {
                _ = try await transcriber.transcribe(wav: self.wavData)
                XCTFail("Expected .network")
            } catch let error as TranscribeError {
                if case .network(let msg) = error {
                    XCTAssertEqual(msg, Transcriber.noInternetMessage)
                } else {
                    XCTFail("Expected .network, got \(error)")
                }
            }
            XCTAssertEqual(transport.requestCount, 0)
        }
    }

    @objc func testNetworkAvailable_RequestIsSent() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"должно дойти"}"#.utf8))
        let transcriber = Transcriber(baseURL: "https://example.test/v1/audio/transcriptions",
                                      model: "gigaam-v3",
                                      apiKey: "test-key",
                                      transport: transport,
                                      networkChecker: { true },
                                      adapterID: "gigaam")

        runAsync("testPreflightAllowed") {
            let result = try await transcriber.transcribe(wav: self.wavData)
            XCTAssertEqual(result.text, "должно дойти")
            XCTAssertEqual(transport.requestCount, 1, "preflight пропустил — запрос уходит")
        }
    }

    // MARK: - NEW: Жёсткий сетевой таймаут (min(config, networkRequestTimeout))

    @objc func testTimeoutInterval_CapsByNetworkRequestTimeout() {
        // Default config (120 s) cannot raise network timeout above 20 s.
        let transport = MockTransport(status: 200, body: Data(#"{"text":"x"}"#.utf8))
        let transcriber = Transcriber(baseURL: "https://test.api/endpoint",
                                      model: "m",
                                      apiKey: "k",
                                      timeout: 120,
                                      transport: transport,
                                      networkChecker: { true },
                                      adapterID: "gigaam")

        runAsync("testTimeoutCap") {
            _ = try await transcriber.transcribe(wav: self.wavData)
            guard let req = transport.lastRequest else {
                XCTFail("No request")
                return
            }
            XCTAssertEqual(req.timeoutInterval, Transcriber.networkRequestTimeout,
                           "конфиг 120 с должен обрезаться до жёстких 20 с")
        }
    }

    @objc func testTimeoutInterval_ConfigSmallerThanCapIsRespected() {
        // Smaller config value (5 s) caps network timeout.
        let transport = MockTransport(status: 200, body: Data(#"{"text":"x"}"#.utf8))
        let transcriber = Transcriber(baseURL: "https://test.api/endpoint",
                                      model: "m",
                                      apiKey: "k",
                                      timeout: 5,
                                      transport: transport,
                                      networkChecker: { true },
                                      adapterID: "gigaam")

        runAsync("testTimeoutConfigLower") {
            _ = try await transcriber.transcribe(wav: self.wavData)
            guard let req = transport.lastRequest else {
                XCTFail("No request")
                return
            }
            XCTAssertEqual(req.timeoutInterval, 5, "меньший таймаут конфига должен работать")
        }
    }

    // MARK: - NEW: prompt — контекст сегментов (пошаговая диктовка)

    @objc func testPromptFieldAddedWhenProvided() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"x"}"#.utf8))
        let transcriber = makeTranscriber(transport: transport)

        runAsync("testPromptAdded") {
            _ = try await transcriber.transcribe(wav: self.wavData, filename: "seg-1.wav", prompt: "Один два.")
            guard let body = transport.lastRequest?.httpBody,
                  let text = String(data: body, encoding: .utf8) else {
                XCTFail("No HTTP body")
                return
            }
            XCTAssertTrue(text.contains("name=\"prompt\""), "multipart должен содержать поле prompt")
            XCTAssertTrue(text.contains("Один два."), "поле prompt должно нести контекст сегментов")
        }
    }

    @objc func testPromptFieldAbsentWhenNil() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"x"}"#.utf8))
        let transcriber = makeTranscriber(transport: transport)

        runAsync("testPromptAbsent") {
            // Legacy path (chunked = false): prompt not sent at all.
            _ = try await transcriber.transcribe(wav: self.wavData)
            guard let body = transport.lastRequest?.httpBody,
                  let text = String(data: body, encoding: .utf8) else {
                XCTFail("No HTTP body")
                return
            }
            XCTAssertFalse(text.contains("name=\"prompt\""), "при nil prompt поле должно отсутствовать")
        }
    }

    @objc func testPromptFieldAbsentWhenEmptyString() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"x"}"#.utf8))
        let transcriber = makeTranscriber(transport: transport)

        runAsync("testPromptEmpty") {
            // Empty prompt (nothing to give as context) — no field.
            _ = try await transcriber.transcribe(wav: self.wavData, prompt: "")
            guard let body = transport.lastRequest?.httpBody,
                  let text = String(data: body, encoding: .utf8) else {
                XCTFail("No HTTP body")
                return
            }
            XCTAssertFalse(text.contains("name=\"prompt\""), "при пустом prompt поле должно отсутствовать")
        }
    }

    // MARK: - NEW: NetworkReachability — чистая логика «есть ли интернет»

    @objc func testReachability_Unsatisfied_AlwaysNoInternet() {
        XCTAssertFalse(NetworkReachability.isReachable(status: .unsatisfied, possibleExternalRoute: true))
        XCTAssertFalse(NetworkReachability.isReachable(status: .unsatisfied, possibleExternalRoute: false))
    }

    @objc func testReachability_RequiresConnection_ProbeOptimistically() {
        // On-demand route (VPN/PPP) — try request, timeout covers.
        XCTAssertTrue(NetworkReachability.isReachable(status: .requiresConnection, possibleExternalRoute: false))
        XCTAssertTrue(NetworkReachability.isReachable(status: .requiresConnection, possibleExternalRoute: true))
    }

    @objc func testReachability_Satisfied_NeedsExternalRoute() {
        // Loopback-only cannot reach external API.
        XCTAssertTrue(NetworkReachability.isReachable(status: .satisfied, possibleExternalRoute: true))
        XCTAssertFalse(NetworkReachability.isReachable(status: .satisfied, possibleExternalRoute: false))
    }

    // MARK: - Cookie-relay (transport == "cookie-relay")

    private let cookieRelayChallengeHTML = """
    <html><body><script type="text/javascript" src="/aes.js" ></script><script>function toNumbers(d){var e=[];d.replace(/(..)/g,function(d){e.push(parseInt(d,16))});return e}function toHex(){for(var d=[],d=1==arguments.length&&arguments[0].constructor==Array?arguments[0]:arguments,e="",f=0;f<d.length;f++)e+=(16>d[f]?"0":"")+d[f].toString(16);return e.toLowerCase()}var a=toNumbers("f655ba9d09a112d4968c63579db590b4"),b=toNumbers("98344c2eee86c3994890592585b49f80"),c=toNumbers("3e512bc3e42f39a757e79f4739c74138");document.cookie="__test="+toHex(slowAES.decrypt(c,2,a,b))+"; max-age=21600; expires=Thu, 31-Dec-37 23:55:55 GMT; path=/"; location.href="https://proxy.example.com/?i=1";</script><noscript>This site requires Javascript to work, please enable Javascript in your browser or use a browser with Javascript support</noscript></body></html>
    """

    private func makeCookieRelayTranscriber(
        sttTransport: CookieRelayMockTransport,
        relayTransport: CookieRelayMockTransport?
    ) -> Transcriber {
        let relay = relayTransport.map { CookieRelayProvider(origin: "https://proxy.example.com", transport: $0) }
        return Transcriber(baseURL: "https://proxy.example.com/go/https://api.example/v1/audio/transcriptions",
                           model: "gigaam-v3",
                           apiKey: "test-key",
                           transport: sttTransport,
                           networkChecker: { true },
                           cookieRelayProvider: relay,
                           adapterID: "gigaam")
    }

    @objc func testCookieRelaySetsCookieAndChromeUA() {
        let stt = CookieRelayMockTransport(challengeBody: cookieRelayChallengeHTML)
        let relayTransport = CookieRelayMockTransport(challengeBody: cookieRelayChallengeHTML)
        let relay = CookieRelayProvider(origin: "https://proxy.example.com", transport: relayTransport)

        runAsync("testCookieRelayHeaders") {
            // Token warm-up — first request already carries cookie (same
            // CookieRelayProvider as in Transcriber: token in memory).
            _ = await relay.refreshBlocking()

            let transcriber = Transcriber(baseURL: "https://proxy.example.com/go/https://api.example/v1/audio/transcriptions",
                                          model: "gigaam-v3",
                                          apiKey: "test-key",
                                          transport: stt,
                                          networkChecker: { true },
                                          cookieRelayProvider: relay,
                                          adapterID: "gigaam")
            let result = try await transcriber.transcribe(wav: self.wavData)
            XCTAssertEqual(result.text, "ok")
            guard let req = stt.lastRequest else {
                XCTFail("No STT request captured")
                return
            }
            XCTAssertEqual(req.value(forHTTPHeaderField: "Cookie"), "__test=d74696de7d49fcda5f03f4d247e07cf4")
            XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), CookieRelayProvider.chromeUA)
            XCTAssertEqual(stt.requestCount, 1, "cookie был свежий — челленджа и ретрая нет")
        }
    }

    @objc func testNoCookieRelayNoCookieNoUA() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"x"}"#.utf8))
        let transcriber = makeTranscriber(transport: transport)

        runAsync("testNoCookieRelayHeaders") {
            _ = try await transcriber.transcribe(wav: self.wavData)
            guard let req = transport.lastRequest else {
                XCTFail("No request")
                return
            }
            XCTAssertNil(req.value(forHTTPHeaderField: "Cookie"),
                         "без cookie-relay cookie-логики быть не должно")
            XCTAssertNil(req.value(forHTTPHeaderField: "User-Agent"),
                         "без cookie-relay фиксированный UA не подставляется (как раньше)")
        }
    }

    @objc func testChallengeTriggersSingleRetryWithFreshCookie() {
        let stt = CookieRelayMockTransport(challengeBody: cookieRelayChallengeHTML, rejectPostCount: 1)
        let relayTransport = CookieRelayMockTransport(challengeBody: cookieRelayChallengeHTML)
        let transcriber = makeCookieRelayTranscriber(sttTransport: stt, relayTransport: relayTransport)

        runAsync("testChallengeRetry") {
            let result = try await transcriber.transcribe(wav: self.wavData)
            XCTAssertEqual(result.text, "ok")
            XCTAssertEqual(stt.postCount, 2, "STT-попыток ровно 2 (мёртвая кука НЕ сжигает попытку)")
            XCTAssertEqual(relayTransport.requestCount, 2, "refresh = GET челленджа + probe GET")
            guard let retry = stt.requests.first(where: { $0.httpMethod == "POST" && $0.value(forHTTPHeaderField: "Cookie") != nil }) else {
                XCTFail("Ретрай должен идти со свежей кукой")
                return
            }
            XCTAssertEqual(retry.value(forHTTPHeaderField: "Cookie"), "__test=d74696de7d49fcda5f03f4d247e07cf4")
            XCTAssertEqual(retry.value(forHTTPHeaderField: "User-Agent"), CookieRelayProvider.chromeUA)
        }
    }

    @objc func testAlwaysChallengeRetriesOnceThenInvalidResponse() {
        // Both STT-POSTs face challenge even with fresh cookie: refresh ok
        // (probe GET accepted cookie), STT endpoint still challenges.
        let stt = CookieRelayMockTransport(challengeBody: cookieRelayChallengeHTML, rejectPostCount: 2)
        let relayTransport = CookieRelayMockTransport(challengeBody: cookieRelayChallengeHTML)
        let transcriber = makeCookieRelayTranscriber(sttTransport: stt, relayTransport: relayTransport)

        runAsync("testAlwaysChallenge") {
            do {
                _ = try await transcriber.transcribe(wav: self.wavData)
                XCTFail("Expected TranscribeError.invalidResponse")
            } catch let error as TranscribeError {
                if case .invalidResponse(let msg) = error {
                    XCTAssertFalse(msg.isEmpty)
                } else {
                    XCTFail("Expected .invalidResponse, got \(error)")
                }
            }
            XCTAssertEqual(stt.postCount, 2, "ровно 2 STT-POST: исходный + один ретрай со свежей кукой")
            XCTAssertEqual(relayTransport.requestCount, 2, "cookie пересчитан один раз")
        }
    }

    @objc func testChallengeRefreshFailureThrowsInvalidResponse() {
        // Probe rejects fresh cookie (honorCookie=false) → refresh gave no
        // token → no retry, error marked as challenge.
        let stt = CookieRelayMockTransport(challengeBody: cookieRelayChallengeHTML, rejectPostCount: 1)
        let relayTransport = CookieRelayMockTransport(challengeBody: cookieRelayChallengeHTML, honorCookie: false)
        let transcriber = makeCookieRelayTranscriber(sttTransport: stt, relayTransport: relayTransport)

        runAsync("testChallengeRefreshFails") {
            do {
                _ = try await transcriber.transcribe(wav: self.wavData)
                XCTFail("Expected TranscribeError.invalidResponse")
            } catch let error as TranscribeError {
                if case .invalidResponse(let msg) = error {
                    XCTAssertTrue(msg.contains("challenge"))
                } else {
                    XCTFail("Expected .invalidResponse, got \(error)")
                }
            }
            XCTAssertEqual(stt.postCount, 1, "без свежего токена ретрая нет")
            XCTAssertEqual(relayTransport.requestCount, 2, "refresh всё же сходил за токеном")
        }
    }

    // MARK: - HTTP-прокси (transport == "http")

    @objc func testHTTPProxyRewritesURLAndAddsProxyAuthorization() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"ok"}"#.utf8))
        let transcriber = Transcriber(
            baseURL: "https://api.example/v1/audio/transcriptions",
            model: "gigaam-v3",
            apiKey: "test-key",
            transport: transport,
            networkChecker: { true },
            httpProxy: "https://proxy.example.com:8080",
            proxyUser: "alice",
            proxyPassword: "secret",
            adapterID: "gigaam"
        )

        runAsync("testHTTPProxyRewrite") {
            let result = try await transcriber.transcribe(wav: self.wavData)
            XCTAssertEqual(result.text, "ok")
            guard let req = transport.lastRequest else {
                XCTFail("No STT request captured")
                return
            }
            XCTAssertEqual(
                req.url?.absoluteString,
                "https://proxy.example.com:8080/https://api.example/v1/audio/transcriptions",
                "URL переписан: https://<httpProxy>/<полный-исходный-URL>"
            )
            let expected = "Basic " + Data("alice:secret".utf8).base64EncodedString()
            XCTAssertEqual(req.value(forHTTPHeaderField: "Proxy-Authorization"), expected)
        }
    }

    @objc func testHTTPProxyWithoutCredentialsSkipsProxyAuthorization() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"ok"}"#.utf8))
        let transcriber = Transcriber(
            baseURL: "https://api.example/v1/audio/transcriptions",
            model: "gigaam-v3",
            apiKey: "test-key",
            transport: transport,
            networkChecker: { true },
            httpProxy: "https://proxy.example.com:8080",
            adapterID: "gigaam"
        )

        runAsync("testHTTPProxyNoCreds") {
            _ = try await transcriber.transcribe(wav: self.wavData)
            guard let req = transport.lastRequest else {
                XCTFail("No STT request captured")
                return
            }
            XCTAssertEqual(
                req.url?.absoluteString,
                "https://proxy.example.com:8080/https://api.example/v1/audio/transcriptions",
                "без кредов URL всё равно переписывается"
            )
            XCTAssertNil(
                req.value(forHTTPHeaderField: "Proxy-Authorization"),
                "без proxy_user заголовок не добавляется"
            )
        }
    }

    @objc func testWithoutHTTPProxyURLAintRewritten() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"ok"}"#.utf8))
        let transcriber = makeTranscriber(transport: transport)

        runAsync("testNoHTTPProxy") {
            _ = try await transcriber.transcribe(wav: self.wavData)
            guard let req = transport.lastRequest else {
                XCTFail("No STT request captured")
                return
            }
            XCTAssertFalse(
                req.url?.absoluteString.hasPrefix("http://proxy") ?? true,
                "без http_proxy URL остаётся исходным"
            )
            XCTAssertNil(req.value(forHTTPHeaderField: "Proxy-Authorization"))
        }
    }

    // MARK: - Адаптерный путь (adapterID)

    @objc func testAdapterOpenAIResolvesDefaultsAndSendsMultipart() {
        // Empty baseURL/model + adapterID "openai" → adapter defaults resolved
        // in plan(): request goes to api.openai.com with whisper-1, multipart.
        let transport = MockTransport(status: 200, body: Data(#"{"text":"привет"}"#.utf8))
        let transcriber = Transcriber(
            baseURL: "", model: "", apiKey: "sk-openai",
            language: "ru", transport: transport, networkChecker: { true },
            adapterID: "openai"
        )

        runAsync("testAdapterOpenAI") {
            let result = try await transcriber.transcribe(wav: self.wavData)
            XCTAssertEqual(result.text, "привет")
        }
        XCTAssertEqual(transport.requestCount, 1)
        XCTAssertEqual(transport.lastRequest?.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(transport.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer sk-openai")
        XCTAssertTrue((transport.lastRequest?.value(forHTTPHeaderField: "Content-Type") ?? "")
            .hasPrefix("multipart/form-data; boundary=Boundary-"), "multipart контент-тип")
        let bodyText = String(data: transport.lastRequest?.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(bodyText.contains("name=\"file\"; filename=\"audio.wav\""))
        XCTAssertTrue(bodyText.contains("whisper-1"))
        XCTAssertTrue(bodyText.contains("name=\"language\""))
    }

    @objc func testAdapterCloudflareRawAudioAndTranscriptPath() {
        // cloudflare: raw audio + Content-Type audio/wav, Bearer,
        // baseURL as-is (model baked into URL), text via
        // transcriptPath ["result","text"] from Workers AI response.
        let cfJSON = #"{"result":{"text":"привет тайге"}}"#
        let transport = MockTransport(status: 200, body: Data(cfJSON.utf8))
        let transcriber = Transcriber(
            baseURL: "https://api.cloudflare.com/client/v4/accounts/acct/ai/run/@cf/openai/whisper-large-v3-turbo",
            model: "", apiKey: "cf-key",
            language: "ru", transport: transport, networkChecker: { true },
            adapterID: "cloudflare"
        )

        runAsync("testAdapterCloudflare") {
            let result = try await transcriber.transcribe(wav: self.wavData)
            XCTAssertEqual(result.text, "привет тайге")
        }
        XCTAssertEqual(transport.requestCount, 1)
        XCTAssertEqual(
            transport.lastRequest?.url?.absoluteString,
            "https://api.cloudflare.com/client/v4/accounts/acct/ai/run/@cf/openai/whisper-large-v3-turbo",
            "baseURL используется как есть"
        )
        XCTAssertEqual(transport.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Bearer cf-key")
        XCTAssertEqual(transport.lastRequest?.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
        XCTAssertEqual(transport.lastRequest?.httpBody, wavData, "тело = сырое аудио, не multipart")
    }

    /// Cloudflare adapter with empty baseURL: no request built (no default
    /// endpoint) — fails with request error before HTTP.
    @objc func testAdapterCloudflareNegativeMissingBaseURL() {
        let transport = MockTransport(status: 200, body: Data(#"{"result":{"text":"x"}}"#.utf8))
        let transcriber = Transcriber(
            baseURL: "", model: "", apiKey: "cf-key",
            transport: transport, networkChecker: { true },
            adapterID: "cloudflare"
        )

        runAsync("testAdapterCloudflareNoURL") {
            do {
                _ = try await transcriber.transcribe(wav: self.wavData)
                XCTFail("Expected .network (нет baseURL)")
            } catch let error as TranscribeError {
                guard case .network(let msg) = error else {
                    XCTFail("Expected .network, got \(error)")
                    return
                }
                XCTAssertEqual(msg, "Invalid base URL")
            }
        }
        XCTAssertEqual(transport.requestCount, 0, "запрос не строится — HTTP-вызовов нет")
    }

    /// adapterID == nil + no baseURL (provider not configured): transcribe()
    /// fails immediately, before preflight and request build — no HTTP calls.
    @objc func testTranscribeWithoutAdapterIDThrows() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"x"}"#.utf8))
        let transcriber = Transcriber(
            baseURL: "",
            model: "gigaam-v3",
            apiKey: "test-key",
            transport: transport,
            networkChecker: { true },
            adapterID: nil
        )

        runAsync("testTranscribeNoAdapterID") {
            do {
                _ = try await transcriber.transcribe(wav: self.wavData)
                XCTFail("Expected .network (нет провайдера)")
            } catch let error as TranscribeError {
                guard case .network(let msg) = error else {
                    XCTFail("Expected .network, got \(error)")
                    return
                }
                XCTAssertEqual(msg, "No STT provider configured")
            }
        }
        XCTAssertEqual(transport.requestCount, 0, "без провайдера запрос не строится — HTTP-вызовов нет")
    }

    // MARK: - NEW: пустой apiKey — Authorization не уходит в запрос

    /// Пустой apiKey: адаптер строит в spec.headers «Authorization: Bearer \(apiKey)»
    /// → «Bearer » без токена (planOpenAICompatible); transcribeViaAdapter скипает
    /// такой заголовок — в исходящий запрос Authorization не попадает вовсе
    /// (эталон — BatchRequestBuilder.makeRequest). Непустой ключ покрыт
    /// testAuthorizationBearerHeader («Bearer my-secret-token»).
    @objc func testEmptyApiKeyOmitsAuthorizationHeader() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"x"}"#.utf8))
        let transcriber = Transcriber(baseURL: "https://test.api/endpoint",
                                      model: "m",
                                      apiKey: "",
                                      transport: transport,
                                      networkChecker: { true },
                                      adapterID: "gigaam")

        runAsync("testEmptyApiKeyNoAuth") {
            _ = try await transcriber.transcribe(wav: self.wavData)
            guard let req = transport.lastRequest else {
                XCTFail("No request")
                return
            }
            XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"),
                         "пустой apiKey не должен давать «Bearer » без токена")
        }
    }
}
