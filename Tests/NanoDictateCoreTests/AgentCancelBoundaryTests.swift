import Foundation
import AVFoundation
@testable import NanoDictateCore

// MARK: - Esc terminal-boundary integration coverage (issue #156)
//
// The Agent executable itself is not importable by this test target, so these
// tests cover the real orchestration in two complementary halves (the same
// split the repository already uses for live orchestration in
// LiveOrchestrationBranchTests):
//
//   1. Behavioral composition: the REAL Core gates the agent wires together
//      (RetryInsertionGate, MicAccessRequester, NanoDictateFlow,
//      EnterSendLatch, ReviewGate.Decision) driven through the EXACT sequences
//      the agent runs — retry review pending -> Esc -> late decision,
//      retry review pending -> new dictation -> stale decision, mic permission
//      pending -> Esc -> late grant, normal grant, Enter/Esc latch paths.
//      Where the agent keeps a plain-integer generation next to a coordinator
//      token, the test keeps the same plain-integer generation (mirroring
//      Agent.micRequestSession) rather than inventing a new abstraction.
//   2. Structural wiring: pins that Sources/NanoDictateAgent/main.swift
//      actually performs those sequences (Esc bumps the generations,
//      completions re-validate them, Enter/Esc paths are unchanged).
//
// Both halves must stay green together: behavior proves the sequence is
// correct, structure proves the agent runs that sequence.

final class AgentCancelBoundaryTests: XCTestCase {

    // MARK: - Harness (mirrors Agent.micRequestSession wiring, main.swift)

    /// Controlled system request: holds the TCC callback until the test
    /// answers it (or never answers, modelling the hung dialog).
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

