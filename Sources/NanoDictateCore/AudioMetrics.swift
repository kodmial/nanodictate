import AVFoundation
import Foundation

// MARK: - Статус доступа к микрофону (TCC)

/// Читаемое строковое представление статуса разрешения на доступ к микрофону.
///
/// Чистая функция без I/O: маппинг `AVAuthorizationStatus` → короткая метка,
/// которая попадает в `agent.log` при каждом старте записи и при каждом запросе
/// доступа. Нужна для диагностики главной жалобы — повторных запросов доступа:
/// если TCC-грант периодически «теряется» (статус снова `notDetermined`), это
/// сразу видно в логе.
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

/// Сводные метрики уровня записи по истории RMS буферов: минимум, среднее и
/// максимум (линейная шкала, 0...1), плюс флаг «около-тишины».
public struct RecordingMetrics: Equatable {
  /// Минимальный RMS по буферам записи (линейный, 0...1).
  public let minRMS: Float
  /// Средний RMS по буферам записи (линейный, 0...1).
  public let avgRMS: Float
  /// Максимальный RMS по буферам записи (линейный, 0...1).
  public let maxRMS: Float
  /// «Около-тишина»: средний RMS ниже порога `AudioMetrics.nearSilenceThreshold`.
  public let nearSilence: Bool

  public init(minRMS: Float, avgRMS: Float, maxRMS: Float, nearSilence: Bool) {
    self.minRMS = minRMS
    self.avgRMS = avgRMS
    self.maxRMS = maxRMS
    self.nearSilence = nearSilence
  }
}

/// Чистый расчёт уровней записи: сводные метрики по RMS-истории, RMS по Int16
/// PCM-сэмплам и порог «около-тишины». Без I/O и без обращения к аудио-устройствам,
/// поэтому полностью покрывается юнит-тестами.
public enum AudioMetrics {
  /// Порог «около-тишины» по среднему RMS: −50 dBFS (линейно ≈ 0.00316).
  ///
  /// Типовой VAD-порог: если средний уровень записи ниже него, в записи
  /// почти наверняка только шум микрофона / паузы — именно такой «аудио»
  /// не должен уходить в LLM как речь.
  public static let nearSilenceThreshold: Float = 0.00316  // −50 dBFS

  /// Переводит линейную амплитуду (0...1) в децибелы относительно полной шкалы
  /// (dBFS): 1.0 → 0 dBFS, 0.1 → −20 dBFS. Нулевая амплитуда — −120 dBFS (пол).
  public static func dbfs(_ linear: Float) -> Float {
    linear > 0 ? 20 * log10(linear) : -120
  }

  /// Сводные метрики по истории RMS буферов (линейные, 0...1).
  /// Пустая история (запись без единого буфера) не считается «тишиной» —
  /// метрики нулевые, `nearSilence == false`: судить не о чем.
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

  /// RMS по Int16 PCM-сэмплам (линейный, 0...1); полная шкала Int16 = 32767.
  /// Пустой массив → 0. Вычисляется над тем же массивом сэмплов, который
  /// уходит в WAV/STT, — чтобы видеть фактический уровень запрашиваемого аудио.
  public static func rms(samples: [Int16]) -> Float {
    guard !samples.isEmpty else { return 0 }
    var sum: Float = 0
    for sample in samples {
      let value = Float(sample) / 32767.0
      sum += value * value
    }
    return sqrt(sum / Float(samples.count))
  }

  /// Флаг «около-тишины» для среднего RMS: `avgRMS < threshold` (строго).
  /// На границе (avg == threshold) запись к тишине не относится.
  public static func isNearSilence(
    avgRMS: Float,
    threshold: Float = nearSilenceThreshold
  ) -> Bool {
    avgRMS < threshold
  }
}
