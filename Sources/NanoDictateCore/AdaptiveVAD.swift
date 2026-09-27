import Foundation

// MARK: - Adaptive speech detection (issue #21)

// Decouples VAD from AGC: speech decisions run on the raw/pre-gain signal
// with an adaptive noise-floor tracker plus hysteresis. Lightweight enough
// for Intel macOS 12 (a few flops per audio buffer, no allocations).

/// Adaptive noise-floor tracker over raw RMS.
///
/// Asymmetric one-pole follower: fast down (quiet gaps pull the floor down
/// quickly), slow up (speech bursts barely move it). This separates steady
/// background noise (floor rises to meet it) from speech (short loud bursts
/// above the floor).
public struct NoiseFloorTracker: Equatable {
  /// Current floor estimate, linear RMS 0...1.
  public private(set) var floor: Float
  /// Absolute floor bounds to avoid pathological sensitivity.
  public let minFloor: Float
  public let maxFloor: Float
  /// Time constant for downward adaptation (seconds).
  public let downTau: TimeInterval
  /// Time constant for upward adaptation (seconds).
  public let upTau: TimeInterval

  public init(
    initialFloor: Float = 0.001,
    minFloor: Float = 0.0001,
    maxFloor: Float = 0.02,
    downTau: TimeInterval = 0.4,
    upTau: TimeInterval = 3.0
  ) {
    self.minFloor = minFloor
    self.maxFloor = maxFloor
    self.downTau = max(downTau, 0.01)
    self.upTau = max(upTau, 0.1)
    let clamped = min(max(initialFloor, minFloor), maxFloor)
    self.floor = clamped
  }

  /// Advances the floor estimate with one buffer RMS and its duration.
  /// Returns the new floor. Deterministic, no I/O.
  ///
  /// dB-domain one-pole: loud speech bursts (tens of dB above the floor) move
  /// the linear floor only slightly per buffer, so short utterances never drag
  /// thresholds up (resampler ringing after speech still reads as speech);
  /// sustained noise converges over seconds. Down is fast (quiet gaps), up is
  /// slow (speech barely moves it).
  @discardableResult
  public mutating func update(rms: Float, duration: TimeInterval) -> Float {
    let dt = max(0, duration)
    guard dt > 0, rms.isFinite else { return floor }
    let cleanRms = min(max(rms, 0), 1)
    let floorDb = AudioMetrics.dbfs(floor)
    let rmsDb = AudioMetrics.dbfs(cleanRms)
    let tau = rmsDb < floorDb ? downTau : upTau
    let alpha = 1 - exp(-dt / tau)
    let newDb = floorDb + Float(alpha) * (rmsDb - floorDb)
    let newLinear = powf(10, newDb / 20)
    floor = min(max(newLinear, minFloor), maxFloor)
    return floor
  }

  public mutating func reset(to value: Float? = nil) {
    if let value, value.isFinite {
      floor = min(max(value, minFloor), maxFloor)
    } else {
      floor = min(max(0.001, minFloor), maxFloor)
    }
  }
}

/// Adaptive VAD configuration.
///
/// Thresholds are relative to the noise floor:
/// enter = floor + enterMarginDb, exit = enter - hysteresisDb.
/// Absolute clamps keep behavior sane in very quiet or very loud rooms.
public struct AdaptiveVADConfig: Equatable {
  /// Speech entry margin above the noise floor in dB.
  public var enterMarginDb: Float
  /// Hysteresis width in dB (exit = enter - hysteresis).
  public var hysteresisDb: Float
  /// Absolute bounds for the enter threshold in dBFS.
  public var minEnterDb: Float
  public var maxEnterDb: Float

  public init(
    enterMarginDb: Float = 8,
    hysteresisDb: Float = 4,
    minEnterDb: Float = -60,
    maxEnterDb: Float = -25
  ) {
    self.enterMarginDb = enterMarginDb
    self.hysteresisDb = max(1, hysteresisDb)
    self.minEnterDb = minEnterDb
    self.maxEnterDb = max(maxEnterDb, minEnterDb)
  }

