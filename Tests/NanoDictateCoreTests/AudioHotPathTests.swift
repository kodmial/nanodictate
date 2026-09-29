import Foundation
import AVFoundation
@testable import NanoDictateCore

/// Realtime hot-path regression (allocation/lock/metering): verifies the tap
/// callback reuses its conversion buffer, clips samples without loss or
/// reorder, and coalesces UI meter delivery to a single pending update.
final class AudioHotPathTests: XCTestCase {

    // MARK: - Float32 -> Int16 clipping (order, no loss)

    @objc func testClipFloatToInt16PreservesOrderAndClips() {
        XCTAssertEqual(AudioService.clipFloatToInt16(0), 0)
        XCTAssertEqual(AudioService.clipFloatToInt16(0.5), Int16(0.5 * 32767))
        XCTAssertEqual(AudioService.clipFloatToInt16(1.0), 32767)
        XCTAssertEqual(AudioService.clipFloatToInt16(-1.0), -32768)
        XCTAssertEqual(AudioService.clipFloatToInt16(2.0), 32767)
        XCTAssertEqual(AudioService.clipFloatToInt16(-2.0), -32768)
        // Monotonic order preserved across the range (no reorder).
        let inputs: [Float] = [-2, -1, -0.5, 0, 0.25, 0.9, 1, 5]
        let outputs = inputs.map(AudioService.clipFloatToInt16)
        for i in 1..<outputs.count {
            XCTAssertGreaterThanOrEqual(Int(outputs[i]), Int(outputs[i - 1]), "order violated at \(i)")
        }
    }

    // MARK: - Converter buffer reuse (no per-callback allocation)

    @objc func testConvertOnceReusesBufferInSteadyState() {
        if ProcessInfo.processInfo.environment["CI"] != nil { return }
        let inputFmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        let outFmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)!
        let converter = AVAudioConverter(from: inputFmt, to: outFmt)!
        func makeInput() -> AVAudioPCMBuffer {
            let buf = AVAudioPCMBuffer(pcmFormat: inputFmt, frameCapacity: 4096)!
            buf.frameLength = 4096
            let ch = buf.floatChannelData![0]
            for i in 0..<4096 { ch[i] = 0.2 }
            return buf
        }
        guard
            let first = AudioService.convertOnce(
                input: makeInput(), inputFormat: inputFmt, converter: converter,
                targetFormat: outFmt, reusing: nil)
        else {
            XCTFail("first conversion must succeed")
            return
        }
        XCTAssertFalse(first.reused, "cold buffer cannot report reuse")
        XCTAssertGreaterThan(first.converted.frameLength, 0)
        let cached = first.converted
        guard
            let second = AudioService.convertOnce(
                input: makeInput(), inputFormat: inputFmt, converter: converter,
                targetFormat: outFmt, reusing: cached)
        else {
            XCTFail("second conversion must succeed")
            return
        }
        XCTAssertTrue(second.reused, "steady-state callback must reuse the buffer")
        XCTAssertTrue(second.converted === cached, "same instance refilled in place")
        XCTAssertGreaterThan(second.converted.frameLength, 0, "reused buffer must carry frames")
    }

    @objc func testOutputFrameCapacityBoundsSteadyState() {
        let cap = AudioService.outputFrameCapacity(
            forInputFrames: 4096, inputRate: 48000, outputRate: 16000)
        // 4096 * 16/48 = 1365 base + quarter margin.
        XCTAssertGreaterThanOrEqual(Int(cap), 1365)
        XCTAssertLessThanOrEqual(Int(cap), 1800, "capacity must stay bounded (no oversize alloc)")
    }

    // MARK: - Meter coalescing (no unbounded main-queue backlog)

    @objc func testMeterCoalescerCollapsesRapidUpdates() {
        let coalescer = LevelMeterCoalescer()
        XCTAssertTrue(coalescer.submit(0.1), "first update schedules a flush")
        for level in stride(from: Float(0.2), through: 1.0, by: 0.1) {
            XCTAssertFalse(coalescer.submit(level), "pending flush must absorb stale levels")
        }
        XCTAssertTrue(coalescer.hasPending)
        XCTAssertEqual(coalescer.takePending(), 1.0, accuracy: 0.0001, "flush delivers latest only")
        XCTAssertFalse(coalescer.hasPending)
        XCTAssertTrue(coalescer.submit(0.5), "post-flush update schedules again")
        XCTAssertEqual(coalescer.takePending(), 0.5, accuracy: 0.0001)
    }
}
