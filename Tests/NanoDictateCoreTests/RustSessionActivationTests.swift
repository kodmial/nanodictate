import Foundation
import AVFoundation
import NanoDictateRustBridge
@testable import NanoDictateCore

/// Production-path proof that the shipped macOS dictation composition
/// executes the shared Rust session engine — not only the parity vectors
/// (which call the bridge directly), but the `AudioService` lifecycle the
/// application actually ships: one `RustSession` per dictation session,
/// driven with the native macOS events, with the recording-ready gate
/// consuming the Rust decision.
///
/// Fake engine, no hardware (same pattern as AudioServiceCaptureReadyTests).
final class RustSessionActivationTests: XCTestCase {

    private struct InjectedEngineError: Error {}

    // MARK: - Startup seam

    /// The composition-boundary check the application runs at startup must
    /// succeed against the linked engine.
    @objc func testStartupCheckAvailable() {
        do {
            try RustEngine.checkAvailable()
        } catch {
            XCTFail("RustEngine.checkAvailable() must succeed on the shipping link: \(error)")
        }
    }

    /// The seam factory used by the shipping path creates a live session
    /// with a nonzero generation.
    @objc func testSeamFactoryCreatesLiveSession() {
        do {
            let made = try RustEngine.makeSession()
            XCTAssertTrue(made.generation > 0, "engine generation must be nonzero")
            XCTAssertFalse(made.session.isCaptureReady, "fresh session is not ready")
        } catch {
            XCTFail("RustEngine.makeSession() must succeed on the shipping link: \(error)")
        }
    }

    // MARK: - Shipping start drives Rust

