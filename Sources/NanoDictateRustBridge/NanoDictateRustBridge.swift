import Foundation
import NanoDictateRustFFI

// swiftlint:disable file_length

// MARK: - NanoDictateRustBridge
//
// Idiomatic Swift surface over the shared Rust engine (nanodictate-core).
// This module owns no behavior: every function below is a thin, memory-safe
// wrapper around the C ABI declared in nanodictate_core.h. Deterministic
// product logic lives in Rust; macOS integrations (AVFoundation capture,
// event taps, permissions, overlay, packaging) stay in NanoDictateCore and
// the agent executables.
//
// Threading and ownership follow the ABI contract: opaque handles are
// reference types with exclusive access (mirror the Swift classes they
// port), strings crossing the boundary are UTF-8 with explicit lengths,
// and every Rust-owned allocation is released exactly once.

// MARK: - Errors

/// Failure of a Rust engine call. The message is the ABI diagnostic text.
public struct RustEngineError: Error, Equatable {
  public let code: Int32
  public let message: String

  public init(code: Int32, message: String) {
    self.code = code
    self.message = message
  }
}

func lastErrorMessage() -> String {
  guard let raw = nd_last_error_text() else { return "unknown engine error" }
  return String(cString: raw)
}

// MARK: - ABI version

/// Asserts the linked engine speaks the ABI this bridge was generated for.
public func assertEngineABIVersion(expected: UInt32 = UInt32(ND_ABI_VERSION)) throws {
  let linked = nd_abi_version()
  guard linked == expected else {
    throw RustEngineError(
      code: -1,
      message: "engine ABI mismatch: linked \(linked), expected \(expected)")
  }
}

// MARK: - String/bytes plumbing

/// Copies a Rust-owned NUL-terminated string and releases the original.
func takeString(_ ptr: UnsafeMutablePointer<CChar>?) throws -> String {
  guard let ptr else {
    throw RustEngineError(code: -1, message: lastErrorMessage())
  }
  defer { nd_string_free(ptr) }
  return String(cString: ptr)
}

extension String {
  /// Runs `body` with the string's UTF-8 bytes and byte count.
  func withUTF8Bytes<T>(_ body: (UnsafePointer<CChar>?, Int) throws -> T) rethrows -> T {
    let bytes = Array(utf8)
    return try bytes.withUnsafeBufferPointer { buffer in
      let pointer = buffer.baseAddress.map {
        UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)
      }
      return try body(pointer, buffer.count)
    }
  }
}

// MARK: - Audio metrics

/// Linear amplitude (0...1) to dBFS.
public func rustDbfs(_ linear: Float) -> Float {
  nd_dbfs(linear)
}

/// RMS over Int16 samples (0...1). Throws on a null/empty bridge misuse.
public func rustRMS(samples: [Int16]) -> Float {
  samples.withUnsafeBufferPointer { buffer in
    nd_rms_i16(buffer.baseAddress, buffer.count)
  }
}

/// Bounded soft limiter for one sample.
public func rustSoftLimit(_ x: Float) -> Float {
  nd_soft_limit(x)
}

// MARK: - WAV codec

/// Encodes Int16 samples as 16-bit PCM WAV. Byte-identical to WAVEncoder.
public func rustWAVEncode(samples: [Int16], sampleRate: UInt32, channels: UInt16) throws -> Data {
  var out = NdByteBuffer(data: nil, len: 0, cap: 0)
  let code = samples.withUnsafeBufferPointer { buffer in
    nd_wav_encode(buffer.baseAddress, buffer.count, sampleRate, channels, &out)
  }
  guard code == 0 else {
    throw RustEngineError(code: code, message: lastErrorMessage())
  }
  defer { nd_bytes_free(out) }
  guard let data = out.data else {
    throw RustEngineError(code: -1, message: "engine returned an empty WAV buffer")
  }
  return Data(bytes: data, count: out.len)
}

/// WAV header metadata without copying samples.
public struct RustWAVInfo: Equatable {
  public let sampleRate: UInt32
  public let channels: UInt16
  public let sampleCount: Int
}

/// Reads WAV header metadata. Throws on non-WAV/non-PCM input.
public func rustWAVDecodeInfo(_ data: Data) throws -> RustWAVInfo {
  var sampleRate: UInt32 = 0
  var channels: UInt16 = 0
  var sampleCount: Int = 0
  let code: Int32 = data.withUnsafeBytes { raw in
    nd_wav_decode_info(
      raw.baseAddress?.assumingMemoryBound(to: UInt8.self),
      data.count,
      &sampleRate,
      &channels,
      &sampleCount)
  }
  guard code == 0 else {
    throw RustEngineError(code: code, message: lastErrorMessage())
  }
  return RustWAVInfo(
    sampleRate: sampleRate, channels: channels, sampleCount: Int(sampleCount))
}

// MARK: - Word diff

