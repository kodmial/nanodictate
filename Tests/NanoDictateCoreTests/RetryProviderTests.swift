import Foundation
@testable import NanoDictateCore

/// Ошибка, НЕ являющаяся TranscribeError (как ошибки микрофона в проде).
private struct NonTranscribeError: Error {}

final class RetryProviderTests: XCTestCase {

    // MARK: - Helpers

    private func makeResult(_ text: String) -> TranscriptionResult {
        TranscriptionResult(text: text, rawData: Data())
    }

    private let providerA = AppConfig.Provider(id: "a", name: "A", baseURL: "https://a", model: "m", apiKey: "keyA", apiKeyFile: nil, proxyKey: "")
    private let providerB = AppConfig.Provider(id: "b", name: "B", baseURL: "https://b", model: "m", apiKey: "keyB", apiKeyFile: nil, proxyKey: "")

    /// Runs an async closure to completion inside a synchronous test method
    /// (мини-XCTest без Xcode не умеет вызывать async-методы по селектору).
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

    // MARK: - Store / retrieve

    @objc func testStoreAndRetrieve() {
        let rp = RetryProvider()
        XCTAssertFalse(rp.hasLastRecording)
        XCTAssertNil(rp.lastWAV)

        let wav = Data("wav-data".utf8)
        rp.store(wav: wav)
        XCTAssertTrue(rp.hasLastRecording)
        XCTAssertEqual(rp.lastWAV, wav)
    }

    @objc func testStoreOverwritesPrevious() {
        let rp = RetryProvider()
        rp.store(wav: Data("first".utf8))
        rp.store(wav: Data("second".utf8))
        XCTAssertEqual(rp.lastWAV, Data("second".utf8))
    }

    @objc func testLastWAVCreatedAt() {
        let rp = RetryProvider()
        XCTAssertNil(rp.lastWAVCreatedAt)

        rp.store(wav: Data("x".utf8))
        let stored = rp.lastWAVCreatedAt!
        let now = Date()
        XCTAssertLessThanOrEqual(abs(stored.timeIntervalSince(now)), 2.0)
    }

    // MARK: - retranscribe

    @objc func testRetranscribeSuccess() {
        runAsync("testRetranscribeSuccess") {
            var seenProviderID: String?
            let rp = RetryProvider { wav, provider in
                seenProviderID = provider.id
                return TranscriptionResult(text: "hello", rawData: Data())
            }
            rp.store(wav: Data("sample".utf8))

            let result = try await rp.retranscribe(with: self.providerA)
            XCTAssertEqual(result?.text, "hello")
            XCTAssertEqual(seenProviderID, "a", "retranscribe должен звать функцию с выбранным провайдером")
        }
    }

    @objc func testRetranscribeWithoutWAVReturnsNil() {
        runAsync("testRetranscribeWithoutWAV") {
            let rp = RetryProvider { _, _ in
                XCTFail("Функция не должна вызываться без сохранённой записи")
                return TranscriptionResult(text: "", rawData: Data())
            }
            let result = try await rp.retranscribe(with: self.providerA)
            XCTAssertNil(result)
        }
    }

    @objc func testRetranscribePropagatesError() {
        runAsync("testRetranscribePropagatesError") {
            let rp = RetryProvider { _, _ in
                throw TranscribeError.network("timeout")
            }
            rp.store(wav: Data("x".utf8))

            do {
                _ = try await rp.retranscribe(with: self.providerA)
                XCTFail("Ожидалась ошибка")
            } catch let error as TranscribeError {
                XCTAssertEqual(error, .network("timeout"))
            } catch {
                XCTFail("Неожиданная ошибка: \(error)")
            }
        }
    }

    // MARK: - transcribeWithFailover

    @objc func testFailoverOnTranscribeError() {
        runAsync("testFailoverOnTranscribeError") {
            // Первый вызов — сеть упала, второй — успех (характерно для failover-цепочки).
            var calls: [String] = []
            let rp = RetryProvider { wav, provider in
                calls.append(provider.id)
                if calls.count == 1 {
                    throw TranscribeError.network("fail")
                }
                return TranscriptionResult(text: "recovered", rawData: Data())
            }

            let (result, providerID) = try await rp.transcribeWithFailover(
                wav: Data("sample".utf8),
                order: [self.providerA, self.providerB],
                autoFailover: true
            )
            XCTAssertEqual(result.text, "recovered")
            XCTAssertEqual(providerID, "b")
            XCTAssertEqual(calls, ["a", "b"])
        }
    }

    @objc func testFailoverSkipsOnNonTranscribeError() {
        runAsync("testFailoverSkipsOnNonTranscribeError") {
            var calls = 0
            let rp = RetryProvider { _, _ in
                calls += 1
                throw NonTranscribeError()
            }
            do {
                _ = try await rp.transcribeWithFailover(
                    wav: Data("sample".utf8),
                    order: [self.providerA, self.providerB],
                    autoFailover: true
                )
                XCTFail("Ожидалась ошибка")
            } catch {
                XCTAssertEqual(calls, 1, "micError (не TranscribeError) не должен запускать failover")
            }
        }
    }

