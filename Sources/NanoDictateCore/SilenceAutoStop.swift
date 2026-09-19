import Foundation

// MARK: - Автоостановка записи по непрерывной тишине (~3 c)

/// Конфигурация автоостановки записи по тишине.
///
/// Идея фичи: когда распознавание включено двойным Alt (агент слушает
/// микрофон), непрерывная тишина ~3 секунды означает «пользователь закончил
/// говорить и ждёт результат» — запись останавливается автоматически, и
/// запускается распознавание тем же путём, что ручное повторное Alt+Alt.
///
/// Модель тишины — RMS с ГИСТЕРЕЗИСОМ (два порога вместо одного): буфер с
/// RMS ≥ `speechRMSThreshold` — речь; буфер с RMS < `silenceRMSThreshold` —
/// тишина; уровень между порогами (‑58…‑45 dBFS) — «серая зона», в которой
/// состояние НЕ меняется (нет дребезга классификации на тихих слогах и
/// межсловных пробелах тихой диктовки).
///
/// Почему пороги не совпадают с общим `AudioMetrics.nearSilenceThreshold`
/// (−50 dBFS): этот порог удобен для сегментации/VAD, где «тишина» должна
/// ловиться раньше и резать чанки на паузах, но как порог ОСТАНОВКИ записи
/// он лежит ВНУТРИ динамики тихой речи (реальные −48.6…−55 dBFS) — из-за
/// этого спокойная диктовка обрывалась «через 3 секунды». У автоостановки
/// своя пара порогов: тишина считается только на реальном шумовом фоне
/// (−58 dBFS ≈ тихие сэмплы, в проде −82…−90), а речью считается уверенный
/// сигнал (−45 dBFS и громче). Диапазон −58…−45 dBFS — гистерезисная зона
/// «не меняем решение», специально подобранная под динамику пользователя.
public struct AutoStopConfig: Equatable {
  // MARK: Значения по умолчанию (единый источник правды для конфига и детектора)

  /// Речь ≥ −45 dBFS (линейно ≈ 0.00562): уверенный сигнал — пики тихой
  /// речи пользователя (−20…−35 dBFS) лежат заметно выше.
  public static let defaultSpeechRMSThreshold: Float = 0.00562

  /// Тишина < −58 dBFS (линейно ≈ 0.00126): реальный шумовой фон/пауза.
  /// Ниже уровня тихой речи −48.6…−55 dBFS — спокойная диктовка не
  /// классифицируется как молчание.
  public static let defaultSilenceRMSThreshold: Float = 0.00126

  /// Grace-период после старта записи: первые 2 c не копят тишину
  /// (обустройство, клавиатура, вдох перед фразой — не «конец диктовки»).
  public static let defaultGracePeriod: TimeInterval = 2.0

  /// Гейт «речь была»: автостоп невозможен, пока не накоплен непрерывный
  /// отрезок речи ≥ 0.3 c — «защёлкивается» навсегда в рамках сеанса.
  public static let defaultMinSpeechRun: TimeInterval = 0.3

  /// Минимальная длительность записи до возможного автостопа: 3 c —
  /// жёсткий пол независимо от остальных порогов (защита от
  /// патологических конфигов с крошечным requiredSilenceDuration).
  public static let defaultMinRecordingDuration: TimeInterval = 3.0

  /// Рубильник фичи: `false` полностью выключает автоостановку (запись живёт
  /// до ручного Alt+Alt или 60-секундного лимита — поведение до фичи).
  /// Спасательный люк для шумного окружения/длинных диктовок/PTT; по
  /// умолчанию включено — ровно по задаче.
  public var enabled: Bool

  /// Порог РЕЧИ одного буфера: RMS ≥ порога → речь (сброс тишины).
  public var speechRMSThreshold: Float

  /// Порог ТИШИНЫ одного буфера: RMS СТРОГО ниже порога → молчание
  /// (согласовано с `AudioMetrics.isNearSilence`: граница «в пользу» звука).
  /// Между `speechRMSThreshold` и `silenceRMSThreshold` — гистерезис: буфер
  /// не меняет текущее состояние классификации.
  public var silenceRMSThreshold: Float

  /// Минимальная длительность НЕПРЕРЫВНОЙ тишины (сек) для срабатывания.
  /// Фича-требование: ~3 секунды; паузы < 3 c не останавливают запись.
  public var requiredSilenceDuration: TimeInterval

  /// Grace-период после старта записи: буферы, начавшиеся раньше этого
  /// времени (сек с начала аудио), в тишину не накапливаются.
  public var gracePeriod: TimeInterval

  /// Гейт «речь была»: автостоп не сработает, пока непрерывный отрезок речи
  /// не достиг этой длительности (сек) хотя бы один раз за сеанс.
  public var minSpeechRun: TimeInterval

