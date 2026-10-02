import Foundation

// swiftlint:disable file_length

// MARK: - Pure-Swift lossless FLAC codec (mono 16-bit batch transport)
//
// Native/lightweight encoding approach compatible with every supported macOS
// version: no AVFoundation, no third-party dependency — fixed predictors
// (orders 0-4) + Rice coding over 4096-sample blocks, STREAMINFO + framed
// subset of the FLAC format (xiph.org/flac/format.html).
//
// Scope: exactly what NanoDictate batch profiles need — mono PCM16 at the
// profile sample rate (16 kHz for every built-in model). Multichannel input
// is rejected (`encode` returns nil) so a caller can never silently ship a
// 48 kHz stereo payload to a 16 kHz mono model. The decoder below covers
// the encoded subset and exists to verify the lossless round-trip locally
// (benchmarks + tests); it is not a general-purpose FLAC player.

// MARK: - Bit writer/reader

struct FLACBitWriter {
  var bytes: [UInt8] = []
  private var current: UInt8 = 0
  private var filled: Int = 0

  mutating func writeBits(_ value: UInt32, count: Int) {
    guard count > 0 else { return }
    for i in stride(from: count - 1, through: 0, by: -1) {
      let bit = UInt8((value >> UInt32(i)) & 1)
      current = (current << 1) | bit
      filled += 1
      if filled == 8 {
        bytes.append(current)
        current = 0
        filled = 0
      }
    }
  }

  mutating func writeUnary(_ count: Int) {
    // RFC 9639 section 5: unary is zero bits terminated with a one bit
    // (e.g. 5 is 0b000001). This also keeps long one-runs (frame sync)
    // out of Rice-coded residuals.
    for _ in 0..<count {
      writeBits(0, count: 1)
    }
    writeBits(1, count: 1)
  }

  mutating func flush() {
    if filled > 0 {
      current <<= (8 - filled)
      bytes.append(current)
      current = 0
      filled = 0
    }
  }
}

struct FLACBitReader {
  let bytes: [UInt8]
  var bitPos: Int

  init(data: Data) {
    self.bytes = [UInt8](data)
    self.bitPos = 0
  }

  init(bytes: [UInt8], bitPos: Int = 0) {
    self.bytes = bytes
    self.bitPos = bitPos
  }

  var bitsLeft: Int { bytes.count * 8 - bitPos }

  mutating func readBits(_ count: Int) -> UInt32? {
    guard count > 0, bitsLeft >= count else { return nil }
    var value: UInt32 = 0
    for _ in 0..<count {
      let byte = bytes[bitPos / 8]
      let bit = (byte >> (7 - (bitPos % 8))) & 1
      value = (value << 1) | UInt32(bit)
      bitPos += 1
    }
    return value
  }

  mutating func readUnary() -> Int? {
    // Zeros terminated with a one bit (RFC 9639 section 5).
    var count = 0
    while true {
      guard let bit = readBits(1) else { return nil }
      if bit == 1 { return count }
      count += 1
    }
  }

  mutating func readSigned(bits: Int) -> Int32? {
    guard let raw = readBits(bits) else { return nil }
    if bits == 32 { return Int32(bitPattern: raw) }
    let shift = 32 - bits
    return Int32(bitPattern: raw << UInt32(shift)) >> shift
  }
}

// MARK: - CRC

enum FLACCRC {
  static func crc8(_ bytes: [UInt8]) -> UInt8 {
    var crc: UInt8 = 0
    for byte in bytes {
      crc ^= byte
      for _ in 0..<8 {
        crc = (crc & 0x80) != 0 ? (crc << 1) ^ 0x07 : crc << 1
      }
    }
    return crc
  }

  static func crc16(_ bytes: [UInt8]) -> UInt16 {
    var crc: UInt16 = 0
    for byte in bytes {
      crc ^= UInt16(byte) << 8
      for _ in 0..<8 {
        crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x8005 : crc << 1
      }
    }
    return crc
  }
}

// MARK: - Encoder

/// Lossless FLAC encoder for mono PCM16 batch audio.
public enum FLACEncoder {
  public static let maxBlockSize = 4096

