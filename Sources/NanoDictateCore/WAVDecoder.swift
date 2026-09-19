import Foundation

// MARK: - Ответственность: декодирование WAV (RIFF/PCM) в Int16-сэмплы

// Batch recognition works on samples (chunks, duration), so WAV decodes into
// [Int16], not raw bytes. Canonical PCM WAV supported (typical afconvert output
// with LIST/fact chunks): fmt chunk (PCM, channels, sampleRate, bit depth) +
// data chunk; unknown chunks skipped. Non-WAV/non-PCM → nil (caller converts
// via afconvert).

public struct WAVInfo: Equatable {
  public let sampleRate: Int
  public let channels: Int
  /// PCM Int16 samples (channel-interleaved for multichannel).
  public let samples: [Int16]

  public init(sampleRate: Int, channels: Int, samples: [Int16]) {
    self.sampleRate = sampleRate
    self.channels = channels
    self.samples = samples
  }
}

/// WAV file metadata: fmt+data (no sample copy).
public struct WAVPCMHeader: Equatable {
  public let sampleRate: Int
  public let channels: Int
  public let bitsPerSample: Int
  public let dataOffset: Int
  public let dataSize: Int
  public var sampleCount: Int {
    dataSize / 2
  }
}

public enum WAVDecoder {
  /// Parse WAV HEADER (RIFF/fmt/data: PCM, channels, sampleRate, bit depth,
  /// offset and size of PCM data) WITHOUT copying samples. Only canonical PCM
  /// 16-bit (like decodePCM16); unknown chunks (LIST/fact/...) skipped.
  /// Walks chunk chain (4-byte id + 4-byte size, 2-byte alignment — odd payload
  /// padded with one byte). Canonical layout requirements: fmt chunk must come
  /// BEFORE data (data before fmt → nil); of several data chunks FIRST counts,
  /// rest ignored. File needs only window covering chunks UP TO data: data
  /// chunk header (id+size, 8 bytes) must be in window, its payload (whole
  /// sound) NOT required — only offset and size remembered.
  public static func pcmHeader(in data: Data) -> WAVPCMHeader? {
    guard data.count >= 44, isRIFFWAVEPrefix(data) else { return nil }

    // Walk chunks: fmt required before data, others skipped.
    var cursor = 12
    var sampleRate = 0
    var channels = 0
    var bitsPerSample = 0
    var dataOffset = -1
    var dataSize = 0

    while cursor + 8 <= data.count {
      let chunkID = String(bytes: data[cursor..<(cursor + 4)], encoding: .ascii) ?? ""
      let size = Int(readUInt32LE(data, at: cursor + 4))
      let payloadStart = cursor + 8

      if chunkID == "data" {
        // data chunk found: stop here. FIRST data wins — later data chunks
        // (nonstandard files) ignored. Payload may be huge (whole sound) and
        // not needed in window — take only offset and size from header.
        dataOffset = payloadStart
        dataSize = size
        break
      }

      // Other chunks: need payload length to skip to next header.
      guard payloadStart + size <= data.count else { return nil }

      switch chunkID {
      case "fmt ":
        guard let fmt = readFmtChunk(data, payloadStart: payloadStart, size: size) else {
          return nil
        }
        channels = fmt.channels
        sampleRate = fmt.sampleRate
        bitsPerSample = fmt.bitsPerSample
      default:
        break
      }

      cursor = payloadStart + size + (size % 2)  // chunks 2-byte aligned
    }

    guard sampleRate > 0, channels > 0, dataOffset >= 0, dataSize > 0 else { return nil }
    // data chunk header (id+size) guaranteed in window by loop condition
    // (dataOffset = found chunk cursor + 8 ≤ data.count); payload not needed
    // in window — file prefix up to data suffices.
    guard dataOffset <= data.count else { return nil }
    return WAVPCMHeader(
      sampleRate: sampleRate,
      channels: channels,
      bitsPerSample: bitsPerSample,
      dataOffset: dataOffset,
      dataSize: dataSize
    )
  }

  /// Decode whole WAV into [Int16]. Unlike pcmHeader (prefix-based) requires
  /// data payload fully in buffer: declared dataSize > actual → nil (truncated WAV).
  public static func decodePCM16(_ data: Data) -> WAVInfo? {
    guard let header = pcmHeader(in: data) else { return nil }
    let sampleCount = header.sampleCount
    guard sampleCount > 0 else { return nil }
    // Cap reserve at available bytes: declared dataSize may be huge (prefix
    // of big file, size=2^32-1) — no huge reserve for nonexistent samples
    // before check.
    let availableSamples = max(0, (data.count - header.dataOffset) / 2)

    var samples: [Int16] = []
    samples.reserveCapacity(min(sampleCount, availableSamples))
    for i in 0..<sampleCount {
      let offset = header.dataOffset + i * 2
      guard offset + 2 <= data.count else { break }
      let value = readUInt16LE(data, at: offset)
      samples.append(Int16(bitPattern: value))
    }
    guard samples.count == sampleCount else { return nil }
    return WAVInfo(sampleRate: header.sampleRate, channels: header.channels, samples: samples)
  }

  private static func isRIFFWAVEPrefix(_ data: Data) -> Bool {
    String(bytes: data[0..<4], encoding: .ascii) == "RIFF"
      && String(bytes: data[8..<12], encoding: .ascii) == "WAVE"
  }

  /// fmt chunk fields meaningful for decoding (PCM 16-bit).
  private struct PCMFmtChunk {
    var channels: Int
    var sampleRate: Int
    var bitsPerSample: Int
  }

  /// Parse fmt chunk (canonical PCM 16-bit). nil unless requirements met:
  /// minimal size, audioFormat == 1, bit depth == 16.
  private static func readFmtChunk(
    _ data: Data,
    payloadStart: Int,
    size: Int
  ) -> PCMFmtChunk? {
    guard size >= 16 else { return nil }
    let audioFormat = Int(readUInt16LE(data, at: payloadStart))
    guard audioFormat == 1 else { return nil }  // PCM only
    let fmt = PCMFmtChunk(
      channels: Int(readUInt16LE(data, at: payloadStart + 2)),
      sampleRate: Int(readUInt32LE(data, at: payloadStart + 4)),
      bitsPerSample: Int(readUInt16LE(data, at: payloadStart + 14))
    )
    guard fmt.bitsPerSample == 16 else { return nil }
    return fmt
  }

  private static func readUInt16LE(_ bytes: Data, at offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
  }

  private static func readUInt32LE(_ bytes: Data, at offset: Int) -> UInt32 {
    UInt32(bytes[offset])
      | (UInt32(bytes[offset + 1]) << 8)
      | (UInt32(bytes[offset + 2]) << 16)
      | (UInt32(bytes[offset + 3]) << 24)
  }
}
