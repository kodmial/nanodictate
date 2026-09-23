import Foundation
@testable import NanoDictateCore

/// Non-TranscribeError mirrors production mic errors (failover must skip them).
private struct NonTranscribeError: Error {}

final class RetryProviderTests: XCTestCase {

    // MARK: - Helpers

    private func makeResult(_ text: String) -> TranscriptionResult {
        TranscriptionResult(text: text, rawData: Data())
    }

    private let providerA = AppConfig.Provider(id: "a", name: "A", baseURL: "https://a", model: "m", apiKey: "keyA", apiKeyFile: nil, proxyKey: "")
    private let providerB = AppConfig.Provider(id: "b", name: "B", baseURL: "https://b", model: "m", apiKey: "keyB", apiKeyFile: nil, proxyKey: "")

    /// Async closure via expectation: mini-XCTest cannot call async selectors.
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

    // MARK: - lastFailedProviderID переносится В КОНЕЦ очереди (autoFailover)

    @objc func testFailoverMovesLastFailedProviderToEnd() {
        runAsync("testFailoverMovesLastFailedProviderToEnd") {
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
                XCTAssertEqual(calls, ["b", "a"],
                               "Упавший ранее провайдер переносится В КОНЕЦ очереди — повторная попытка после остальных")
            }
        }
    }

    @objc func testFailoverDisabledKeepsQueueOrder() {
        runAsync("testFailoverDisabledKeepsQueueOrder") {
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
                    autoFailover: false
                )
                XCTFail("Ожидалась ошибка")
            } catch {
                XCTAssertEqual(calls, ["a"],
                               "autoFailover=false — порядок очереди НЕ меняется: упавший остаётся на месте, пробуется только первый")
            }
        }
    }

    // MARK: - Параллельный failover (RetryProvider.parallelFailover)

    /// Thread-safe event sink for concurrent group tasks (@unchecked Sendable).
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

    /// (a) First success wins, cancels rest; sleep swallows cancel, loop-top catches it.
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
                // Sleep so candidate 1 wins and cancels the others first.
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

    /// (b) All fail: last-completed error wins (c instant, b 50ms, a 200ms).
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

    /// (c) Non-TranscribeError (abort) wins even after lastFailure was seen.
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

    /// (d) CR12 fix: after abort wins, `break drain` stops draining — a
    /// cancelled sibling throwing CancellationError (non-TranscribeError)
    /// must NOT overwrite the first abort error.
    @objc func testParallelFailoverAbortSurvivesCancelledSibling() {
        runAsync("testParallelFailoverAbortSurvivesCancelledSibling") {
            do {
                _ = try await RetryProvider.parallelFailover(
                    candidates: ["a", "b", "c"]
                ) { candidate in
                    if candidate == "a" {
                        throw NonTranscribeError()
                    }
                    // Siblings start sleeping; abort returns instantly and
                    // cancelAll cancels them — Task.sleep throws
                    // CancellationError, which is not a TranscribeError and
                    // must not replace the abort.
                    try await Task.sleep(nanoseconds: 200_000_000)
                    return (self.makeResult("unexpected-\(candidate)"), candidate)
                }
                XCTFail("Ожидалась ошибка")
            } catch let error {
                XCTAssertTrue(error is NonTranscribeError,
                              "abort-победа не затирается CancellationError отменённого sibling: получен \(error)")
            }
        }
    }

    // MARK: - resolveAPIKey: env активному > собственный api_key > api_key_file

    @objc func testResolveAPIKeyEnvWinsOverInlineAndFile() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolve_api_key_env_\(UUID().uuidString).txt")
        try? "file-key".data(using: .utf8)?.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = AppConfig.Provider(id: "a", name: "A", baseURL: "", model: "", apiKey: "inline", apiKeyFile: file.path, proxyKey: "")

        setenv("NANODICTATE_API_KEY", "env-key", 1)
        defer { unsetenv("NANODICTATE_API_KEY") }
        XCTAssertEqual(RetryProvider.resolveAPIKey(for: provider, activeProviderID: "a"), "env-key",
                       "активному провайдеру env-ключ приоритетнее inline-ключа и файла")
    }

    @objc func testResolveAPIKeyInlineBeatsFile() {
        unsetenv("NANODICTATE_API_KEY")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolve_api_key_inline_\(UUID().uuidString).txt")
        try? "file-key".data(using: .utf8)?.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = AppConfig.Provider(id: "a", name: "A", baseURL: "", model: "", apiKey: "inline", apiKeyFile: file.path, proxyKey: "")
        XCTAssertEqual(RetryProvider.resolveAPIKey(for: provider, activeProviderID: nil), "inline")
    }

    @objc func testResolveAPIKeyFileReadsQuotedContent() {
        unsetenv("NANODICTATE_API_KEY")
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolve_api_key_file_\(UUID().uuidString).txt")
        try? "# комментарий\n\"file-key\"\n".data(using: .utf8)?.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = AppConfig.Provider(id: "a", name: "A", baseURL: "", model: "", apiKey: "", apiKeyFile: file.path, proxyKey: "")
        XCTAssertEqual(RetryProvider.resolveAPIKey(for: provider, activeProviderID: nil), "file-key",
                       "из файла берётся строка без кавычек (комментарии пропускаются)")
    }

    @objc func testResolveAPIKeyMissingReturnsEmpty() {
        unsetenv("NANODICTATE_API_KEY")
        let provider = AppConfig.Provider(id: "a", name: "A", baseURL: "", model: "", apiKey: "", apiKeyFile: nil, proxyKey: "")
        XCTAssertEqual(RetryProvider.resolveAPIKey(for: provider, activeProviderID: nil), "")
    }

    // MARK: - resolveAPIKey: env-ключ НЕ утекает неактивным провайдерам

    @objc func testResolveAPIKeyEnvNotGivenToInactiveProviderWithOwnInlineKey() {
        setenv("NANODICTATE_API_KEY", "env-key", 1)
        defer { unsetenv("NANODICTATE_API_KEY") }
        let provider = AppConfig.Provider(id: "b", name: "B", baseURL: "", model: "", apiKey: "keyB", apiKeyFile: nil, proxyKey: "")
        XCTAssertEqual(RetryProvider.resolveAPIKey(for: provider, activeProviderID: "a"), "keyB",
                       "неактивный провайдер получает СВОЙ api_key, а не env-ключ")
    }

    @objc func testResolveAPIKeyEnvNotGivenToInactiveProviderWithFileKey() {
        setenv("NANODICTATE_API_KEY", "env-key", 1)
        defer { unsetenv("NANODICTATE_API_KEY") }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("resolve_api_key_inactive_\(UUID().uuidString).txt")
        try? "fileB".data(using: .utf8)?.write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let provider = AppConfig.Provider(id: "b", name: "B", baseURL: "", model: "", apiKey: "", apiKeyFile: file.path, proxyKey: "")
        XCTAssertEqual(RetryProvider.resolveAPIKey(for: provider, activeProviderID: "a"), "fileB",
                       "неактивный провайдер получает ключ из СВОЕГО api_key_file, а не env-ключ")
    }

    @objc func testResolveAPIKeyEnvNotGivenToInactiveProviderWithoutKey() {
        setenv("NANODICTATE_API_KEY", "env-key", 1)
        defer { unsetenv("NANODICTATE_API_KEY") }
        let provider = AppConfig.Provider(id: "b", name: "B", baseURL: "", model: "", apiKey: "", apiKeyFile: nil, proxyKey: "")
        XCTAssertEqual(RetryProvider.resolveAPIKey(for: provider, activeProviderID: "a"), "",
                       "неактивный провайдер без собственного ключа получает пусто — env-ключ не утекает, запрос падает штатно")
    }

    @objc func testResolveAPIKeyEnvNotGivenToProviderWithStaleActiveID() {
        setenv("NANODICTATE_API_KEY", "env-key", 1)
        defer { unsetenv("NANODICTATE_API_KEY") }
        let provider = AppConfig.Provider(id: "a", name: "A", baseURL: "", model: "", apiKey: "keyA", apiKeyFile: nil, proxyKey: "")
        XCTAssertEqual(RetryProvider.resolveAPIKey(for: provider, activeProviderID: "unknown"), "keyA",
                       "при неизвестном activeProviderID env не выдаётся — fail-closed, свой ключ остаётся")
    }

    @objc func testResolveAPIKeyEnvNotGivenWithoutActiveContext() {
        setenv("NANODICTATE_API_KEY", "env-key", 1)
        defer { unsetenv("NANODICTATE_API_KEY") }
        let provider = AppConfig.Provider(id: "a", name: "A", baseURL: "", model: "", apiKey: "keyA", apiKeyFile: nil, proxyKey: "")
        XCTAssertEqual(RetryProvider.resolveAPIKey(for: provider, activeProviderID: nil), "keyA",
                       "nil-активный (нет конфиг-контекста) — env не выдаётся, свой ключ остаётся")
    }

    @objc func testResolveAPIKeyEnvGivenToActiveProviderEvenWithoutOwnKey() {
        setenv("NANODICTATE_API_KEY", "env-key", 1)
        defer { unsetenv("NANODICTATE_API_KEY") }
        let provider = AppConfig.Provider(id: "a", name: "A", baseURL: "", model: "", apiKey: "", apiKeyFile: nil, proxyKey: "")
        XCTAssertEqual(RetryProvider.resolveAPIKey(for: provider, activeProviderID: "a"), "env-key",
                       "активному провайдеру env-ключ отдаётся даже без собственного ключа")
    }
}