  public static func canEncode(profile: STTAudioProfile) -> Bool {
    profile.channels == 1 && profile.sampleRate > 0
  }

  /// Encode mono PCM16 samples. Returns nil for non-mono input.
  public static func encode(
    samples: [Int16], sampleRate: Int = 16000, channels: Int = 1
  ) -> Data? {
    guard channels == 1, sampleRate > 0 else { return nil }
    var out = Data()
    out.append(contentsOf: [0x66, 0x4C, 0x61, 0x43])  // "fLaC"
    out.append(contentsOf: streamInfo(
      sampleRate: sampleRate, channels: channels, totalSamples: samples.count))
    var frameIndex = 0
    var offset = 0
    while offset < samples.count {
      let end = min(offset + maxBlockSize, samples.count)
      let block = Array(samples[offset..<end])
      out.append(contentsOf: encodeFrame(
        block: block, frameIndex: frameIndex, sampleRate: sampleRate))
      frameIndex += 1
      offset = end
    }
    return out
  }

  // MARK: - STREAMINFO

  static func streamInfo(sampleRate: Int, channels: Int, totalSamples: Int) -> [UInt8] {
    var header: [UInt8] = [0x80]  // last-metadata-block + type 0 (STREAMINFO)
    header += [0x00, 0x00, 0x22]  // length 34
    var body: [UInt8] = []
    // RFC 9639 forbids min/max block sizes below 16 in STREAMINFO. Tiny
    // inputs (fewer than 16 samples) still encode as one last block, which
    // is exempt from the minimum; the fields are clamped, never the audio.
    let actualMax = totalSamples == 0 ? maxBlockSize : min(maxBlockSize, totalSamples)
    let minBlock = max(16, actualMax)
    let maxBlock = max(16, actualMax)
    body += [UInt8((minBlock >> 8) & 0xFF), UInt8(minBlock & 0xFF)]
    body += [UInt8((maxBlock >> 8) & 0xFF), UInt8(maxBlock & 0xFF)]
    body += [0x00, 0x00, 0x00, 0x00, 0x00, 0x00]  // min/max frame size unknown
    let packed: UInt64 =
      (UInt64(sampleRate) << 44)
      | (UInt64(channels - 1) << 41)
      | (UInt64(16 - 1) << 36)
      | UInt64(totalSamples)
    for shift in stride(from: 56, through: 0, by: -8) {
      body.append(UInt8((packed >> UInt64(shift)) & 0xFF))
    }
    body += [UInt8](repeating: 0, count: 16)  // MD5 (unknown)
    return header + body
  }

  // MARK: - Frame

  /// Sample-rate table (RFC 9639 section 9.1.2). The streamable subset
  /// requires frame headers to carry the rate (bits 0001-1110), never a
  /// streaminfo reference (0000); unknown rates fall back to 0000.
  static func sampleRateBits(_ sampleRate: Int) -> UInt32 {
    switch sampleRate {
    case 8000: return 0b0100
    case 16000: return 0b0101
    case 22050: return 0b0110
    case 24000: return 0b0111
    case 32000: return 0b1000
    case 44100: return 0b1001
    case 48000: return 0b1010
    case 96000: return 0b1011
    default: return 0b0000
    }
  }

  static func sampleRateFromBits(_ bits: UInt32) -> Int? {
    switch bits {
    case 0b0100: return 8000
    case 0b0101: return 16000
    case 0b0110: return 22050
    case 0b0111: return 24000
    case 0b1000: return 32000
    case 0b1001: return 44100
    case 0b1010: return 48000
    case 0b1011: return 96000
    default: return nil
    }
  }