  /// Минимальная длительность записи (сек) до возможного автостопа — жёсткий
  /// пол независимо от остальных порогов.
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
    // Инвариант гистерезиса: порог речи не ниже порога тишины.
    self.speechRMSThreshold = max(speechRMSThreshold, silenceRMSThreshold)
    self.silenceRMSThreshold = silenceRMSThreshold
    self.requiredSilenceDuration = requiredSilenceDuration
    self.gracePeriod = gracePeriod
    self.minSpeechRun = minSpeechRun
    self.minRecordingDuration = minRecordingDuration
  }

  /// Конфигурация по умолчанию: включено, гистерезис −45/−58 dBFS,
  /// непрерывная тишина 3 c, grace 2 c, гейт 0.3 c, пол записи 3 c.
  public static let defaults = AutoStopConfig()

  /// Фабрика из окружения — пломбинг конфига из Agent без правки конфиг-файлов
  /// (тот же путь, что `NANODICTATE_API_KEY` в `Config.swift`/`RetryProvider`).
  ///
  /// Пустое окружение даёт ровно `.defaults`. Переопределения (все
  /// опциональны, некорректные значения игнорируются и оставляют значение
  /// по умолчанию):
  ///   • `NANODICTATE_AUTOSTOP_DISABLED=1` (или `true`) — рубильник: фича
  ///     выключена вовсе, любая пауза не останавливает запись;
  ///   • `NANODICTATE_AUTOSTOP_DURATION=5` — порог непрерывной тишины в
  ///     секундах (Double, строго > 0);
  ///   • `NANODICTATE_AUTOSTOP_RMS=0.01` — порог ТИШИНЫ в линейной шкале
  ///     (Float, строго > 0; −58 дБФС ≈ 0.00126);
  ///   • `NANODICTATE_AUTOSTOP_SPEECH_RMS=0.02` — порог РЕЧИ в линейной
  ///     шкале (Float, строго > 0; −45 дБФС ≈ 0.00562).
  /// Порог речи всегда клампится вверх до порога тишины (инвариант
  /// гистерезиса не нарушается ни при какой комбинации ключей).
  /// Значения провайдеров/конфиг-файлов здесь не затрагиваются.
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
    // Инвариант: речь не может распознаваться «тише», чем тишина.
    if config.speechRMSThreshold < config.silenceRMSThreshold {
      config.speechRMSThreshold = config.silenceRMSThreshold
    }
    return config
  }

  /// Признак «фича выключена» для `NANODICTATE_AUTOSTOP_DISABLED`.
  private static func parseDisabledFlag(_ raw: String) -> Bool {
    raw == "1" || raw == "true" || raw == "TRUE"
  }
}

/// Чистый детектор автоостановки: накапливает длительность НЕПРЕРЫВНОЙ
/// тишины, защищённой от ложных срабатываний (гистерезис, grace, гейт «речь
/// была», минимальная длительность записи). Никакого I/O — только математика,
/// поэтому логика полностью юнит-тестируема.
///
/// Питается из цикла записи (AudioService.process): для каждого буфера —
/// его RMS (0...1, как в level-метриках) и его РЕАЛЬНАЯ длительность
/// (фреймы конвертированного буфера / 16000). Накопление идёт по фактической
/// длительности, а не по счётчику буферов: частота колбэков зависит от
/// частоты дискретизации железа (~85 мс @ 48 кГц, ~93 мс @ 44.1 кГц,
/// ~256 мс @ 16 кГц) — по буферам «3 секунды» не меряются, по времени — да.
///
/// Модель решения (см. AutoStopConfig):
///   • РЕЧЬ (RMS ≥ speechRMSThreshold): обнуляет накопитель тишины, копит
///     отрезок речи для гейта. Один речевой буфер рвёт непрерывность тишины.
///   • ТИШИНА (RMS < silenceRMSThreshold): накапливается, НО только вне
///     grace-периода и только непрерывным отрезком (любой речевой буфер
///     сбрасывает — межсловные паузы не суммируются).
///   • СЕРАЯ ЗОНА (между порогами): гистерезис — состояние классификации
///     не меняется (накопление не идёт, сброса нет), чтобы тихие слоги и
///     межсловные пробелы не «дребезжали» между речью и тишиной.
///
/// Семантика результата: `feed` возвращает true, когда выполнены ВСЕ условия
/// (гейт «речь была» пройден + запись ≥ minRecordingDuration + накопленная
/// НЕПРЕРЫВНАЯ тишина ≥ requiredSilenceDuration). Возвращает true и на
/// последующих тихих буферах, пока накопитель не сброшен речью или `reset()`.
/// Защёлку «сработало один раз» держит внешний слой (AudioService помечает
/// остановку запланированной): у детектора ответственность — только честно
/// отвечать «тишина сейчас ≥ порога или нет».
public struct SilenceAutoStopDetector {
  /// Порог речи буфера (см. AutoStopConfig.speechRMSThreshold).
  public let speechRMSThreshold: Float

