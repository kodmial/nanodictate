import Foundation

// MARK: - Цифровое усиление входного сигнала (AGC)

/// AGC input gain config.
///
/// Speech sits at −55…−40 dBFS — 2–3× quieter than normal −25…−18 dBFS, so STT
/// gets weak signal. AGC lifts current RMS toward `targetRmsDb`, capped by
/// `maxGainDb`: gain = clamp(target − current, 0, max). Silence (≤ −50 dBFS)
/// never amplified — mic noise must not confuse VAD/autostop.
///
/// Applied to Float32 buffer AFTER 16 kHz/mono conversion, BEFORE Int16: all
/// consumers (level meter, live-VAD, autostop, WAV) see amplified signal.
/// One-pole smoothing: fast attack (~25 ms) up, slow release (~300 ms) down;
/// peaks clamped to [−1.0, 1.0] to avoid Int16 clipping.
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
/// `targetRmsDb`, capped by maxGainDb, zero at/below silence threshold (−50 dBFS).
/// Actual gain chases target via one-pole: each sample shifts `currentGainDb` by α
/// of the gap (α from attack on rise, release on fall; τ in samples = seconds × sampleRate).
/// Post-gain sample clamped to [−1.0, 1.0]. Returns RMS of AMPLIFIED buffer
/// (post-clamp) — feeds level metric, live-VAD and autostop.
public final class InputGain {
  public let config: InputGainConfig

  /// Current smoothed gain in dB (0 = none). One-pole updated per sample inside
  /// `apply`; exposed for diagnostics and tests.
  public private(set) var currentGainDb: Float = 0

  public init(config: InputGainConfig = .defaults) {
    self.config = config
  }

  /// Reset gain to zero (new recording session): first buffer must not start from
  /// previous recording's residual gain.
  public func reset() {
    currentGainDb = 0
  }

  /// Target gain for current RMS (dB): shortfall to `targetRmsDb`, range 0…maxGainDb.
  /// Silence (≤ −50 dBFS) or disabled switch give 0 — mic noise never amplified.
  public func targetGainDb(forRms rms: Float) -> Float {
    guard config.enabled else { return 0 }
    let currentDb = AudioMetrics.dbfs(rms)
    // Near-silence threshold — codebase-wide constant (−50 dBFS). Amplify only
    // above it: else background noise would climb toward speech level and
    // confuse VAD/autostop.
    guard currentDb > AudioMetrics.dbfs(AudioMetrics.nearSilenceThreshold) else { return 0 }
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
    // Silence (≤ −50 dBFS) NEVER amplified: without this guard even smoothed gain
    // would leak into silence via release tail (~0.3 s), lifting noise and confusing
    // VAD/autostop. Silence = passthrough + gain reset: pause breaks context, next
    // speech attacks from zero.
    guard AudioMetrics.dbfs(rms) > AudioMetrics.dbfs(AudioMetrics.nearSilenceThreshold) else {
      currentGainDb = 0
      return rms
    }
    let target = targetGainDb(forRms: rms)
    // One-pole α = 1 − e^(−dt/τ): τ seconds, dt samples → τ in samples = τ·sampleRate.
    let rate = max(1, sampleRate)
    let attackAlpha = 1 - exp(-1 / max(1, config.attackTime * Double(rate)))
    let releaseAlpha = 1 - exp(-1 / max(1, config.releaseTime * Double(rate)))

    // powf (транcцендент) выносится из per-sample цикла: коэффициент
    // пересчитывается раз в `gainFactorRefreshSamples` сэмплов, между
    // пересчётами плавающий gainDb догоняет его линейным one-pole — расхождение
    // с точным per-sample вариантом ограничено ΔgainDb за ≤64 сэмпла (~4 мс
    // на 16 кГц), на слух и для RMS-метрики неотличимо. Первый сэмпл считает
    // коэффициент сразу (sinceUpdate == лимит) — стартовая амплитуда точная.
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
      // Peak clamp: amplified sample stays in [−1.0, 1.0] — Int16 conversion below never clips.
      let clamped = min(max(amplified, -1), 1)
      channel[i] = clamped
      sum += clamped * clamped
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