  static func encodeFrame(block: [Int16], frameIndex: Int, sampleRate: Int = 16000) -> [UInt8] {
    var header = FLACBitWriter()
    // RFC 9639 section 9.1: 15-bit sync + strategy = 0xFFF8 (fixed blocks).
    // Fixed prefix is 32 bits, so header + coded number + extras + CRC-8
    // stays byte-aligned: frames start on byte boundaries.
    header.writeBits(0b111111111111100, count: 15)  // sync
    header.writeBits(0, count: 1)  // fixed blocksize strategy
    header.writeBits(0b0111, count: 4)  // 16-bit blocksize-1 follows
    header.writeBits(sampleRateBits(sampleRate), count: 4)
    header.writeBits(0, count: 4)  // channels: mono independent
    header.writeBits(0b100, count: 3)  // bit depth: 16 bits per sample
    header.writeBits(0, count: 1)  // reserved
    writeUTF8(&header, value: frameIndex)
    header.writeBits(UInt32(block.count - 1), count: 16)
    header.flush()
    var headerBytes = header.bytes
    headerBytes.append(FLACCRC.crc8(headerBytes))

    var subframe = FLACBitWriter()
    writeSubframe(&subframe, block: block)
    subframe.flush()

    var frame = headerBytes + subframe.bytes
    let crc = FLACCRC.crc16(frame)
    frame.append(UInt8((crc >> 8) & 0xFF))
    frame.append(UInt8(crc & 0xFF))
    return frame
  }

  static func writeUTF8(_ writer: inout FLACBitWriter, value: Int) {
    let scalar = UInt32(value)
    if scalar < 0x80 {
      writer.writeBits(scalar, count: 8)
      return
    }
    // RFC 9639 Table 18: byte count by value range.
    let count: Int
    switch scalar {
    case ..<0x800: count = 2
    case ..<0x1_0000: count = 3
    case ..<0x20_0000: count = 4
    case ..<0x400_0000: count = 5
    default: count = 6
    }
    let contBits = 6 * (count - 1)
    let marker = (UInt32(0xFF) << UInt32(8 - count)) & 0xFF
    writer.writeBits(marker | (scalar >> UInt32(contBits)), count: 8)
    for i in stride(from: count - 2, through: 0, by: -1) {
      writer.writeBits(0x80 | ((scalar >> UInt32(6 * i)) & 0x3F), count: 8)
    }
  }

  // MARK: - Subframe

  static func writeSubframe(_ writer: inout FLACBitWriter, block: [Int16]) {
    let residuals = fixedResiduals(block: block)
    // RFC 9639 Table 19: 0b000000 = constant, 0b000001 = verbatim.
    if let constant = residuals.constantValue {
      writer.writeBits(0, count: 1)
      writer.writeBits(0b000000, count: 6)
      writer.writeBits(0, count: 1)
      writer.writeBits(UInt32(bitPattern: Int32(constant)) & 0xFFFF, count: 16)
      return
    }
    let choice = bestOrder(residuals: residuals, count: block.count)
    if choice.useVerbatim {
      writer.writeBits(0, count: 1)
      writer.writeBits(0b000001, count: 6)
      writer.writeBits(0, count: 1)
      for sample in block {
        writer.writeBits(UInt32(bitPattern: Int32(sample)) & 0xFFFF, count: 16)
      }
      return
    }
    writer.writeBits(0, count: 1)
    writer.writeBits(UInt32(0b001000 | choice.order), count: 6)
    writer.writeBits(0, count: 1)
    for i in 0..<choice.order {
      writer.writeBits(UInt32(bitPattern: Int32(block[i])) & 0xFFFF, count: 16)
    }
    writer.writeBits(0, count: 2)  // Rice 4-bit partitions
    writer.writeBits(0, count: 4)  // partition order 0 (single partition)
    writeRicePartition(
      writer: &writer,
      residuals: Array(residuals.values[choice.order].dropFirst(choice.order)),
      riceParam: choice.riceParam,
      escapeBits: choice.escapeBits)
  }

  struct OrderChoice {
    var order: Int
    var riceParam: Int
    var useVerbatim: Bool
    // Raw-bits escape when set (>= 0): samples stored un-Rice-coded.
    var escapeBits: Int = -1
  }

  struct BlockResiduals {
    // values[order] holds full-length residuals for that fixed order
    // (first `order` entries unused warmup positions).
    var values: [[Int32]]
    var constantValue: Int16?
  }

