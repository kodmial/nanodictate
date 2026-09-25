import Foundation
import AVFoundation
import AudioEngineGuard
@testable import NanoDictateCore

// MARK: - Общие фейки AudioService (инъекция движка в тестах)

/// Mutable format (engine's is constant): nil-converter and format-fix restart
/// branches update it on the fly.
final class FakeInputNode: AudioInputNodeLike {
    var format: AVAudioFormat
    var tapBlock: AVAudioNodeTapBlock?
    /// Fired synchronously inside installTap (before tapCount grows) — lets a
    /// test interleave `replaceEngineAfterWedge()` at the exact tap/recording
    /// stage of a bring-up (the generation-race window). nil = no hook.
    var onInstallTap: (() -> Void)?
    private(set) var tapCount = 0
    private(set) var removeTapCount = 0

    init(format: AVAudioFormat? = nil, sampleRate: Double = 44100) {
        if let format = format {
            self.format = format
        } else {
            // Match lifecycle tests' 44.1 kHz/mono default.
            self.format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        }
    }

    func outputFormat(forBus bus: AVAudioNodeBus) -> AVAudioFormat {
        format
    }

    func installTap(
        onBus bus: AVAudioNodeBus,
        bufferSize: AVAudioFrameCount,
        format: AVAudioFormat?,
        block tapBlock: @escaping AVAudioNodeTapBlock
    ) {
        onInstallTap?()
        tapCount += 1
        self.tapBlock = tapBlock
    }

    func removeTap(onBus bus: AVAudioNodeBus) {
        removeTapCount += 1
    }

    func emit(_ buffer: AVAudioPCMBuffer) {
        tapBlock?(buffer, AVAudioTime())
    }
}

/// Test engine with failure-injection switches:
///   • `failStart` — start() throws, checked AFTER hangStart.wait() (hang→throw);
///   • `hangStart` — start() blocks on a semaphore (models HAL-wedge: never returns);
///   • `failSetup` — makeInputNode() raises NSException under ObjC gateway;
///   • `overrideNode` — replaces input node (AVAudioFormat() → nil converter).
final class FakeEngine: AudioEngineLike {
    let node = FakeInputNode()
    var failStart = false
    var hangStart: DispatchSemaphore?
    var failSetup = false
    var overrideNode: AudioInputNodeLike?
    private(set) var prepareCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func makeInputNode() -> AudioInputNodeLike {
        if failSetup {
            // NSException under gateway; see testEngineExceptionGuardConvertsExceptionToError.
            NanoDictateRaiseAudioEngineTestException()
        }
        return overrideNode ?? node
    }

    func prepare() {
        prepareCount += 1
    }

    func start() throws {
        startCount += 1
        if let hangStart = hangStart {
            // Blocks before failStart check: startCount already grew — test
            // distinguishes "hung" from "never started".
            hangStart.wait()
        }
        if failStart {
            // Checked after wait(): hang→throw covers stale-guard start-failure
            // branch; any error = AudioService "engine not up" path.
            throw AudioServiceError.unsupportedFormat
        }
    }

    func stop() {
        stopCount += 1
    }
}

// MARK: - Общие helpers тестов

/// Shared async-start helpers: avoid per-suite duplication (no common base class).

typealias AudioStartResult = Result<Void, Error>

extension XCTestCase {

    /// Spin RunLoop until async start completes (as prod main thread does).
    func runStart(_ service: AudioService, file: StaticString = #file, line: UInt = #line) -> AudioStartResult {
        let done = expectation(description: "audio start completion")
        var result: AudioStartResult = .failure(AudioServiceError.engineGone)
        service.start { startResult in
            result = startResult
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return done.isFulfilled ? result : .failure(AudioServiceError.engineGone)
    }

    /// Give engineQueue RunLoop passes for async teardown.
    func drainEngineQueue() {
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Poll condition spinning RunLoop (background-queue / engine teardown events).
    @discardableResult
    func eventually(
        timeout: TimeInterval = 2.0,
        file: StaticString = #file,
        line: UInt = #line,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}