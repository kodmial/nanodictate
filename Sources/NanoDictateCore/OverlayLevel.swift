import CoreGraphics
import Foundation

// MARK: - Чистая логика VU-отображения уровня звука (оверлей «Halo»)

/// Чистый расчёт VU-фидбека оверлея: dB-ремап линейного RMS в метр 0…1,
/// баллистика (быстрый attack / медленный release), зона «горячего» уровня
/// и толщина штриха кольца-дуги. Без SwiftUI и без I/O — полностью покрывается
/// юнит-тестами.
public enum OverlayLevel {
  /// Нижняя граница отображаемой шкалы в dBFS: −50 dBFS → метр 0.
  /// Верхняя граница шкалы — 0 dBFS → метр 1.
  public static let floordB: Float = -50

  /// Время attack в секундах: метр догоняет цель за ~70 мс.
  public static let attackTime: TimeInterval = 0.07

  /// Постоянная времени release: экспоненциальный спад с τ ≈ 0.5 с —
  /// при тике ~11 Гц (интервал ≈ 0.09 с) это ~×0.83 за тик, «плавно, но
  /// заметно» и соответствует ×~0.9/тик из спеки.
  public static let releaseTime: TimeInterval = 0.5

  /// Порог «горячей» зоны в dBFS: выше него фидбек теплеет (см. isHot).
  public static let hotThresholddB: Float = -6

  /// Порог «горячей» зоны в метрах — выведен из dBFS-порога (0.88 при −6 dBFS).
  public static var hotMeterThreshold: Float {
    (hotThresholddB - floordB) / -floordB // (−6 − (−50))/50 = 0.88
  }

  /// Перевод линейного RMS (0…1) в метр 0…1 по шкале −50…0 dBFS:
  /// `rms <= 0 ? 0 : clamp((20·log10(rms) + 50)/50, 0…1)`.
  /// Та же шкала, что у `AudioMetrics.nearSilenceThreshold` (−50 dBFS ≈ 0.00316).
  public static func meter(fromRMS rms: Float) -> Float {
    guard rms > 0 else { return 0 }
    let decibels = 20 * log10(rms)
    return min(max((decibels - floordB) / -floordB, 0), 1)
  }

  /// Обратная функция шкалы: dBFS, которому соответствует метр 0…1.
  /// Необходимо для проверки порогов в тестах и для логов.
  public static func dbfs(forMeter meter: Float) -> Float {
    floordB + min(max(meter, 0), 1) * -floordB
  }

  /// «Горячая» зона: уровень выше −6 dBFS (метр > 0.88) — кольцо теплеет.
  public static func isHot(meter: Float) -> Bool {
    meter > hotMeterThreshold
  }

  /// Envelope-баллистика VU за шаг `dt` (секунды). Входы — текущий и целевой
  /// метр (0…1), оба клампятся. Если цель выше — быстрый attack (линейное
  /// сближение за `attackTime`); иначе — экспоненциальный release к цели
  /// (не ниже её). Результат 0…1.
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

  /// Толщина штриха кольца-дуги: растёт с уровнем 3…9 пт.
  public static func strokeWidth(forMeter meter: Float) -> CGFloat {
    CGFloat(3 + min(max(meter, 0), 1) * 6)
  }
}

/// Следящий пик VU-метра: держит максимальный уровень ~`holdTime`, затем плавно
/// опадает. Используется пик-точкой кольца («маленький кружок»), чтобы короткие
/// всплески уровня были видны, а не пропадали мгновенно.
public struct OverlayPeak: Equatable {
  /// Сколько секунд пик держит максимум до начала спада.
  public static let holdTime: TimeInterval = 0.8

  /// Скорость плавного спада после окончания удержания (единиц в секунду,
  /// линейно): с 1.0 до 0 — ~1.4 с.
  public static let fallRate: Float = 0.7

  /// Текущее значение пика (0…1).
  public private(set) var value: Float = 0
  private var holdRemaining: TimeInterval = 0

  public init() {}

  /// Обновляет пик за шаг `dt`: новый максимум фиксируется и держится
  /// `holdTime`; пока уровень ниже — идёт оставшееся удержание, затем плавный
  /// спад. Возвращает текущее значение пика.
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

  /// Сброс пика в ноль (начало новой сессии / скрытие оверлея).
  public mutating func reset() {
    value = 0
    holdRemaining = 0
  }
}