    @objc func testFailoverDisabledOnlyTriesFirst() {
        runAsync("testFailoverDisabledOnlyTriesFirst") {
            var calls = 0
            let rp = RetryProvider { _, _ in
                calls += 1
                throw TranscribeError.network("fail")
            }
            do {
                _ = try await rp.transcribeWithFailover(
                    wav: Data("sample".utf8),
                    order: [self.providerA, self.providerB],
                    autoFailover: false
                )
                XCTFail("Ожидалась ошибка")
            } catch {
                XCTAssertEqual(calls, 1, "autoFailover=false → только первый провайдер")
            }
        }
    }

    @objc func testFailoverSuccessOnFirstProvider() {
        runAsync("testFailoverSuccessOnFirstProvider") {
            let rp = RetryProvider { _, provider in
                TranscriptionResult(text: "first-ok", rawData: Data())
            }
            let (result, providerID) = try await rp.transcribeWithFailover(
                wav: Data("sample".utf8),
                order: [self.providerA, self.providerB],
                autoFailover: true
            )
            XCTAssertEqual(result.text, "first-ok")
            XCTAssertEqual(providerID, "a")
        }
    }

    @objc func testFailoverAllProvidersFail() {
        runAsync("testFailoverAllProvidersFail") {
            let rp = RetryProvider { _, _ in
                throw TranscribeError.network("all-fail")
            }
            do {
                _ = try await rp.transcribeWithFailover(
                    wav: Data("sample".utf8),
                    order: [self.providerA, self.providerB],
                    autoFailover: true
                )
                XCTFail("Ожидалась ошибка")
            } catch let error as TranscribeError {
                XCTAssertEqual(error, .network("all-fail"))
            } catch {
                XCTFail("Неожиданная ошибка: \(error)")
            }
        }
    }

    @objc func testFailoverEmptyOrderThrows() {
        runAsync("testFailoverEmptyOrderThrows") {
            let rp = RetryProvider { _, _ in
                XCTFail("Функция не должна вызываться при пустой очереди")
                return TranscriptionResult(text: "", rawData: Data())
            }
            do {
                _ = try await rp.transcribeWithFailover(wav: Data("x".utf8), order: [], autoFailover: true)
                XCTFail("Ожидалась ошибка")
            } catch let error as TranscribeError {
                XCTAssertEqual(error, .invalidResponse("no providers configured for failover"))
            } catch {
                XCTFail("Неожиданная ошибка: \(error)")
            }
        }
    }

    // MARK: - lastFailedProviderID исключается из очереди

    @objc func testFailoverExcludesLastFailedProvider() {
        runAsync("testFailoverExcludesLastFailedProvider") {
            var calls: [String] = []
            let rp = RetryProvider { _, provider in
                calls.append(provider.id)
                throw TranscribeError.network("fail")
            }
            rp.lastFailedProviderID = "a"

            do {
                _ = try await rp.transcribeWithFailover(
                    wav: Data("x".utf8),
                    order: [self.providerA, self.providerB],
                    autoFailover: true
                )
                XCTFail("Ожидалась ошибка")
            } catch {
                XCTAssertEqual(calls, ["b"], "Упавший ранее провайдер исключается из failover-очереди")
            }
        }
    }

    // MARK: - Параллельный failover (RetryProvider.parallelFailover)

