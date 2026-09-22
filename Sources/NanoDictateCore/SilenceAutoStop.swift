import Foundation

// MARK: - Автоостановка записи по непрерывной тишине (~3 c)

/// Auto-stop config: ~3 s of continuous silence = "user finished speaking,
/// awaiting result" — recording stops, recognition runs the same path as
/// manual double Alt+Alt.
///
/// Silence model — RMS with HYSTERESIS (two thresholds instead of one):
/// buffer with RMS ≥ speechRMSThreshold — speech; RMS < silenceRMSThreshold —
/// silence; level between (−58…−45 dBFS) is a gray zone where state does NOT
/// change (no classification jitter on quiet syllables / inter-word gaps of
/// quiet dictation).
///
/// Why thresholds differ from shared AudioMetrics.nearSilenceThreshold
/// (−50 dBFS): that threshold suits segmentation/VAD, which must catch
/// silence early and cut chunks on pauses, but as a STOP threshold it lies
/// INSIDE quiet-speech dynamics (real −48.6…−55 dBFS) — calm dictation got
/// cut off "after 3 seconds". Autostop owns the pair: silence only on the
/// real noise floor (−58 dBFS ≈ quiet samples, prod −82…−90), speech only on
/// confident signal (−45 dBFS and louder). The −58…−45 dBFS range is the
/// deliberate no-change band, tuned to the user's dynamics.
public struct AutoStopConfig: Equatable {
  // MARK: Значения по умолчанию (единый источник правды для конфига и детектора)

  /// Speech ≥ −45 dBFS (linear ≈ 0.00562): confident signal; quiet-speech
  /// peaks (−20…−35 dBFS) sit far above.
  public static let defaultSpeechRMSThreshold: Float = 0.00562

  /// Silence < −58 dBFS (linear ≈ 0.00126): real noise floor/pause. Below
  /// quiet-speech level — calm dictation never reads as silence.
  public static let defaultSilenceRMSThreshold: Float = 0.00126

  /// First 2 s after recording start don't accumulate silence (setup,
  /// breath before phrase — not "end of dictation").
  public static let defaultGracePeriod: TimeInterval = 2.0

  /// Speech gate: autostop impossible until ≥ 0.3 s of continuous speech —
  /// latched forever within the session.
  public static let defaultMinSpeechRun: TimeInterval = 0.3

  /// 3 s floor before autostop, independent of other thresholds — guards
  /// pathological configs with tiny requiredSilenceDuration.
  public static let defaultMinRecordingDuration: TimeInterval = 3.0

  /// Feature kill switch: `false` disables autostop completely (recording
  /// lives till manual Alt+Alt or the 60 s limit — pre-feature behavior).
  /// Escape hatch for noisy rooms / long dictation / PTT; default on.
  public var enabled: Bool

  /// Buffer RMS ≥ this → speech (resets silence).
  public var speechRMSThreshold: Float

  /// Buffer RMS strictly below → silence (consistent with
  /// `AudioMetrics.isNearSilence`: boundary favors sound). Between the two
  /// thresholds — hysteresis: buffer never changes classification.
  public var silenceRMSThreshold: Float

  /// Continuous-silence duration (s) required to fire. Feature spec: ~3 s;
  /// pauses < 3 s don't stop recording.
  public var requiredSilenceDuration: TimeInterval

  /// Buffers starting inside this window (s from audio start) don't
  /// accumulate silence.
  public var gracePeriod: TimeInterval

  /// Autostop won't fire until continuous speech reaches this duration (s)
  /// at least once per session.
  public var minSpeechRun: TimeInterval

  /// Recording duration floor (s) before autostop — hard, independent of
  /// other thresholds.
  public var minRecordingDuration: TimeInterval

  public init(
    enabled: Bool = true,
    speechRMSThreshold: Float = AutoStopConfig.defaultSpeechRMSThreshold,
    silenceRMSThreshold: Float = AutoStopConfig.defaultSilenceRMSThreshold,
    requiredSilenceDuration: TimeInterval = 3.0,
    gracePeriod: TimeInterval = AutoStopConfig.defaultGracePeriod,
    minSpeechRun: TimeInterval = AutoStopConfig.defaultMinSpeechRun,
    minRecordingDuration: TimeInterval = AutoStopConfig.defaultMinRecordingDuration
  ) {
    self.enabled = enabled
    // Hysteresis invariant: speech threshold never below silence threshold.
    self.speechRMSThreshold = max(speechRMSThreshold, silenceRMSThreshold)
    self.silenceRMSThreshold = silenceRMSThreshold
    self.requiredSilenceDuration = requiredSilenceDuration
    self.gracePeriod = gracePeriod
    self.minSpeechRun = minSpeechRun
    self.minRecordingDuration = minRecordingDuration
  }

