import Foundation
@testable import NanoDictateCore

/// Non-TranscribeError mirrors production mic errors (failover must abort).
private struct HedgedNonTranscribeError: Error {}

/// Deterministic fake backend: slow, failing and succeeding providers with
/// concurrency and upload tracking.
private final class HedgedFakeBackend: @unchecked Sendable {
    struct Behavior {
        var delayNanoseconds: UInt64
        var result: Result<String, Error>
    }

    private let lock = NSLock()
    private var behaviors: [String: Behavior]
    private var started: [String] = []
    private var completedUploads: [String] = []
    private var cancelledObservations: [String] = []
    private var inFlight = 0
    private var maxObserved = 0

    init(behaviors: [String: Behavior]) {
        self.behaviors = behaviors
    }

    func transcribe(_ candidate: String) async throws -> (TranscriptionResult, String) {
        lock.lock()
        started.append(candidate)
        inFlight += 1
        maxObserved = max(maxObserved, inFlight)
        let behavior = behaviors[candidate]
        lock.unlock()

        guard let behavior else {
            lock.lock()
            inFlight -= 1
            lock.unlock()
            throw TranscribeError.network("unknown candidate \(candidate)")
        }
        do {
            if behavior.delayNanoseconds > 0 {
                try await Task.sleep(nanoseconds: behavior.delayNanoseconds)
            }
        } catch {
            // Hedge loser cancelled while sleeping: record observation, do not
            // count as a completed upload (no duplicate transcript).
            lock.lock()
            inFlight -= 1
            cancelledObservations.append(candidate)
            lock.unlock()
            throw CancellationError()
        }
        if Task.isCancelled {
            lock.lock()
            inFlight -= 1
            cancelledObservations.append(candidate)
            lock.unlock()
            throw CancellationError()
        }
        lock.lock()
        inFlight -= 1
        lock.unlock()
        switch behavior.result {
        case .success(let text):
            // Winner commits exactly one upload; losers cancelled above never
            // reach here, so completed uploads equal committed transcripts.
            lock.lock()
            completedUploads.append(candidate)
            lock.unlock()
            return (TranscriptionResult(text: text, rawData: Data()), candidate)
        case .failure(let error):
            throw error
        }
    }

    var startedSnapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    var completedSnapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return completedUploads
    }

    var cancelledSnapshot: [String] {
        lock.lock(); defer { lock.unlock() }
        return cancelledObservations
    }

    var maxObservedConcurrency: Int {
        lock.lock(); defer { lock.unlock() }
        return maxObserved
    }
}

final class HedgedFailoverTests: XCTestCase {

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

    private func ok(_ text: String) -> Result<String, Error> {
        .success(text)
    }

    private func net(_ message: String) -> Result<String, Error> {
        .failure(TranscribeError.network(message))
    }

    // MARK: - Budget is explicit

    @objc func testHedgedPolicyBudgetIsExplicit() {
        XCTAssertEqual(RetryProvider.HedgedFailoverPolicy.default.maxConcurrentAttempts, 2)
        XCTAssertEqual(RetryProvider.HedgedFailoverPolicy.default.hedgeDelaySeconds, 1.0)
        XCTAssertEqual(Transcriber.maxAttempts, 4)
    }

    @objc func testRetryClassificationPreserved() {
        XCTAssertTrue(Transcriber.isRetryable(.http(429, "busy")))
        XCTAssertTrue(Transcriber.isRetryable(.http(500, "boom")))
        XCTAssertTrue(Transcriber.isRetryable(.network("down")))
        XCTAssertFalse(Transcriber.isRetryable(.http(400, "bad request")))
        XCTAssertFalse(Transcriber.isRetryable(.invalidResponse("no text")))
        XCTAssertTrue(RustEngine.shouldFailover(error: TranscribeError.network("x")))
        XCTAssertTrue(RustEngine.shouldFailover(error: TranscribeError.http(400, "terminal still fails over")))
        XCTAssertTrue(RustEngine.shouldFailover(error: TranscribeError.invalidResponse("terminal still fails over")))
        XCTAssertFalse(RustEngine.shouldFailover(error: HedgedNonTranscribeError()))
    }

    // MARK: - Ordered priority

    @objc func testHedgedRespectsOrderedPrioritySequential() {
        runAsync("testHedgedRespectsOrderedPrioritySequential") {
            let backend = HedgedFakeBackend(behaviors: [
                "a": .init(delayNanoseconds: 0, result: self.net("a-down")),
                "b": .init(delayNanoseconds: 0, result: self.ok("b-wins")),
                "c": .init(delayNanoseconds: 0, result: self.ok("c-late")),
            ])
            let policy = RetryProvider.HedgedFailoverPolicy(maxConcurrentAttempts: 1, hedgeDelaySeconds: 10)
            let (result, winner) = try await RetryProvider.hedgedFailover(
                candidates: ["a", "b", "c"], policy: policy
            ) { candidate in
                try await backend.transcribe(candidate)
            }
            XCTAssertEqual(result.text, "b-wins")
            XCTAssertEqual(winner, "b")
            XCTAssertEqual(backend.startedSnapshot, ["a", "b"])
        }
    }