  static func fixedResiduals(block: [Int16]) -> BlockResiduals {
    let sampleCount = block.count
    if sampleCount > 0, block.allSatisfy({ $0 == block[0] }) {
      return BlockResiduals(
        values: [[Int32]](repeating: [Int32](repeating: 0, count: sampleCount), count: 5),
        constantValue: block[0])
    }
    var values: [[Int32]] = []
    let pcmSamples = block.map { Int32($0) }
    for order in 0...4 {
      var residualRow = [Int32](repeating: 0, count: sampleCount)
      if order < sampleCount {
        for i in order..<sampleCount {
          let predicted: Int32
          switch order {
          case 0: predicted = 0
          case 1: predicted = pcmSamples[i - 1]
          case 2: predicted = 2 * pcmSamples[i - 1] - pcmSamples[i - 2]
          case 3: predicted = 3 * pcmSamples[i - 1] - 3 * pcmSamples[i - 2] + pcmSamples[i - 3]
          default: predicted = 4 * pcmSamples[i - 1] - 6 * pcmSamples[i - 2] + 4 * pcmSamples[i - 3] - pcmSamples[i - 4]
          }
          residualRow[i] = pcmSamples[i] &- predicted
        }
      }
      values.append(residualRow)
    }
    return BlockResiduals(values: values, constantValue: nil)
  }

  static func bestOrder(residuals: BlockResiduals, count sampleCount: Int) -> OrderChoice {
    let verbatimBits = 8 + sampleCount * 16
    var best = OrderChoice(order: 0, riceParam: 0, useVerbatim: true)
    var bestBits = verbatimBits
    for order in 0...4 {
      guard order < sampleCount else { continue }
      let tail = Array(residuals.values[order].dropFirst(order))
      let (param, escape, bits) = riceCost(residuals: tail)
      let total = 8 + order * 16 + 10 + bits
      if total < bestBits {
        bestBits = total
        if escape >= 0 {
          best = OrderChoice(order: order, riceParam: 15, useVerbatim: false, escapeBits: escape)
        } else {
          best = OrderChoice(order: order, riceParam: param, useVerbatim: false)
        }
      }
    }
    return best
  }

  /// Returns (riceParam or 15 for escape, raw escape bits or -1, total bits).
  static func riceCost(residuals: [Int32]) -> (Int, Int, Int) {
    guard !residuals.isEmpty else { return (0, -1, 0) }
    var maxAbs: UInt32 = 0
    for residual in residuals {
      let folded = fold(residual)
      if folded > maxAbs { maxAbs = folded }
    }
    // Exact bit cost for every Rice parameter: cheap integer scan, so heavy
    // tails pick a larger parameter instead of exploding into megabyte
    // unary runs (slow to write, slow to read, poor compression). Long
    // blocks are estimated on a stride sample (k choice is a heuristic;
    // the chosen parameter encodes the full block, so this never affects
    // correctness, only estimator speed).
    let stride = max(1, residuals.count / 512)
    var bestParam = 0
    var bestBits = Int.max
    for param in 0...14 {
      var bits = 0
      var index = 0
      while index < residuals.count {
        let unsignedValue = fold(residuals[index])
        bits += Int(unsignedValue >> UInt32(param)) + 1 + param
        index += stride
      }
      bits *= stride
      if bits < bestBits {
        bestBits = bits
        bestParam = param
      }
    }
    // Raw escape fallback for pathological residuals.
    let rawBits = max(1, bitLength(maxAbs) + 1)
    let escapeBits = 9 + residuals.count * rawBits
    if escapeBits < bestBits {
      return (15, rawBits, escapeBits)
    }
    return (bestParam, -1, bestBits)
  }

  static func writeRicePartition(
    writer: inout FLACBitWriter, residuals: [Int32], riceParam: Int, escapeBits: Int
  ) {
    if riceParam == 15 {
      let rawBits = max(escapeBits, 1)
      writer.writeBits(0b1111, count: 4)
      writer.writeBits(UInt32(rawBits), count: 5)
      for residual in residuals {
        writer.writeBits(UInt32(bitPattern: residual) & mask(rawBits), count: rawBits)
      }
      return
    }
    writer.writeBits(UInt32(riceParam), count: 4)
    for residual in residuals {
      let unsignedValue = fold(residual)
      writer.writeUnary(Int(unsignedValue >> UInt32(riceParam)))
      if riceParam > 0 {
        writer.writeBits(unsignedValue & mask(riceParam), count: riceParam)
      }
    }
  }

