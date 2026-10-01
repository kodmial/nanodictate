import Foundation
import AVFoundation
@testable import NanoDictateCore

/// P0 Alt+Alt latency: first-Alt non-capturing pre-arm and fast-path start.
///
/// Contract under test (extends the #48 invariants in
/// AudioServiceCaptureReadyTests, which must keep passing unmodified):
///   - armForImminentStart captures nothing: no tap, no recording, no ready
///     cue, no stored audio (no always-on microphone in the default mode);
///   - arm -> confirmed start reaches capture readiness with the first buffer
///     preserved (no first-word loss) and reports an ordered startup
///     breakdown;
///   - arm timeout/cancel leaves no persistent audio resources: the next
///     start performs a full bring-up and still succeeds;
///   - stale generations (wedge swap) invalidate the arm: no false ready cue
///     and no half-open tap/engine/session;
///   - the tap request size is the chosen 1024-frame value.
final class AudioServiceArmingTests: XCTestCase {

    @objc func testTapBufferSizeIs1024() {
        XCTAssertEqual(AudioService.tapBufferSize, 1024)
    }

    @objc func testStartInstallsTapWith1024Frames() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)
        guard case .success = runStart(service) else {
            XCTFail("start must succeed")
            return
        }
        XCTAssertEqual(engine.node.tapCount, 1)
        XCTAssertEqual(engine.node.lastBufferSize, 1024)
        _ = service.stop()
    }

    @objc func testArmCapturesNothing() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)
        var readyCount = 0
        service.onCaptureReady = { _ in readyCount += 1 }

        service.armForImminentStart()
        drainEngineQueue()

        XCTAssertEqual(engine.node.tapCount, 0, "pre-arm must never install a tap")
        XCTAssertFalse(service.isCaptureReady, "pre-arm alone must not become capture-ready")
        XCTAssertEqual(readyCount, 0, "pre-arm alone must not fire readiness")
        XCTAssertEqual(service.stop(), [], "pre-arm alone must capture no audio")
    }

    @objc func testArmThenStartReachesReadinessWithFirstBuffer() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)
        var readyCount = 0
        service.onCaptureReady = { _ in readyCount += 1 }

        service.noteFirstAltTap()
        service.armForImminentStart()
        drainEngineQueue()
        XCTAssertTrue(service.isArmedForTests(), "arm must be pending before confirm")

        service.noteSecondAltTap()
        guard case .success = runStart(service) else {
            XCTFail("confirmed start after arm must succeed")
            return
        }
        XCTAssertFalse(service.isArmedForTests(), "confirmed start must consume the arm exactly once")
        XCTAssertEqual(readyCount, 0, "no ready cue before the first buffer")

        engine.node.emit(makeToneBuffer(engine: engine))
        XCTAssertTrue(eventually { readyCount == 1 }, "first buffer must fire readiness once")
        XCTAssertTrue(service.isCaptureReady)

        let samples = service.stop()
        XCTAssertGreaterThanOrEqual(samples.count, 300, "first buffer must reach the WAV/STT path")
        XCTAssertLessThanOrEqual(samples.count, 520, "first buffer must not duplicate")

        guard let stages = service.lastStartupBreakdown else {
            XCTFail("readiness must record a startup breakdown")
            return
        }
        XCTAssertGreaterThanOrEqual(stages.queueEntryNanos, stages.requestNanos)
        XCTAssertGreaterThanOrEqual(stages.firstAcceptedNanos, stages.engineStartedNanos)
        XCTAssertGreaterThanOrEqual(stages.firstRawCallbackNanos, stages.engineStartedNanos)
    }

    @objc func testArmCancelLeavesNoResourcesAndNextStartSucceeds() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)
        var readyCount = 0
        service.onCaptureReady = { _ in readyCount += 1 }

        service.armForImminentStart()
        drainEngineQueue()
        XCTAssertTrue(service.isArmedForTests())
        service.cancelPendingArm()
        drainEngineQueue()
        XCTAssertFalse(service.isArmedForTests(), "cancel must discard the arm")
        XCTAssertEqual(engine.node.tapCount, 0, "cancelled arm must leave no tap")
        XCTAssertEqual(service.stop(), [], "cancelled arm must capture no audio")

        guard case .success = runStart(service) else {
            XCTFail("start after arm cancel must succeed via full bring-up")
            return
        }
        engine.node.emit(makeToneBuffer(engine: engine))
        XCTAssertTrue(eventually { readyCount == 1 }, "session after cancel reaches readiness")
        _ = service.stop()
    }

    @objc func testRepeatedSingleAltNeverCaptures() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)
        var readyCount = 0
        service.onCaptureReady = { _ in readyCount += 1 }

        for _ in 0..<3 {
            service.noteFirstAltTap()
            service.armForImminentStart()
            drainEngineQueue()
            service.cancelPendingArm()
            drainEngineQueue()
        }
        XCTAssertFalse(service.isArmedForTests())
        XCTAssertEqual(engine.node.tapCount, 0, "repeated single-Alt must install no tap")
        XCTAssertEqual(readyCount, 0, "repeated single-Alt must never fire readiness")
        XCTAssertEqual(service.stop(), [], "repeated single-Alt must capture no audio")
    }

    @objc func testWedgeInvalidatesArmWithoutFalseReady() {
        let engine = FakeEngine()
        let freshEngine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine, makeEngine: { freshEngine })
        var readyCount = 0
        service.onCaptureReady = { _ in readyCount += 1 }

        service.armForImminentStart()
        drainEngineQueue()
        service.replaceEngineAfterWedge()
        XCTAssertFalse(service.isArmedForTests(), "wedge swap must invalidate the arm")
        XCTAssertFalse(service.isCaptureReady)

        guard case .success = runStart(service) else {
            XCTFail("start on the fresh engine must succeed")
            return
        }
        XCTAssertEqual(readyCount, 0, "no false ready cue from the discarded arm")
        freshEngine.node.emit(makeToneBuffer(engine: freshEngine))
        XCTAssertTrue(eventually { readyCount == 1 }, "fresh session reaches readiness independently")
        _ = service.stop()
    }

    @objc func testConfigurationChangeDiscardsPendingArm() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)
        var readyCount = 0
        service.onCaptureReady = { _ in readyCount += 1 }

        service.armForImminentStart()
        drainEngineQueue()
        XCTAssertTrue(service.isArmedForTests(), "arm must be pending before device change")

        service.simulateConfigurationChangeForTests()
        XCTAssertFalse(service.isArmedForTests(), "device change must discard the arm")

        guard case .success = runStart(service) else {
            XCTFail("start after device change must succeed via full bring-up")
            return
        }
        engine.node.emit(makeToneBuffer(engine: engine))
        XCTAssertTrue(eventually { readyCount == 1 }, "session after device change reaches readiness")
        _ = service.stop()
    }

    @objc func testRacingArmPublicationAfterConfigurationChangeIsRejected() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)
        var readyCount = 0
        service.onCaptureReady = { _ in readyCount += 1 }

        let entered = expectation(description: "arm entered input setup")
        engine.onMakeInputNode = { entered.fulfill() }
        engine.makeInputGate = DispatchSemaphore(value: 0)
        service.armForImminentStart()
        wait(for: [entered], timeout: 5)
        // Device change lands while the arm is blocked mid-preparation on the
        // same input format: the late publication must be rejected even
        // though the generation and hardware signature are unchanged.
        service.simulateConfigurationChangeForTests()
        engine.makeInputGate?.signal()
        engine.makeInputGate = nil
        drainEngineQueue()
        XCTAssertFalse(
            service.isArmedForTests(),
            "arm preparation racing a device change must not publish stale state")
        XCTAssertEqual(engine.node.tapCount, 0, "rejected arm must install no tap")

        let preparesBeforeStart = engine.prepareCount
        guard case .success = runStart(service) else {
            XCTFail("start after raced device change must succeed")
            return
        }
        XCTAssertGreaterThan(
            engine.prepareCount, preparesBeforeStart,
            "start must perform a full prepare instead of consuming a stale arm")
        engine.node.emit(makeToneBuffer(engine: engine))
        XCTAssertTrue(eventually { readyCount == 1 }, "fresh session reaches readiness independently")
        _ = service.stop()
    }

    @objc func testPreArmObservesConfigurationChangeNotification() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)
        var readyCount = 0
        service.onCaptureReady = { _ in readyCount += 1 }

        service.armForImminentStart()
        drainEngineQueue()
        XCTAssertTrue(service.isArmedForTests(), "arm must be pending before device change")

        // The pre-arm window itself must observe device changes: without an
        // observer installed before preparation, a same-format swap would
        // leave the epoch unchanged and allow stale preparation to be
        // consumed. FakeEngine posts with a nil object, matching the
        // nil-object subscription, so a real notification must invalidate.
        NotificationCenter.default.post(
            name: .AVAudioEngineConfigurationChange, object: nil)
        XCTAssertFalse(
            service.isArmedForTests(),
            "pre-arm observer must discard the arm on device-change notification")

        let preparesBeforeStart = engine.prepareCount
        guard case .success = runStart(service) else {
            XCTFail("start after observed device change must succeed")
            return
        }
        XCTAssertGreaterThan(
            engine.prepareCount, preparesBeforeStart,
            "start must perform a full prepare instead of consuming a stale arm")
        engine.node.emit(makeToneBuffer(engine: engine))
        XCTAssertTrue(eventually { readyCount == 1 }, "fresh session reaches readiness independently")
        _ = service.stop()
    }

    @objc func testConfigurationChangeAfterArmConsumptionForcesPrepare() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)
        var readyCount = 0
        service.onCaptureReady = { _ in readyCount += 1 }

        service.armForImminentStart()
        drainEngineQueue()
        XCTAssertTrue(service.isArmedForTests(), "arm must be pending before confirm")
        let preparesAfterArm = engine.prepareCount
        XCTAssertGreaterThan(preparesAfterArm, 0, "arm must have prepared the graph")

        // Device change lands after arm consumption (during format bring-up,
        // before tap install) but before the prepare-skipping decision: the
        // consumed epoch is stale, so the start must fall back to a fresh
        // prepare instead of skipping it.
        engine.node.onInstallTap = { [weak service] in
            service?.simulateConfigurationChangeForTests()
        }
        guard case .success = runStart(service) else {
            engine.node.onInstallTap = nil
            XCTFail("start after post-consumption device change must succeed")
            return
        }
        engine.node.onInstallTap = nil
        XCTAssertGreaterThan(
            engine.prepareCount, preparesAfterArm,
            "post-consumption device change must invalidate the skipped prepare")
        engine.node.emit(makeToneBuffer(engine: engine))
        XCTAssertTrue(eventually { readyCount == 1 }, "session after invalidation reaches readiness")
        _ = service.stop()
    }

    @objc func testConfigurationChangeDuringArmedStartAbortsStaleStartup() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)

        service.armForImminentStart()
        drainEngineQueue()
        XCTAssertTrue(service.isArmedForTests(), "arm must be pending before confirm")
        let preparesAfterArm = engine.prepareCount
        XCTAssertGreaterThan(preparesAfterArm, 0, "arm must have prepared the graph")

        // Device change lands in the final race window: after the last epoch
        // check, before engine.start() completes. Clearing pendingArm cannot
        // invalidate the already-consumed arm, so the post-startup check must
        // abort the stale startup instead of returning success on a rebuilt
        // graph.
        engine.onStart = { [weak service] in
            service?.simulateConfigurationChangeForTests()
        }
        let result = runStart(service)
        engine.onStart = nil
        switch result {
        case .failure(AudioServiceError.deviceChanged):
            break
        case .failure(let error):
            XCTFail("stale armed startup must abort with deviceChanged, got \(error)")
            _ = service.stop()
            return
        case .success:
            XCTFail("armed start racing a device change must abort, not succeed on stale preparation")
            _ = service.stop()
            return
        }
        XCTAssertEqual(
            engine.prepareCount, preparesAfterArm,
            "aborted stale startup must not silently reuse the arm's prepare")
        XCTAssertFalse(service.isArmedForTests(), "aborted startup must leave no pending arm")
        drainEngineQueue()

        guard case .success = runStart(service) else {
            XCTFail("start after aborted stale startup must succeed via full bring-up")
            return
        }
        _ = service.stop()
    }

    // MARK: - Helpers

    private func makeToneBuffer(engine: FakeEngine) -> AVAudioPCMBuffer {
        let frames: AVAudioFrameCount = 1024
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.node.format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            channel[i] = 0.2
        }
        return buffer
    }
}