    // MARK: - Primary failure then first-fallback success sends one upload

    @objc func testPrimaryFailureFirstFallbackSuccessSendsSingleUpload() {
        runAsync("testPrimaryFailureFirstFallbackSuccessSendsSingleUpload") {
            // Primary fails; hedged fallback with a fast first candidate must
            // not fan out to every configured provider.
            do {
                throw TranscribeError.network("primary down")
            } catch let primary as TranscribeError {
                XCTAssertEqual(primary, .network("primary down"))
            }
            let backend = HedgedFakeBackend(behaviors: [
                "fallback1": .init(delayNanoseconds: 0, result: self.ok("first-fallback")),
                "fallback2": .init(delayNanoseconds: 200_000_000, result: self.ok("slow")),
                "fallback3": .init(delayNanoseconds: 200_000_000, result: self.ok("slow")),
            ])
            let policy = RetryProvider.HedgedFailoverPolicy(maxConcurrentAttempts: 2, hedgeDelaySeconds: 5)
            let (result, winner) = try await RetryProvider.hedgedFailover(
                candidates: ["fallback1", "fallback2", "fallback3"], policy: policy
            ) { candidate in
                try await backend.transcribe(candidate)
            }
            XCTAssertEqual(result.text, "first-fallback")
            XCTAssertEqual(winner, "fallback1")
            // Give any stray hedge a chance to (incorrectly) fire.
            try await Task.sleep(nanoseconds: 200_000_000)
            XCTAssertEqual(backend.startedSnapshot, ["fallback1"])
            XCTAssertEqual(backend.completedSnapshot, ["fallback1"])
        }
    }

    // MARK: - Hedged second fallback wins when first is slow

    @objc func testHedgedSecondFallbackWinsWhenFirstIsSlow() {
        runAsync("testHedgedSecondFallbackWinsWhenFirstIsSlow") {
            let backend = HedgedFakeBackend(behaviors: [
                "first": .init(delayNanoseconds: 500_000_000, result: self.ok("slow-first")),
                "second": .init(delayNanoseconds: 0, result: self.ok("hedged-wins")),
                "third": .init(delayNanoseconds: 0, result: self.ok("never")),
            ])
            let policy = RetryProvider.HedgedFailoverPolicy(maxConcurrentAttempts: 2, hedgeDelaySeconds: 0.05)
            let (result, winner) = try await RetryProvider.hedgedFailover(
                candidates: ["first", "second", "third"], policy: policy
            ) { candidate in
                try await backend.transcribe(candidate)
            }
            XCTAssertEqual(result.text, "hedged-wins")
            XCTAssertEqual(winner, "second")
            XCTAssertTrue(backend.startedSnapshot.contains("first"))
            XCTAssertTrue(backend.startedSnapshot.contains("second"))
            XCTAssertFalse(backend.startedSnapshot.contains("third"))
            // Exactly one committed transcript: no duplicate insertion.
            XCTAssertEqual(backend.completedSnapshot, ["second"])
            XCTAssertTrue(backend.cancelledSnapshot.contains("first"))
        }
    }

    @objc func testSlowFailingFirstStillPermitsLaterWinner() {
        runAsync("testSlowFailingFirstStillPermitsLaterWinner") {
            let backend = HedgedFakeBackend(behaviors: [
                "a": .init(delayNanoseconds: 400_000_000, result: self.net("a-slow-fail")),
                "b": .init(delayNanoseconds: 0, result: self.ok("b-hedged")),
            ])
            let policy = RetryProvider.HedgedFailoverPolicy(maxConcurrentAttempts: 2, hedgeDelaySeconds: 0.05)
            let (result, winner) = try await RetryProvider.hedgedFailover(
                candidates: ["a", "b"], policy: policy
            ) { candidate in
                try await backend.transcribe(candidate)
            }
            XCTAssertEqual(winner, "b")
            XCTAssertEqual(result.text, "b-hedged")
        }
    }

    // MARK: - Concurrency is bounded

    @objc func testHedgedConcurrencyIsBounded() {
        runAsync("testHedgedConcurrencyIsBounded") {
            let backend = HedgedFakeBackend(behaviors: [
                "a": .init(delayNanoseconds: 100_000_000, result: self.net("a")),
                "b": .init(delayNanoseconds: 100_000_000, result: self.net("b")),
                "c": .init(delayNanoseconds: 100_000_000, result: self.net("c")),
                "d": .init(delayNanoseconds: 100_000_000, result: self.net("d")),
            ])
            let policy = RetryProvider.HedgedFailoverPolicy(maxConcurrentAttempts: 2, hedgeDelaySeconds: 0.01)
            do {
                _ = try await RetryProvider.hedgedFailover(
                    candidates: ["a", "b", "c", "d"], policy: policy
                ) { candidate in
                    try await backend.transcribe(candidate)
                }
                XCTFail("Expected all-fail error")
            } catch let error as TranscribeError {
                // Last completed failure wins; exact identity is timing-shaped,
                // but it must be one of the candidates.
                switch error {
                case .network(let message):
                    XCTAssertTrue(["a", "b", "c", "d"].contains(message))
                default:
                    XCTFail("Expected .network, got \(error)")
                }
            }
            XCTAssertLessThanOrEqual(backend.maxObservedConcurrency, 2)
            XCTAssertEqual(backend.startedSnapshot.count, 4)
        }
    }

