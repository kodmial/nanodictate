import Foundation

/// Encode PCM Int16 samples to WAV (RIFF) format.
public enum WAVEncoder {
  /// Encode Int16 samples to WAV (mono, 16-bit, given sampleRate).
  public static func encode(samples: [Int16], sampleRate: Int = 16000) -> Data {
    let numChannels: Int16 = 1
    let bitsPerSample: Int16 = 16
    let byteRate = Int32(sampleRate) * Int32(numChannels) * Int32(bitsPerSample / 8)
    let blockAlign = numChannels * (bitsPerSample / 8)
    let dataSize = Int32(samples.count * 2)
    let fileSize = 36 + dataSize

    var data = Data()
    data.reserveCapacity(44 + samples.count * 2)

    // RIFF header
    data.append(contentsOf: "RIFF".utf8)
    data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
    data.append(contentsOf: "WAVE".utf8)

    // fmt sub-chunk
    data.append(contentsOf: "fmt ".utf8)
    // sub-chunk size
    data.append(contentsOf: withUnsafeBytes(of: Int32(16).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: Int16(1).littleEndian) { Array($0) })  // PCM
    data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: Int32(sampleRate).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })

    // data sub-chunk
    data.append(contentsOf: "data".utf8)
    data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
    // Pre-reserved capacity (44 + n*2): bulk append, no per-sample temp arrays.
    // Little-endian native on all Macs.
    if !samples.isEmpty {
      samples.withUnsafeBytes { raw in
        data.append(contentsOf: raw)
      }
    }

    return data
  }
}
