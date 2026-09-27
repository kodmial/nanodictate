import Foundation

// MARK: - Digital input gain (AGC)

/// AGC input gain config.
///
/// Quiet speech sits well below normal levels, so STT gets weak signal. AGC
/// lifts current raw RMS toward `targetRmsDb`, capped by `maxGainDb`:
/// gain = clamp(target − current, 0, max). Gating is adaptive (issue #21):
/// only raw signal above the noise floor (+4 dB) and above -70 dBFS absolute
/// is amplified — steady noise at the floor never climbs toward speech level.
///
/// Applied to Float32 buffer AFTER 16 kHz/mono conversion, BEFORE Int16: level
/// meter and recording see the conditioned signal. VAD/autostop decisions use
/// the raw/pre-gain RMS, never the amplified value.
/// One-pole smoothing: fast attack (~25 ms) up, slow release (~300 ms) down;
/// peaks pass a bounded soft limiter to avoid hard-clipped plateaus.
public struct InputGainConfig: Equatable {
  /// Master switch; `false` passes buffer through untouched.
  /// Kill switch: NANODICTATE_GAIN_DISABLED=1. Default on per spec.
  public var enabled: Bool

  /// Target speech RMS in dBFS. Spec: −20 dBFS (speech −55…−40 lifted to −25…−18).
  public var targetRmsDb: Float

  /// Gain ceiling in dB: prevents 30×+ noise/hiss amplification.
  public var maxGainDb: Float

  /// Smoothing time constant on gain RISE, seconds (~25 ms).
  public var attackTime: TimeInterval

  /// Smoothing time constant on gain FALL, seconds (~300 ms).
  public var releaseTime: TimeInterval

  public init(
    enabled: Bool = true,
    targetRmsDb: Float = -20,
    maxGainDb: Float = 30,
    attackTime: TimeInterval = 0.025,
    releaseTime: TimeInterval = 0.300
  ) {
    self.enabled = enabled
    // Pathological config guard: target below full scale, ceiling 1…60 dB, τ > 0.
    self.targetRmsDb = min(max(targetRmsDb, -120), -1)
    self.maxGainDb = min(max(maxGainDb, 1), 60)
    self.attackTime = max(attackTime, 0.001)
    self.releaseTime = max(releaseTime, 0.001)
  }

  /// Defaults: enabled, −20 dBFS target, +30 dB ceiling, attack 25 ms, release 300 ms.
  public static let defaults = InputGainConfig()

  /// Env-based factory — config stamping from Agent without editing config files
  /// (same path as `NANODICTATE_AUTOSTOP_*` in `AutoStopConfig.fromEnvironment`).
  ///
  /// Empty env yields exactly `.defaults`. Overrides (all optional; invalid values
  /// ignored, default kept):
  ///   • `NANODICTATE_GAIN_DISABLED=1` (or `true`) — kill switch: AGC off, buffer passes untouched;
  ///   • `NANODICTATE_GAIN_TARGET_DB=-25` — target speech RMS in dBFS (below 0, above −120);
  ///   • `NANODICTATE_GAIN_MAX_DB=40` — gain ceiling in dB (1…60).
  public static func fromEnvironment(
    _ env: [String: String] = ProcessInfo.processInfo.environment
  ) -> InputGainConfig {
    var enabled = InputGainConfig.defaults.enabled
    var target = InputGainConfig.defaults.targetRmsDb
    var maxGain = InputGainConfig.defaults.maxGainDb
    if env["NANODICTATE_GAIN_DISABLED"].map(parseDisabledFlag) ?? false {
      enabled = false
    }
    if let raw = env["NANODICTATE_GAIN_TARGET_DB"], let value = Double(raw), value.isFinite,
      value < 0, value > -120
    {  // swiftlint:disable:this opening_brace
      target = Float(value)
    }
    if let raw = env["NANODICTATE_GAIN_MAX_DB"], let value = Double(raw), value.isFinite, value > 0,
      value <= 60
    {  // swiftlint:disable:this opening_brace
      maxGain = Float(value)
    }
    // Итог строится через init — НАСТОЯЩИЙ кламп (−120…−1 и 1…60) тот же,
    // что у прямых вызовов init: env не может нарушить инварианты конфига
    // (например `NANODICTATE_GAIN_MAX_DB=0.5` не задаст потолок ниже init-минимума).
    var base = InputGainConfig.defaults
    base.enabled = enabled
    return InputGainConfig(
      enabled: enabled,
      targetRmsDb: target,
      maxGainDb: maxGain,
      attackTime: base.attackTime,
      releaseTime: base.releaseTime
    )
  }

  private static func parseDisabledFlag(_ raw: String) -> Bool {
    raw == "1" || raw == "true" || raw == "TRUE"
  }
}

/// Input gain processor. Pure math over Float32 buffer, no audio hardware — fully unit-testable.
///
/// `apply` semantics: target gain from CURRENT (unamplified) RMS — dB shortfall to
/// `targetRmsDb`, capped by maxGainDb. Gating is adaptive (issue #21): amplify only
/// when raw RMS sits above the estimated noise floor (+4 dB) and above an absolute
/// minimum (-70 dBFS). Steady noise at the floor is never amplified; quiet speech
/// above the floor is, even when below the old fixed -50 dBFS threshold.
/// Actual gain chases target via one-pole: each sample shifts `currentGainDb` by α
/// of the gap (α from attack on rise, release on fall; τ in samples = seconds × sampleRate).
/// Post-gain samples pass a bounded soft limiter (no hard-clipped plateaus).
/// Returns RMS of AMPLIFIED buffer (post-limit) — feeds level metric and recording.
/// VAD/autostop decisions use the raw/pre-gain RMS, never this amplified value.
public final class InputGain {
  public let config: InputGainConfig

