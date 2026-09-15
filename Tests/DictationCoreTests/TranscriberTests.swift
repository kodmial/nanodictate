import Foundation
@testable import DictationCore

// MARK: - MockTransport

final class MockTransport: HTTPTransport, @unchecked Sendable {

    var status: Int
    var body: Data
    var sendError: Error?

    /// Если заданы, подставляются в ответ (нужны для Retry-After).
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

/// Транспорт с последовательностью HTTP-статусов: отдаёт статусы списком по
/// очереди, последний — навсегда (проверка ретраев 5xx и терминальности 4xx).
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

/// Записывает паузы между ретраями (инъекция retrySleep) — thread-safe, зовётся
/// из async-контекста.
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
            // Data.contains(_ other: Data) требует macOS 13 — на 12 используем range.
            XCTAssertTrue(body.range(of: self.wavData) != nil)
        }
    }

    // MARK: Retry on network error

    /// Сетевая ошибка ретраится до исчерпания попыток (maxAttempts = 4):
    /// каждая попытка снова даёт .cannotConnectToHost.
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

    /// Паузы между попытками: экспоненциальный backoff 0.5·2^n плюс джиттер
    /// (0…0.25 с). Ретраи идут не мгновенно и с РАСТУЩЕЙ задержкой.
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

    /// 429 ретраится, а пауза берётся ИЗ заголовка Retry-After, а не из backoff.
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

    /// Retry-After больше 10 с срезается на 10: суммарный backoff ограничен.
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

    /// Retry-After датой (IMF-fixdate / RFC 850 / asctime): задержка =
    /// (дата − сейчас) в секундах, а не nil.
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

    /// Не-дата и не-число → nil (тогда дефолтный backoff), а не крах.
    @objc func testRetryAfterGarbageReturnsNil() {
        XCTAssertNil(Transcriber.retryAfterSeconds(from: ["Retry-After": "soon!"]))
        XCTAssertNil(Transcriber.retryAfterSeconds(from: ["Retry-After": ""]))
    }

    // MARK: - NEW: отмена во время retrySleep не шлёт повторный POST

    /// Дефолтный retrySleep глотает отмену (try?), поэтому проверка
    /// Task.isCancelled — в начале итерации ретрай-цикла: после cancelAll
    /// (первый успех параллельного failover) сиблинг НЕ делает лишний запрос.
    @objc func testCancelDuringRetrySleepSkipsRepeatRequest() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"ok"}"#.utf8))
        transport.sendError = URLError(.notConnectedToInternet)
        transport.failCount = 10 // все попытки падают — если отмена не сработает
        // БЕЗ инъекции retrySleep: реальный сон (backoff первой попытки ~1 c).
        let transcriber = Transcriber(baseURL: "https://example.test/v1/audio/transcriptions",
                                      model: "gigaam-v3",
                                      apiKey: "test-key",
                                      transport: transport,
                                      networkChecker: { true })
        let done = expectation(description: "cancelled transcribe finished")
        let task = Task {
            _ = try? await transcriber.transcribe(wav: self.wavData)
            done.fulfill()
        }

        // Даём первой попытке упасть и уйти в retrySleep, затем отменяем.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        task.cancel()
        wait(for: [done], timeout: 10)

        XCTAssertEqual(transport.requestCount, 1,
                       "после отмены во время сна повторный POST не отправляется")
    }

    // MARK: - NEW: 5xx ретраится, потом успех; 4xx (кроме 429) — терминально

    @objc func testHTTP500RetriedThenSucceeds() {
        let transport = StatusSequenceTransport(statuses: [500, 500, 200])
        // 500 → ретрай → 500 → ретрай → 200: тело с третьей попытки и есть ответ.
        let transcriber = Transcriber(baseURL: "https://example.test/v1/audio/transcriptions",
                                      model: "gigaam-v3",
                                      apiKey: "test-key",
                                      transport: transport,
                                      networkChecker: { true },
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

    /// Успешный verbose_json-ответ: words[] разбираются в TranscriptionResult.
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

    /// Без words[] (обычный text-ответ) — список таймстампов пустой.
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
                                      networkChecker: { true })

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
                                      networkChecker: { true })

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
                                      networkChecker: { true })

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

    // MARK: - NEW: language=ru form field in multipart body (default)

    @objc func testRequestContainsLanguageField() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"x"}"#.utf8))
        // Default Transcriber has language = "ru"
        let transcriber = makeTranscriber(transport: transport)

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
                                      networkChecker: { true })

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
                                      networkChecker: { false })

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
        // Нет сети, даже при log_level == "debug": preflight рубит запрос до
        // HTTP — исходящих вызовов нет, ошибка каноническое «Нет интернета».
        // (Сам дамп и сохранение записи этим тестом не проверяются.)
        let transport = MockTransport(status: 200, body: Data())
        let transcriber = Transcriber(baseURL: "https://example.test/v1/audio/transcriptions",
                                      model: "gigaam-v3",
                                      apiKey: "k",
                                      logLevel: "debug",
                                      transport: transport,
                                      networkChecker: { false })

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
                                      networkChecker: { true })

        runAsync("testPreflightAllowed") {
            let result = try await transcriber.transcribe(wav: self.wavData)
            XCTAssertEqual(result.text, "должно дойти")
            XCTAssertEqual(transport.requestCount, 1, "preflight пропустил — запрос уходит")
        }
    }

    // MARK: - NEW: Жёсткий сетевой таймаут (min(config, networkRequestTimeout))

    @objc func testTimeoutInterval_CapsByNetworkRequestTimeout() {
        // Конфиг по умолчанию (120 с) не может поднять сетевой таймаут выше 20 с.
        let transport = MockTransport(status: 200, body: Data(#"{"text":"x"}"#.utf8))
        let transcriber = Transcriber(baseURL: "https://test.api/endpoint",
                                      model: "m",
                                      apiKey: "k",
                                      timeout: 120,
                                      transport: transport,
                                      networkChecker: { true })

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
        // Меньшее значение из конфига (5 с) ОГРАНИЧИВАЕТ сетевой таймаут.
        let transport = MockTransport(status: 200, body: Data(#"{"text":"x"}"#.utf8))
        let transcriber = Transcriber(baseURL: "https://test.api/endpoint",
                                      model: "m",
                                      apiKey: "k",
                                      timeout: 5,
                                      transport: transport,
                                      networkChecker: { true })

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
            // Старый путь (chunked = false): prompt не передаётся вообще.
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
            // Пустой prompt (нечего давать в контекст) — поля быть не должно.
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
        // Маршрут по требованию (VPN/PPP) — пробуем запрос, таймаут подстрахует.
        XCTAssertTrue(NetworkReachability.isReachable(status: .requiresConnection, possibleExternalRoute: false))
        XCTAssertTrue(NetworkReachability.isReachable(status: .requiresConnection, possibleExternalRoute: true))
    }

    @objc func testReachability_Satisfied_NeedsExternalRoute() {
        // Одна лишь локальная петля (loopback-only) до внешнего API не достанет.
        XCTAssertTrue(NetworkReachability.isReachable(status: .satisfied, possibleExternalRoute: true))
        XCTAssertFalse(NetworkReachability.isReachable(status: .satisfied, possibleExternalRoute: false))
    }

    // MARK: - Byet-cookie-слой (transport == "infinityfree")

    private let byetChallengeHTML = """
    <html><body><script type="text/javascript" src="/aes.js" ></script><script>function toNumbers(d){var e=[];d.replace(/(..)/g,function(d){e.push(parseInt(d,16))});return e}function toHex(){for(var d=[],d=1==arguments.length&&arguments[0].constructor==Array?arguments[0]:arguments,e="",f=0;f<d.length;f++)e+=(16>d[f]?"0":"")+d[f].toString(16);return e.toLowerCase()}var a=toNumbers("f655ba9d09a112d4968c63579db590b4"),b=toNumbers("98344c2eee86c3994890592585b49f80"),c=toNumbers("3e512bc3e42f39a757e79f4739c74138");document.cookie="__test="+toHex(slowAES.decrypt(c,2,a,b))+"; max-age=21600; expires=Thu, 31-Dec-37 23:55:55 GMT; path=/"; location.href="https://kodmai.xo.je/?i=1";</script><noscript>This site requires Javascript to work, please enable Javascript in your browser or use a browser with Javascript support</noscript></body></html>
    """

    private func makeByetTranscriber(
        sttTransport: ByetMockTransport,
        byetTransport: ByetMockTransport?
    ) -> Transcriber {
        let byet = byetTransport.map { ByetCookieProvider(origin: "https://kodmai.xo.je", transport: $0) }
        return Transcriber(baseURL: "https://kodmai.xo.je/go/https://api.example/v1/audio/transcriptions",
                           model: "gigaam-v3",
                           apiKey: "test-key",
                           transport: sttTransport,
                           networkChecker: { true },
                           byetCookieProvider: byet)
    }

    @objc func testByetTransportSetsCookieAndChromeUA() {
        let stt = ByetMockTransport(challengeBody: byetChallengeHTML)
        let byetTransport = ByetMockTransport(challengeBody: byetChallengeHTML)
        let byet = ByetCookieProvider(origin: "https://kodmai.xo.je", transport: byetTransport)

        runAsync("testByetHeaders") {
            // Прогрев токена — первый запрос уходит уже с кукой (тот же
            // ByetCookieProvider, что в Transcriber: токен живёт в памяти).
            _ = await byet.refreshBlocking()

            let transcriber = Transcriber(baseURL: "https://kodmai.xo.je/go/https://api.example/v1/audio/transcriptions",
                                          model: "gigaam-v3",
                                          apiKey: "test-key",
                                          transport: stt,
                                          networkChecker: { true },
                                          byetCookieProvider: byet)
            let result = try await transcriber.transcribe(wav: self.wavData)
            XCTAssertEqual(result.text, "ok")
            guard let req = stt.lastRequest else {
                XCTFail("No STT request captured")
                return
            }
            XCTAssertEqual(req.value(forHTTPHeaderField: "Cookie"), "__test=d74696de7d49fcda5f03f4d247e07cf4")
            XCTAssertEqual(req.value(forHTTPHeaderField: "User-Agent"), ByetCookieProvider.chromeUA)
            XCTAssertEqual(stt.requestCount, 1, "cookie был свежий — челленджа и ретрая нет")
        }
    }

    @objc func testNoByetNoCookieNoUA() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"x"}"#.utf8))
        let transcriber = makeTranscriber(transport: transport)

        runAsync("testNoByetHeaders") {
            _ = try await transcriber.transcribe(wav: self.wavData)
            guard let req = transport.lastRequest else {
                XCTFail("No request")
                return
            }
            XCTAssertNil(req.value(forHTTPHeaderField: "Cookie"),
                         "без Byet cookie-логики быть не должно")
            XCTAssertNil(req.value(forHTTPHeaderField: "User-Agent"),
                         "без Byet фиксированный UA не подставляется (как раньше)")
        }
    }

    @objc func testChallengeTriggersSingleRetryWithFreshCookie() {
        let stt = ByetMockTransport(challengeBody: byetChallengeHTML, rejectPostCount: 1)
        let byetTransport = ByetMockTransport(challengeBody: byetChallengeHTML)
        let transcriber = makeByetTranscriber(sttTransport: stt, byetTransport: byetTransport)

        runAsync("testChallengeRetry") {
            let result = try await transcriber.transcribe(wav: self.wavData)
            XCTAssertEqual(result.text, "ok")
            XCTAssertEqual(stt.postCount, 2, "STT-попыток ровно 2 (мёртвая кука НЕ сжигает попытку)")
            XCTAssertEqual(byetTransport.requestCount, 2, "refresh = GET челленджа + probe GET")
            guard let retry = stt.requests.first(where: { $0.httpMethod == "POST" && $0.value(forHTTPHeaderField: "Cookie") != nil }) else {
                XCTFail("Ретрай должен идти со свежей кукой")
                return
            }
            XCTAssertEqual(retry.value(forHTTPHeaderField: "Cookie"), "__test=d74696de7d49fcda5f03f4d247e07cf4")
            XCTAssertEqual(retry.value(forHTTPHeaderField: "User-Agent"), ByetCookieProvider.chromeUA)
        }
    }

    @objc func testAlwaysChallengeRetriesOnceThenInvalidResponse() {
        // Оба STT-POST получают челлендж даже со свежей кукой: refresh прошёл
        // (probe GET принял cookie), но STT-эндпоинт всё равно отвечает челленджем.
        let stt = ByetMockTransport(challengeBody: byetChallengeHTML, rejectPostCount: 2)
        let byetTransport = ByetMockTransport(challengeBody: byetChallengeHTML)
        let transcriber = makeByetTranscriber(sttTransport: stt, byetTransport: byetTransport)

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
            XCTAssertEqual(byetTransport.requestCount, 2, "cookie пересчитан один раз")
        }
    }

    @objc func testChallengeRefreshFailureThrowsInvalidResponse() {
        // Probe не принимает свежую куку (honorCookie=false) → refresh не дал
        // токена → ретрая нет, ошибка с признаком челленджа.
        let stt = ByetMockTransport(challengeBody: byetChallengeHTML, rejectPostCount: 1)
        let byetTransport = ByetMockTransport(challengeBody: byetChallengeHTML, honorCookie: false)
        let transcriber = makeByetTranscriber(sttTransport: stt, byetTransport: byetTransport)

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
            XCTAssertEqual(byetTransport.requestCount, 2, "refresh всё же сходил за токеном")
        }
    }

    // MARK: - Адаптерный путь (adapterID)

    @objc func testAdapterOpenAIResolvesDefaultsAndSendsMultipart() {
        // Пустые baseURL/model + adapterID "openai" → дефолты адаптера резолвятся
        // внутри plan(): запрос уходит на api.openai.com с whisper-1 и multipart.
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

    @objc func testAdapterDeepgramRawAudioAndTranscriptPath() {
        // deepgram: сырое аудио, заголовок Token, дефолты nova-3/endpoint,
        // текст извлекается по transcriptPath из ответа.
        let deepgramJSON = #"{"results":{"channels":[{"alternatives":[{"transcript":"привет тайге"}]}]}}"#
        let transport = MockTransport(status: 200, body: Data(deepgramJSON.utf8))
        let transcriber = Transcriber(
            baseURL: "", model: "", apiKey: "dg-key",
            language: "ru", transport: transport, networkChecker: { true },
            adapterID: "deepgram"
        )

        runAsync("testAdapterDeepgram") {
            let result = try await transcriber.transcribe(wav: self.wavData)
            XCTAssertEqual(result.text, "привет тайге")
        }
        XCTAssertEqual(transport.requestCount, 1)
        XCTAssertEqual(transport.lastRequest?.url?.host, "api.deepgram.com")
        XCTAssertEqual(transport.lastRequest?.url?.path, "/v1/listen")
        XCTAssertTrue(transport.lastRequest?.url?.query?.contains("model=nova-3") ?? false)
        XCTAssertTrue(transport.lastRequest?.url?.query?.contains("language=ru") ?? false)
        XCTAssertEqual(transport.lastRequest?.value(forHTTPHeaderField: "Authorization"), "Token dg-key")
        XCTAssertEqual(transport.lastRequest?.value(forHTTPHeaderField: "Content-Type"), "audio/wav")
        XCTAssertEqual(transport.lastRequest?.httpBody, wavData, "тело = сырое аудио, не multipart")
    }
}