/// Word-level diff result from the engine. `change == false` means the
/// texts match word-wise (nothing to change).
public struct RustWordDiff: Equatable {
  public let change: Bool
  public let spanOld: String
  public let spanNew: String
  public let spanStartOld: Int
  public let spanStartNew: Int
}

/// Word-level diff between inserted (`old`) and final (`new`) text.
public func rustWordDiff(old: String, new: String) throws -> RustWordDiff {
  let json = try old.withUTF8Bytes { oldPtr, oldLen in
    try new.withUTF8Bytes { newPtr, newLen in
      try takeString(nd_word_diff(oldPtr, oldLen, newPtr, newLen))
    }
  }
  guard let data = json.data(using: .utf8),
    let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  else {
    throw RustEngineError(code: -1, message: "engine returned malformed diff JSON")
  }
  return RustWordDiff(
    change: (object["change"] as? Bool) ?? false,
    spanOld: (object["span_old"] as? String) ?? "",
    spanNew: (object["span_new"] as? String) ?? "",
    spanStartOld: (object["span_start_old"] as? Int) ?? 0,
    spanStartNew: (object["span_start_new"] as? Int) ?? 0
  )
}

// MARK: - Text stitching

/// Joins chunk texts with boundary-overlap dedup (see BatchTextJoiner).
public func rustTextJoin(_ texts: [String]) throws -> String {
  // One contiguous UTF-8 store plus pointer/length arrays; everything
  // stays alive inside the buffer scopes for the duration of the call.
  var storage: [UInt8] = []
  var offsets: [Int] = []
  var lengths: [Int] = []
  for text in texts {
    offsets.append(storage.count)
    lengths.append(text.utf8.count)
    storage.append(contentsOf: text.utf8)
  }
  return try storage.withUnsafeBufferPointer { storageBuf in
    guard let base = storageBuf.baseAddress else {
      // No texts (or all empty): the engine joins to an empty string.
      return try takeString(nd_text_join(nil, nil, 0))
    }
    let raw = UnsafeRawPointer(base)
    let pointers: [UnsafePointer<CChar>?] = offsets.map {
      raw.advanced(by: $0).assumingMemoryBound(to: CChar.self)
    }
    return try pointers.withUnsafeBufferPointer { ptrBuf in
      try lengths.withUnsafeBufferPointer { lenBuf in
        guard let ptrBase = ptrBuf.baseAddress, let lenBase = lenBuf.baseAddress else {
          throw RustEngineError(code: -1, message: "bridge buffer failure")
        }
        return try takeString(nd_text_join(ptrBase, lenBase, texts.count))
      }
    }
  }
}

// MARK: - STT policy

/// Resolves the model profile for an (adapter id, model) pair as raw JSON.
public func rustSTTResolve(adapterID: String, model: String) throws -> String {
  try adapterID.withUTF8Bytes { adapterPtr, adapterLen in
    try model.withUTF8Bytes { modelPtr, modelLen in
      try takeString(nd_stt_resolve(adapterPtr, adapterLen, modelPtr, modelLen))
    }
  }
}

/// Parses an STT response body into `{"text":...,"words":[...]}` JSON.
/// `path` selects the transcript field (nil/empty means flat `text`).
public func rustTranscriptParse(body: String, path: String? = nil) throws -> String {
  try body.withUTF8Bytes { bodyPtr, bodyLen in
    if let path, !path.isEmpty {
      return try path.withUTF8Bytes { pathPtr, pathLen in
        try takeString(nd_transcript_parse(bodyPtr, bodyLen, pathPtr, pathLen))
      }
    }
    return try takeString(nd_transcript_parse(bodyPtr, bodyLen, nil, 0))
  }
}

// MARK: - Retry / failover

/// Orders failover candidates as a comma-separated id list.
public func rustFailoverOrder(ids: [String], failedID: String?, autoFailover: Bool) throws
  -> [String]
{
  let joined = ids.joined(separator: ",")
  let result = try joined.withUTF8Bytes { idsPtr, idsLen in
    if let failedID, !failedID.isEmpty {
      return try failedID.withUTF8Bytes { failedPtr, failedLen in
        try takeString(
          nd_failover_order(idsPtr, idsLen, failedPtr, failedLen, autoFailover))
      }
    }
    return try takeString(nd_failover_order(idsPtr, idsLen, nil, 0, autoFailover))
  }
  guard !result.isEmpty else { return [] }
  return result.split(separator: ",").map(String.init)
}

/// Exponential backoff delay in milliseconds (deterministic, no jitter).
public func rustBackoffDelay(attempt: UInt32, baseMs: UInt64, capMs: UInt64) -> UInt64 {
  nd_backoff_delay_ms(attempt, baseMs, capMs)
}

// MARK: - Review / gates / policy