/// First-Alt arming observer on HotkeyService: first tap opens the window and
/// notifies, confirm fires the double tap, timeout/foreign keys cancel with
/// notification. No audio behavior here — the delegate (agent) owns disarm.
final class HotkeyArmingTests: XCTestCase {
    private final class ArmingSpy: HotkeyDelegate {
        var doubleTapCount = 0
        var firstTapCount = 0
        var pendingCancelledCount = 0
        func altDoubleTapped() { doubleTapCount += 1 }
        func altFirstTapDetected() { firstTapCount += 1 }
        func altPendingCancelled() { pendingCancelledCount += 1 }
        func cancelKeyPressed() {}
        func enterKeyPressed() {}
        func shouldSwallowReturnKeyEvent() -> Bool { false }
    }

    @objc func testFirstTapNotifiesAndMarksPending() {
        let spy = ArmingSpy()
        let service = HotkeyService()
        service.delegate = spy
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 1.0)
        XCTAssertEqual(spy.firstTapCount, 1)
        XCTAssertEqual(spy.doubleTapCount, 0)
        XCTAssertTrue(service.isAltPending)
    }

    @objc func testSecondTapConfirmsWithoutCancelNotification() {
        let spy = ArmingSpy()
        let service = HotkeyService()
        service.delegate = spy
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 1.0)
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 1.2)
        XCTAssertEqual(spy.doubleTapCount, 1)
        XCTAssertEqual(spy.pendingCancelledCount, 0, "confirm must not count as cancel")
        XCTAssertFalse(service.isAltPending)
    }

    @objc func testForeignKeyCancelsPendingWithNotification() {
        let spy = ArmingSpy()
        let service = HotkeyService()
        service.delegate = spy
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 1.0)
        service.handleKeyboardEvent(type: .keyDown, keyCode: 0, flags: [], isRepeat: false, at: 1.1)
        XCTAssertEqual(spy.pendingCancelledCount, 1)
        XCTAssertFalse(service.isAltPending)
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 1.2)
        XCTAssertEqual(spy.doubleTapCount, 0, "cancelled first tap must not pair")
        XCTAssertEqual(spy.firstTapCount, 2, "new tap opens a fresh window")
    }

    @objc func testExpiryCancelsPendingWithNotification() {
        let spy = ArmingSpy()
        let service = HotkeyService()
        service.delegate = spy
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 1.0)
        XCTAssertTrue(service.isAltPending)
        service.expirePendingAltForTests()
        XCTAssertEqual(spy.pendingCancelledCount, 1)
        XCTAssertFalse(service.isAltPending)
    }

    @objc func testStartingUIDeferThreshold() {
        XCTAssertFalse(OverlayLifecycle.StartingUIDefer.shouldShowStarting(elapsed: 0.05))
        XCTAssertTrue(OverlayLifecycle.StartingUIDefer.shouldShowStarting(elapsed: 0.12))
        XCTAssertTrue(OverlayLifecycle.StartingUIDefer.shouldShowStarting(elapsed: 0.5))
    }
}
