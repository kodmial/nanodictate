import Foundation
@testable import DictationCore

// MARK: - MockTransport

final class MockTransport: HTTPTransport, @unchecked Sendable {

    var status: Int
    var body: Data
    var sendError: Error?

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

    func send(request: URLRequest) async throws -> (status: Int, body: Data) {
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

        return (status, body)
    }
}

// MARK: - Tests

final class TranscriberTests: XCTestCase {

    private let wavData = Data([0x52, 0x49, 0x46, 0x46]) // "RIFF"

    private func makeTranscriber(transport: MockTransport) -> Transcriber {
        Transcriber(baseURL: "https://example.test/v1/audio/transcriptions",
                    model: "gigaam-v3",
                    apiKey: "test-key",
                    transport: transport)
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
            XCTAssertEqual(request.timeoutInterval, 120)

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

    @objc func testNetworkErrorRetriesTwice() {
        let transport = MockTransport(status: 0,
                                      body: Data(),
                                      sendError: URLError(.cannotConnectToHost))
        let transcriber = makeTranscriber(transport: transport)

        runAsync("testRetry") {
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
            XCTAssertEqual(transport.requestCount, 2)
        }
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

    // MARK: - NEW: Timeout error → .network

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
                    XCTAssertFalse(msg.isEmpty)
                } else {
                    XCTFail("Expected .network, got \(error)")
                }
            }
            XCTAssertEqual(transport.requestCount, 2)
        }
    }

    // MARK: - NEW: Authorization header contains Bearer

    @objc func testAuthorizationBearerHeader() {
        let transport = MockTransport(status: 200, body: Data(#"{"text":"x"}"#.utf8))
        let transcriber = Transcriber(baseURL: "https://test.api/endpoint",
                                      model: "m",
                                      apiKey: "my-secret-token",
                                      transport: transport)

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
                                      transport: transport)

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
                                      transport: transport)

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
                                      transport: transport)

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
}
