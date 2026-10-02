import Foundation
import NanoDictateRustBridge

// MARK: - RustEngine: composition seam between Swift and the shared engine
//
// Migration status (see docs/architecture-rust-engine.md): the shared Rust
// engine (`nanodictate-core`) implements the deterministic product logic,
// the Swift bridge (`NanoDictateRustBridge`) exposes it, and this seam
// connects both to the native macOS layer.
//
// Existing production call sites still use the Swift reference
// implementations until the macOS hardware parity gate passes; the switch
// happens one subsystem at a time after equivalent output is demonstrated
// on shared input vectors (Tests/NanoDictateCoreTests/RustParityTests.swift
// runs the same vectors against both implementations in CI).
//
// New code that needs deterministic shared behavior should enter through
// this seam so the cutover is a call-site change, not a redesign.

/// Entry points into the shared Rust engine for native macOS code.
public enum RustEngine {
  /// The linked engine speaks the ABI this bridge was built for.
  /// Checked once at startup; a mismatch is a hard integration error.
  public static func checkAvailable() throws {
    try assertEngineABIVersion()
  }

  /// Word-level diff between inserted (`old`) and final (`new`) text.
  /// Engine equivalent of `WordDiff.change` (see `RustWordDiff.change`).
  public static func wordDiff(old: String, new: String) throws -> RustWordDiff {
    try rustWordDiff(old: old, new: new)
  }

  /// Encodes Int16 samples as 16-bit PCM WAV.
  /// Engine equivalent of `WAVEncoder.encode`.
  public static func wavEncode(
    samples: [Int16], sampleRate: UInt32, channels: UInt16
  ) throws -> Data {
    try rustWAVEncode(samples: samples, sampleRate: sampleRate, channels: channels)
  }

  /// Reads WAV header metadata without copying samples.
  /// Engine equivalent of `WAVDecoder.pcmHeader`.
  public static func wavInfo(_ data: Data) throws -> RustWAVInfo {
    try rustWAVDecodeInfo(data)
  }

  /// Joins chunk texts with boundary-overlap dedup.
  /// Engine equivalent of `BatchTextJoiner.join`.
  public static func joinChunkTexts(_ texts: [String]) throws -> String {
    try rustTextJoin(texts)
  }

  /// Resolves the model profile for an (adapter id, model) pair as JSON.
  /// Engine equivalent of `STTModelRegistry.resolve`.
  public static func resolveSTTProfile(adapterID: String, model: String) throws -> String {
    try rustSTTResolve(adapterID: adapterID, model: model)
  }

  /// Parses an STT response body into `{"text":...,"words":[...]}` JSON.
  public static func parseTranscript(body: String, path: String? = nil) throws -> String {
    try rustTranscriptParse(body: body, path: path)
  }

  /// Orders failover candidates as id lists.
  /// Engine equivalent of the `RetryProvider` queue policy.
  public static func failoverOrder(
    ids: [String], failedID: String?, autoFailover: Bool
  ) throws -> [String] {
    try rustFailoverOrder(ids: ids, failedID: failedID, autoFailover: autoFailover)
  }
}
