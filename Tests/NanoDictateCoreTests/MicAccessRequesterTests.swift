import Foundation
import AVFoundation
@testable import NanoDictateCore

/// Tests of MicAccessRequester — testable in mini-XCTest (no audio hardware,
/// no TCC; coordinator extracted from Agent into Core for this reason).
/// Cover whole "protected request cycle":
///   • authorized/denied/restricted — sync outcome, no system prompt;
///   • granted/denied from system dialog — outcome on main queue;
///   • watchdog: callback not arrived by timeout → .timedOut (no eternal wait),
///     timeout counted in storm policy;
///   • LATE granted after timeout dropped by session token: no second outcome,
///     no storm-counter reset (fix regression);
///   • re-request while dialog pending — no second dialog;
///   • anti-storm: after 3 timeouts in a 6h window request not opened at all.
final class MicAccessRequesterTests: XCTestCase {

    /// Controlled "system request": opens no dialog, holds callback until
    /// test command (respond/stay silent). callCount — real request starts.
    private final class RequestStub {
        private(set) var callCount = 0
        private(set) var lastCompletion: ((Bool) -> Void)?

        func asRequestAccess() -> MicAccessRequester.RequestAccess {
            { [weak self] completion in
                self?.callCount += 1
                self?.lastCompletion = completion
            }
        }
    }

    private func makeRequester(
        status: @escaping MicAccessRequester.StatusProvider,
        stub: RequestStub,
        policyFile: URL,
        timeout: TimeInterval = 0.2
    ) -> MicAccessRequester {
        MicAccessRequester(
            status: status,
            requestAccess: stub.asRequestAccess(),
            policy: MicRequestPolicy(fileURL: policyFile),
            timeout: timeout
        )
    }

    /// Waits exactly one outcome (coordinator completion — EXACTLY once).
    private func waitForOutcome(
        _ requester: MicAccessRequester,
        timeout: TimeInterval = 2
    ) -> (MicAccessRequester.Outcome, [MicAccessRequester.Outcome]) {
        let done = expectation(description: "mic access outcome")
        var outcomes: [MicAccessRequester.Outcome] = []
        requester.requestIfNeeded { outcome in
            outcomes.append(outcome)
            if outcomes.count == 1 { done.fulfill() }
        }
        wait(for: [done], timeout: timeout)
        return (outcomes.first ?? .denied, outcomes)
    }

    // MARK: - Статус уже известен (без системного запроса)

    @objc func testAuthorizedGrantsImmediately() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("requester-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let stub = RequestStub()
        let requester = makeRequester(status: { .authorized }, stub: stub, policyFile: file)

        var outcomes: [MicAccessRequester.Outcome] = []
        requester.requestIfNeeded { outcomes.append($0) }

        // Sync, no wait: status already known — no system prompt.
        XCTAssertEqual(outcomes, [.granted])
        XCTAssertEqual(stub.callCount, 0, "системный диалог не открывается при выданном доступе")
        XCTAssertFalse(requester.isInFlight)
    }

