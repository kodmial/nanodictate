import AVFoundation
import Foundation

// MARK: - Статус доступа к микрофону (TCC)

/// Mic permission label for agent.log; `notDetermined` reveals periodically lost TCC grants.
public enum MicrophoneAuth {
  public static func statusText(_ status: AVAuthorizationStatus) -> String {
    switch status {
    case .authorized:
      return "granted"
    case .denied:
      return "denied"
    case .notDetermined:
      return "notDetermined"
    case .restricted:
      return "restricted"
    @unknown default:
      return "unknown(\(status.rawValue))"
    }
  }
}

// MARK: - Метрики уровня записи (RMS)

/// Recording level metrics over RMS history: min/avg/max (0…1) + near-silence flag.
public struct RecordingMetrics: Equatable {
  public let minRMS: Float
  public let avgRMS: Float
  public let maxRMS: Float
  /// Avg RMS below AudioMetrics.nearSilenceThreshold.
  public let nearSilence: Bool

  public init(minRMS: Float, avgRMS: Float, maxRMS: Float, nearSilence: Bool) {
    self.minRMS = minRMS
    self.avgRMS = avgRMS
    self.maxRMS = maxRMS
    self.nearSilence = nearSilence
  }
}

/// Pure recording-level math: RMS summary, Int16 RMS, silence threshold. No I/O — unit-tested.
public enum AudioMetrics {
  /// Near-silence VAD threshold (≈ 0.00316 = −50 dBFS): below is mic noise, not speech.
  public static let nearSilenceThreshold: Float = 0.00316  // −50 dBFS

  /// Linear amplitude → dBFS: 1.0 → 0, 0.1 → −20; zero → −120 dBFS floor.
  public static func dbfs(_ linear: Float) -> Float {
    linear > 0 ? 20 * log10(linear) : -120
  }

  /// RMS history summary; empty history → zeros, nearSilence false (nothing to judge).
  public static func summarize(
    rmsValues: [Float],
    threshold: Float = nearSilenceThreshold
  ) -> RecordingMetrics {
    guard !rmsValues.isEmpty else {
      return RecordingMetrics(minRMS: 0, avgRMS: 0, maxRMS: 0, nearSilence: false)
    }
    let minRMS = rmsValues.min() ?? 0
    let maxRMS = rmsValues.max() ?? 0
    let avgRMS = rmsValues.reduce(0, +) / Float(rmsValues.count)
    return RecordingMetrics(
      minRMS: minRMS,
      avgRMS: avgRMS,
      maxRMS: maxRMS,
      nearSilence: avgRMS < threshold
    )
  }

  /// RMS over Int16 samples (0…1, full scale 32767); empty → 0. Same array as goes to WAV/STT.
  public static func rms(samples: [Int16]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Float = 0
    for sample in samples {
      let value = Float(sample) / 32767.0
      sum += value * value
    }
    return sqrt(sum / Float(samples.count))
  }

  /// Near-silence: avgRMS strictly < threshold (boundary not silence).
  public static func isNearSilence(
    avgRMS: Float,
    threshold: Float = nearSilenceThreshold
  ) -> Bool {
    avgRMS < threshold
  }
}