  static func fold(_ value: Int32) -> UInt32 {
    UInt32(bitPattern: (value << 1) ^ (value >> 31))
  }

  static func unfold(_ value: UInt32) -> Int32 {
    Int32(bitPattern: (value >> 1) ^ (0 &- (value & 1)))
  }

  static func bitLength(_ value: UInt32) -> Int {
    value == 0 ? 0 : 32 - value.leadingZeroBitCount
  }

  static func mask(_ bits: Int) -> UInt32 {
    bits >= 32 ? 0xFFFF_FFFF : (bits == 0 ? 0 : (1 << UInt32(bits)) - 1)
  }
}

// MARK: - Decoder (encoded subset; lossless verification)

public struct FLACAudioInfo: Equatable {
  public var sampleRate: Int
  public var channels: Int
  public var samples: [Int16]

  public init(sampleRate: Int, channels: Int, samples: [Int16]) {
    self.sampleRate = sampleRate
    self.channels = channels
    self.samples = samples
  }
}

public enum FLACDecoder {
  public enum DecodeError: Error, Equatable {
    case invalidMagic
    case truncated
    case unsupported(String)
    case crcMismatch
  }

  public static func decode(_ data: Data) throws -> FLACAudioInfo {
    let bytes = [UInt8](data)
    guard bytes.count >= 4,
      bytes[0] == 0x66, bytes[1] == 0x4C, bytes[2] == 0x61, bytes[3] == 0x43
    else { throw DecodeError.invalidMagic }
    var cursor = 4
    var sampleRate = 0
    var channels = 0
    var totalSamples = 0
    var seenStreamInfo = false
    while true {
      guard cursor + 4 <= bytes.count else { throw DecodeError.truncated }
      let last = (bytes[cursor] & 0x80) != 0
      let type = bytes[cursor] & 0x7F
      let length = (Int(bytes[cursor + 1]) << 16) | (Int(bytes[cursor + 2]) << 8) | Int(
        bytes[cursor + 3])
      cursor += 4
      guard cursor + length <= bytes.count else { throw DecodeError.truncated }
      if type == 0 {
        let info = try parseStreamInfo(Array(bytes[cursor..<(cursor + length)]))
        sampleRate = info.0
        channels = info.1
        totalSamples = info.2
        seenStreamInfo = true
      }
      cursor += length
      if last { break }
    }
    guard seenStreamInfo else { throw DecodeError.unsupported("missing STREAMINFO") }
    var samples: [Int16] = []
    samples.reserveCapacity(totalSamples)
    var frameIndex = 0
    while samples.count < totalSamples {
      let consumed = try decodeFrame(
        bytes: bytes, cursor: cursor, frameIndex: frameIndex,
        channels: channels, streamSampleRate: sampleRate, into: &samples)
      cursor += consumed
      frameIndex += 1
    }
    return FLACAudioInfo(sampleRate: sampleRate, channels: channels, samples: samples)
  }

  static func parseStreamInfo(_ body: [UInt8]) throws -> (Int, Int, Int) {
    guard body.count == 34 else { throw DecodeError.unsupported("bad STREAMINFO length") }
    var packed: UInt64 = 0
    for i in 10..<18 {
      packed = (packed << 8) | UInt64(body[i])
    }
    let sampleRate = Int((packed >> 44) & 0xF_FFFF)
    let channels = Int(((packed >> 41) & 0x7) + 1)
    let total = Int(packed & 0xF_FFFF_FFFF)
    return (sampleRate, channels, total)
  }