    @objc func testDeniedAndRestrictedFailImmediately() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("requester-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        for status in [AVAuthorizationStatus.denied, .restricted] {
            let stub = RequestStub()
            let requester = makeRequester(status: { status }, stub: stub, policyFile: file)
            var outcomes: [MicAccessRequester.Outcome] = []
            requester.requestIfNeeded { outcomes.append($0) }
            XCTAssertEqual(outcomes, [.denied], "статус \(status) → .denied")
            XCTAssertEqual(stub.callCount, 0)
        }
    }

    // MARK: - Ответ системного диалога (в срок)

    @objc func testPromptGrantSucceedsAndResetsStormCounter() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("requester-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        // Two past timeouts (storm counter at 2 of 3 — request still allowed)…
        var policy = MicRequestPolicy(fileURL: file)
        for _ in 0..<(MicRequestPolicy.maxTimeoutsInWindow - 1) {
            policy.recordTimeout(now: Date())
        }
        XCTAssertTrue(MicRequestPolicy(fileURL: file).allowRequest(now: Date()), "2 таймаута — ещё до порога")

        // …and NORMAL granted on request: storm cleared.
        let stub = RequestStub()
        let requester = makeRequester(status: { .notDetermined }, stub: stub, policyFile: file)

        let done = expectation(description: "granted outcome")
        var outcomes: [MicAccessRequester.Outcome] = []
        requester.requestIfNeeded { outcome in
            outcomes.append(outcome)
            if outcomes.count == 1 { done.fulfill() }
        }
        XCTAssertEqual(stub.callCount, 1, "системный запрос открыт ровно один раз")
        // Dialog answers granted in time (0.2s watchdog does not fire)…
        stub.lastCompletion?(true)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(outcomes, [.granted])
        XCTAssertTrue(
            eventually { requester.isInFlight == false },
            "после granted флаг «в полёте» снят"
        )
        // Grant received — timeout counter reset.
        XCTAssertTrue(
            MicRequestPolicy(fileURL: file).allowRequest(now: Date()),
            "granted в срок обязан сбросить штормовой счётчик"
        )
    }

    @objc func testPromptDenyFails() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("requester-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let stub = RequestStub()
        let requester = makeRequester(status: { .notDetermined }, stub: stub, policyFile: file)

        requester.requestIfNeeded { _ in }
        stub.lastCompletion?(false)
        // Completion hops to main (async): wait until first request finishes and
        // clears the flag — else retry hits guard isInFlight (no second
        // dialog, no outcome).
        XCTAssertTrue(
            eventually { requester.isInFlight == false },
            "первый запрос обязан завершиться до повторного"
        )

        let done = expectation(description: "denied outcome")
        var outcomes: [MicAccessRequester.Outcome] = []
        requester.requestIfNeeded { outcome in
            outcomes.append(outcome)
            done.fulfill()
        }
        // Next Alt+Alt opens NEW dialog; deny answer → .denied.
        stub.lastCompletion?(false)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(outcomes, [.denied])
    }

    // MARK: - Сторож таймаута

    @objc func testTimeoutFiresWhenNoResponse() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("requester-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        // Seed 2 timeouts in window (counter 2 of 3): third (watchdog) must
        // cross the limit — assert below proves timeout REALLY recorded.
        var seed = MicRequestPolicy(fileURL: file)
        seed.recordTimeout(now: Date())
        seed.recordTimeout(now: Date())
        XCTAssertTrue(MicRequestPolicy(fileURL: file).allowRequest(now: Date()), "2 таймаута — ещё до порога")

        let stub = RequestStub()
        // Short watchdog (0.2s) — test does not wait prod's 10s.
        let requester = makeRequester(status: { .notDetermined }, stub: stub, policyFile: file, timeout: 0.2)

        let (outcome, _) = waitForOutcome(requester)
        XCTAssertEqual(outcome, .timedOut, "молчащий диалог обязан дать .timedOut")
        XCTAssertEqual(stub.callCount, 1, "запрос стартовал один раз")
        XCTAssertFalse(requester.isInFlight, "после таймаута флаг «в полёте» снят")
        // Watchdog's 3rd timeout (plus 2 seeded) crossed the threshold:
        // fresh policy from same file rejects request now.
        XCTAssertFalse(
            MicRequestPolicy(fileURL: file).allowRequest(now: Date()),
            "таймаут записан в штормовой счётчик (2+1 на пределе)"
        )
    }

    /// Late grant after timeout — the exact regression that made watchdog
    /// CHANGE TOKEN, not just clear flag: answer after shown error gives no
    /// second outcome (recording won't start) and does not reset storm
    /// counter (request counted as timeout).
    @objc func testLateGrantAfterTimeoutIsDropped() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("requester-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let stub = RequestStub()
        // Empty start policy: three silent dialogs themselves drive counter
        // to limit (after 3rd timeout 4th request blocked).
        let requester = makeRequester(status: { .notDetermined }, stub: stub, policyFile: file, timeout: 0.15)

        // Three timeouts in a row: each cycle a new request, no answer.
        var lastCycleOutcomes: [MicAccessRequester.Outcome] = []
        for _ in 0..<3 {
            let (outcome, outcomes) = waitForOutcome(requester)
            XCTAssertEqual(outcome, .timedOut)
            lastCycleOutcomes = outcomes
        }
        // 4th request — anti-storm (counter at limit): system dialog not
        // opened at all, single outcome.
        let (suppressedOutcome, suppressedOutcomes) = waitForOutcome(requester)
        XCTAssertEqual(suppressedOutcome, .suppressedByPolicy)
        XCTAssertEqual(suppressedOutcomes, [.suppressedByPolicy], "анти-шторм: один исход, диалог не открывался")

        // Last REAL dialog (3rd cycle) answers granted — BUT after watchdog
        // fired and changed session.
        stub.lastCompletion?(true)
        // Answer that would start recording is absent: last real cycle still
        // has exactly ONE outcome (.timedOut). drainEngineQueue spins
        // run loop — undropped grant would have arrived by now.
        drainEngineQueue()
        XCTAssertEqual(
            lastCycleOutcomes,
            [.timedOut],
            "поздний granted не даёт второго исхода (запись не начнётся)"
        )
        // Storm counter NOT reset by late grant: request stays blocked
        // (fresh policy reads state from file).
        XCTAssertFalse(
            MicRequestPolicy(fileURL: file).allowRequest(now: Date()),
            "поздний granted не должен сбрасывать штормовой счётчик"
        )
    }

    /// Repeat request while system dialog hangs opens no second dialog
    /// and gives no second outcome.
    @objc func testDuplicateWhileInFlightIsIgnored() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("requester-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let stub = RequestStub()
        let requester = makeRequester(status: { .notDetermined }, stub: stub, policyFile: file, timeout: 0.5)

        var outcomes: [MicAccessRequester.Outcome] = []
        requester.requestIfNeeded { outcomes.append($0) }
        XCTAssertEqual(stub.callCount, 1, "первый запрос стартует")

        // Second Alt+Alt in flight: neither outcome nor second system request.
        requester.requestIfNeeded { outcomes.append($0) }
        XCTAssertEqual(stub.callCount, 1, "второй запрос не открывает второй диалог")
        XCTAssertEqual(outcomes, [], "повторный вызов в полёте не даёт исхода")

        // Answer to FIRST request — exactly one outcome.
        stub.lastCompletion?(true)
        XCTAssertTrue(
            eventually(timeout: 1.0, { outcomes == [.granted] }),
            "исход первого запроса приходит ровно один раз: \(outcomes)"
        )
    }

    // MARK: - Анти-шторм

    @objc func testSuppressedAfterTimeoutLimit() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("requester-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let stub = RequestStub()
        var policy = MicRequestPolicy(fileURL: file)
        for _ in 0..<MicRequestPolicy.maxTimeoutsInWindow {
            policy.recordTimeout(now: Date())
        }

        let requester = makeRequester(status: { .notDetermined }, stub: stub, policyFile: file, timeout: 0.2)
        let (outcome, _) = waitForOutcome(requester)
        XCTAssertEqual(outcome, .suppressedByPolicy, "лимит таймаутов → запрос не открывается вовсе")
        XCTAssertEqual(stub.callCount, 0, "системный диалог НЕ открывается под анти-штормом")
        XCTAssertFalse(requester.isInFlight)
    }
}