  /// Порог тишины буфера (см. AutoStopConfig.silenceRMSThreshold).
  public let silenceRMSThreshold: Float

  /// Требуемая длительность непрерывной тишины (см. AutoStopConfig).
  public let requiredSilenceDuration: TimeInterval

  /// Grace-период после старта записи (см. AutoStopConfig.gracePeriod).
  public let gracePeriod: TimeInterval

  /// Гейт «речь была»: минимальный непрерывный отрезок речи (см. AutoStopConfig).
  public let minSpeechRun: TimeInterval

  /// Минимальная длительность записи до срабатывания (см. AutoStopConfig).
  public let minRecordingDuration: TimeInterval

  /// Накопленная длительность текущей НЕПРЕРЫВНОЙ тишины (сек).
  /// Доступно на чтение для диагностики и тестов.
  public private(set) var silenceDuration: TimeInterval

  /// Суммарное аудио-время, скормленное детектору (сек) — «длительность записи».
  public private(set) var elapsed: TimeInterval

  /// Длительность текущего непрерывного отрезка речи (сек). Серая зона
  /// (между порогами) его не обнуляет — тихие слоги не рвут отрезок речи.
  public private(set) var speechRun: TimeInterval

  /// Гейт «речь была»: защёлкнут, когда отрезок речи достиг `minSpeechRun`.
  /// Автостоп невозможен до первого защёлкивания в рамках сеанса.
  public private(set) var speechGatePassed: Bool

  public init(
    silenceRMSThreshold: Float = AutoStopConfig.defaultSilenceRMSThreshold,
    speechRMSThreshold: Float = AutoStopConfig.defaultSpeechRMSThreshold,
    requiredSilenceDuration: TimeInterval = 3.0,
    gracePeriod: TimeInterval = AutoStopConfig.defaultGracePeriod,
    minSpeechRun: TimeInterval = AutoStopConfig.defaultMinSpeechRun,
    minRecordingDuration: TimeInterval = AutoStopConfig.defaultMinRecordingDuration
  ) {
    // Инвариант гистерезиса: порог речи не ниже порога тишины.
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

  /// Кормит детектор одним буфером.
  ///
  /// - Parameters:
  ///   - rms: линейный RMS буфера (0...1). Буфер молчит, если RMS СТРОГО
  ///     ниже `silenceRMSThreshold`, говорит — если ≥ `speechRMSThreshold`;
  ///     между порогами состояние не меняется (гистерезис).
  ///   - duration: реальная длительность буфера в секундах. Отрицательная
  ///     длительность (защита от мусорного ввода) клампится в 0 — накопление
  ///     не может пойти назад.
  /// - Returns: `true`, когда выполнены все условия остановки: гейт «речь
  ///   была» пройден, запись длится ≥ `minRecordingDuration`, и накопленная
  ///   непрерывная тишина ≥ `requiredSilenceDuration`. Возвращает `true` и на
  ///   последующих тихих/нейтральных буферах, пока накопитель не сброшен
  ///   речью или `reset()`.
  @discardableResult
  public mutating func feed(rms: Float, duration: TimeInterval) -> Bool {
    let effectiveDuration = max(0, duration)
    // Буфер, начавшийся до конца grace-периода, в тишину не накапливается
    // (речь при этом копится — гейт может пройти и внутри grace).
    let bufferStartsInGrace = elapsed < gracePeriod
    elapsed += effectiveDuration

    if rms >= speechRMSThreshold {
      // Речь: непрерывность тишины прервана — накопитель обнуляется;
      // отрезок речи растёт и при достижении minSpeechRun защёлкивает гейт.
      speechRun += effectiveDuration
      if !speechGatePassed, speechRun >= minSpeechRun {
        speechGatePassed = true
      }
      silenceDuration = 0
    } else if rms < silenceRMSThreshold {
      // Тишина: непрерывность речи прервана; накопление — только вне
      // grace-периода, непрерывным отрезком.
      speechRun = 0
      if !bufferStartsInGrace {
        silenceDuration += effectiveDuration
      }
    }
    // Между порогами — гистерезис: состояние не меняется (ни накопление,
    // ни сброс) — тихие слоги не «дребезжат» классификацией.

    return canStop
  }

  /// Все условия остановки: речь когда-либо была, запись не короче пола,
  /// непрерывная тишина достигла порога.
  private var canStop: Bool {
    guard speechGatePassed else { return false }
    guard elapsed >= minRecordingDuration else { return false }
    return silenceDuration >= requiredSilenceDuration
  }

  /// Сбрасывает всё состояние (новый сеанс записи).
  public mutating func reset() {
    silenceDuration = 0
    elapsed = 0
    speechRun = 0
    speechGatePassed = false
  }
}
