import Foundation
import AVFoundation
@testable import NanoDictateCore

/// Capture-readiness regression tests (P0 first-word clipping).
///
/// Contract under test:
///   • `start(completion:)` success means only "engine started" — it must NOT
///     imply microphone buffers flow, and the normal start cue (sound +
///     "Recording" UI) must be gated on `onCaptureReady` (first valid buffer),
///     never on engine-start alone;
///   • `onCaptureReady` fires exactly once per successful session, on the main
///     queue, with monotonic timing info (no raw audio);
///   • the first valid buffer is retained in the full recording regardless of
///     VAD classification (pre-roll stays segmentation-only);
///   • startup failure/cancel paths never fire a false ready cue;
///   • pre-warming captures nothing (no always-on microphone) and keeps the
///     next start working;
///   • repeated start/stop cycles each reach readiness independently.
///
/// Fake engine, no hardware (same pattern as AudioServiceLifecycleTests).
final class AudioServiceCaptureReadyTests: XCTestCase {

    // MARK: - Engine start is not capture-ready

    /// Success of `start` alone must not report capture readiness and must not
    /// fire the ready callback: buffers have not flowed yet.
    @objc func testEngineStartSuccessDoesNotImplyCaptureReady() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)
        var readyCount = 0
        service.onCaptureReady = { _ in readyCount += 1 }

        guard case .success = runStart(service) else {
            XCTFail("start must succeed on the fake engine")
            return
        }
        XCTAssertFalse(service.isCaptureReady, "engine started, but no buffer flowed — not capture-ready")
        drainEngineQueue()
        XCTAssertEqual(readyCount, 0, "ready callback must not fire before the first buffer")
    }

    // MARK: - First buffer fires readiness exactly once

    /// First valid buffer fires `onCaptureReady` once with sane monotonic
    /// timings; the second buffer never re-fires.
    @objc func testFirstBufferFiresCaptureReadyExactlyOnceWithTimings() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)
        var readyCount = 0
        var capturedInfo: AudioService.CaptureReadyInfo?
        service.onCaptureReady = { info in
            readyCount += 1
            capturedInfo = info
        }

        let triggerNanos = DispatchTime.now().uptimeNanoseconds
        let done = expectation(description: "audio start completion")
        var startResult: AudioStartResult = .failure(AudioServiceError.engineGone)
        service.start(triggerUptimeNanos: triggerNanos) { result in
            startResult = result
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        guard case .success = startResult else {
            XCTFail("start must succeed, got \(startResult)")
            return
        }
        XCTAssertEqual(readyCount, 0, "no ready cue before the first buffer")

        engine.node.emit(makeToneBuffer(engine: engine))
        XCTAssertTrue(
            eventually { readyCount == 1 },
            "first valid buffer must fire capture readiness once"
        )
        XCTAssertTrue(service.isCaptureReady, "session must report capture-ready after first buffer")
        guard let info = capturedInfo else {
            XCTFail("ready callback must deliver timing info")
            return
        }
        XCTAssertGreaterThanOrEqual(info.requestToEngineStartedMs, 0, "timing must be non-negative")
        XCTAssertGreaterThanOrEqual(info.engineStartedToFirstBufferMs, 0, "timing must be non-negative")
        XCTAssertGreaterThanOrEqual(info.requestToFirstBufferMs, 0, "timing must be non-negative")
        XCTAssertNotNil(info.triggerToRequestMs, "trigger stamp must produce trigger->request timing")
        if let triggerToRequest = info.triggerToRequestMs {
            XCTAssertGreaterThanOrEqual(triggerToRequest, 0, "trigger timing must be non-negative")
        }

        engine.node.emit(makeToneBuffer(engine: engine))
        drainEngineQueue()
        XCTAssertEqual(readyCount, 1, "second buffer must not re-fire readiness")
        _ = service.stop()
    }

    // MARK: - Regression: no success cue before capture readiness

    /// Models the application gating: the success cue flag is set ONLY in the
    /// `onCaptureReady` handler (as Agent.emitRecordingReadyCue does), never in
    /// the `start` completion. Proves the app cannot emit the successful
    /// recording-ready cue before capture readiness is observed.
    @objc func testNoReadyCueBeforeCaptureReadiness() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)
        var cueEmitted = false
        var engineDone = false
        service.onCaptureReady = { _ in
            cueEmitted = true
        }

        let done = expectation(description: "audio start completion")
        service.start { result in
            // Application rule: engine-start completion NEVER emits the cue.
            engineDone = true
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertTrue(engineDone, "engine start must complete")
        XCTAssertFalse(cueEmitted, "REGRESSION: success cue must not precede capture readiness")

        engine.node.emit(makeToneBuffer(engine: engine))
        XCTAssertTrue(
            eventually { cueEmitted },
            "cue must follow once capture readiness is observed"
        )
        _ = service.stop()
    }

    // MARK: - First buffer preserved in the recording

    /// A buffer emitted immediately after start (speech begun right after the
    /// future ready cue) must be fully retained in `stop()` output — the
    /// initial speech attack is never discarded by VAD/pre-roll accounting.
    @objc func testFirstBufferPreservedInRecording() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)

        guard case .success = runStart(service) else {
            XCTFail("start must succeed")
            return
        }
        // Immediate speech: first buffer arrives with no prior silence.
        engine.node.emit(makeToneBuffer(engine: engine))

        let samples = service.stop()
        // One 44.1 kHz x 4096-frame buffer resamples to ~1486 frames @16 kHz.
        XCTAssertGreaterThanOrEqual(samples.count, 1410, "first buffer must reach the WAV/STT path")
        XCTAssertLessThanOrEqual(samples.count, 1560, "first buffer must not duplicate with pre-roll")
        let maxAbs = samples.map { abs(Int($0)) }.max() ?? 0
        XCTAssertGreaterThanOrEqual(maxAbs, 3000, "speech attack amplitude must survive")
    }

    // MARK: - Repeated start/stop lifecycle

    /// Each start/stop cycle independently reaches readiness exactly once and
    /// keeps its own first buffer; no stale latch leaks across sessions.
    @objc func testRepeatedStartStopLifecycle() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)
        var readyCount = 0
        service.onCaptureReady = { _ in readyCount += 1 }

        guard case .success = runStart(service) else {
            XCTFail("first start must succeed")
            return
        }
        engine.node.emit(makeToneBuffer(engine: engine))
        XCTAssertTrue(eventually { readyCount == 1 }, "first session must reach readiness")
        let first = service.stop()
        XCTAssertGreaterThanOrEqual(first.count, 1410, "first session keeps its buffer")
        drainEngineQueue()

        guard case .success = runStart(service) else {
            XCTFail("second start must succeed")
            return
        }
        XCTAssertFalse(service.isCaptureReady, "new session starts not-ready")
        engine.node.emit(makeToneBuffer(engine: engine))
        XCTAssertTrue(eventually { readyCount == 2 }, "second session must reach readiness independently")
        let second = service.stop()
        XCTAssertGreaterThanOrEqual(second.count, 1410, "second session keeps its buffer")
        XCTAssertLessThanOrEqual(second.count, 1560, "no cross-session duplication")
    }

    // MARK: - Cancel during startup suppresses readiness

    /// Cancel after engine start but before any buffer: the pending readiness
    /// must never fire (race-safe abort, no false cue afterwards).
    @objc func testCancelDuringStartupSuppressesCaptureReady() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)
        var readyCount = 0
        service.onCaptureReady = { _ in readyCount += 1 }

        guard case .success = runStart(service) else {
            XCTFail("start must succeed")
            return
        }
        service.cancel()
        engine.node.emit(makeToneBuffer(engine: engine))
        drainEngineQueue()
        XCTAssertEqual(readyCount, 0, "cancelled startup must never become ready")
        XCTAssertEqual(service.stop(), [], "nothing recorded after cancel")
    }

    // MARK: - Failure paths never cue readiness

    /// Engine-start failure: terminal `.failure` with teardown and no ready
    /// callback — the error path never emits a false ready cue; retry works.
    @objc func testStartFailureNeverFiresCaptureReady() {
        let engine = FakeEngine()
        engine.failStart = true
        let service = AudioService(logLevel: "info", engine: engine)
        var readyCount = 0
        service.onCaptureReady = { _ in readyCount += 1 }

        let first = runStart(service)
        guard case .failure = first else {
            XCTFail("start must fail with failStart injected")
            return
        }
        engine.node.emit(makeToneBuffer(engine: engine))
        drainEngineQueue()
        XCTAssertEqual(readyCount, 0, "failed startup must never fire readiness")
        XCTAssertFalse(service.isCaptureReady, "failed session is never ready")

        engine.failStart = false
        guard case .success = runStart(service) else {
            XCTFail("retry after failure must succeed")
            return
        }
        engine.node.emit(makeToneBuffer(engine: engine))
        XCTAssertTrue(eventually { readyCount == 1 }, "retry session reaches readiness")
        _ = service.stop()
    }

    // MARK: - Pre-warm captures nothing, keeps next start cheap

    /// `prewarm()` must not start a recording (no always-on microphone):
    /// nothing is captured, readiness stays false — yet the following real
    /// start still succeeds and reaches readiness with its first buffer.
    @objc func testPrewarmCapturesNothingAndNextStartSucceeds() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)
        var readyCount = 0
        service.onCaptureReady = { _ in readyCount += 1 }

        service.prewarm()
        drainEngineQueue()
        XCTAssertFalse(service.isCaptureReady, "prewarm alone must not become capture-ready")
        XCTAssertEqual(readyCount, 0, "prewarm alone must not fire readiness")
        XCTAssertEqual(service.stop(), [], "prewarm alone must capture no audio")

        guard case .success = runStart(service) else {
            XCTFail("start after prewarm must succeed")
            return
        }
        engine.node.emit(makeToneBuffer(engine: engine))
        XCTAssertTrue(eventually { readyCount == 1 }, "start after prewarm reaches readiness")
        let samples = service.stop()
        XCTAssertGreaterThanOrEqual(samples.count, 1410, "first buffer preserved after prewarm")
    }

    // MARK: - Helpers

    /// Tone buffer in the fake engine node format (speech-like, not silence).
    private func makeToneBuffer(engine: FakeEngine) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.node.format, frameCapacity: 4096)!
        buffer.frameLength = 4096
        let channel = buffer.floatChannelData![0]
        for i in 0..<4096 {
            channel[i] = 0.2
        }
        return buffer
    }
}