  static func decodeFrame(
    bytes: [UInt8], cursor: Int, frameIndex: Int, channels: Int,
    streamSampleRate: Int, into samples: inout [Int16]
  ) throws -> Int {
    var reader = FLACBitReader(bytes: bytes, bitPos: cursor * 8)
    let frameStart = cursor
    let blockSize = try decodeFrameHeader(
      &reader, bytes: bytes, frameStart: frameStart, streamSampleRate: streamSampleRate)
    let block = try decodeSubframeSamples(&reader, blockSize: blockSize)
    // Byte-align, then CRC-16 over the whole frame.
    let endBit = ((reader.bitPos + 7) / 8) * 8
    reader.bitPos = endBit
    let frameEndByte = reader.bitPos / 8
    guard frameEndByte + 2 <= bytes.count else { throw DecodeError.truncated }
    let frameBytes = Array(bytes[frameStart..<frameEndByte])
    let stored = (UInt16(bytes[frameEndByte]) << 8) | UInt16(bytes[frameEndByte + 1])
    guard FLACCRC.crc16(frameBytes) == stored else { throw DecodeError.crcMismatch }
    samples += block
    return (frameEndByte + 2) - frameStart
  }

  static func decodeFrameHeader(
    _ reader: inout FLACBitReader, bytes: [UInt8], frameStart: Int, streamSampleRate: Int
  ) throws -> Int {
    // RFC 9639 section 9.1: 15-bit sync + strategy 0 (fixed) = 0xFFF8.
    guard let sync = reader.readBits(15), sync == 0b111111111111100,
      let strategy = reader.readBits(1), strategy == 0
    else { throw DecodeError.invalidMagic }
    guard let blockSizeBits = reader.readBits(4), blockSizeBits == 0b0111,
      let sampleRateBits = reader.readBits(4),
      let channelBits = reader.readBits(4), channelBits == 0,
      let bitDepthBits = reader.readBits(3),
      bitDepthBits == 0b000 || bitDepthBits == 0b100,
      let reservedBit = reader.readBits(1), reservedBit == 0
    else { throw DecodeError.unsupported("frame header flags") }
    try validateSampleRateBits(sampleRateBits, streamSampleRate: streamSampleRate)
    // Else 0b0000: rate from STREAMINFO (valid, not streamable-subset).
    _ = try readUTF8(&reader)
    guard let blockMinusOne = reader.readBits(16) else { throw DecodeError.truncated }
    // CRC-8 over header bytes.
    let headerEndByte = (reader.bitPos + 7) / 8
    guard headerEndByte <= bytes.count else { throw DecodeError.truncated }
    let headerBytes = Array(bytes[frameStart..<headerEndByte])
    guard let crcByte = reader.readBits(8), UInt8(crcByte) == FLACCRC.crc8(headerBytes) else {
      throw DecodeError.crcMismatch
    }
    return Int(blockMinusOne) + 1
  }

  static func validateSampleRateBits(_ sampleRateBits: UInt32, streamSampleRate: Int) throws {
    if let tableRate = FLACEncoder.sampleRateFromBits(sampleRateBits) {
      guard tableRate == streamSampleRate else {
        throw DecodeError.unsupported("sample rate change")
      }
    } else if sampleRateBits != 0 {
      throw DecodeError.unsupported("sample rate bits")
    }
  }

  static func decodeSubframeSamples(_ reader: inout FLACBitReader, blockSize: Int) throws -> [Int16] {
    guard let padding = reader.readBits(1), padding == 0,
      let predictor = reader.readBits(6),
      let wasted = reader.readBits(1), wasted == 0
    else { throw DecodeError.truncated }
    // RFC 9639 Table 19: 0b000000 = constant, 0b000001 = verbatim.
    switch predictor {
    case 0b000001:
      return try decodeVerbatimBlock(&reader, blockSize: blockSize)
    case 0b000000:
      return try decodeConstantBlock(&reader, blockSize: blockSize)
    case 0b001000...0b001100:
      let order = Int(predictor) - 0b001000
      return try decodeFixedBlock(&reader, blockSize: blockSize, order: order)
    default:
      throw DecodeError.unsupported("predictor \(predictor)")
    }
  }

  static func decodeVerbatimBlock(_ reader: inout FLACBitReader, blockSize: Int) throws -> [Int16] {
    var block: [Int16] = []
    block.reserveCapacity(blockSize)
    for _ in 0..<blockSize {
      guard let decodedSample = reader.readSigned(bits: 16) else { throw DecodeError.truncated }
      block.append(Int16(decodedSample))
    }
    return block
  }