/// Review-before-insert decision: true = insert, false = cancel.
public func rustReviewDecide(line: String?) throws -> Bool {
  if let line {
    return try line.withUTF8Bytes { ptr, len in
      let code = nd_review_decide(ptr, len, true)
      guard code >= 0 else {
        throw RustEngineError(code: code, message: lastErrorMessage())
      }
      return code != 0
    }
  }
  let code = nd_review_decide(nil, 0, false)
  guard code >= 0 else {
    throw RustEngineError(code: code, message: lastErrorMessage())
  }
  return code != 0
}

// MARK: - Stateful handles

/// Adaptive VAD handle (see AdaptiveVAD). Exclusive access, like the
/// Swift value it mirrors; the caller serializes calls.
public final class RustVAD {
  private var handle: OpaquePointer?

  public init() throws {
    guard let created = nd_vad_new() else {
      throw RustEngineError(code: -1, message: lastErrorMessage())
    }
    handle = created
  }

  deinit { nd_vad_free(handle) }

  /// Feeds one buffer RMS with its duration. Returns the speech state.
  public func feed(rms: Float, duration: Double) throws -> Bool {
    let code = nd_vad_feed(handle, rms, duration)
    guard code >= 0 else {
      throw RustEngineError(code: code, message: lastErrorMessage())
    }
    return code != 0
  }

  /// Realtime ingress: feeds one block of Float32 samples. No per-sample
  /// FFI, no allocation on the engine side.
  public func feedSamples(_ samples: [Float], sampleRate: UInt32) throws -> Bool {
    let code = samples.withUnsafeBufferPointer { buffer in
      nd_vad_feed_samples(handle, buffer.baseAddress, buffer.count, sampleRate)
    }
    guard code >= 0 else {
      throw RustEngineError(code: code, message: lastErrorMessage())
    }
    return code != 0
  }

  public func reset() throws {
    let code = nd_vad_reset(handle)
    guard code == 0 else {
      throw RustEngineError(code: code, message: lastErrorMessage())
    }
  }
}

/// Input-gain (AGC) handle. Applies gain to Float32 blocks in place.
public final class RustInputGain {
  private var handle: OpaquePointer?

  public init() throws {
    guard let created = nd_gain_new() else {
      throw RustEngineError(code: -1, message: lastErrorMessage())
    }
    handle = created
  }

  deinit { nd_gain_free(handle) }

  /// Applies gain in place; returns the amplified RMS.
  public func apply(samples: inout [Float], rms: Float, sampleRate: UInt32) throws -> Float {
    let result: Float = samples.withUnsafeMutableBufferPointer { buffer in
      nd_gain_apply(handle, buffer.baseAddress, buffer.count, rms, sampleRate)
    }
    guard result >= 0 else {
      throw RustEngineError(code: -1, message: lastErrorMessage())
    }
    return result
  }
}

/// Silence auto-stop handle. `isSpeech`: true/false for a VAD hint, nil
/// for RMS-threshold classification.
public final class RustAutoStop {
  private var handle: OpaquePointer?

  public init() throws {
    guard let created = nd_autostop_new() else {
      throw RustEngineError(code: -1, message: lastErrorMessage())
    }
    handle = created
  }

  deinit { nd_autostop_free(handle) }

  public func feed(rms: Float, duration: Double, isSpeech: Bool?) throws -> Bool {
    let hint: Int32 = isSpeech.map { $0 ? 1 : 0 } ?? -1
    let code = nd_autostop_feed(handle, rms, duration, hint)
    guard code >= 0 else {
      throw RustEngineError(code: code, message: lastErrorMessage())
    }
    return code != 0
  }
}

/// Dictation session handle. Encodes the capture-readiness latch: the
/// recording-ready cue may only follow the first valid buffer of the
/// current generation. The native layer drives events; the engine gates
/// what the user may observe.
public final class RustSession {
  private var handle: OpaquePointer?

  public init() throws {
    guard let created = nd_session_new() else {
      throw RustEngineError(code: -1, message: lastErrorMessage())
    }
    handle = created
  }

  deinit { nd_session_free(handle) }

  /// Starts a new session; returns the new engine generation.
  public func start() throws -> UInt64 {
    let generation = nd_session_start(handle)
    guard generation != 0 else {
      throw RustEngineError(code: -1, message: lastErrorMessage())
    }
    return generation
  }

  public enum SessionEvent: UInt32 {
    case engineStarted = 0
    case firstBuffer = 1
    case engineFailed = 2
    case cancelled = 3
    case stopRequested = 4
    case transcriptionDone = 5
  }

  public func onEvent(_ event: SessionEvent, generation: UInt64) throws {
    let code = nd_session_event(handle, event.rawValue, generation)
    guard code == 0 else {
      throw RustEngineError(code: code, message: lastErrorMessage())
    }
  }

  public var isCaptureReady: Bool {
    nd_session_is_capture_ready(handle) > 0
  }

  /// At most once per session, only after capture readiness.
  public var shouldEmitReadyCue: Bool {
    nd_session_should_emit_ready_cue(handle) > 0
  }

  public var state: UInt32 {
    nd_session_state(handle)
  }
}