    /// A normal production start (default factory, as shipped) creates a
    /// Rust session in Recording before any buffer flows — and reports no
    /// readiness until the first buffer, preserving the #48 invariant.
    @objc func testProductionStartCreatesRustSessionBeforeFirstBuffer() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)

        guard case .success = runStart(service) else {
            XCTFail("start must succeed on the fake engine")
            return
        }
        XCTAssertTrue(service.isRustSessionActive, "shipping start must drive a live RustSession")
        XCTAssertNotNil(service.activeRustGeneration, "shipping start must tag a Rust generation")
        XCTAssertEqual(service.rustSessionStartCount, 1, "one RustSession per dictation lifecycle")
        XCTAssertEqual(
            service.rustSessionStateForDiagnostics, 1,
            "Rust session must be Recording after engine start"
        )
        XCTAssertFalse(service.isCaptureReady, "no readiness before the first buffer (#48)")
        _ = service.stop()
    }

    /// The first valid buffer completes the gate through the Rust decision:
    /// readiness observes, the cue fires exactly once, and the Rust session
    /// stays Recording (Transcribing only after stop).
    @objc func testFirstBufferCompletesGateThroughRustDecision() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)
        var readyCount = 0
        service.onCaptureReady = { _ in readyCount += 1 }

        guard case .success = runStart(service) else {
            XCTFail("start must succeed")
            return
        }
        engine.node.emit(makeToneBuffer(engine: engine))
        XCTAssertTrue(eventually { readyCount == 1 }, "first buffer must fire the ready cue once")
        XCTAssertTrue(service.isCaptureReady, "readiness must observe the Rust decision")
        XCTAssertEqual(service.rustSessionStateForDiagnostics, 1, "still Recording before stop")

        engine.node.emit(makeToneBuffer(engine: engine))
        drainEngineQueue()
        XCTAssertEqual(readyCount, 1, "second buffer must not re-fire the one-shot cue")
        _ = service.stop()
    }

    // MARK: - No silent fallback

    /// A Rust bootstrap failure fails the start loudly: no success, no
    /// ready cue, no Swift-only session carrying on silently.
    @objc func testRustBootstrapFailureFailsStartLoudly() {
        let engine = FakeEngine()
        let service = AudioService(
            logLevel: "info",
            engine: engine,
            rustSessionFactory: { throw InjectedEngineError() }
        )
        var readyCount = 0
        service.onCaptureReady = { _ in readyCount += 1 }

        let result = runStart(service)
        guard case .failure = result else {
            XCTFail("start without a Rust session must fail, not fall back silently")
            return
        }
        XCTAssertFalse(service.isRustSessionActive, "no Rust session must be live after failure")
        XCTAssertFalse(service.isCaptureReady, "failed session is never ready")
        engine.node.emit(makeToneBuffer(engine: engine))
        drainEngineQueue()
        XCTAssertEqual(readyCount, 0, "failed session must never cue readiness")
    }

    // MARK: - Terminal events

    /// Cancel before the first buffer ends the Rust lifecycle: no cue ever,
    /// and the handle is gone.
    @objc func testCancelBeforeBufferEndsRustLifecycle() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)
        var readyCount = 0
        service.onCaptureReady = { _ in readyCount += 1 }

        guard case .success = runStart(service) else {
            XCTFail("start must succeed")
            return
        }
        XCTAssertTrue(service.isRustSessionActive, "session must be live before cancel")
        service.cancel()
        XCTAssertFalse(service.isRustSessionActive, "cancel must end the Rust lifecycle")
        XCTAssertFalse(service.isCaptureReady, "cancelled session is never ready")
        engine.node.emit(makeToneBuffer(engine: engine))
        drainEngineQueue()
        XCTAssertEqual(readyCount, 0, "cancelled session must never cue readiness")
    }

    /// Engine-start failure drives the Rust failure path: the session ends,
    /// nothing cues, and a retry gets a fresh Rust session that reaches
    /// readiness.
    @objc func testEngineFailureEndsRustSessionAndRetryRecovers() {
        let engine = FakeEngine()
        engine.failStart = true
        let service = AudioService(logLevel: "info", engine: engine)
        var readyCount = 0
        service.onCaptureReady = { _ in readyCount += 1 }

        guard case .failure = runStart(service) else {
            XCTFail("start must fail with failStart injected")
            return
        }
        XCTAssertFalse(service.isRustSessionActive, "failed start must end the Rust session")
        engine.node.emit(makeToneBuffer(engine: engine))
        drainEngineQueue()
        XCTAssertEqual(readyCount, 0, "failed session must never cue readiness")

        engine.failStart = false
        guard case .success = runStart(service) else {
            XCTFail("retry after failure must succeed")
            return
        }
        XCTAssertTrue(service.isRustSessionActive, "retry must drive a fresh Rust session")
        XCTAssertEqual(service.rustSessionStartCount, 2, "one RustSession per lifecycle attempt")
        engine.node.emit(makeToneBuffer(engine: engine))
        XCTAssertTrue(eventually { readyCount == 1 }, "retry session reaches readiness via Rust")
        _ = service.stop()
    }

    /// Stop moves the Rust session to Transcribing and the transcription-done
    /// hook completes it to Idle; a stale generation never touches the live
    /// session.
    @objc func testStopAndTranscriptionDoneCompleteRustLifecycle() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)

        guard case .success = runStart(service) else {
            XCTFail("start must succeed")
            return
        }
        engine.node.emit(makeToneBuffer(engine: engine))
        XCTAssertTrue(
            eventually { service.isCaptureReady },
            "session must reach readiness before stop")
        let firstGeneration = service.activeRustGeneration
        XCTAssertNotNil(firstGeneration, "transcribed session must carry a Rust generation")

        let samples = service.stop()
        XCTAssertFalse(samples.isEmpty, "first buffer must be retained in stop output")
        XCTAssertFalse(service.isCaptureReady, "readiness lapses at stop")
        XCTAssertEqual(
            service.rustSessionStateForDiagnostics, 2, "Rust session Transcribing after stop")

        // Stale generation from a previous lifecycle is ignored.
        service.notifyTranscriptionDone(rustGeneration: (firstGeneration ?? 1) &+ 10_000)
        XCTAssertEqual(
            service.rustSessionStateForDiagnostics, 2,
            "stale transcriptionDone must not touch the live session")

        service.notifyTranscriptionDone(rustGeneration: firstGeneration)
        XCTAssertFalse(service.isRustSessionActive, "transcriptionDone must end the Rust lifecycle")
    }

    /// Repeated shipping cycles each get their own Rust session and each
    /// reaches readiness independently.
    @objc func testRepeatedCyclesEachDriveRustSession() {
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
        let firstGeneration = service.activeRustGeneration
        let firstSamples = service.stop()
        XCTAssertFalse(firstSamples.isEmpty, "first session keeps its buffer")
        service.notifyTranscriptionDone(rustGeneration: firstGeneration)
        drainEngineQueue()

        guard case .success = runStart(service) else {
            XCTFail("second start must succeed")
            return
        }
        XCTAssertEqual(service.rustSessionStartCount, 2, "second cycle creates its own RustSession")
        XCTAssertFalse(service.isCaptureReady, "new session starts not-ready")
        engine.node.emit(makeToneBuffer(engine: engine))
        XCTAssertTrue(eventually { readyCount == 2 }, "second session reaches readiness via Rust")
        _ = service.stop()
    }

    /// Cancel during engine bring-up (before the recording flag is set)
    /// still ends the Rust lifecycle: no session is abandoned mid-lifecycle,
    /// and the aborted session can never cue readiness afterwards.
    @objc func testBringUpCancelBeforeRecordingEndsRustSession() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)
        var readyCount = 0
        service.onCaptureReady = { _ in readyCount += 1 }

        // Hold the bring-up inside makeInputNode: session reset (including
        // Rust creation) has completed, but the recording flag is not set.
        engine.makeInputGate = DispatchSemaphore(value: 0)
        let enteredSetup = expectation(description: "bring-up reaches input setup")
        engine.onMakeInputNode = { enteredSetup.fulfill() }
        let done = expectation(description: "audio start completion")
        var startResult: AudioStartResult = .failure(AudioServiceError.engineGone)
        service.start { result in
            startResult = result
            done.fulfill()
        }
        wait(for: [enteredSetup], timeout: 5)
        XCTAssertTrue(service.isRustSessionActive, "reset must have created the Rust session")

        service.cancel()
        XCTAssertFalse(service.isRustSessionActive, "bring-up cancel must end the Rust session")
        XCTAssertFalse(service.isCaptureReady, "cancelled bring-up is never ready")

        engine.makeInputGate?.signal()
        wait(for: [done], timeout: 5)
        guard case .success = startResult else {
            XCTFail("bring-up itself still completes (Swift behavior preserved)")
            return
        }
        engine.node.emit(makeToneBuffer(engine: engine))
        drainEngineQueue()
        XCTAssertEqual(readyCount, 0, "cancelled bring-up must never cue readiness")
        _ = service.stop()
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
