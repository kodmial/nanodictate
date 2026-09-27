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
