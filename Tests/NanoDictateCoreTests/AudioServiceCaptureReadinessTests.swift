import Foundation
import AVFoundation
@testable import NanoDictateCore

/// Capture-readiness gate (first-word-clipping fix): the truthful
/// recording-ready point is the first valid microphone buffer, never the
/// `engine.start()` return alone.
///
/// Covers:
///   • REGRESSION: no successful ready cue before capture readiness is
///     observed (engine-up completion fires first, `onCaptureReady` only
///     after the first valid buffer);
///   • the first buffer (speech AND silence) is retained in the full
///     recording regardless of VAD classification, without pre-roll
///     duplication;
///   • repeated start/stop cycles each signal readiness exactly once;
///   • stop before the first buffer prevents any late ready cue;
///   • stale-generation buffers never signal readiness of a new session;
///   • safe pre-warm holds no capture and the converter cache reuses on a
///     stable device but rebuilds after a format change.
final class AudioServiceCaptureReadinessTests: XCTestCase {

    private func makeService(engine: FakeEngine) -> AudioService {
        AudioService(
            logLevel: "info",
            engine: engine,
            autoStopConfig: AutoStopConfig(enabled: false)
        )
    }

    private func makeBuffer(engine: FakeEngine, amplitude: Float = 0.2) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.node.format, frameCapacity: 4096)!
        buffer.frameLength = 4096
        let channel = buffer.floatChannelData![0]
        for i in 0..<4096 {
            channel[i] = amplitude
        }
        return buffer
    }

    // MARK: - Regression: no ready cue before capture readiness

    /// The application-level ready cue (modelled here as the `readyCue`
    /// closure, mirroring the agent's start-sound/UI/timer emission) must be
    /// unreachable before the capture path delivers its first valid buffer:
    /// `start` success (engine up) fires first and alone, `onCaptureReady`
    /// fires only after a buffer is emitted, exactly once.
    @objc func testReadyCueCannotFireBeforeCaptureReadiness() {
        let engine = FakeEngine()
        let service = makeService(engine: engine)

        var events: [String] = []
        var readyCount = 0
        service.onCaptureReady = {
            readyCount += 1
            events.append("ready")
        }

        var engineResult: AudioStartResult?
        let done = expectation(description: "audio start completion")
        let requestTime = AudioService.monotonicNow()
        service.start(requestTime: requestTime) { result in
            engineResult = result
            events.append("engineUp")
            done.fulfill()
        }
        wait(for: [done], timeout: 5)

        guard case .success = engineResult else {
            XCTFail("engine bring-up must succeed, got \(String(describing: engineResult))")
            return
        }
        XCTAssertEqual(events, ["engineUp"], "engine-up must not emit the ready cue by itself")
        XCTAssertEqual(readyCount, 0, "no ready cue before the first captured buffer")
        XCTAssertFalse(service.isCaptureReady, "capture must not be ready before the first buffer")

        engine.node.emit(makeBuffer(engine: engine))
        XCTAssertTrue(
            eventually { readyCount == 1 },
            "first valid buffer must fire capture readiness exactly once"
        )
        XCTAssertTrue(service.isCaptureReady)
        XCTAssertEqual(events, ["engineUp", "ready"], "ordering must be engine-up THEN ready")
        XCTAssertEqual(readyCount, 1, "readiness must fire exactly once per session")

        // A second buffer must not re-fire readiness.
        engine.node.emit(makeBuffer(engine: engine))
        drainEngineQueue()
        XCTAssertEqual(readyCount, 1, "readiness must never fire twice in one session")
        _ = service.stop()
    }

    // MARK: - First buffer preserved regardless of VAD

    /// A speech buffer arriving immediately after start (the clipped
    /// first-word attack in production) must be retained in full in the
    /// recording returned by `stop()`.
    @objc func testImmediateFirstSpeechBufferPreserved() {
        let engine = FakeEngine()
        let service = makeService(engine: engine)
        guard case .success = runStart(service) else {
            XCTFail("start must succeed")
            return
        }
        engine.node.emit(makeBuffer(engine: engine, amplitude: 0.2))
        let samples = service.stop()
        XCTAssertGreaterThanOrEqual(samples.count, 1410, "first speech buffer must reach the WAV/STT path")
        XCTAssertLessThanOrEqual(samples.count, 1560, "first buffer must not be duplicated")
        XCTAssertTrue(service.isCaptureReady)
    }

    /// A silence first buffer also proves the capture path is live: readiness
    /// fires and the buffer is retained (no VAD rule may discard the initial
    /// attack from the full recording).
    @objc func testSilenceFirstBufferStillSignalsReadiness() {
        let engine = FakeEngine()
        let service = makeService(engine: engine)
        var readyCount = 0
        service.onCaptureReady = { readyCount += 1 }
        guard case .success = runStart(service) else {
            XCTFail("start must succeed")
            return
        }
        XCTAssertEqual(readyCount, 0)
        engine.node.emit(makeBuffer(engine: engine, amplitude: 0.001))
        XCTAssertTrue(eventually { readyCount == 1 }, "even a silence buffer proves capture is live")
        let samples = service.stop()
        XCTAssertGreaterThanOrEqual(samples.count, 1410, "silence first buffer must be retained too")
    }

    // MARK: - Repeated start/stop lifecycle

    /// Repeated sessions each reach readiness exactly once and keep working:
    /// no tap lifecycle or generation regression from the readiness gate.
    @objc func testRepeatedStartStopEachSignalsReadinessOnce() {
        let engine = FakeEngine()
        let service = makeService(engine: engine)
        XCTAssertFalse(service.isCaptureReady, "initial state starts not-ready")
        for round in 1...3 {
            var readyCount = 0
            service.onCaptureReady = { readyCount += 1 }
            guard case .success = runStart(service) else {
                XCTFail("round \(round): start must succeed")
                return
            }
            // Readiness resets at session start (async bring-up): engine-up
            // alone must never report ready. No check before start here on
            // purpose — isCaptureReady intentionally reflects the last session
            // until the next start completes (stop/teardown never clear it).
            XCTAssertFalse(service.isCaptureReady, "round \(round): engine-up alone is not ready")
            engine.node.emit(makeBuffer(engine: engine))
            XCTAssertTrue(
                eventually { readyCount == 1 },
                "round \(round): readiness must fire exactly once"
            )
            let samples = service.stop()
            XCTAssertGreaterThanOrEqual(samples.count, 1410, "round \(round): samples must be collected")
            drainEngineQueue()
        }
        XCTAssertEqual(engine.node.tapCount, 3, "three sessions install three taps")
    }

    // MARK: - Stop during startup prevents late cue

    /// Stopping before any buffer arrived must prevent a late ready cue: a
    /// buffer emitted on the torn-down tap afterwards is dropped and never
    /// signals readiness.
    @objc func testStopBeforeFirstBufferPreventsLateReady() {
        let engine = FakeEngine()
        let service = makeService(engine: engine)
        var readyCount = 0
        service.onCaptureReady = { readyCount += 1 }
        guard case .success = runStart(service) else {
            XCTFail("start must succeed")
            return
        }
        let early = service.stop()
        XCTAssertTrue(early.isEmpty, "no buffer arrived — stop returns empty")
        drainEngineQueue()
        engine.node.emit(makeBuffer(engine: engine))
        drainEngineQueue()
        XCTAssertEqual(readyCount, 0, "cancelled startup must never emit a ready cue")
        XCTAssertFalse(service.isCaptureReady)
    }

    // MARK: - Stale generation never signals the new session

    /// After a wedge swap, buffers from the discarded engine's tap must not
    /// signal readiness of the fresh session; only the fresh engine's first
    /// buffer does.
    @objc func testStaleEngineBufferNeverSignalsNewSession() {
        let hanging = FakeEngine()
        let working = FakeEngine()
        let service = AudioService(
            logLevel: "info",
            engine: hanging,
            makeEngine: { working },
            autoStopConfig: AutoStopConfig(enabled: false)
        )
        let hangSignal = DispatchSemaphore(value: 0)
        hanging.hangStart = hangSignal
        service.start { _ in }
        XCTAssertTrue(eventually { hanging.startCount == 1 }, "start must reach the hung engine")
        service.replaceEngineAfterWedge()

        var readyCount = 0
        service.onCaptureReady = { readyCount += 1 }
        guard case .success = runStart(service) else {
            XCTFail("fresh start must succeed")
            hangSignal.signal()
            return
        }
        // Stale tap still installed on the discarded engine: dropped silently.
        hanging.node.emit(makeBuffer(engine: hanging))
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(readyCount, 0, "stale buffer must not signal the new session")
        XCTAssertFalse(service.isCaptureReady)

        working.node.emit(makeBuffer(engine: working))
        XCTAssertTrue(eventually { readyCount == 1 }, "fresh buffer signals the fresh session")
        _ = service.stop()
        hangSignal.signal()
    }

    // MARK: - Pre-warm and converter reuse

    /// Pre-warm must not capture: no tap installed, not recording, no
    /// readiness — yet the following start succeeds.
    @objc func testPrewarmHoldsNoCapture() {
        let engine = FakeEngine()
        let service = makeService(engine: engine)
        service.prewarm()
        XCTAssertTrue(
            eventually { engine.startCount == 0 },
            "prewarm must never start the engine"
        )
        XCTAssertEqual(engine.node.tapCount, 0, "prewarm must never install a tap")
        XCTAssertFalse(service.isRecording, "prewarm must never record")
        XCTAssertFalse(service.isCaptureReady, "prewarm must never signal readiness")
        guard case .success = runStart(service) else {
            XCTFail("start after prewarm must succeed")
            return
        }
        _ = service.stop()
    }

    /// Stable device: the second session reuses the cached converter and
    /// still converts correctly. Changed hardware format: the cache is
    /// rebuilt, never reused across a device change.
    @objc func testConverterReusedOnStableDeviceRebuiltOnFormatChange() {
        let engine = FakeEngine()
        let service = makeService(engine: engine)

        guard case .success = runStart(service) else {
            XCTFail("first start must succeed")
            return
        }
        engine.node.emit(makeBuffer(engine: engine))
        _ = service.stop()
        drainEngineQueue()
        XCTAssertFalse(service.lastStartReusedConverter, "first session builds the converter")

        guard case .success = runStart(service) else {
            XCTFail("second start must succeed")
            return
        }
        XCTAssertTrue(service.lastStartReusedConverter, "stable device must reuse the converter")
        engine.node.emit(makeBuffer(engine: engine))
        let reused = service.stop()
        XCTAssertGreaterThanOrEqual(reused.count, 1410, "reused converter must still convert")
        XCTAssertLessThanOrEqual(reused.count, 1560, "reused converter must not duplicate")
        drainEngineQueue()

        // Device change: new hardware sample rate invalidates the cache.
        engine.node.format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        guard case .success = runStart(service) else {
            XCTFail("start after device change must succeed")
            return
        }
        XCTAssertFalse(service.lastStartReusedConverter, "device change must rebuild the converter")
        engine.node.emit(makeBuffer(engine: engine))
        let rebuilt = service.stop()
        XCTAssertGreaterThanOrEqual(rebuilt.count, 1300, "rebuilt converter must convert the new format")
    }
}