  /// Defaults: on, −45/−58 dBFS, 3 s silence, 2 s grace, 0.3 s gate, 3 s floor.
  public static let defaults = AutoStopConfig()

  /// Env seal for config from Agent, without config-file edits (same path
  /// as `NANODICTATE_API_KEY` in `Config.swift`/`RetryProvider`). Empty env
  /// gives exactly `.defaults`. Overrides all optional; bad values ignored,
  /// default kept:
  ///   • `NANODICTATE_AUTOSTOP_DISABLED=1` (or `true`) — kill switch: no
  ///     pause ever stops recording;
  ///   • `NANODICTATE_AUTOSTOP_DURATION=5` — silence threshold, seconds,
  ///     strictly > 0;
  ///   • `NANODICTATE_AUTOSTOP_RMS=0.01` — SILENCE threshold, linear scale,
  ///     strictly > 0 (−58 dBFS ≈ 0.00126);
  ///   • `NANODICTATE_AUTOSTOP_SPEECH_RMS=0.02` — SPEECH threshold, linear
  ///     scale, strictly > 0 (−45 dBFS ≈ 0.00562).
  /// Speech always clamps up to the silence threshold (hysteresis invariant
  /// holds for any key combination). Provider/config-file values untouched.
  public static func fromEnvironment(
    _ env: [String: String] = ProcessInfo.processInfo.environment
  ) -> AutoStopConfig {
    var config = AutoStopConfig.defaults
    if env["NANODICTATE_AUTOSTOP_DISABLED"].map(parseDisabledFlag) ?? false {
      config.enabled = false
    }
    if let raw = env["NANODICTATE_AUTOSTOP_DURATION"], let duration = Double(raw),
      duration.isFinite, duration > 0
    {  // swiftlint:disable:this opening_brace
      config.requiredSilenceDuration = duration
    }
    if let raw = env["NANODICTATE_AUTOSTOP_RMS"], let value = Float(raw), value.isFinite, value > 0
    {  // swiftlint:disable:this opening_brace
      config.silenceRMSThreshold = value
    }
    if let raw = env["NANODICTATE_AUTOSTOP_SPEECH_RMS"], let value = Float(raw), value.isFinite,
      value > 0
    {  // swiftlint:disable:this opening_brace
      config.speechRMSThreshold = value
    }
    // Invariant: speech cannot be recognized quieter than silence.
    if config.speechRMSThreshold < config.silenceRMSThreshold {
      config.speechRMSThreshold = config.silenceRMSThreshold
    }
    return config
  }

  private static func parseDisabledFlag(_ raw: String) -> Bool {
    raw == "1" || raw == "true" || raw == "TRUE"
  }
}

/// Pure autostop detector: accumulates CONTINUOUS silence, shielded against
/// false triggers (hysteresis, grace, speech gate, min recording duration).
/// No I/O — math only, fully unit-testable.
///
/// Fed from the recording loop (AudioService.process): per buffer its RMS
/// (0...1, as in level metrics) and its REAL duration (converted frames /
/// 16000). Accumulation counts actual duration, not buffer count: callback
/// frequency tracks the hardware sample rate (~85 ms @ 48 kHz, ~93 ms
/// @ 44.1 kHz, ~256 ms @ 16 kHz) — "3 seconds" measure by time, not buffers.
///
/// Decision model (see AutoStopConfig):
///   • SPEECH (RMS ≥ speech threshold): resets the silence accumulator,
///     grows the speech run for the gate. One speech buffer breaks silence.
///   • SILENCE (RMS < silence threshold): accumulates, but only outside
///     grace and as a continuous run (any speech buffer resets — inter-word
///     pauses don't sum).
///   • GRAY ZONE (between thresholds): hysteresis — classification state
///     unchanged (no accumulation, no reset).
///
/// Result semantics: `feed` returns true when ALL conditions hold (speech
/// gate passed + recording ≥ minRecordingDuration + accumulated CONTINUOUS
/// silence ≥ requiredSilenceDuration); stays true on later quiet buffers
/// until speech or `reset()`. The one-shot latch lives outside
/// (AudioService marks the stop scheduled); the detector only answers
/// honestly "is silence ≥ threshold or not".
public struct SilenceAutoStopDetector {
  public let speechRMSThreshold: Float