  static func decodeConstantBlock(_ reader: inout FLACBitReader, blockSize: Int) throws -> [Int16] {
    guard let decodedSample = reader.readSigned(bits: 16) else { throw DecodeError.truncated }
    return [Int16](repeating: Int16(decodedSample), count: blockSize)
  }

  static func decodeFixedBlock(
    _ reader: inout FLACBitReader, blockSize: Int, order: Int
  ) throws -> [Int16] {
    var warmup: [Int32] = []
    warmup.reserveCapacity(order)
    for _ in 0..<order {
      guard let decodedSample = reader.readSigned(bits: 16) else { throw DecodeError.truncated }
      warmup.append(decodedSample)
    }
    guard let method = reader.readBits(2), method == 0,
      let partitionOrder = reader.readBits(4), partitionOrder == 0,
      let riceParam = reader.readBits(4)
    else { throw DecodeError.unsupported("residual coding") }
    let residualCount = blockSize - order
    let residuals: [Int32]
    if riceParam == 15 {
      residuals = try decodeRawResiduals(&reader, count: residualCount)
    } else {
      residuals = try decodeRiceValues(&reader, count: residualCount, riceParam: Int(riceParam))
    }
    return reconstructFixed(warmup: warmup, residuals: residuals, order: order)
  }

  static func decodeRawResiduals(_ reader: inout FLACBitReader, count residualCount: Int) throws -> [Int32] {
    guard let rawBits = reader.readBits(5) else { throw DecodeError.truncated }
    var residuals: [Int32] = []
    residuals.reserveCapacity(residualCount)
    for _ in 0..<residualCount {
      guard let decodedSample = reader.readSigned(bits: Int(rawBits)) else { throw DecodeError.truncated }
      residuals.append(decodedSample)
    }
    return residuals
  }

  static func decodeRiceValues(
    _ reader: inout FLACBitReader, count residualCount: Int, riceParam: Int
  ) throws -> [Int32] {
    var residuals: [Int32] = []
    residuals.reserveCapacity(residualCount)
    for _ in 0..<residualCount {
      guard let quotient = reader.readUnary() else { throw DecodeError.truncated }
      var unsignedValue = UInt32(quotient) << UInt32(riceParam)
      if riceParam > 0 {
        guard let remainder = reader.readBits(riceParam) else { throw DecodeError.truncated }
        unsignedValue |= remainder
      }
      residuals.append(FLACEncoder.unfold(unsignedValue))
    }
    return residuals
  }

  static func readUTF8(_ reader: inout FLACBitReader) throws -> Int {
    guard let first = reader.readBits(8) else { throw DecodeError.truncated }
    if first & 0x80 == 0 { return Int(first) }
    var extra = 0
    var value = 0
    if first & 0xE0 == 0xC0 { extra = 1; value = Int(first & 0x1F) } else if first & 0xF0 == 0xE0 {
      extra = 2; value = Int(first & 0x0F)
    } else if first & 0xF8 == 0xF0 { extra = 3; value = Int(first & 0x07) } else if first & 0xFC == 0xF8 {
      extra = 4; value = Int(first & 0x03)
    } else if first & 0xFE == 0xFC { extra = 5; value = Int(first & 0x01) } else {
      throw DecodeError.unsupported("frame number encoding")
    }
    for _ in 0..<extra {
      guard let cont = reader.readBits(8), cont & 0xC0 == 0x80 else { throw DecodeError.truncated }
      value = (value << 6) | Int(cont & 0x3F)
    }
    return value
  }

  static func reconstructFixed(warmup: [Int32], residuals: [Int32], order: Int) -> [Int16] {
    var output = warmup
    for residual in residuals {
      let i = output.count
      let predicted: Int32
      switch order {
      case 0: predicted = 0
      case 1: predicted = output[i - 1]
      case 2: predicted = 2 * output[i - 1] - output[i - 2]
      case 3: predicted = 3 * output[i - 1] - 3 * output[i - 2] + output[i - 3]
      default: predicted = 4 * output[i - 1] - 6 * output[i - 2] + 4 * output[i - 3] - output[i - 4]
      }
      output.append(residual &+ predicted)
    }
    return output.map { Int16(clamping: $0) }
  }
}

// swiftlint:enable file_length
