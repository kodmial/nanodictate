import Foundation
@testable import DictationCore

// MARK: - Тесты WAVDecoder (разбор RIFF/PCM в Int16-сэмплы)

final class WAVDecoderTests: XCTestCase {

    // MARK: Ручной сборщик RIFF/WAV для нестандартных случаев

    private func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
    }

    private func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        data.append(UInt8(value & 0xFF))
        data.append(UInt8((value >> 8) & 0xFF))
        data.append(UInt8((value >> 16) & 0xFF))
        data.append(UInt8((value >> 24) & 0xFF))
    }

    /// Собирает WAV-файл: fmt (PCM/битность/каналы/rate) + data + необязательный
    /// незнакомый чанк перед data (например "LIST").
    private func makeWAV(
        sampleRate: Int = 16000,
        channels: Int = 1,
        bits: Int = 16,
        audioFormat: UInt16 = 1,
        samples: [Int16] = [0, 1, -1],
        unknownChunk: (id: String, payload: [UInt8])? = nil
    ) -> Data {
        var sampleBytes: [UInt8] = []
        for s in samples {
            let u = UInt16(bitPattern: s)
            if bits == 16 {
                sampleBytes.append(UInt8(u & 0xFF))
                sampleBytes.append(UInt8(u >> 8))
            }
        }

        var data = Data()
        data.append(contentsOf: Array("RIFF".utf8))
        let riffSize = 4 + (8 + 16) + (unknownChunk != nil ? 8 + unknownChunk!.payload.count : 0) + (8 + sampleBytes.count)
        appendUInt32LE(UInt32(riffSize), to: &data)
        data.append(contentsOf: Array("WAVE".utf8))

        // fmt
        data.append(contentsOf: Array("fmt ".utf8))
        appendUInt32LE(16, to: &data)
        appendUInt16LE(audioFormat, to: &data) // 1 = PCM
        appendUInt16LE(UInt16(channels), to: &data)
        appendUInt32LE(UInt32(sampleRate), to: &data)
        appendUInt32LE(UInt32(sampleRate * channels * bits / 8), to: &data)
        appendUInt16LE(UInt16(channels * bits / 8), to: &data)
        appendUInt16LE(UInt16(bits), to: &data)

        // Незнакомый чанк (LIST и т.п.) — должен пропускаться.
        if let unknown = unknownChunk {
            data.append(contentsOf: Array(unknown.id.utf8))
            appendUInt32LE(UInt32(unknown.payload.count), to: &data)
            data.append(contentsOf: unknown.payload)
        }

        // data
        data.append(contentsOf: Array("data".utf8))
        appendUInt32LE(UInt32(sampleBytes.count), to: &data)
        data.append(contentsOf: sampleBytes)
        return data
    }

    // MARK: Круглые пути через WAVEncoder

    @objc func testRoundTripWithEncoder() {
        let samples: [Int16] = [-32768, -1, 0, 1, 32767, 12345, -5432]
        let wav = WAVEncoder.encode(samples: samples, sampleRate: 16000)
        guard let info = WAVDecoder.decodePCM16(wav) else {
            XCTFail("декодер не разобрал WAV от WAVEncoder")
            return
        }
        XCTAssertEqual(info.sampleRate, 16000)
        XCTAssertEqual(info.channels, 1)
        XCTAssertEqual(info.samples, samples)
    }

    // MARK: Отклонения

    @objc func testRejectsNotWAV() {
        XCTAssertNil(WAVDecoder.decodePCM16(Data("совсем не wav".utf8)))
    }

    @objc func testRejectsNonPCMFormat() {
        let wav = makeWAV(audioFormat: 3) // IEEE float
        XCTAssertNil(WAVDecoder.decodePCM16(wav), "только PCM (audioFormat == 1)")
    }

    @objc func testRejectsNon16Bit() {
        let wav = makeWAV(bits: 8)
        XCTAssertNil(WAVDecoder.decodePCM16(wav), "только 16-бит")
    }

    @objc func testRejectsTruncatedHeader() {
        var wav = makeWAV()
        wav = wav.prefix(20)
        XCTAssertNil(WAVDecoder.decodePCM16(wav))
    }

    @objc func testRejectsEmptyDataChunk() {
        let wav = makeWAV(samples: [])
        XCTAssertNil(WAVDecoder.decodePCM16(wav), "data без сэмплов — nil")
    }

    // MARK: Нестандартные, но валидные файлы

    @objc func testSkipsUnknownChunks() {
        let wav = makeWAV(samples: [7, -7], unknownChunk: ("LIST", Array("JUNKINFO".utf8)))
        guard let info = WAVDecoder.decodePCM16(wav) else {
            XCTFail("LIST-чанк должен пропускаться")
            return
        }
        XCTAssertEqual(info.samples, [7, -7])
        XCTAssertEqual(info.sampleRate, 16000)
    }

    @objc func testMultiChannelSamplesInterleaved() {
        let wav = makeWAV(sampleRate: 8000, channels: 2, samples: [1, 2, 3, 4])
        guard let info = WAVDecoder.decodePCM16(wav) else {
            XCTFail("мультиканальный PCM должен декодироваться")
            return
        }
        XCTAssertEqual(info.channels, 2)
        XCTAssertEqual(info.sampleRate, 8000)
        XCTAssertEqual(info.samples, [1, 2, 3, 4], "сэмплы по каналам подряд (interleaved)")
    }

    @objc func testNegativeSamplesPreserved() {
        let wav = makeWAV(samples: [-1234, 0, 1234, -32768, 32767])
        guard let info = WAVDecoder.decodePCM16(wav) else {
            XCTFail("отрицательные сэмплы должны сохраняться")
            return
        }
        XCTAssertEqual(info.samples, [-1234, 0, 1234, -32768, 32767])
    }

    @objc func testHighSampleRateKept() {
        let wav = makeWAV(sampleRate: 48000, samples: [5])
        guard let info = WAVDecoder.decodePCM16(wav) else {
            XCTFail("48 кГц — валидный WAV")
            return
        }
        XCTAssertEqual(info.sampleRate, 48000)
    }

    // MARK: Сэмплы из реального WAV-файла

    @objc func testDecodesEncodedFileBytes() {
        // Двухканальный файл, собраный вручную, разбирается целиком.
        let wav = makeWAV(sampleRate: 16000, channels: 1, samples: Array(0..<100).map { Int16($0 * 100) })
        guard let info = WAVDecoder.decodePCM16(wav) else {
            XCTFail("провал декодирования")
            return
        }
        XCTAssertEqual(info.samples.count, 100)
        XCTAssertEqual(info.samples.last, Int16(99 * 100))
    }
}