  public let silenceRMSThreshold: Float

  public let requiredSilenceDuration: TimeInterval

  public let gracePeriod: TimeInterval

  public let minSpeechRun: TimeInterval

  public let minRecordingDuration: TimeInterval

  /// Accumulated CONTINUOUS silence (s); readable for diagnostics and tests.
  public private(set) var silenceDuration: TimeInterval

  /// Total audio time fed to the detector (s) — "recording duration".
  public private(set) var elapsed: TimeInterval

  /// Current continuous speech run (s). Gray zone doesn't reset it —
  /// quiet syllables don't break the run.
  public private(set) var speechRun: TimeInterval

  /// "Speech happened" gate: latched when the run reaches `minSpeechRun`.
  /// Autostop impossible before the first latch within a session.
  public private(set) var speechGatePassed: Bool

  public init(
    silenceRMSThreshold: Float = AutoStopConfig.defaultSilenceRMSThreshold,
    speechRMSThreshold: Float = AutoStopConfig.defaultSpeechRMSThreshold,
    requiredSilenceDuration: TimeInterval = 3.0,
    gracePeriod: TimeInterval = AutoStopConfig.defaultGracePeriod,
    minSpeechRun: TimeInterval = AutoStopConfig.defaultMinSpeechRun,
    minRecordingDuration: TimeInterval = AutoStopConfig.defaultMinRecordingDuration
  ) {
    // Hysteresis invariant: speech threshold never below silence threshold.
    self.speechRMSThreshold = max(speechRMSThreshold, silenceRMSThreshold)
    self.silenceRMSThreshold = silenceRMSThreshold
    self.requiredSilenceDuration = requiredSilenceDuration
    self.gracePeriod = gracePeriod
    self.minSpeechRun = minSpeechRun
    self.minRecordingDuration = minRecordingDuration
    silenceDuration = 0
    elapsed = 0
    speechRun = 0
    speechGatePassed = false
  }

  /// Feeds the detector one buffer.
  ///
  /// - Parameters:
  ///   - rms: linear buffer RMS (0...1). Strictly below silenceRMSThreshold —
  ///     silence; ≥ speechRMSThreshold — speech; between the thresholds —
  ///     state unchanged (hysteresis).
  ///   - duration: real buffer duration in seconds. Negative duration
  ///     clamps to 0 — accumulation never goes backward.
  /// - Returns: true when all stop conditions hold: speech gate passed,
  ///   recording ≥ `minRecordingDuration`, accumulated CONTINUOUS silence ≥
  ///   `requiredSilenceDuration`. Stays true on later quiet/neutral buffers
  ///   until speech or `reset()` resets the accumulator.
  @discardableResult
  public mutating func feed(rms: Float, duration: TimeInterval) -> Bool {
    let effectiveDuration = max(0, duration)
    // Buffer starting inside grace: no silence accumulation, but speech still
    // counts — the gate can pass within grace.
    let bufferStartsInGrace = elapsed < gracePeriod
    elapsed += effectiveDuration

    if rms >= speechRMSThreshold {
      // Speech: silence continuity broken, accumulator reset; speech run grows,
      // latches the gate at minSpeechRun.
      speechRun += effectiveDuration
      if !speechGatePassed, speechRun >= minSpeechRun {
        speechGatePassed = true
      }
      silenceDuration = 0
    } else if rms < silenceRMSThreshold {
      // Silence: speech continuity broken; accumulates only outside grace, as a
      // continuous run.
      speechRun = 0
      if !bufferStartsInGrace {
        silenceDuration += effectiveDuration
      }
    }
    // Between thresholds — hysteresis: no accumulation, no reset — quiet
    // syllables don't jitter classification.

    return canStop
  }

  /// All stop conditions: speech once present, recording ≥ floor, continuous
  /// silence reached the threshold.
  private var canStop: Bool {
    guard speechGatePassed else { return false }
    guard elapsed >= minRecordingDuration else { return false }
    return silenceDuration >= requiredSilenceDuration
  }

  public mutating func reset() {
    silenceDuration = 0
    elapsed = 0
    speechRun = 0
    speechGatePassed = false
  }
}
