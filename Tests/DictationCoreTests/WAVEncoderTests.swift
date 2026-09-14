import Foundation
@testable import DictationCore

final class WAVEncoderTests: XCTestCase {

    // MARK: - Existing

    @objc func testEmpty() {
        let data = WAVEncoder.encode(samples: [])
        XCTAssertEqual(data.count, 44) // only header
    }

    @objc func testKnownSamples() {
        let samples: [Int16] = [1000, -1000, 32767, -32768]
        let data = WAVEncoder.encode(samples: samples)
        // header (44) + 4 samples * 2 bytes = 52
        XCTAssertEqual(data.count, 52)

        let bytes = [UInt8](data)
        // RIFF header
        XCTAssertEqual(bytes[0], 0x52) // 'R'
        XCTAssertEqual(bytes[1], 0x49) // 'I'
        XCTAssertEqual(bytes[2], 0x46) // 'F'
        XCTAssertEqual(bytes[3], 0x46) // 'F'

        // fileSize = 52 - 8 = 44
        let fileSize = bytes[4...7].withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(fileSize, 44)

        // WAVE
        XCTAssertEqual(bytes[8], 0x57) // 'W'
        XCTAssertEqual(bytes[9], 0x41) // 'A'
        XCTAssertEqual(bytes[10], 0x56) // 'V'
        XCTAssertEqual(bytes[11], 0x45) // 'E'

        // fmt chunk
        XCTAssertEqual(bytes[12...15].map { Character(UnicodeScalar($0)) }, Array("fmt "))
        let subChunkSize = bytes[16...19].withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(subChunkSize, 16)

        // data chunk: starts at offset 36
        XCTAssertEqual(bytes[36...39].map { Character(UnicodeScalar($0)) }, Array("data"))

        // First sample at offset 44: 1000 LE
        let sample0 = bytes[44...45].withUnsafeBytes { $0.load(as: Int16.self) }
        XCTAssertEqual(sample0, 1000)
        let sample1 = bytes[46...47].withUnsafeBytes { $0.load(as: Int16.self) }
        XCTAssertEqual(sample1, -1000)
    }

    @objc func testSampleRate() {
        let data = WAVEncoder.encode(samples: [0], sampleRate: 44100)
        let bytes = [UInt8](data)
        // sampleRate at offset 24 (LE uint32)
        let rate = bytes[24...27].withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(rate, 44100)
        // byteRate at offset 28
        let byteRate = bytes[28...31].withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(byteRate, 88200) // 44100 * 1 * 2
    }

    // MARK: - sampleRate 8000

    @objc func testSampleRate8000() {
        let data = WAVEncoder.encode(samples: [0, 0], sampleRate: 8000)
        let bytes = [UInt8](data)

        let rate = bytes[24...27].withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(rate, 8000)

        let byteRate = bytes[28...31].withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(byteRate, 16000) // 8000 * 1 * 2
    }

    // MARK: - Int16.max / Int16.min edge samples

    @objc func testEdgeInt16Samples() {
        let samples: [Int16] = [Int16.max, Int16.min]
        let data = WAVEncoder.encode(samples: samples)
        let bytes = [UInt8](data)

        // Int16.max = 32767 → LE bytes: 0xFF 0x7F
        XCTAssertEqual(bytes[44], 0xFF)
        XCTAssertEqual(bytes[45], 0x7F)

        // Int16.min = -32768 → LE bytes: 0x00 0x80
        XCTAssertEqual(bytes[46], 0x00)
        XCTAssertEqual(bytes[47], 0x80)

        // Verify roundtrip via load
        let s0 = bytes[44...45].withUnsafeBytes { $0.load(as: Int16.self) }
        let s1 = bytes[46...47].withUnsafeBytes { $0.load(as: Int16.self) }
        XCTAssertEqual(s0, Int16.max)
        XCTAssertEqual(s1, Int16.min)
    }

    // MARK: - Binary structure at 16kHz mono

    @objc func testBinaryStructure16kHzMono16bit() {
        let samples: [Int16] = [100, -200, 300]
        let data = WAVEncoder.encode(samples: samples, sampleRate: 16000)
        let bytes = [UInt8](data)

        // byteRate = 16000 * 1 * 2 = 32000
        let byteRate = bytes[28...31].withUnsafeBytes { $0.load(as: UInt32.self) }
        XCTAssertEqual(byteRate, 32000)

        // blockAlign at offset 32 (Int16 LE)
        let blockAlign = bytes[32...33].withUnsafeBytes { $0.load(as: Int16.self) }
        XCTAssertEqual(blockAlign, 2) // 1 channel * (16/8)

        // bitsPerSample at offset 34 (Int16 LE)
        let bitsPerSample = bytes[34...35].withUnsafeBytes { $0.load(as: Int16.self) }
        XCTAssertEqual(bitsPerSample, 16)

        // numChannels at offset 22 (Int16 LE)
        let numChannels = bytes[22...23].withUnsafeBytes { $0.load(as: Int16.self) }
        XCTAssertEqual(numChannels, 1)
    }

    // MARK: - fileSize = 36 + dataSize

    @objc func testFileSizeFormula() {
        let samples: [Int16] = [1, 2, 3, 4, 5]
        let data = WAVEncoder.encode(samples: samples)
        let bytes = [UInt8](data)

        let fileSize = bytes[4...7].withUnsafeBytes { $0.load(as: UInt32.self) }
        let dataSize = Int32(samples.count * 2)
        XCTAssertEqual(fileSize, 36 + UInt32(dataSize))

        // Total file = 8 (RIFF header) + fileSize
        XCTAssertEqual(data.count, 8 + Int(fileSize))
    }

    // MARK: - Tags: "RIFF", "WAVE", "fmt ", "data"

    @objc func testChunkTags() {
        let data = WAVEncoder.encode(samples: [0])
        let bytes = [UInt8](data)

        // RIFF at 0..4
        XCTAssertEqual(String(bytes: bytes[0..<4], encoding: .ascii), "RIFF")
        // WAVE at 8..12
        XCTAssertEqual(String(bytes: bytes[8..<12], encoding: .ascii), "WAVE")
        // fmt  at 12..16
        XCTAssertEqual(String(bytes: bytes[12..<16], encoding: .ascii), "fmt ")
        // data at 36..40
        XCTAssertEqual(String(bytes: bytes[36..<40], encoding: .ascii), "data")
    }
}