  public static let defaults = AdaptiveVADConfig()
}

/// Stateful adaptive voice activity detector.
///
/// Fed with raw/pre-gain RMS per buffer. Hysteresis prevents threshold
/// chatter: silence -> speech needs RMS >= enter, speech -> silence needs
/// RMS < exit (exit < enter). Short impulsive bursts still read as momentary
/// speech (they are loud) but collapse back to silence on the next quiet
/// buffers without latching; steady noise raises the floor so it stops
/// crossing enter.
public struct AdaptiveVAD: Equatable {
  public var config: AdaptiveVADConfig
  public var tracker: NoiseFloorTracker
  /// Current speech state. Starts in silence.
  public private(set) var isSpeech: Bool

  public init(
    config: AdaptiveVADConfig = .defaults,
    tracker: NoiseFloorTracker = NoiseFloorTracker()
  ) {
    self.config = config
    self.tracker = tracker
    self.isSpeech = false
  }

  /// Current noise floor (linear RMS).
  public var noiseFloor: Float { tracker.floor }

  /// Current enter threshold (linear RMS).
  public var enterThreshold: Float {
    threshold(enterDb: enterDb)
  }

  /// Current exit threshold (linear RMS, strictly below enter).
  public var exitThreshold: Float {
    threshold(enterDb: enterDb - config.hysteresisDb)
  }

  private var enterDb: Float {
    let floorDb = AudioMetrics.dbfs(tracker.floor)
    let raw = floorDb + config.enterMarginDb
    return min(max(raw, config.minEnterDb), config.maxEnterDb)
  }

  private func threshold(enterDb db: Float) -> Float {
    // dBFS -> linear: 10^(db/20). Clamp to valid RMS range.
    let linear = powf(10, db / 20)
    return min(max(linear, 0.00001), 1)
  }

  /// Feeds one buffer. Decision uses the prior floor, then the floor adapts
  /// to the observation (asymmetric taus keep speech from dragging the floor).
  /// Returns the new speech state.
  @discardableResult
  public mutating func update(rms: Float, duration: TimeInterval) -> Bool {
    let cleanRms = rms.isFinite ? min(max(rms, 0), 1) : 0
    let enter = enterThreshold
    let exit = exitThreshold
    // Relative tolerance for the enter comparison: a level sitting exactly on
    // the threshold (for example -52 dBFS speech vs a computed -52 dBFS enter)
    // must read as speech despite Float rounding of 10^(db/20).
    let enterWithTolerance = enter * 0.999
    if isSpeech {
      if cleanRms < exit {
        isSpeech = false
      }
    } else {
      if cleanRms >= enterWithTolerance {
        isSpeech = true
      }
    }
    _ = tracker.update(rms: cleanRms, duration: duration)
    return isSpeech
  }

  public mutating func reset() {
    isSpeech = false
    tracker.reset()
  }
}

// MARK: - Soft limiter for speech (issue #21)

// Bounded soft knee above 0.8: linear below, exponential compression toward
// 1.0 above. Normal speech peaks pass untouched; large transients after big
// gain steps compress instead of flattening into hard-clipped plateaus.
// Only loud samples pay the exp() cost; quiet buffers stay linear and cheap.
public enum SoftLimiter {
  /// Knee point: linear below, compressed above.
  public static let knee: Float = 0.8

  /// Soft-limits one sample to (-1, 1) without a hard plateau.
  public static func process(_ x: Float) -> Float {
    let ax = abs(x)
    guard ax > knee else { return x }
    let sign: Float = x >= 0 ? 1 : -1
    let excess = (ax - knee) / (1 - knee)
    let compressed = 1 - expf(-excess)
    return sign * (knee + (1 - knee) * compressed)
  }
}
