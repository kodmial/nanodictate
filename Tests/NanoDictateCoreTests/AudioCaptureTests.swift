import Foundation
import AVFoundation
@testable import NanoDictateCore

/// AVAudioConverter drive: one input buffer → one output chunk of ~target/input,
/// no duplication — guards the stretched-recording regression at 44.1/48 kHz → 16 kHz.
final class AudioCaptureTests: XCTestCase {

    // MARK: - Ресемплинг одного буфера

    @objc func testSingleBufferResampleNoDuplication() {
        let inputFmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: false
        )!
        let outFmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false
        )!
        let converter = AVAudioConverter(from: inputFmt, to: outFmt)!

        // 4410 frames @44.1 kHz = 100 ms of speech.
        let input = AVAudioPCMBuffer(pcmFormat: inputFmt, frameCapacity: 4410)!
        input.frameLength = 4410
        // Constant 16-bit amplitude — no zero-energy risk.
        let samples = input.int16ChannelData![0]
        for i in 0..<4410 {
            samples[i] = Int16(6000)
        }

        let result = AudioService.convertOnce(
            input: input, inputFormat: inputFmt, converter: converter, targetFormat: outFmt
        )
        XCTAssertNotNil(result, "4410 фр. 44.1кГц → 16 кГц должен дать непустой выход")
        guard let result = result else { return }

        let out = result.converted
        XCTAssertTrue(out.frameLength > 0, "выход не должен быть пустым")

        // Expected: 4410 × 16000 / 44100 = 1600 frames, no duplicates.
        let expected = 1600
        let tolerance = Int(Double(expected) * 0.02) // ±2% tolerance
        XCTAssertGreaterThanOrEqual(
            Int(out.frameLength), expected - tolerance,
            "frameLength \(out.frameLength) < \(expected - tolerance) — выход потерян"
        )
        XCTAssertLessThanOrEqual(
            Int(out.frameLength), expected + tolerance,
            "frameLength \(out.frameLength) > \(expected + tolerance) — аудио продублировано"
        )
        // Old bug: frameCapacity = input (4410) → duplicated output.
        XCTAssertFalse(Int(out.frameLength) == 4410, "выход не должен совпадать с входной длиной")

        // Must be a data status, not .error.
        XCTAssertTrue(
            result.status == .haveData
                || result.status == .inputRanDry
                || result.status == .endOfStream,
            "статус \(result.status.rawValue) не должен быть ошибкой"
        )
    }

    // MARK: - Переиспользование конвертера между буферами

    @objc func testConverterReuseMultipleBuffersNoLoss() {
        let inputFmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 1, interleaved: false
        )!
        let outFmt = AVAudioFormat(
            commonFormat: .pcmFormatInt16, sampleRate: 16000, channels: 1, interleaved: false
        )!
        // One converter for all chunks — as in the live process tap.
        let converter = AVAudioConverter(from: inputFmt, to: outFmt)!

        // Three 100 ms buffers, each ~1600 frames; catches old-bug dupes
        // and chunk loss on the endOfStream latch.
        let amplitudes: [Int16] = [2000, 6000, 10000]
        var chunkLengths: [Int] = []
        var chunkMeans: [Float] = []

        for amp in amplitudes {
            let input = AVAudioPCMBuffer(pcmFormat: inputFmt, frameCapacity: 4410)!
            input.frameLength = 4410
            let samples = input.int16ChannelData![0]
            for i in 0..<4410 {
                samples[i] = amp
            }

            let result = AudioService.convertOnce(
                input: input, inputFormat: inputFmt, converter: converter, targetFormat: outFmt
            )
            XCTAssertNotNil(result, "чанк с амплитудой \(amp) должен дать непустой выход")
            guard let result = result else { return }

            let out = result.converted
            XCTAssertTrue(
                out.frameLength > 0,
                "чанк \(amp): конвертер не должен терять данные после первого буфера"
            )
            let n = Int(out.frameLength)
            chunkLengths.append(n)

            // Chunk energy = mean amplitude of output samples.
            let ch = out.int16ChannelData![0]
            var sum: Float = 0
            for i in 0..<n {
                sum += Float(abs(ch[i]))
            }
            chunkMeans.append(n > 0 ? sum / Float(n) : 0)
        }

        // Each chunk ~1600 frames ±2%; the old bug would give 4410.
        for n in chunkLengths {
            XCTAssertGreaterThanOrEqual(n, 1568, "чанк \(n) < 1568 — данные потеряны")
            XCTAssertLessThanOrEqual(n, 1632, "чанк \(n) > 1632 — дублирование")
        }

        // Total of three chunks ≈ 4800 ±2%.
        let total = chunkLengths.reduce(0, +)
        XCTAssertGreaterThanOrEqual(total, 4704, "total \(total) < 4704 — часть данных после первого буфера потеряна")
        XCTAssertLessThanOrEqual(total, 4896, "total \(total) > 4896 — данные продублированы")

        // Distinct chunk amplitudes — equal means duplication.
        XCTAssertTrue(
            chunkMeans[0] < chunkMeans[1] && chunkMeans[1] < chunkMeans[2],
            "средние амплитуды должны расти вслед за входными: \(chunkMeans)"
        )
    }
}