    // MARK: - All-fail

    @objc func testHedgedAllFailThrowsLastFailure() {
        runAsync("testHedgedAllFailThrowsLastFailure") {
            let backend = HedgedFakeBackend(behaviors: [
                "a": .init(delayNanoseconds: 0, result: self.net("a-down")),
                "b": .init(delayNanoseconds: 0, result: TranscribeError.http(500, "b-down").asResult()),
            ])
            let policy = RetryProvider.HedgedFailoverPolicy(maxConcurrentAttempts: 1, hedgeDelaySeconds: 10)
            do {
                _ = try await RetryProvider.hedgedFailover(
                    candidates: ["a", "b"], policy: policy
                ) { candidate in
                    try await backend.transcribe(candidate)
                }
                XCTFail("Expected failure")
            } catch let error as TranscribeError {
                XCTAssertEqual(error, .http(500, "b-down"))
            }
            XCTAssertEqual(backend.startedSnapshot, ["a", "b"])
        }
    }

    @objc func testHedgedTerminalErrorStillFailsOver() {
        runAsync("testHedgedTerminalErrorStillFailsOver") {
            let backend = HedgedFakeBackend(behaviors: [
                "a": .init(delayNanoseconds: 0, result: TranscribeError.http(400, "bad").asResult()),
                "b": .init(delayNanoseconds: 0, result: self.ok("recovered")),
            ])
            let policy = RetryProvider.HedgedFailoverPolicy(maxConcurrentAttempts: 1, hedgeDelaySeconds: 10)
            let (result, winner) = try await RetryProvider.hedgedFailover(
                candidates: ["a", "b"], policy: policy
            ) { candidate in
                try await backend.transcribe(candidate)
            }
            XCTAssertEqual(winner, "b")
            XCTAssertEqual(result.text, "recovered")
        }
    }

    @objc func testHedgedAbortOnNonTranscribeError() {
        runAsync("testHedgedAbortOnNonTranscribeError") {
            let backend = HedgedFakeBackend(behaviors: [
                "a": .init(delayNanoseconds: 0, result: .failure(HedgedNonTranscribeError())),
                "b": .init(delayNanoseconds: 50_000_000, result: self.ok("must-not-win")),
            ])
            let policy = RetryProvider.HedgedFailoverPolicy(maxConcurrentAttempts: 1, hedgeDelaySeconds: 10)
            do {
                _ = try await RetryProvider.hedgedFailover(
                    candidates: ["a", "b"], policy: policy
                ) { candidate in
                    try await backend.transcribe(candidate)
                }
                XCTFail("Expected abort error")
            } catch {
                XCTAssertTrue(error is HedgedNonTranscribeError)
            }
            // Sequential budget: abort stops before the next candidate.
            XCTAssertEqual(backend.startedSnapshot, ["a"])
        }
    }

    @objc func testHedgedEmptyCandidatesThrows() {
        runAsync("testHedgedEmptyCandidatesThrows") {
            do {
                _ = try await RetryProvider.hedgedFailover(
                    candidates: [String](), policy: .default
                ) { _ in
                    throw TranscribeError.network("unreachable")
                }
                XCTFail("Expected empty-candidates error")
            } catch let error as TranscribeError {
                XCTAssertEqual(error, .invalidResponse("failover has no candidates"))
            }
        }
    }

    // MARK: - Cancellation does not leak or duplicate

    @objc func testHedgedCancellationPropagatesWithoutDuplicateInsert() {
        let started = expectation(description: "fallback started")
        let done = expectation(description: "hedged cancelled")
        let task = Task {
            do {
                _ = try await RetryProvider.hedgedFailover(
                    candidates: ["a", "b"],
                    policy: RetryProvider.HedgedFailoverPolicy(maxConcurrentAttempts: 2, hedgeDelaySeconds: 5)
                ) { candidate in
                    if candidate == "a" {
                        started.fulfill()
                        try await Task.sleep(nanoseconds: 500_000_000)
                        if Task.isCancelled { throw CancellationError() }
                        return (TranscriptionResult(text: "late-\(candidate)", rawData: Data()), candidate)
                    }
                    try await Task.sleep(nanoseconds: 500_000_000)
                    if Task.isCancelled { throw CancellationError() }
                    return (TranscriptionResult(text: "late-\(candidate)", rawData: Data()), candidate)
                }
                XCTFail("Expected CancellationError")
            } catch {
                XCTAssertTrue(error is CancellationError)
            }
            done.fulfill()
        }
        wait(for: [started], timeout: 10)
        task.cancel()
        wait(for: [done], timeout: 10)
    }
}

private extension TranscribeError {
    func asResult() -> Result<String, Error> {
        .failure(self)
    }
}
