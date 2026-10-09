import Foundation
import NanoDictateRustBridge

// MARK: - RustRealtimeAudio: shipping realtime audio composition (#133)
//
// The default production audio path executes its realtime-safe,
// OS-independent signal processing through the shared Rust engine
// (`nanodictate-core`): per-block raw RMS (audio metrics), adaptive VAD
// on the raw/pre-gain signal, AGC input gain applied in place, and the
// silence auto-stop decision fed with the VAD hint. Offline portable
// segmentation/chunk-boundary math lives behind the same engine
// (`RustEngine.livePlan` / `RustEngine.batchChunkRanges`).
//
// Host-owned and intentionally native (never in Rust): AVAudioEngine
// capture, AVAudioConverter resampling, device handling, permissions,
// session lifecycle, the live pause/chunk state machine, and PCM staging.
// The FFI is block-oriented only: one RMS call, one VAD feed, one
// in-place gain call, and one auto-stop feed per audio block — no
// per-sample calls, no network work, no unbounded waits, and no
// allocation on the realtime callback.
//
// The Swift reference implementations (`AdaptiveVAD`, `InputGain`,
// `SilenceAutoStopDetector`, `AudioMetrics`, `AudioSegmenter`) are
// retained as parity oracles until the final hardware gate in #123
// removes them. They never run on the shipping path: every engine
// failure here throws loudly so the session fails closed instead of
// silently falling back to Swift.
//
// Threading mirrors the Swift objects this replaces: the handles are
// confined to the audio thread while a session is recording (created at
// session reset, dropped at session end); reset runs only when no
// session is live. The caller serializes calls, exactly like the Swift
// values before.

/// Shipping realtime audio composition over the shared engine: VAD plus
/// AGC plus auto-stop driven with one block-oriented call each.
public final class RustRealtimeAudio {
  private let vad: RustVAD
  private let gain: RustInputGain
  private let autoStop: RustAutoStop
  private let autoStopEnabled: Bool

  /// Builds the composition from the host policy configs. Any handle
  /// failure throws loudly — the caller fails the dictation start
  /// instead of silently running a Swift-only session.
  public init(
    gainConfig: InputGainConfig,
    vadConfig: AdaptiveVADConfig,
    autoStopConfig: AutoStopConfig
  ) throws {
    vad = try RustVAD(
      enterMarginDb: vadConfig.enterMarginDb,
      hysteresisDb: vadConfig.hysteresisDb,
      minEnterDb: vadConfig.minEnterDb,
      maxEnterDb: vadConfig.maxEnterDb
    )
    gain = try RustInputGain(
      enabled: gainConfig.enabled,
      targetRmsDb: gainConfig.targetRmsDb,
      maxGainDb: gainConfig.maxGainDb,
      attackTime: gainConfig.attackTime,
      releaseTime: gainConfig.releaseTime
    )
    autoStop = try RustAutoStop(
      speechRMS: autoStopConfig.speechRMSThreshold,
      silenceRMS: autoStopConfig.silenceRMSThreshold,
      requiredSilence: autoStopConfig.requiredSilenceDuration,
      grace: autoStopConfig.gracePeriod,
      minSpeechRun: autoStopConfig.minSpeechRun,
      minRecording: autoStopConfig.minRecordingDuration
    )
    autoStopEnabled = autoStopConfig.enabled
  }

  /// One realtime block: raw RMS (engine metrics) on the pre-gain
  /// signal, then the adaptive VAD decision on that raw value, then AGC
  /// applied to the block in place. Returns the raw RMS (drives
  /// auto-stop and diagnostics, never the amplified value), the VAD
  /// speech flag, and the amplified RMS (drives the level meter and the
  /// recording). Throws loudly on any engine error — the caller drops
  /// the block instead of processing it in Swift.
  public struct IngestOutcome: Equatable {
    public let rawRMS: Float
    public let isSpeech: Bool
    public let amplifiedRMS: Float

    public init(rawRMS: Float, isSpeech: Bool, amplifiedRMS: Float) {
      self.rawRMS = rawRMS
      self.isSpeech = isSpeech
      self.amplifiedRMS = amplifiedRMS
    }
  }

  public func ingest(
    channel: UnsafeMutablePointer<Float>?,
    frameLength: Int,
    sampleRate: UInt32
  ) throws -> IngestOutcome {
    let duration =
      frameLength > 0 ? Double(frameLength) / Double(max(1, sampleRate)) : 0
    let rawRMS = rustRMSf32Block(UnsafePointer(channel), count: frameLength)
    guard rawRMS >= 0 else {
      throw RustEngineError(
        code: -1, message: "engine RMS block failed: \(lastErrorMessage())")
    }
    let isSpeech = try vad.feed(rms: rawRMS, duration: duration)
    let amplified = try gain.applyBlock(
      channel, count: frameLength, rms: rawRMS, sampleRate: sampleRate)
    return IngestOutcome(rawRMS: rawRMS, isSpeech: isSpeech, amplifiedRMS: amplified)
  }
  /// Feeds one block to the silence auto-stop detector with the VAD
  /// speech hint from `ingest`. Honors the host kill switch: a disabled
  /// feature never fires. Returns true once all stop conditions hold.
  /// Throws loudly on engine errors.
  public func feedAutoStop(rms: Float, duration: Double, isSpeech: Bool) throws -> Bool {
    guard autoStopEnabled else { return false }
    return try autoStop.feed(rms: rms, duration: duration, isSpeech: isSpeech)
  }

  /// Current smoothed AGC gain in dB (0 = none) for diagnostics.
  public var currentGainDb: Float { gain.currentGainDb }

  /// Live VAD diagnostics (noise floor, thresholds, speech flag) for the
  /// level meter and debug logs. Read-only; never disturbs the detector.
  public func vadDiagnostics() throws -> RustVAD.Diagnostics {
    try vad.diagnostics()
  }

  /// Resets all three detectors for a new session. Runs only when no
  /// session is live (same confinement as the Swift values before).
  public func reset() throws {
    try vad.reset()
    try gain.reset()
    try autoStop.reset()
  }
}

// MARK: - Realtime callback instrumentation (#133)

/// Snapshot of shipping-path realtime audio instrumentation: callback
/// overhead, block/error counts, and the worst observed block. Timing
/// covers the engine block calls (RMS plus VAD plus gain) measured on
/// the host around the bridge, matching
/// `docs/architecture-rust-engine.md`. Copies are structural (the tap
/// path reuses its conversion buffer and staging); this snapshot proves
/// the block count the engine actually served.
public struct RealtimeAudioStats: Equatable {
  /// Engine-ingested blocks since the service was created (cumulative
  /// across sessions; a new session never resets shipping proof).
  public var blocks: Int
  /// Blocks dropped on engine errors (fail-closed; never Swift-processed).
  public var engineErrors: Int
  /// Total engine block nanos across all sessions.
  public var totalNanos: UInt64
  /// Worst single engine block in nanos.
  public var maxNanos: UInt64

  public init(
    blocks: Int = 0, engineErrors: Int = 0, totalNanos: UInt64 = 0, maxNanos: UInt64 = 0
  ) {
    self.blocks = blocks
    self.engineErrors = engineErrors
    self.totalNanos = totalNanos
    self.maxNanos = maxNanos
  }

  /// Mean engine block cost in milliseconds (0 with no blocks).
  public var meanBlockMs: Double {
    guard blocks > 0 else { return 0 }
    return Double(totalNanos) / Double(blocks) / 1_000_000.0
  }

  /// Worst engine block cost in milliseconds.
  public var maxBlockMs: Double {
    Double(maxNanos) / 1_000_000.0
  }
}
