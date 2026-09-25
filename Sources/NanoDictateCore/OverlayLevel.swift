import CoreGraphics
import Foundation

// MARK: - Чистая логика VU-отображения уровня звука (оверлей «Halo»)

/// Pure VU meter math: RMS remap, ballistics, hot zone, stroke width. No I/O — unit-tested.
public enum OverlayLevel {
  /// Meter scale floor: −50 dBFS → 0; ceiling 0 dBFS → 1.
  public static let floordB: Float = -50

  /// Attack time: meter reaches target in ~70 ms.
  public static let attackTime: TimeInterval = 0.07

  /// Release τ ≈ 0.5 s: at ~11 Hz tick ≈ ×0.83 — smooth but visible, per spec ~×0.9/tick.
  public static let releaseTime: TimeInterval = 0.5

  /// Hot zone threshold (dBFS): above it feedback warms.
  public static let hotThresholddB: Float = -6

  /// Hot threshold in meters, derived from dBFS (−6 dBFS → 0.88).
  public static var hotMeterThreshold: Float {
    (hotThresholddB - floordB) / -floordB  // (−6 − (−50))/50 = 0.88
  }

  /// Linear RMS → meter on −50…0 dBFS scale; same scale as AudioMetrics.nearSilenceThreshold.
  public static func meter(fromRMS rms: Float) -> Float {
    guard rms > 0 else { return 0 }
    let decibels = 20 * log10(rms)
    return min(max((decibels - floordB) / -floordB, 0), 1)
  }

  /// Inverse scale: dBFS for given meter; used by tests and logs.
  public static func dbfs(forMeter meter: Float) -> Float {
    floordB + min(max(meter, 0), 1) * -floordB
  }

  /// Hot zone: above −6 dBFS (meter > 0.88) — ring warms.
  public static func isHot(meter: Float) -> Bool {
    meter > hotMeterThreshold
  }

  /// VU ballistics for dt: higher target → linear attack; else exp release. Clamped 0…1.
  public static func enveloped(current: Float, target: Float, dt delta: TimeInterval) -> Float {
    let current = min(max(current, 0), 1)
    let target = min(max(target, 0), 1)
    if target > current {
      let step = Float(delta / attackTime)
      return min(target, current + step * (target - current))
    }
    let decayed = current * Float(exp(-delta / releaseTime))
    return max(target, decayed)
  }

  /// Ring stroke width: grows 3…9 pt with level.
  public static func strokeWidth(forMeter meter: Float) -> CGFloat {
    CGFloat(3 + min(max(meter, 0), 1) * 6)
  }
}

/// Peak follower: holds max ~holdTime, decays after. Ring dot keeps brief spikes visible.
public struct OverlayPeak: Equatable {
  /// Seconds peak holds max before decay.
  public static let holdTime: TimeInterval = 0.8

  /// Linear decay rate (units/s): 1.0 → 0 in ~1.4 s.
  public static let fallRate: Float = 0.7

  /// Peak value, 0…1.
  public private(set) var value: Float = 0
  private var holdRemaining: TimeInterval = 0

  public init() {}

  /// Step dt: new max held holdTime; below — hold then decay. Returns peak.
  public mutating func update(level: Float, dt delta: TimeInterval) -> Float {
    let level = min(max(level, 0), 1)
    if level > value {
      value = level
      holdRemaining = Self.holdTime
    } else if holdRemaining > 0 {
      holdRemaining -= delta
    } else if value > 0 {
      value = max(0, value - Self.fallRate * Float(delta))
    }
    return value
  }

  /// Reset to zero (new session / overlay hide).
  public mutating func reset() {
    value = 0
    holdRemaining = 0
  }
}
