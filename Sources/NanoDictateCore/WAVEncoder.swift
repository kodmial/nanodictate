import Foundation

/// Encode PCM Int16 samples to WAV (RIFF) format.
public enum WAVEncoder {
  /// Encode Int16 samples to WAV (16-bit, given sampleRate/channels).
  /// Default is the historic batch profile: mono 16 kHz.
  public static func encode(samples: [Int16], sampleRate: Int = 16000, channels: Int = 1) -> Data {
    let numChannels = Int16(clamping: channels)
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

  /// Encode a non-owning slice view without materializing an Array first.
  public static func encode(
    samples slice: ArraySlice<Int16>, sampleRate: Int = 16000, channels: Int = 1
  ) -> Data {
    let numChannels = Int16(clamping: channels)
    let bitsPerSample: Int16 = 16
    let byteRate = Int32(sampleRate) * Int32(numChannels) * Int32(bitsPerSample / 8)
    let blockAlign = numChannels * (bitsPerSample / 8)
    let dataSize = Int32(slice.count * 2)
    let fileSize = 36 + dataSize

    var data = Data()
    data.reserveCapacity(44 + slice.count * 2)
    data.append(contentsOf: "RIFF".utf8)
    data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
    data.append(contentsOf: "WAVE".utf8)
    data.append(contentsOf: "fmt ".utf8)
    data.append(contentsOf: withUnsafeBytes(of: Int32(16).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: Int16(1).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: Int32(sampleRate).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
    data.append(contentsOf: "data".utf8)
    data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
    if !slice.isEmpty {
      slice.withUnsafeBytes { raw in
        data.append(contentsOf: raw)
      }
    }
    return data
  }

  /// Encode one planned segment straight from the source buffer: overlap tail
  /// + body are appended to the WAV payload in order without building an
  /// intermediate combined `[Int16]`. Only the segment being sent is touched.
  public static func encodeSegment(
    source: [Int16],
    bodyRange: Range<Int>,
    overlapRange: Range<Int>? = nil,
    sampleRate: Int = 16000,
    channels: Int = 1
  ) -> Data {
    let total = source.count
    let bodyLow = max(0, min(total, bodyRange.lowerBound))
    let bodyHigh = max(0, min(total, bodyRange.upperBound))
    var overlapLow = 0
    var overlapHigh = 0
    if let overlap = overlapRange {
      overlapLow = max(0, min(total, overlap.lowerBound))
      overlapHigh = max(0, min(total, overlap.upperBound))
      if overlapLow >= overlapHigh {
        overlapLow = 0
        overlapHigh = 0
      }
    }
    let sampleCount = (overlapHigh - overlapLow) + max(0, bodyHigh - bodyLow)
    let numChannels = Int16(clamping: channels)
    let bitsPerSample: Int16 = 16
    let byteRate = Int32(sampleRate) * Int32(numChannels) * Int32(bitsPerSample / 8)
    let blockAlign = numChannels * (bitsPerSample / 8)
    let dataSize = Int32(sampleCount * 2)
    let fileSize = 36 + dataSize

    var data = Data()
    data.reserveCapacity(44 + sampleCount * 2)
    data.append(contentsOf: "RIFF".utf8)
    data.append(contentsOf: withUnsafeBytes(of: fileSize.littleEndian) { Array($0) })
    data.append(contentsOf: "WAVE".utf8)
    data.append(contentsOf: "fmt ".utf8)
    data.append(contentsOf: withUnsafeBytes(of: Int32(16).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: Int16(1).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: numChannels.littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: Int32(sampleRate).littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: byteRate.littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: blockAlign.littleEndian) { Array($0) })
    data.append(contentsOf: withUnsafeBytes(of: bitsPerSample.littleEndian) { Array($0) })
    data.append(contentsOf: "data".utf8)
    data.append(contentsOf: withUnsafeBytes(of: dataSize.littleEndian) { Array($0) })
    if sampleCount > 0 {
      source.withUnsafeBufferPointer { buffer in
        guard let base = buffer.baseAddress else { return }
        if overlapHigh > overlapLow {
          let raw = UnsafeRawBufferPointer(
            start: base.advanced(by: overlapLow), count: (overlapHigh - overlapLow) * 2)
          data.append(contentsOf: raw)
        }
        if bodyHigh > bodyLow {
          let raw = UnsafeRawBufferPointer(
            start: base.advanced(by: bodyLow), count: (bodyHigh - bodyLow) * 2)
          data.append(contentsOf: raw)
        }
      }
    }
    return data
  }

  /// Encode for a concrete STT model profile: sample rate/channels come from
  /// the model audio requirements instead of a hard-coded batch assumption.
  /// All built-in profiles currently require 16 kHz mono, so this is
  /// byte-identical to `encode(samples:)` for them.
  public static func encode(samples: [Int16], audioProfile: STTAudioProfile) -> Data {
    encode(samples: samples, sampleRate: audioProfile.sampleRate, channels: audioProfile.channels)
  }

  /// Audio profile for a concrete (adapterID, model) pair — shorthand for
  /// `ProviderRequestBuilder.audioProfile` at encode call sites.
  public static func audioProfile(adapterID: String, model: String) -> STTAudioProfile {
    ProviderRequestBuilder.audioProfile(adapterID: adapterID, model: model)
  }
}
