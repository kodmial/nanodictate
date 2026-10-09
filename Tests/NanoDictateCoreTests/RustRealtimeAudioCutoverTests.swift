import Foundation
import AVFoundation
import NanoDictateRustBridge
@testable import NanoDictateCore

// MARK: - Production-path proof for the realtime Rust audio cutover (#133)
//
// Unlike RustParityTests (which calls the bridge directly), every test here
// drives the SHIPPING composition — the same AudioService lifecycle, the
// same ChunkedPipeline entry points, and the same segmenter call sites the
// application uses — and asserts the outcome produced through the shared
// engine. The Swift reference implementations stay intact as parity
// oracles: several tests require the production result to equal the
// reference output, so a silent drift in either implementation fails
// loudly. Fake engine, no hardware (same pattern as
// RustSessionActivationTests).

final class RustRealtimeAudioCutoverTests: XCTestCase {

    private struct InjectedAudioError: Error {}

    // MARK: - Shipping start builds the engine audio composition

    /// A normal production start (default factories, as shipped) builds
    /// the realtime audio composition before any buffer flows.
    @objc func testProductionStartBuildsRustAudioComposition() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)

        guard case .success = runStart(service) else {
            XCTFail("start must succeed on the fake engine")
            return
        }
        XCTAssertTrue(
            service.isRustAudioActive,
            "shipping start must build the Rust realtime audio composition")
        XCTAssertEqual(service.rustAudioBlockCount, 0, "no blocks before the first buffer")
        XCTAssertEqual(service.realtimeAudioStats.blocks, 0)
        XCTAssertEqual(service.realtimeAudioStats.engineErrors, 0)
        _ = service.stop()
        XCTAssertFalse(service.isRustAudioActive, "stop ends the audio composition")
    }

    /// Buffers flow through the engine composition: every emitted buffer
    /// increments the engine block count with no engine errors, and the
    /// collected samples prove the conditioned signal was recorded.
    @objc func testBuffersExecuteRustAudioPath() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)

        guard case .success = runStart(service) else {
            XCTFail("start must succeed")
            return
        }
        for _ in 0..<5 {
            engine.node.emit(makeToneBuffer(engine: engine, amplitude: 0.2))
        }
        XCTAssertEqual(service.rustAudioBlockCount, 5, "every buffer must ingest via the engine")
        let stats = service.realtimeAudioStats
        XCTAssertEqual(stats.blocks, 5)
        XCTAssertEqual(stats.engineErrors, 0, "valid blocks never fail closed")
        XCTAssertGreaterThan(stats.totalNanos, 0, "instrumentation must observe block cost")
        XCTAssertGreaterThanOrEqual(stats.maxNanos, 1)
        XCTAssertGreaterThanOrEqual(
            stats.maxBlockMs, stats.meanBlockMs, "max covers the mean by construction")
        let samples = service.stop()
        XCTAssertFalse(samples.isEmpty, "conditioned signal must be recorded")
        XCTAssertEqual(service.rustAudioBlockCount, 5, "block proof is cumulative across stop")
    }

    // MARK: - No silent fallback

    /// A realtime-audio bootstrap failure fails the start loudly: no
    /// success, no blocks, no ready cue, no Swift-only audio carrying on
    /// silently.
    @objc func testRustAudioBootstrapFailureFailsStartLoudly() {
        let engine = FakeEngine()
        let service = AudioService(
            logLevel: "info",
            engine: engine,
            rustAudioFactory: { throw InjectedAudioError() }
        )
        var readyCount = 0
        service.onCaptureReady = { _ in readyCount += 1 }

        let result = runStart(service)
        guard case .failure = result else {
            XCTFail("start without a Rust audio composition must fail, not fall back silently")
            return
        }
        XCTAssertFalse(service.isRustAudioActive, "no audio composition must be live after failure")
        XCTAssertEqual(service.rustAudioBlockCount, 0, "no block may run without the engine")
        engine.node.emit(makeToneBuffer(engine: engine, amplitude: 0.2))
        drainEngineQueue()
        XCTAssertEqual(readyCount, 0, "failed session must never cue readiness")
        XCTAssertEqual(service.rustAudioBlockCount, 0)
    }

    // MARK: - Shipping behavior preserved through the engine

    /// Speech followed by sustained silence fires auto-stop through the
    /// engine composition (same scenario as the Swift-path VAD tests),
    /// with the engine block proof attached.
    @objc func testAutoStopFiresThroughEngine() {
        let engine = FakeEngine()
        var segmenterConfig = AudioSegmenterConfig.defaults
        segmenterConfig.pauseDuration = 0.2
        let service = AudioService(
            logLevel: "info", engine: engine, segmenterConfig: segmenterConfig)
        let autoStopDone = expectation(description: "auto-stop by silence")
        var autoStopSamples: [Int16] = []
        service.onAutoStop = { samples in
            autoStopSamples = samples
            autoStopDone.fulfill()
        }

        guard case .success = runStart(service) else {
            XCTFail("start must succeed")
            return
        }
        emit(engine: engine, amplitude: 0.2, count: 6)
        emit(engine: engine, amplitude: 0.001, count: 60)
        wait(for: [autoStopDone], timeout: 5)

        XCTAssertTrue(
            autoStopSamples.count > 2000, "engine auto-stop must deliver the collected samples")
        XCTAssertGreaterThan(
            service.rustAudioBlockCount, 0, "auto-stop decision ran on engine-ingested blocks")
        XCTAssertEqual(service.realtimeAudioStats.engineErrors, 0)
    }

    /// Disabled auto-stop never fires on the shipping path either: the
    /// host kill switch is honored inside the engine composition.
    @objc func testDisabledAutoStopHonoredThroughEngine() {
        let engine = FakeEngine()
        var segmenterConfig = AudioSegmenterConfig.defaults
        segmenterConfig.pauseDuration = 0.2
        var autoStopConfig = AutoStopConfig.defaults
        autoStopConfig.enabled = false
        let service = AudioService(
            logLevel: "info", engine: engine, segmenterConfig: segmenterConfig,
            autoStopConfig: autoStopConfig)
        var autoStopFired = false
        service.onAutoStop = { _ in autoStopFired = true }

        guard case .success = runStart(service) else {
            XCTFail("start must succeed")
            return
        }
        emit(engine: engine, amplitude: 0.2, count: 2)
        emit(engine: engine, amplitude: 0.001, count: 45)
        let samples = service.stop()

        XCTAssertFalse(autoStopFired, "disabled auto-stop must not fire through the engine")
        XCTAssertTrue(samples.count >= 47 * 1480, "stop returns the whole record: \(samples.count)")
        XCTAssertGreaterThan(service.rustAudioBlockCount, 0)
    }

    /// Live utterance segmentation still delivers copy-segments on the
    /// engine-driven path: a sustained pause closes exactly one segment
    /// and stop() returns the whole record with the segment as its prefix.
    @objc func testLiveSegmentationDeliversCopyThroughEngine() {
        let engine = FakeEngine()
        var segmenterConfig = AudioSegmenterConfig.defaults
        segmenterConfig.pauseDuration = 0.2
        let service = AudioService(
            logLevel: "info", engine: engine, segmenterConfig: segmenterConfig)
        var deliveries: [(samples: [Int16], isTail: Bool)] = []
        service.onSpeechSegment = { samples, isTail in
            deliveries.append((samples, isTail))
        }

        guard case .success = runStart(service) else {
            XCTFail("start must succeed")
            return
        }
        emit(engine: engine, amplitude: 0.2, count: 2)
        emit(engine: engine, amplitude: 0.001, count: 6)

        XCTAssertEqual(deliveries.count, 1, "one pause closes one segment via engine VAD")
        XCTAssertFalse(deliveries[0].isTail)
        let segment = deliveries[0].samples
        XCTAssertTrue(segment.count > 7800, "segment carries speech plus post-roll")
        XCTAssertTrue(segment.count < 9100, "segment excludes the pause body")
        let samples = service.stop()
        XCTAssertEqual(
            Array(samples.prefix(segment.count)), segment,
            "record buffer untouched by segment delivery")
    }

    // MARK: - Composition parity against the Swift reference

    /// The shipping composition agrees with the Swift reference
    /// sample-for-sample on VAD flags and within tolerance on amplified
    /// RMS: quiet room tone, a speech attack, then quiet again.
    @objc func testCompositionParityWithSwiftReference() {
        let engineAudio: RustRealtimeAudio
        do {
            engineAudio = try RustRealtimeAudio(
                gainConfig: .defaults, vadConfig: .defaults,
                autoStopConfig: .defaults)
        } catch {
            XCTFail("composition must build: \(error)")
            return
        }
        var swiftVAD = AdaptiveVAD()
        let swiftGain = InputGain()
        // Constant-amplitude blocks have exact RMS (= amplitude), so both
        // sides observe identical inputs without converter drift.
        let amplitudes: [Float] =
            [Float](repeating: 0.0005, count: 30) + [0.02]
            + [Float](repeating: 0.0002, count: 10)
        for amplitude in amplitudes {
            var block = [Float](repeating: amplitude, count: 1360)
            let outcome: RustRealtimeAudio.IngestOutcome
            do {
                outcome = try block.withUnsafeMutableBufferPointer { pointer in
                    try engineAudio.ingest(
                        channel: pointer.baseAddress, frameLength: pointer.count,
                        sampleRate: 16000)
                }
            } catch {
                XCTFail("ingest must not fail on valid blocks: \(error)")
                return
            }
            let duration = Double(1360) / 16000.0
            let swiftSpeech = swiftVAD.update(rms: amplitude, duration: duration)
            XCTAssertEqual(
                outcome.isSpeech, swiftSpeech,
                "VAD agreement at raw RMS \(amplitude)")
            XCTAssertEqual(outcome.rawRMS, amplitude, accuracy: 0.0005)
            var swiftBlock = [Float](repeating: amplitude, count: 1360)
            let swiftRMS = swiftGain.apply(
                to: &swiftBlock, rms: amplitude, sampleRate: 16000)
            XCTAssertEqual(
                outcome.amplifiedRMS, swiftRMS, accuracy: 0.002,
                "amplified RMS parity at \(amplitude)")
            XCTAssertEqual(block, swiftBlock, "conditioned samples match the reference")
        }
    }

    /// Disabled AGC passes the block through untouched on the shipping
    /// composition (metered RMS equals raw RMS).
    @objc func testDisabledGainPassesThroughEngine() {
        let disabled = InputGainConfig(enabled: false)
        let engineAudio: RustRealtimeAudio
        do {
            engineAudio = try RustRealtimeAudio(
                gainConfig: disabled, vadConfig: .defaults,
                autoStopConfig: .defaults)
        } catch {
            XCTFail("composition must build: \(error)")
            return
        }
        var block = [Float](repeating: 0.004, count: 1024)
        do {
            let outcome = try block.withUnsafeMutableBufferPointer { pointer in
                try engineAudio.ingest(
                    channel: pointer.baseAddress, frameLength: pointer.count,
                    sampleRate: 16000)
            }
            XCTAssertEqual(outcome.rawRMS, 0.004, accuracy: 0.0005)
            XCTAssertEqual(outcome.amplifiedRMS, outcome.rawRMS, accuracy: 0.0001)
            XCTAssertTrue(block.allSatisfy { $0 == 0.004 }, "buffer untouched when disabled")
        } catch {
            XCTFail("ingest must not fail: \(error)")
        }
    }

    /// The engine auto-stop composition agrees with the Swift detector on
    /// the full cycle: speech opens the gate, sustained silence fires,
    /// reset returns to the unlatched state.
    @objc func testAutoStopCompositionParityWithSwiftReference() {
        let engineAudio: RustRealtimeAudio
        do {
            engineAudio = try RustRealtimeAudio(
                gainConfig: .defaults, vadConfig: .defaults,
                autoStopConfig: .defaults)
        } catch {
            XCTFail("composition must build: \(error)")
            return
        }
        var swift = SilenceAutoStopDetector()
        for _ in 0..<5 {
            let engineFired: Bool
            do {
                engineFired = try engineAudio.feedAutoStop(
                    rms: 0.02, duration: 0.1, isSpeech: true)
            } catch {
                XCTFail("auto-stop feed must not fail: \(error)")
                return
            }
            let swiftFired = swift.feed(rms: 0.02, duration: 0.1, isSpeech: true)
            XCTAssertEqual(engineFired, swiftFired, "speech feeds agree")
        }
        XCTAssertTrue(swift.speechGatePassed, "reference gate opens")
        var engineFired = false
        var swiftFired = false
        for _ in 0..<60 {
            do {
                engineFired = try engineAudio.feedAutoStop(
                    rms: 0.0005, duration: 0.1, isSpeech: false)
            } catch {
                XCTFail("auto-stop feed must not fail: \(error)")
                return
            }
            swiftFired = swift.feed(rms: 0.0005, duration: 0.1, isSpeech: false)
        }
        XCTAssertEqual(engineFired, swiftFired, "silence feeds agree")
        XCTAssertTrue(engineFired, "composition fires after sustained silence")
        do {
            try engineAudio.reset()
        } catch {
            XCTFail("reset must not fail: \(error)")
            return
        }
        do {
            let afterReset = try engineAudio.feedAutoStop(
                rms: 0.0005, duration: 0.1, isSpeech: false)
            XCTAssertFalse(afterReset, "reset clears the gate: silence alone never stops")
        } catch {
            XCTFail("feed after reset must not fail: \(error)")
        }
    }

    // MARK: - Segmentation through the engine

    /// The shipping chunked entry point plans through the engine with the
    /// same specs as the Swift reference on a pause-split vector.
    @objc func testChunkedPlanThroughEngineMatchesReference() {
        var samples = [Int16](repeating: 2000, count: 16000 * 4)
        samples += [Int16](repeating: 0, count: 16000 * 2)
        samples += [Int16](repeating: 2000, count: 16000 * 4)
        var config = AudioSegmenterConfig.defaults
        config.pauseDuration = 1.0
        config.minSegment = 1.0
        let pipeline = ChunkedPipeline(segmenterConfig: config)
        let shipped = pipeline.plan(samples: samples)
        let reference = AudioSegmenter.plan(samples: samples, sampleRate: 16000, config: config)
        XCTAssertEqual(shipped, reference, "shipping plan must equal the reference plan")
        XCTAssertEqual(shipped.count, 2, "pause splits the recording in two")
        XCTAssertEqual(
            AudioSegmenter.requestCount(for: shipped), 3, "two segments plus the final pass")
    }

    /// Fixed-length batch chunking ships through the engine with the same
    /// bodies and overlap windows as the reference math.
    @objc func testBatchSegmentsThroughEngine() {
        // Distinct body markers prove the overlap window content, not just
        // its length: chunk N > 0 must start with the tail of body N - 1.
        var samples = [Int16](repeating: 1000, count: 16000 * 5)
        samples += [Int16](repeating: 2000, count: 16000 * 5)
        samples += [Int16](repeating: 3000, count: 16000 * 2)
        let chunks = BatchSegmenter.segments(
            samples: samples, sampleRate: 16000, maxSegment: 5, overlap: 2.5)
        XCTAssertEqual(chunks.count, 3, "12 s at 5 s bodies needs three chunks")
        // BatchChunk exposes body boundaries in seconds (BatchBodySpec
        // carries the sample-window bodyRange/overlapRange); the seconds
        // below encode exactly 0..<80000, 80000..<160000, 160000..<192000.
        XCTAssertEqual(chunks[0].bodyStart, 0, accuracy: 0.001)
        XCTAssertEqual(chunks[0].bodyEnd, 5, accuracy: 0.001)
        XCTAssertEqual(chunks[1].bodyStart, 5, accuracy: 0.001)
        XCTAssertEqual(chunks[1].bodyEnd, 10, accuracy: 0.001)
        XCTAssertEqual(chunks[2].bodyStart, 10, accuracy: 0.001)
        XCTAssertEqual(chunks[2].bodyEnd, 12, accuracy: 0.001)
        // First chunk carries no overlap; later chunks carry a full 2.5 s
        // overlap head plus their body.
        XCTAssertEqual(chunks[0].samples.count, 16000 * 5)
        XCTAssertEqual(chunks[1].samples.count, Int(16000 * 2.5) + 16000 * 5)
        XCTAssertEqual(chunks[2].samples.count, Int(16000 * 2.5) + 16000 * 2)
        XCTAssertEqual(chunks[0].samples, Array(samples[0..<(16000 * 5)]))
        XCTAssertEqual(
            Array(chunks[1].samples.prefix(Int(16000 * 2.5))),
            Array(samples[(16000 * 5 - Int(16000 * 2.5))..<(16000 * 5)]),
            "chunk 1 overlap is the tail of body 0")
        XCTAssertEqual(
            Array(chunks[2].samples.prefix(Int(16000 * 2.5))),
            Array(samples[(16000 * 10 - Int(16000 * 2.5))..<(16000 * 10)]),
            "chunk 2 overlap is the tail of body 1")
        // Bodies stay contiguous with no gaps or overlaps; every sample is
        // a body sample exactly once.
        for index in 1..<chunks.count {
            XCTAssertEqual(chunks[index - 1].bodyEnd, chunks[index].bodyStart)
        }
        // The portable boundary decisions come from the shared engine ABI:
        // the same fixed plan through RustEngine matches the shipped bodies.
        do {
            let specs = try RustEngine.batchBodySpecs(
                sampleCount: samples.count, sampleRate: 16000,
                maxSegment: 5, overlap: 2.5)
            XCTAssertEqual(specs.count, 3)
            XCTAssertEqual(specs[0].bodyRange, 0..<(16000 * 5))
            XCTAssertEqual(specs[1].bodyRange, (16000 * 5)..<(16000 * 10))
            XCTAssertEqual(specs[2].bodyRange, (16000 * 10)..<(16000 * 12))
            XCTAssertNil(specs[0].overlapRange, "first chunk carries no overlap")
            XCTAssertEqual(specs[1].overlapRange?.count ?? -1, Int(16000 * 2.5))
            XCTAssertEqual(specs[2].overlapRange?.count ?? -1, Int(16000 * 2.5))
        } catch {
            XCTFail("engine batch plan must succeed: \(error)")
        }
        XCTAssertTrue(BatchSegmenter.segments(samples: [], sampleRate: 16000).isEmpty)
    }

    // MARK: - Callback-overhead benchmark (no material regression)

    /// Automated latency/callback evidence for the gate: a deterministic
    /// block stream through the shipping composition stays far inside the
    /// realtime budgets (max 25 ms, mean 5 ms per block).
    @objc func testRealtimeBlockBenchmarkWithinBudgets() {
        let engineAudio: RustRealtimeAudio
        do {
            engineAudio = try RustRealtimeAudio(
                gainConfig: .defaults, vadConfig: .defaults,
                autoStopConfig: .defaults)
        } catch {
            XCTFail("composition must build: \(error)")
            return
        }
        let blockCount = 200
        let blockSize = 1024
        var worstMs = 0.0
        var totalMs = 0.0
        // Speech-like / silence alternation exercises both VAD branches
        // and the AGC attack/release paths.
        for index in 0..<blockCount {
            let amplitude: Float = index % 2 == 0 ? 0.05 : 0.0008
            var block = [Float](repeating: amplitude, count: blockSize)
            let start = Date()
            do {
                try block.withUnsafeMutableBufferPointer { pointer in
                    _ = try engineAudio.ingest(
                        channel: pointer.baseAddress, frameLength: pointer.count,
                        sampleRate: 16000)
                }
            } catch {
                XCTFail("ingest must not fail: \(error)")
                return
            }
            let elapsedMs = Date().timeIntervalSince(start) * 1000.0
            totalMs += elapsedMs
            worstMs = max(worstMs, elapsedMs)
        }
        let meanMs = totalMs / Double(blockCount)
        let budgets = RustParityGate.Budgets.default
        XCTAssertLessThan(
            worstMs, budgets.maxBlockCallMs,
            "worst block \(worstMs) ms must stay inside the \(budgets.maxBlockCallMs) ms budget")
        XCTAssertLessThan(
            meanMs, budgets.maxMeanBlockCallMs,
            "mean block \(meanMs) ms must stay inside the \(budgets.maxMeanBlockCallMs) ms budget")
    }

    // MARK: - Helpers

    /// Constant buffer in the fake node format: RMS equals |amplitude|.
    private func makeToneBuffer(engine: FakeEngine, amplitude: Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.node.format, frameCapacity: 4096)!
        buffer.frameLength = 4096
        let channel = buffer.floatChannelData![0]
        for i in 0..<4096 {
            channel[i] = amplitude
        }
        return buffer
    }

    private func emit(engine: FakeEngine, amplitude: Float, count: Int) {
        for _ in 0..<count {
            engine.node.emit(makeToneBuffer(engine: engine, amplitude: amplitude))
        }
    }
}