    /// Потокобезопасный накопитель событий из group-тасков (модификация в
    /// async-контексте из нескольких задач; box — @unchecked Sendable).
    private final class OrderBox: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func record(_ value: String) {
            lock.lock(); defer { lock.unlock() }
            values.append(value)
        }
        var snapshot: [String] {
            lock.lock(); defer { lock.unlock() }
            return values
        }
    }

    /// (a) Первый успех выигрывает и отменяет остальных: быстрый кандидат №1,
    /// кандидаты №2 и №3 перед «POST» спят — после cancelAll они НЕ делают
    /// лишних POST (дефолтный retrySleep глотает отмену, но верх цикла
    /// Transcriber.sendWithRetry её ловит).
    @objc func testParallelFailoverFirstSuccessCancelsOthers() {
        runAsync("testParallelFailoverFirstSuccessCancelsOthers") {
            let completedPOSTs = OrderBox()
            let cancelledStarts = OrderBox()

            let (result, providerID) = try await RetryProvider.parallelFailover(
                candidates: ["1", "2", "3"]
            ) { candidate in
                if candidate == "1" {
                    return (self.makeResult("first"), "1")
                }
                // Медленные кандидаты: у них достаточно времени, чтобы кандидат
                // №1 успел выиграть и отменить их (cancelAll).
                do {
                    try await Task.sleep(nanoseconds: 300_000_000)
                } catch {
                    cancelledStarts.record(candidate)
                    throw CancellationError()
                }
                if Task.isCancelled {
                    cancelledStarts.record(candidate)
                    throw CancellationError()
                }
                completedPOSTs.record(candidate)
                return (self.makeResult("slow-\(candidate)"), candidate)
            }

            XCTAssertEqual(result.text, "first")
            XCTAssertEqual(providerID, "1")
            XCTAssertTrue(completedPOSTs.snapshot.isEmpty,
                          "отменённые кандидаты не делают «лишних» POST после победы кандидата №1")
            XCTAssertTrue(cancelledStarts.snapshot.count >= 1,
                          "минимум один медленный кандидат наблюдал отмену")
        }
    }

    /// (b) Все кандидаты кидают TranscribeError → наружу уходит ошибка
    /// ПОСЛЕДНЕГО завершившегося (контролируемый порядок: «c» мгновенно,
    /// «b» через 50 мс, «a» через 200 мс).
    @objc func testParallelFailoverAllTranscribeErrorsKeepsLastCompleted() {
        runAsync("testParallelFailoverAllTranscribeErrorsKeepsLastCompleted") {
            do {
                _ = try await RetryProvider.parallelFailover(
                    candidates: ["a", "b", "c"]
                ) { candidate in
                    switch candidate {
                    case "a":
                        try await Task.sleep(nanoseconds: 200_000_000)
                        throw TranscribeError.network("last-completed-a")
                    case "b":
                        try await Task.sleep(nanoseconds: 50_000_000)
                        throw TranscribeError.http(500, "b")
                    default:
                        throw TranscribeError.invalidResponse("c")
                    }
                }
                XCTFail("Ожидалась ошибка")
            } catch let error as TranscribeError {
                XCTAssertEqual(error, .network("last-completed-a"),
                               "побеждает ошибка последнего завершившегося (a завершился позже всех)")
            } catch {
                XCTFail("Неожиданная ошибка: \(error)")
            }
        }
    }

    /// (c) Не-TranscribeError (abortError) пробрасывается независимо от уже
    /// накопленного lastFailure: «a» мгновенно кидает TranscribeError, «b»
    /// (после паузы) — NonTranscribeError. Наружу — abortError, даже если
    /// lastFailure уже был увиден.
    @objc func testParallelFailoverAbortWinsOverLastFailure() {
        runAsync("testParallelFailoverAbortWinsOverLastFailure") {
            let order = OrderBox()
            do {
                _ = try await RetryProvider.parallelFailover(
                    candidates: ["a", "b"]
                ) { candidate in
                    if candidate == "a" {
                        order.record("failure-a")
                        throw TranscribeError.http(500, "a")
                    }
                    try await Task.sleep(nanoseconds: 100_000_000)
                    order.record("abort-b")
                    throw NonTranscribeError()
                }
                XCTFail("Ожидалась ошибка")
            } catch is NonTranscribeError {
                XCTAssertEqual(order.snapshot, ["failure-a", "abort-b"],
                               "lastFailure увиден РАНЬШЕ abortError, но побеждает abortError")
            } catch {
                XCTFail("Неожиданная ошибка: \(error)")
            }
        }
    }

    // MARK: - resolveAPIKey: env > api_key > api_key_file

    @objc func testResolveAPIKeyEnvWinsOverInlineAndFile() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolve_api_key_env_\(UUID().uuidString).txt")
        try? "file-key".data(using: .utf8)?.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = AppConfig.Provider(id: "a", name: "A", baseURL: "", model: "", apiKey: "inline", apiKeyFile: file.path, proxyKey: "")

        setenv("NANODICTATE_API_KEY", "env-key", 1)
        defer { unsetenv("NANODICTATE_API_KEY") }
        XCTAssertEqual(RetryProvider.resolveAPIKey(for: provider), "env-key",
                       "env-ключ приоритетнее inline-ключа и файла")
    }

    @objc func testResolveAPIKeyInlineBeatsFile() {
        unsetenv("NANODICTATE_API_KEY")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolve_api_key_inline_\(UUID().uuidString).txt")
        try? "file-key".data(using: .utf8)?.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = AppConfig.Provider(id: "a", name: "A", baseURL: "", model: "", apiKey: "inline", apiKeyFile: file.path, proxyKey: "")
        XCTAssertEqual(RetryProvider.resolveAPIKey(for: provider), "inline")
    }

    @objc func testResolveAPIKeyFileReadsQuotedContent() {
        unsetenv("NANODICTATE_API_KEY")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolve_api_key_file_\(UUID().uuidString).txt")
        try? "# комментарий\n\"file-key\"\n".data(using: .utf8)?.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = AppConfig.Provider(id: "a", name: "A", baseURL: "", model: "", apiKey: "", apiKeyFile: file.path, proxyKey: "")
        XCTAssertEqual(RetryProvider.resolveAPIKey(for: provider), "file-key",
                       "из файла берётся строка без кавычек (комментарии пропускаются)")
    }

    @objc func testResolveAPIKeyMissingReturnsEmpty() {
        unsetenv("NANODICTATE_API_KEY")
        let provider = AppConfig.Provider(id: "a", name: "A", baseURL: "", model: "", apiKey: "", apiKeyFile: nil, proxyKey: "")
        XCTAssertEqual(RetryProvider.resolveAPIKey(for: provider), "")
    }
}