  /// Current smoothed gain in dB (0 = none). One-pole updated per sample inside
  /// `apply`; exposed for diagnostics and tests.
  public private(set) var currentGainDb: Float = 0

  /// Adaptive noise-floor estimate (raw RMS domain). Independent from the VAD
  /// tracker on purpose: AGC conditioning and speech detection stay separate.
  public private(set) var floorTracker = NoiseFloorTracker()

  /// Absolute minimum raw level that may be amplified (-70 dBFS). Below is
  /// digital silence, never amplified.
  public static let absoluteMinDb: Float = -70

  /// Gate margin above the noise floor in dB: raw must exceed floor by this.
  public static let gateMarginDb: Float = 4

  public init(config: InputGainConfig = .defaults) {
    self.config = config
  }

  /// Reset gain and floor estimate (new recording session).
  public func reset() {
    currentGainDb = 0
    floorTracker.reset()
  }

  /// Current noise floor (linear RMS) for diagnostics.
  public var noiseFloor: Float { floorTracker.floor }

  /// Whether raw RMS passes the adaptive amplification gate.
  public func shouldAmplify(rms: Float) -> Bool {
    guard config.enabled else { return false }
    let cleanRms = rms.isFinite ? min(max(rms, 0), 1) : 0
    guard AudioMetrics.dbfs(cleanRms) > Self.absoluteMinDb else { return false }
    let gate = floorTracker.floor * powf(10, Self.gateMarginDb / 20)
    return cleanRms > gate
  }

  /// Target gain for current RMS (dB): shortfall to `targetRmsDb`, range 0…maxGainDb.
  /// Returns 0 when disabled, below the absolute minimum, or at/below the
  /// adaptive floor gate — mic noise never amplified.
  public func targetGainDb(forRms rms: Float) -> Float {
    guard config.enabled else { return 0 }
    guard shouldAmplify(rms: rms) else { return 0 }
    let currentDb = AudioMetrics.dbfs(rms)
    return min(max(config.targetRmsDb - currentDb, 0), config.maxGainDb)
  }

  /// Applies gain to Float32 channel in place (pointer inout — avoids tap-buffer copy).
  ///
  /// - Parameters:
  ///   - channel: 16 kHz mono sample buffer, modified in place.
  ///   - frameLength: sample count in `channel`.
  ///   - rms: pre-gain RMS (linear 0…1) — target calc input.
  ///   - sampleRate: converts smoothing τ from seconds to samples (default 16000 — converter format).
  /// - Returns: RMS of AMPLIFIED buffer (0…1) — what actually reaches metric/recording.
  ///   Disabled AGC or empty buffer: `rms` unchanged.
  @discardableResult
  public func apply(
    to channel: UnsafeMutablePointer<Float>,
    frameLength: Int,
    rms: Float,
    sampleRate: Int = 16000
  ) -> Float {
    guard config.enabled, frameLength > 0 else { return rms }
    let rate = max(1, sampleRate)
    let duration = TimeInterval(frameLength) / TimeInterval(rate)
    // Adaptive gate on the raw/pre-gain RMS (decision and target with the prior
    // floor, then adapt). Below gate: passthrough + gain reset so release tails
    // never leak into silence/noise and lift it toward speech level.
    let gated = shouldAmplify(rms: rms)
    let target = gated ? targetGainDb(forRms: rms) : 0
    floorTracker.update(rms: rms.isFinite ? min(max(rms, 0), 1) : 0, duration: duration)
    guard gated else {
      currentGainDb = 0
      return rms
    }
    // One-pole α = 1 − e^(−dt/τ): τ seconds, dt samples → τ in samples = τ·sampleRate.
    let attackAlpha = 1 - exp(-1 / max(1, config.attackTime * Double(rate)))
    let releaseAlpha = 1 - exp(-1 / max(1, config.releaseTime * Double(rate)))

    // powf (transcendental) stays out of the per-sample loop: the linear factor
    // refreshes every `gainFactorRefreshSamples` samples while gainDb chases it
    // with one-pole steps — divergence stays within ΔgainDb over ≤64 samples
    // (~4 ms at 16 kHz), inaudible and invisible to RMS metrics. First sample
    // computes the factor immediately for exact start amplitude.
    let gainFactorRefreshSamples = 64

    var sum: Float = 0
    var factor = powf(10, currentGainDb / 20)
    var sinceFactorUpdate = gainFactorRefreshSamples
    for i in 0..<frameLength {
      // Smoothing direction: rise — fast attack, fall — slow release; 0 diff moves nothing.
      let alpha = Float(target > currentGainDb ? attackAlpha : releaseAlpha)
      currentGainDb += alpha * (target - currentGainDb)
      if sinceFactorUpdate >= gainFactorRefreshSamples {
        factor = powf(10, currentGainDb / 20)
        sinceFactorUpdate = 0
      }
      sinceFactorUpdate += 1
      let amplified = channel[i] * factor
      // Bounded soft limiter: compresses large transients toward ±1.0 instead
      // of flattening them into hard-clipped plateaus. Int16 below never clips.
      let limited = SoftLimiter.process(amplified)
      channel[i] = limited
      sum += limited * limited
    }
    return sqrt(sum / Float(frameLength))
  }

  /// Convenience wrapper over `apply(to:frameLength:rms:sampleRate:)` for tests and
  /// `[Float]` owners: mutates array in place, returns amplified RMS.
  @discardableResult
  public func apply(
    to samples: inout [Float],
    rms: Float,
    sampleRate: Int = 16000
  ) -> Float {
    samples.withUnsafeMutableBufferPointer { buf in
      guard let base = buf.baseAddress else { return rms }
      return apply(to: base, frameLength: buf.count, rms: rms, sampleRate: sampleRate)
    }
  }
}