    private func policyFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cancel-boundary-\(UUID().uuidString).json")
    }

    private func makeRequester(
        stub: RequestStub,
        file: URL,
        timeout: TimeInterval = 5.0
    ) -> MicAccessRequester {
        MicAccessRequester(
            status: { .notDetermined },
            requestAccess: stub.asRequestAccess(),
            policy: MicRequestPolicy(fileURL: file),
            timeout: timeout
        )
    }

    // MARK: - 1. Retry review pending -> Esc -> late .insert -> no insertion

    /// The exact agent order: retryInsertion advances processingSession and
    /// waits; handleCancel advances it again; the late completion must drop.
    @objc func testRetryReviewPending_Esc_LateInsertDropped() {
        var processingSession = 5
        // retryInsertion: token advanced around the review wait.
        processingSession += 1
        let reviewSession = processingSession
        XCTAssertEqual(reviewSession, 6)

        // Control: without Esc the current session is accepted.
        XCTAssertFalse(
            RetryInsertionGate.shouldDropRetry(
                state: .idle, processingSession: processingSession, session: reviewSession))

        // handleCancel in .idle with a pending retry review: terminal
        // cancellation boundary, session advanced (see structural pin below).
        processingSession += 1

        // Late ReviewGate .insert decision arrives after Esc.
        let decision = ReviewGate.Decision.insert
        let shouldDrop = RetryInsertionGate.shouldDropRetry(
            state: .idle, processingSession: processingSession, session: reviewSession)
        XCTAssertTrue(shouldDrop, "late review decision after Esc must be dropped")

        // Composition with the insertion point: dropped means finishRetryInsertion
        // never runs — model the insertion as a flag behind the gate.
        var inserted = false
        if !shouldDrop, decision == .insert {
            inserted = true
        }
        XCTAssertFalse(inserted, "no insertion may happen after Esc-cancelled retry review")
    }

    /// A late .cancel decision after Esc is equally terminal: nothing runs.
    @objc func testRetryReviewPending_Esc_LateCancelIsNoOp() {
        var processingSession = 5
        processingSession += 1
        let reviewSession = processingSession
        processingSession += 1 // Esc invalidates the wait.

        XCTAssertTrue(
            RetryInsertionGate.shouldDropRetry(
                state: .idle, processingSession: processingSession, session: reviewSession))
    }

    // MARK: - 2. Retry review pending -> new dictation -> stale -> no insertion

    /// A new dictation cycle that starts (and finishes) while the retry review
    /// waits must clobber neither its overlay nor its text: the stale decision
    /// is dropped both mid-cycle (state guard) and after the cycle (session).
    @objc func testRetryReviewPending_NewDictation_StaleDropped() {
        var processingSession = 5
        processingSession += 1
        let reviewSession = processingSession

        // New loop starts: processSingleRequest advances the session, state
        // leaves .idle. Stale retry decision arriving mid-cycle drops.
        processingSession += 1
        XCTAssertTrue(
            RetryInsertionGate.shouldDropRetry(
                state: .transcribing, processingSession: processingSession, session: reviewSession))
        XCTAssertTrue(
            RetryInsertionGate.shouldDropRetry(
                state: .recording, processingSession: processingSession, session: reviewSession))

        // The new loop finished back in .idle: the session token still
        // mismatches, so the stale decision drops instead of inserting.
        XCTAssertTrue(
            RetryInsertionGate.shouldDropRetry(
                state: .idle, processingSession: processingSession, session: reviewSession))
    }

    // MARK: - 3. Mic permission pending -> Esc -> late .granted -> no start

    /// Real coordinator: Esc invalidates the pending TCC request; the late
    /// system grant resolves the coordinator (releases in-flight) but delivers
    /// NO outcome — recording can never start under it.
    @objc func testMicPending_Esc_LateGrantedDeliversNoOutcome() {
        let file = policyFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let stub = RequestStub()
        // Long watchdog: it must never fire here — Esc, not the timeout,
        // owns this cancellation (also asserted via the storm counter below).
        let requester = makeRequester(stub: stub, file: file, timeout: 30.0)

        var outcomes: [MicAccessRequester.Outcome] = []
        requester.requestIfNeeded { outcomes.append($0) }
        XCTAssertEqual(stub.callCount, 1)
        XCTAssertTrue(requester.isInFlight)

        // handleCancel: agent generation bump + coordinator invalidation.
        requester.invalidatePending()

        // Late system grant arrives after Esc.
        stub.lastCompletion?(true)
        XCTAssertTrue(
            eventually { requester.isInFlight == false },
            "late system answer must still release the coordinator")
        drainEngineQueue()
        XCTAssertEqual(outcomes, [], "late grant after Esc must deliver no outcome (no recording)")
        // Esc is not a watchdog timeout: the storm counter is untouched, so a
        // future request is still allowed once the coordinator is released.
        XCTAssertTrue(
            MicRequestPolicy(fileURL: file).allowRequest(now: Date()),
            "Esc invalidation must not consume the anti-storm timeout budget")
    }

    /// Agent-level generation: mirrors the .granted guard in
    /// requestMicrophoneAndStart — a grant captured before Esc is stale.
    @objc func testMicPending_Esc_AgentGenerationDropsLateGrant() {
        // Mirrors Agent.micRequestSession: bumped on request and on Esc.
        var micRequestSession = 0
        micRequestSession += 1
        let micSession = micRequestSession

        // handleCancel bumps the generation.
        micRequestSession += 1

        // The .granted branch guard (pinned structurally below).
        var recordingStarted = 0
        let grantedIsCurrent = micRequestSession == micSession
        if grantedIsCurrent {
            recordingStarted += 1
        }
        XCTAssertFalse(grantedIsCurrent, "late grant generation must be stale after Esc")
        XCTAssertEqual(recordingStarted, 0, "late grant must not start recording after Esc")
    }

    /// A retry Alt+Alt while the Esc-invalidated system request is still
    /// unresolved must not pile a second dialog (anti-storm preserved).
    @objc func testMicPending_Esc_RetryOpensNoSecondDialog() {
        let file = policyFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let stub = RequestStub()
        let requester = makeRequester(stub: stub, file: file, timeout: 30.0)

        requester.requestIfNeeded { _ in }
        requester.invalidatePending() // Esc.

        var retryOutcomes: [MicAccessRequester.Outcome] = []
        requester.requestIfNeeded { retryOutcomes.append($0) }
        XCTAssertEqual(stub.callCount, 1, "no second system request on top of the pending dialog")
        drainEngineQueue()
        XCTAssertEqual(retryOutcomes, [], "duplicate while in flight yields no outcome")

        // Once the pending system request resolves, a fresh cycle works.
        stub.lastCompletion?(true)
        XCTAssertTrue(eventually { requester.isInFlight == false })
        let done = expectation(description: "fresh grant")
        var fresh: [MicAccessRequester.Outcome] = []
        requester.requestIfNeeded { outcome in
            fresh.append(outcome)
            done.fulfill()
        }
        XCTAssertEqual(stub.callCount, 2, "released coordinator opens exactly one fresh request")
        stub.lastCompletion?(true)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(fresh, [.granted])
    }

    // MARK: - 4. Normal grant without cancellation -> exactly one recording

    @objc func testMicGrantNormal_StartsRecordingExactlyOnce() {
        let file = policyFile()
        defer { try? FileManager.default.removeItem(at: file) }
        let stub = RequestStub()
        let requester = makeRequester(stub: stub, file: file, timeout: 5.0)

        var micRequestSession = 0
        micRequestSession += 1
        let micSession = micRequestSession

        let done = expectation(description: "granted outcome")
        var outcomes: [MicAccessRequester.Outcome] = []
        requester.requestIfNeeded { outcome in
            outcomes.append(outcome)
            done.fulfill()
        }
        stub.lastCompletion?(true)
        wait(for: [done], timeout: 2)

        // Agent .granted branch: generation still current -> start once.
        // startRecording itself refuses re-entry via isStarting (mirrored).
        var recordingStarted = 0
        var isStarting = false
        for outcome in outcomes {
            guard outcome == .granted else { continue }
            guard micRequestSession == micSession else { continue }
            guard !isStarting else { continue }
            isStarting = true
            recordingStarted += 1
        }
        XCTAssertEqual(outcomes, [.granted], "exactly one outcome per request")
        XCTAssertEqual(recordingStarted, 1, "normal grant starts exactly one recording")

        // Even a duplicated system answer cannot start a second recording:
        // the coordinator consumed the token on the first answer.
        stub.lastCompletion?(true)
        drainEngineQueue()
        XCTAssertEqual(outcomes, [.granted], "duplicate system answer yields no second outcome")
    }

    // MARK: - 5. Recording/transcribing Enter/Esc composition unchanged

    /// Enter-stop arms exactly one synthetic Enter; Esc (any phase) consumes
    /// the latch so a cancelled loop never posts Enter afterwards.
    @objc func testEnterLatch_EscExtinguishesArmedEnter() {
        let latch = EnterSendLatch()
        // handleEnterKeyPressed in .recording: arm (once — repeated Enter in
        // .transcribing does not re-arm; structural pin below).
        latch.arm()
        XCTAssertTrue(latch.consume(), "armed latch fires once")
        XCTAssertFalse(latch.consume(), "latch is one-shot")

        latch.arm()
        // handleCancel terminal tail: extinguish the latch.
        latch.cancel()
        XCTAssertFalse(latch.consume(), "Esc-cancelled loop must not post Enter")
    }

    /// Esc during recognition poisons STT delivery: the returning request's
    /// result is ignored even while its session is still active.
    @objc func testTranscribingEsc_PoisonsSttDelivery() {
        XCTAssertFalse(
            NanoDictateFlow.shouldDeliverResult(isCancelled: true, sessionActive: true))
        XCTAssertTrue(
            NanoDictateFlow.shouldDeliverResult(isCancelled: false, sessionActive: true))
        XCTAssertFalse(
            NanoDictateFlow.shouldDeliverResult(isCancelled: false, sessionActive: false))
    }

    // MARK: - 6. Structural wiring pins (main.swift runs these sequences)

    /// Loads agent source (same trick as LiveOrchestrationBranchTests: the
    /// Agent target is not importable, so wiring is pinned structurally).
    private static func agentMainSource() -> String? {
        let fileDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let candidates = [
            fileDir
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/NanoDictateAgent/main.swift"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/NanoDictateAgent/main.swift"),
        ]
        guard let sourceURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            return nil
        }
        return source
    }

    private static func functionBody(named name: String, in source: String) -> String {
        guard let range = source.range(of: "func \(name)(") else { return "" }
        let tail = source[range.lowerBound...]
        if let end = tail.range(of: "\n  private func ") {
            return String(tail[..<end.lowerBound])
        }
        if let end = tail.range(of: "\n  // MARK: ") {
            return String(tail[..<end.lowerBound])
        }
        return String(tail)
    }

    /// Esc invalidates the pending retry-review wait: the .idle branch of
    /// handleCancel must advance processingSession when a review wait was
    /// pending (captured before the flag is cleared), instead of returning
    /// early on `isStarting == false`.
    @objc func testStructure_HandleCancelInvalidatesPendingRetryReview() {
        guard let source = Self.agentMainSource() else {
            XCTFail("cannot read Sources/NanoDictateAgent/main.swift")
            return
        }
        let body = Self.functionBody(named: "handleCancel", in: source)
        XCTAssertFalse(body.isEmpty, "handleCancel must exist")
        XCTAssertTrue(
            body.contains("let hadPendingReview = awaitingReviewDecision"),
            "Esc must capture the pending-review flag before clearing it")
        XCTAssertTrue(
            body.contains("guard isStarting || hadPendingReview else { return }"),
            "idle Esc must not return early while a retry review waits")
        XCTAssertTrue(
            body.contains("if hadPendingReview {"),
            "idle Esc must branch on the pending retry review")
        XCTAssertTrue(
            body.contains("processingSession += 1"),
            "idle Esc must advance the session so the late review completion drops")
    }

    /// retryInsertion must mark the review wait (so Esc can see it) and clear
    /// the mark when the decision arrives, before re-validating the session.
    /// It must also reject retry results while engine bring-up is in flight
    /// (isStarting, state still .idle); otherwise a retry arriving during
    /// startup opens a review that breaks Return swallowing and can insert
    /// after a failed start without session invalidation.
    @objc func testStructure_RetryInsertionTracksReviewWait() {
        guard let source = Self.agentMainSource() else {
            XCTFail("cannot read Sources/NanoDictateAgent/main.swift")
            return
        }
        let body = Self.functionBody(named: "retryInsertion", in: source)
        XCTAssertFalse(body.isEmpty, "retryInsertion must exist")
        guard let waitRange = body.range(of: "awaitingReviewDecision = true"),
              let asyncRange = body.range(of: "ReviewGate.confirmAsync") else {
            XCTFail("retryInsertion must mark the review wait before confirmAsync")
            return
        }
        XCTAssertTrue(
            waitRange.lowerBound < asyncRange.lowerBound,
            "the review-wait mark must precede the async review wait")
        guard let clearRange = body.range(of: "self.awaitingReviewDecision = false"),
              let gateRange = body.range(of: "RetryInsertionGate.shouldDropRetry") else {
            XCTFail("retry completion must clear the mark before re-validating the session")
            return
        }
        XCTAssertTrue(
            clearRange.lowerBound < gateRange.lowerBound,
            "the review-wait mark must clear before the stale-session check")
        XCTAssertTrue(
            body.contains("guard state == .idle, !isStarting else"),
            "retryInsertion must reject retry results while engine bring-up is in flight")
    }

    /// The pending microphone request is cancellable by Esc on two levels:
    /// the agent generation (drops a delivered late grant before
    /// startRecording) and the coordinator token (drops the late answer
    /// itself). Both invalidations must run before the state switch so the
    /// .idle early return cannot skip them.
    @objc func testStructure_MicRequestCancellableByEsc() {
        guard let source = Self.agentMainSource() else {
            XCTFail("cannot read Sources/NanoDictateAgent/main.swift")
            return
        }
        let cancelBody = Self.functionBody(named: "handleCancel", in: source)
        XCTAssertTrue(
            cancelBody.contains("micRequestSession += 1"),
            "Esc must bump the microphone-request generation")
        XCTAssertTrue(
            cancelBody.contains("micAccessRequester.invalidatePending()"),
            "Esc must invalidate the pending coordinator request")
        guard let invalidateRange = cancelBody.range(of: "micAccessRequester.invalidatePending()"),
              let switchRange = cancelBody.range(of: "switch state") else {
            XCTFail("handleCancel must invalidate the mic request before the state switch")
            return
        }
        XCTAssertTrue(
            invalidateRange.lowerBound < switchRange.lowerBound,
            "mic invalidation must precede the switch (applies to the .idle early return too)")

        let requestBody = Self.functionBody(named: "requestMicrophoneAndStart", in: source)
        XCTAssertTrue(
            requestBody.contains("micRequestSession += 1"),
            "each microphone request must open a new generation")
        XCTAssertTrue(
            requestBody.contains("let micSession = micRequestSession"),
            "the pending request must capture its generation")
        guard let guardRange = requestBody.range(of: "guard self.micRequestSession == micSession"),
              let startRange = requestBody.range(of: "self.startRecording(triggerNanos: triggerNanos)") else {
            XCTFail("granted branch must re-validate the generation before startRecording")
            return
        }
        XCTAssertTrue(
            guardRange.lowerBound < startRange.lowerBound,
            "late grants must drop before startRecording")
        // The anti-storm guard is untouched: a pending dialog still refuses a
        // second request.
        XCTAssertTrue(
            requestBody.contains("guard !micAccessRequester.isInFlight else {"),
            "the in-flight anti-storm guard must remain")
    }

    /// Recording/transcribing Enter/Esc paths are unchanged by this repair:
    /// Enter arms the latch only from .recording, transcribing Enter is a
    /// no-op, Esc keeps its per-phase cancel semantics and single terminal
    /// tail.
    @objc func testStructure_EnterEscPathsUnchanged() {
        guard let source = Self.agentMainSource() else {
            XCTFail("cannot read Sources/NanoDictateAgent/main.swift")
            return
        }
        let enterBody = Self.functionBody(named: "handleEnterKeyPressed", in: source)
        XCTAssertTrue(enterBody.contains("enterSendLatch.arm()"), "Enter in .recording arms the latch")
        XCTAssertTrue(enterBody.contains("sendRecording()"), "Enter in .recording stops recording")
        XCTAssertTrue(enterBody.contains("liveFinalize()"), "Enter in .recording covers live dictation")

        let cancelBody = Self.functionBody(named: "handleCancel", in: source)
        XCTAssertTrue(cancelBody.contains("audio.cancel()"), "recording cancel stops the engine")
        XCTAssertTrue(cancelBody.contains("liveSession += 1"), "recording cancel invalidates the live loop")
        XCTAssertTrue(
            cancelBody.contains("cancelRecognition = true"), "transcribing cancel poisons STT delivery")
        XCTAssertTrue(
            cancelBody.contains("scheduledEnterPoster.cancelScheduled()"),
            "Esc cancels an already scheduled synthetic Enter")
        XCTAssertTrue(
            cancelBody.contains("hideAfter(0.8, reason: \"cancelled\")"),
            "cancel keeps its single terminal tail")
        XCTAssertTrue(cancelBody.contains("state = .idle"), "cancel returns the agent to idle")
    }
}
