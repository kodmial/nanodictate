import AVFoundation
import AudioEngineGuard
import Foundation

// MARK: - Протоколы движка (инъекция в тестах)

/// Минимальный интерфейс входного узла AVAudioEngine, используемый
/// AudioService. Реальный класс AVAudioInputNode conforms через extension;
/// тесты подставляют фейк и имитируют отказы старта без аудио-железа.
public protocol AudioInputNodeLike: AnyObject {
  func outputFormat(forBus bus: AVAudioNodeBus) -> AVAudioFormat
  func installTap(
    onBus bus: AVAudioNodeBus,
    bufferSize: AVAudioFrameCount,
    format: AVAudioFormat?,
    block tapBlock: @escaping AVAudioNodeTapBlock
  )
  func removeTap(onBus bus: AVAudioNodeBus)
}

/// Минимальный интерфейс AVAudioEngine, используемый AudioService.
public protocol AudioEngineLike: AnyObject {
  func makeInputNode() -> AudioInputNodeLike
  func prepare()
  func start() throws
  func stop()
}

extension AVAudioInputNode: AudioInputNodeLike {}
extension AVAudioEngine: AudioEngineLike {
  public func makeInputNode() -> AudioInputNodeLike {
    inputNode
  }
}

// MARK: - ObjC-шлюз для NSException AVFAudio

// Тач-функции модуля AudioEngineGuard (см. AudioEngineExceptionGuard.h/m):
// NanoDictateRunAudioEngineBlockGuarded выполняет блок под ObjC @try/@catch и
// возвращает NSError вместо NSException, которое AVFAudio умеет поднимать
// внутри installTap/prepare/start (SetOutputFormat) и которое в Swift не
// ловится через try — падает SIGABRT.

/// Делегат для получения уровня звука (RMS) для анимации.
public protocol AudioLevelDelegate: AnyObject {
  func audioLevelChanged(rms: Float)
}

/// Жёсткий лимит записи: не более `maxDuration` секунд и не более `maxSamples`
/// сэмплов в буфере (16000 Гц × 60 c = 960 000 сэмплов ≈ 1.9 МБ в Int16).
///
/// Чистая тестируемая единица: не зависит от аудио-устройств, поэтому решение
/// «остановить/не останавливать» можно проверять в мини-XCTest напрямую.
public struct RecordingLimit {
  /// Максимальная длительность записи, секунды.
  public let maxDuration: TimeInterval
  /// Максимум накопленных сэмплов (память): `sampleRate × maxDuration`.
  public let maxSamples: Int
  /// Защёлка: после срабатывания лимита остаётся `true` — «хвост» записи
  /// возобновить нельзя, пока не начат новый сеанс (новый экземпляр).
  public private(set) var isExhausted = false

  public init(maxDuration: TimeInterval, sampleRate: Int) {
    self.maxDuration = maxDuration
    // Защита от pathологического zero sampleRate: приём всегда может
    // накопить хотя бы один сэмпл до принудительной остановки.
    maxSamples = max(1, Int(Double(sampleRate) * maxDuration))
  }

  /// Достигнут ли лимит (по времени ИЛИ по объёму). После первого срабатывания
  /// метод всегда возвращает `true` — остановка необратима в рамках сеанса.
  public mutating func shouldStop(elapsed: TimeInterval, totalSamples: Int) -> Bool {
    if isExhausted {
      return true
    }
    if elapsed >= maxDuration || totalSamples >= maxSamples {
      isExhausted = true
    }
    return isExhausted
  }

  /// Сколько сэмплов ещё можно накопить поверх `totalSamples`.
  /// 0 — предел достигнут, буфер дальше не растёт.
  public func remainingSamples(after totalSamples: Int) -> Int {
    max(0, maxSamples - totalSamples)
  }
}

/// Запись звука с микрофона через AVAudioEngine (16кГц моно).
///
/// Входной узел на macOS работает в аппаратном формате (обычно 48 кГц),
/// и `connect(input, to:format:)` с чужим sample rate кидает исключение
/// (`format.sampleRate == hwFormat.sampleRate`). Поэтому tap ставится на
/// аппаратном формате, а пересэмплинг в 16 кГц/моно делает AVAudioConverter.
///
/// Три гарантии жизни/смерти движка (регрессия крашей и «зависаний»):
/// 1. Все операции движка (installTap/prepare/start/stop/removeTap) — ТОЛЬКО
///    на `engineQueue` и под ObjC-шлюзом `guardedEngineCall`: NSException
///    AVFAudio (SetOutputFormat) превращается в Error, а не в SIGABRT.
/// 2. Любая ошибка старта ВСЕГДА снимает tap и останавливает движок
///    (teardownOnEngineQueue) — повторный старт на том же экземпляре не
///    падает на «tap уже установлен».
/// 3. Старт асинхронный (completion на главном): подъём движка не блокирует
///    главный поток (наблюдали заморозку UI на ~11 с при смене устройства).
// swiftlint:disable:next type_body_length
public final class AudioService {
  public weak var levelDelegate: AudioLevelDelegate?

  /// Ошибка смены аудио-устройства во время записи: входной формат движка
  /// изменился (`AVAudioEngineConfigurationChangeNotification`), живой
  /// tap-конвертер под новый формат не пересоздан. Запись завершена
  /// немедленно — продолжение со старым конвертером дало бы тишину или
  /// рассинхрон сэмплов. Пользователь перезапускает запись одной командой.
  public var onDeviceChange: ((Error) -> Void)?

  /// Уровень логирования: `"debug"` включает метрологию (min/avg/max RMS,
  /// флаг «около-тишины»). Не влияет на логи доступа к микрофону и lifecycle
  /// записи — они пишутся всегда, на уровне `info`.
  private let logLevel: String

  /// Вызывается после ПРИНУДИТЕЛЬНОЙ остановки по лимиту (на главной очереди)
  /// с собранными сэмплами — тот же путь финализации, что и у `stop()`
  /// (сборка сэмплов → WAV → транскрибация). nil-безопасно: если никто не
  /// подписался, запись всё равно останавливается, а сэмплы отбрасываются.
  public var onRecordingLimitReached: (([Int16]) -> Void)?

  /// Речевой сегмент собран live-VAD (пауза ≥ pauseDuration закрыла уттеренс)
  /// или отдан «хвост» незакрытого уттеренса при остановке записи (stop()
  /// или принудительный стоп по лимиту). Сэмплы — КОПИЯ из общего буфера:
  /// `collectedSamples` не трогается и продолжает собирать ВСЮ запись для
  /// финального прохода. `isTail == true` — доставка при остановке записи
  /// (сегмент покрывает запись до конца); false — сегмент live-VAD из
  /// середины записи. Вызывается на аудио-потоке (сегменты) или на главном
  /// (хвост stop()/лимита); обработчик должен быть лёгким (не блокировать).
  public var onSpeechSegment: (([Int16], _ isTail: Bool) -> Void)?

  /// Автоостановка по непрерывной тишине (~3 c): срабатывает, когда живая
  /// запись накопила непрерывное молчание ≥ `autoStopConfig.requiredSilenceDuration`
  /// (RMS каждого буфера строго ниже `silenceRMSThreshold`). Вызывается на
  /// главной очереди с собранными сэмплами — тот же путь финализации, что и
  /// у `onRecordingLimitReached` (эквивалент ручного повторного Alt+Alt, но
  /// без нажатия). В live-диктовке «хвост» незакрытого уттеренса отдаётся
  /// `onSpeechSegment` ДО этого колбэка — клиент успевает поставить его в
  /// очередь раньше финализации всей записи. nil-безопасно: запись всё равно
  /// останавливается, сэмплы отбрасываются.
  public var onAutoStop: (([Int16]) -> Void)?

  // var, а не let: replaceEngineAfterWedge() подменяет «зависший» движок
  // свежим экземпляром (восстановление после record-start таймаута).
  private var engine: AudioEngineLike
  private let targetFormat: AVAudioFormat
  private var converter: AVAudioConverter?
  private var collectedSamples: [Int16] = []
  private var tapInstalled = false
  /// Поколение движка: инкрементируется при КАЖДОЙ подмене «зависшего» движка
  /// (replaceEngineAfterWedge). Вместе с (engine, queue) образует атомарный
  /// слот: старты захватывают поколение при диспетчеризации, tap-блок и
  /// терминальные ветки старта сверяют «я — всё ещё текущее поколение?».
  /// Устаревшие движки (отброшенные подменой) молча дропают буферы и не
  /// трогают state нового сеанса.
  /// Регистр `session` держит ЕДИНСТВЕННУЮ копию тройки (generation, isRecording,
  /// autoStopScheduled) — читать её можно и под `lock` (снимок буферов), и
  /// lock-free с realtime-пути, не расходясь с записанным значением.
  private let session: SessionLedger
  /// Жёсткий лимит: 60.0 c, 960 000 сэмплов. Ни при каких условиях запись не
  /// может превысить эти значения (см. `process` и `scheduleLimitStop`).
  private var limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
  private var recordStartTime: CFAbsoluteTime = 0
  /// История RMS (линейный, 0...1) по буферам текущей записи — источник
  /// сводных метрик уровня (min/avg/max) в `logRecordingFinale`.
  private var rmsHistory: [Float] = []
  /// Гарантирует, что принудительная остановка планируется ровно один раз.
  private let lock = NSLock()
  private var limitStopScheduled = false
  /// Автоостановка по тишине: порог/длительность + рубильник `enabled`
  /// (из init; Agent забирает их из окружения — см. AutoStopConfig.fromEnvironment)
  /// и защёлка «финализация уже запланирована» — в регистре `session`
  /// (бит autoStop), как у лимита: ровно один колбэк.
  private let autoStopConfig: AutoStopConfig
  private var autoStopDetector = SilenceAutoStopDetector()
  /// Первый буфер сеанса логируется отдельно (debug): длительность и энергия
  /// показывают, пошёл ли реально звук в движок после старта.
  private var didLogFirstBuffer = false
  /// Цифровое усиление входа (AGC): применяется к Float32-буферу ПОСЛЕ
  /// конвертации в 16 кГц/моно и ДО Int16-конверсии/метрики уровня — все
  /// потребители (анимация уровня, live-VAD, автостоп, запись) видят уже
  /// усиленный сигнал. Конфиг из окружения (`NANODICTATE_GAIN_*`), рубильник
  /// `NANODICTATE_GAIN_DISABLED=1` пропускает буфер без изменений.
  private let gain: InputGain

  // MARK: - Live-VAD (пошаговая диктовка)

  /// Параметры live-VAD — те же, что у оффлайн-сегментера: порог «тишины»
  /// и длительность паузы, после которой уттеренс считается законченным.
  private let liveSilenceRMS: Float
  /// Пауза ≥ этого числа сэмплов (16 кГц) закрывает уттеренс.
  private let livePauseSamples: Int
  /// Pre-roll: сколько сэмплов (16 кГц) речи захватывать ДО обнаруженного
  /// старта уттеренса, чтобы не срезать атаку первого слова.
  private let livePreRollSamples: Int
  /// Post-roll: сколько сэмплов (16 кГц) тишины оставлять после последней
  /// речи, чтобы не срезать хвост последнего слова.
  private let livePostRollSamples: Int
  /// Окно непрерывной речи (16 кГц): когда накопленная РЕЧЬ текущего
  /// уттеренса достигла этого объёма — чанк готов к выдаче при ближайшей
  /// микро-паузе (см. `liveMicroPauseSamples`), не дожидаясь полной
  /// `pauseDuration`. 3.0 c = 48000 сэмплов — комфортная порция для STT.
  private let liveChunkWindowSamples: Int
  /// Микро-пауза (16 кГц): при накопленной речи ≥ `liveChunkWindowSamples`
  /// пауза ≥ этого порога режет чанк во время непрерывного говорения.
  /// 0.25 c = 4000 сэмплов — короче нормального межсловного пробела.
  private let liveMicroPauseSamples: Int
  /// Индекс начала текущего уттеренса в `collectedSamples`; nil — речи нет.
  private var liveUtteranceStart: Int?
  /// Индекс (исключая) конца последней порции РЕЧИ уттеренса — хвостовая
  /// тишина не включается.
  private var liveUtteranceEnd = 0
  /// Индекс начала текущей паузы внутри уттеренса; nil — паузы нет.
  /// Пауза короче `livePauseSamples` — внутренний пробел, уттеренс живёт.
  private var liveSilenceStart: Int?
  /// Индекс сразу после конца последнего доставленного live-сегмента:
  /// pre-roll не может заезжать в уже доставленный ранее кусок.
  private var liveLastCutIndex = 0
  /// Накопленная длительность РЕЧИ текущего уттеренса (16 кГц): растёт на
  /// каждую порцию речи, НЕ сбрасывается микро-паузой (межсловный пробел не
  /// обнуляет прогресс чанка); обнуляется со сбросом VAD после доставки.
  private var liveSpeechDurationSamples = 0

  /// Серийная очередь ВСЕХ операций движка: installTap/removeTap/prepare/start/
  /// stop. Вне очереди их вызывать нельзя — это и есть гарантия отсутствия
  /// гонок teardown↔start и блокировок главного потока.
  /// НЕ `let`: вместе с зависшим движком подменяется и ЕГО очередь
  /// (replaceEngineAfterWedge) — заблокированный engine.start() держит только
  /// свою очередь, операции для свежего движка уходят на свежую очередь.
  private var engineQueue: DispatchQueue
  /// Фабрика свежих движков при подмене после зависания (см.
  /// replaceEngineAfterWedge). Инъекция тестов; по умолчанию — настоящий
  /// AVAudioEngine.
  private let engineFactory: () -> AudioEngineLike
  /// Наблюдатель `AVAudioEngineConfigurationChangeNotification`: смена
  /// аудио-устройства во время записи делает живой tap-конвертер невалидным
  /// (входной формат движка изменился). Храним токен, чтобы снять подписку в
  /// teardown — иначе колбэк бьёт в освобождённый state.
  private var configChangeObserver: NSObjectProtocol?
  /// Фоновая очередь движка или главная — определяется движком, не потоком
  /// вызова. Используется только для диагностики.
  private var isDebug: Bool {
    logLevel.lowercased() == "debug"
  }

  public init(
    logLevel: String = "info",
    engine: AudioEngineLike? = nil,
    makeEngine: (() -> AudioEngineLike)? = nil,
    segmenterConfig: AudioSegmenterConfig = .defaults,
    autoStopConfig: AutoStopConfig = .defaults,
    gainConfig: InputGainConfig = .fromEnvironment()
  ) {
    self.logLevel = logLevel
    // Фабрика движков: начальный экземпляр (если не инъектирован) и замена
    // зависшего создаются ЕЮ — тесты подменяют её и получают контроль над
    // «свежим» движком после подмены.
    let factory = makeEngine ?? { AVAudioEngine() }
    engineFactory = factory
    self.engine = engine ?? factory()
    // Регистр жизненного цикла: единственная копия (generation/isRecording/
    // autoStopScheduled). Стартует с нулевого поколения, флаги сброшены.
    session = SessionLedger(generation: 0)
    engineQueue = DispatchQueue(label: "nanodictate.audio.engine", qos: .userInitiated)
    self.autoStopConfig = autoStopConfig
    gain = InputGain(config: gainConfig)
    autoStopDetector = SilenceAutoStopDetector(
      silenceRMSThreshold: autoStopConfig.silenceRMSThreshold,
      speechRMSThreshold: autoStopConfig.speechRMSThreshold,
      requiredSilenceDuration: autoStopConfig.requiredSilenceDuration,
      gracePeriod: autoStopConfig.gracePeriod,
      minSpeechRun: autoStopConfig.minSpeechRun,
      minRecordingDuration: autoStopConfig.minRecordingDuration
    )
    // Live-VAD живёт на тех же порогах, что оффлайн-сегментация записи:
    // один и тот же `silenceRMS`, одна и та же пауза `pauseDuration`.
    liveSilenceRMS = segmenterConfig.silenceRMS
    livePauseSamples = max(1, Int((segmenterConfig.pauseDuration * 16000).rounded()))
    // Pre-roll 0.5 c (8000 сэмплов) и post-roll 0.25 c (4000 сэмплов)
    // при 16 кГц — запас, который не даёт срезать атаку и хвост слова.
    livePreRollSamples = Int((0.5 * 16000).rounded())
    livePostRollSamples = Int((0.25 * 16000).rounded())
    // Режим «чанков» при непрерывной речи: окно 3.0 c (48000 сэмплов)
    // накопленной РЕЧИ + микро-пауза 0.25 c (4000 сэмплов) разрешают
    // выдачу текста во время говорения — не дожидаясь полной паузы 1 c.
    liveChunkWindowSamples = Int((3.0 * 16000).rounded())
    liveMicroPauseSamples = Int((0.25 * 16000).rounded())
    // Формат, в который пересэмплируем всё аудио: 16 кГц, моно, Float32.
    // Данный init гарантированно валиден на macOS 12+.
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
      )
    else {
      fatalError("AudioService: 16 kHz Float32 mono AVAudioFormat is guaranteed valid on macOS 12+")
    }
    targetFormat = format
  }

  // MARK: - Старт

  /// Начинает запись. Асинхронно: подъём движка идёт на фоновой очереди
  /// (`engineQueue`), completion вызывается на главном потоке. При недоступности
  /// микрофона или сбое движка — `.failure` (движок при этом разобран и готов
  /// к повторному старту, см. `startOnEngineQueue`).
  public func start(completion: @escaping (Result<Void, Error>) -> Void) {
    // Снимок пары (движок, очередь, поколение) под lock, ДО постановки в
    // очередь: блок уходит на очередь ЭТОГО движка и работает с НИМ. Зависший
    // старт блокирует только свою пару — после подмены (replaceEngineAfterWedge)
    // свежая пара работает, не дожидаясь заблокированной очереди. Поколение,
    // захваченное здесь, — «метка» этого старта: tap-блок и терминальные
    // ветки сверяют по ней, что движок всё ещё текущий (см. startOnEngineQueue).
    let slot = captureEngineSlot()
    slot.queue.async { [weak self, engine = slot.engine, startGeneration = slot.generation] in
      guard let self else {
        DispatchQueue.main.async { completion(.failure(AudioServiceError.engineGone)) }
        return
      }
      let result = self.startOnEngineQueue(using: engine, startGeneration: startGeneration)
      DispatchQueue.main.async { completion(result) }
    }
  }

  /// Атомарный снимок «движок + его серийная очередь + поколение» в момент
  /// диспетчеризации операции. Пара меняется только целиком
  /// (replaceEngineAfterWedge), поэтому операция всегда попадает на очередь
  /// СВОЕГО движка: серийность installTap/removeTap/prepare/start/stop на
  /// одном экземпляре сохраняется, а заблокированная очередь зависшего
  /// движка никого больше не держит. Поколение — «метка» старта: по ней
  /// tap-блок и терминальные ветки отличают текущий движок от отброшенного.
  private struct EngineSlot {
    var engine: AudioEngineLike
    var queue: DispatchQueue
    var generation: Int
  }

  private func captureEngineSlot() -> EngineSlot {
    lock.lock()
    defer { lock.unlock() }
    // Поколение берём из регистра `session` (единственная копия — см.
    // SessionLedger): продвигает его только replaceEngineAfterWedge, всегда
    // под этим же `lock`, так что пара (engine, generation) по-прежнему
    // снимается согласованно.
    return EngineSlot(
      engine: engine,
      queue: engineQueue,
      generation: session.snapshot.generation
    )
  }

  /// Весь подъём движка — строго на очереди этого движка. `startGeneration` —
  /// поколение слота на момент диспетчеризации старта: терминальные ветки
  /// разбирают движок и трогают state сеанса ТОЛЬКО если движок, что начал,
  /// всё ещё текущий (не подменён wedge'ом после таймаута сторожа).
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func startOnEngineQueue(using engine: AudioEngineLike, startGeneration: Int) -> Result<
    Void, Error
  > {
    // Новый сеанс: чистые буферы, чистый лимит (после принудительной
    // остановки или аварийной ветки). Всё состояние под lock — старт идёт
    // на очереди движка, process/stop могут читать параллельно.
    didLogFirstBuffer = false
    limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
    recordStartTime = CFAbsoluteTimeGetCurrent()
    lock.lock()
    collectedSamples = []
    rmsHistory = []
    limitStopScheduled = false
    // Защёлка автостопа — в регистре (бит autoStop): новый сеанс стартует
    // без «финализация уже запланирована».
    session.clearAutoStop()
    autoStopDetector.reset()
    gain.reset()  // новый сеанс — с нулевого усиления, без остатка прошлой записи
    liveLastCutIndex = 0
    resetLiveVADLocked()
    lock.unlock()

    // Безопасный старт с нуля: если предыдущая сессия оставила движок с
    // установленным tap (аварийная ветка), снимаем его ДО installTap —
    // повторный installTap на тот же bus поднимает NSException (краш).
    if isTapInstalled {
      teardownOnEngineQueue(using: engine)
    }

    // Подъём входного узла и формата — под тем же ObjC-шлюзом, что и весь
    // движок ниже: makeInputNode/outputFormat(forBus:)/AVAudioConverter могут
    // поднять NSException (SetOutputFormat при рассинхронизации формата после
    // смены аудио-устройства или TCC-гранта — в Swift его нельзя поймать
    // try, голый вызов уронил бы процесс SIGABRT). Результаты собираются
    // во внешние capture-переменные (тело шлюза Void-возвращающее),
    // исключение превращается в NSError и идёт в терминальную ветку ниже.
    var capturedInput: AudioInputNodeLike?
    var capturedHWFormat: AVAudioFormat?
    var capturedConverter: AVAudioConverter?
    var setupFailure = guardedEngineCall {
      capturedInput = engine.makeInputNode()
      capturedHWFormat = capturedInput?.outputFormat(forBus: 0)
    }
    if setupFailure == nil, let fmt = capturedHWFormat {
      setupFailure = guardedEngineCall {
        capturedConverter = AVAudioConverter(from: fmt, to: self.targetFormat)
      }
    }
    if let setupFailure {
      // Терминальная ветка — как у engine.start() ниже: движок обязан быть
      // разобран, иначе следующий Alt+Alt упадёт на повторном installTap.
      // Но сначала гард поколения: если движок, что начал, уже подменён
      // (wedge) — state нового сеанса (session.end()/сброс буферов)
      // трогать нельзя, разбираем только сам устаревший движок.
      guard isCurrentGeneration(startGeneration) else {
        teardownEngineOnly(using: engine)
        return .failure(setupFailure)
      }
      setRecording(false)
      teardownOnEngineQueue(using: engine)
      Logger.log(
        "record engine: input setup failed: \(setupFailure.localizedDescription)", level: "error")
      return .failure(setupFailure)
    }
    guard let input = capturedInput, let hwFormat = capturedHWFormat else {
      // Недостижимо (makeInputNode не возвращает nil) — страховка компайлеру.
      Logger.log("record engine: input node unavailable", level: "error")
      return .failure(AudioServiceError.unsupportedFormat)
    }
    guard let converter = capturedConverter else {
      Logger.log(
        "record engine: AVAudioConverter init failed (hw=\(Int(hwFormat.sampleRate)) Hz -> "
          + "target=\(Int(targetFormat.sampleRate)) Hz)",
        level: "error"
      )
      return .failure(AudioServiceError.unsupportedFormat)
    }
    lock.lock()
    self.converter = converter
    lock.unlock()
    // Подписка на смену аудио-устройства — после того как конвертер лёг в
    // state: уведомление может прийти сразу после регистрации.
    observeConfigurationChanges(for: engine)

    // Доступ к микрофону (TCC) при каждом создании/повторном старте записи.
    // Повторный системный запрос доступа (главная жалоба) выглядит в логе
    // как статус notDetermined перед стартом — сразу видно, что грант теряется.
    let mic = MicrophoneAuth.statusText(AVCaptureDevice.authorizationStatus(for: .audio))
    Logger.log("mic permission: \(mic) (record start)", level: "info")
    Logger.log(
      "record start: sampleRate=\(Int(targetFormat.sampleRate)) Hz, channels=\(targetFormat.channelCount), "
        + "hwFormat=\(Int(hwFormat.sampleRate)) Hz",
      level: "info"
    )
    // Диагностика автоостановки: видно, включена ли фича, пара порогов
    // гистерезиса, grace, гейт «речь была» и пол записи (все значения из
    // окружения — см. fromEnvironment).
    Logger.log(
      "record auto-stop: enabled=\(autoStopConfig.enabled), "
        + "speech>=\(autoStopConfig.speechRMSThreshold), silence<\(autoStopConfig.silenceRMSThreshold), "
        + "silence>=\(String(format: "%.1f", autoStopConfig.requiredSilenceDuration))s, "
        + "grace=\(String(format: "%.1f", autoStopConfig.gracePeriod))s, "
        + "gate>=\(String(format: "%.1f", autoStopConfig.minSpeechRun))s, "
        + "minRecord=\(String(format: "%.1f", autoStopConfig.minRecordingDuration))s",
      level: "info"
    )
    // Диагностика AGC: видно, включено ли усиление и какими параметрами
    // (рубильник/цель/потолок из окружения — см. InputGainConfig.fromEnvironment).
    Logger.log(
      "record input-gain: enabled=\(gain.config.enabled), "
        + "target=\(String(format: "%.1f", gain.config.targetRmsDb)) dBFS, "
        + "max=\(String(format: "%.1f", gain.config.maxGainDb)) dB",
      level: "info"
    )

    // Хлебная крошка перед installTap: если следующий вызов AVFoundation
    // крэшнет, последняя строка лога укажет точное место. Повторный опрос
    // аппаратного формата здесь НЕ делается — тот же вызов уже снят под
    // ObjC-шлюзом в подъёме выше (дублирование не давало новой информации).
    if isDebug {
      Logger.log(
        "record engine: installing tap (bus 0, bufferSize 4096, hwFormat=\(Int(hwFormat.sampleRate)) Hz)",
        level: "debug"
      )
    }

    // Tap вешается на аппаратный формат; конвертация выполняется в блоке.
    var failure = guardedEngineCall {
      input.installTap(
        onBus: 0,
        bufferSize: 4096,
        format: hwFormat
      ) { [weak self, tapGeneration = startGeneration] buffer, _ in
        guard let self else { return }
        // Tap отброшенного поколения (движок подменён wedge'ом ПОСЛЕ
        // установки tap) молча дропает буферы: чужой аудио-поток не
        // должен кормить новую сессию. Сам по себе старый tap не снять
        // (его движок мог зависнуть) — гард поколения дешевле и надёжнее.
        guard self.isCurrentGeneration(tapGeneration) else { return }
        self.process(buffer)
      }
    }
    if failure == nil {
      setTapInstalled(true)
    }
    if failure == nil, isDebug {
      Logger.log("record engine: tap installed, engine.prepare()…", level: "debug")
    }
    if failure == nil {
      failure = guardedEngineCall {
        engine.prepare()
      }
    }
    if failure == nil, isDebug {
      Logger.log("record engine: prepared, engine.start()…", level: "debug")
    }
    // isRecording включается ДО engine.start(): первый буфер, пришедший
    // сразу после старта аудио-потока, не должен быть отброшен.
    if failure == nil {
      setRecording(true)
      failure = guardedEngineCall {
        try engine.start()
      }
    }
    if let failure {
      // Терминальная ветка: движок обязан быть разобран (tap снят, движок
      // остановлен, буферы очищены) — иначе следующий Alt+Alt упадёт на
      // повторном installTap на занятом bus. Гард поколения, как в ветке
      // setup-сбоя: разблокировавшийся ПОСЛЕ подмены старт не трогает
      // state новой сессии — только разбирает сам устаревший движок.
      guard isCurrentGeneration(startGeneration) else {
        teardownEngineOnly(using: engine)
        return .failure(failure)
      }
      setRecording(false)
      teardownOnEngineQueue(using: engine)
      Logger.log("record engine: start failed: \(failure.localizedDescription)", level: "error")
      return .failure(failure)
    }
    // Гард поколения успешной ветки: если движок, что НАЧАЛ запись, уже не
    // текущий (его start() разблокировался после wedge-подмены) — вернуть
    // .success нельзя: агент вызвал бы audio.cancel() на ТЕКУЩЕЙ (возможно,
    // живой) свежей паре. Разбираем только устаревший движок и помечаем
    // старт .failure(.engineSuperseded) — сторожевой completion агента его
    // игнорирует, к cancel() не приводит.
    guard isCurrentGeneration(startGeneration) else {
      Logger.log("record engine: stale start completed after wedge — discarded", level: "info")
      teardownEngineOnly(using: engine)
      return .failure(AudioServiceError.engineSuperseded)
    }
    if isDebug {
      Logger.log("record engine: started OK", level: "debug")
    }
    return .success(())
  }

  // MARK: - Стоп / отмена

  /// Останавливает запись и возвращает собранные сэмплы (Int16, 16кГц).
  /// Снимок сэмплов — синхронный (как и раньше); teardown движка уходит на
  /// engineQueue, чтобы не блокировать главный поток.
  public func stop() -> [Int16] {
    lock.lock()
    guard isRecordingLocked else {
      lock.unlock()
      return []
    }
    let duration = CFAbsoluteTimeGetCurrent() - recordStartTime
    setRecording(false)
    // «Хвост» (незакрытый уттеренс) забираем тем же снимком, под той же
    // блокировкой — VAD-состояние и буфер записи согласованы.
    let tail = takeLiveTailLocked()
    let samples = collectedSamples
    collectedSamples = []
    let rms = rmsHistory
    rmsHistory = []
    lock.unlock()

    // Разборка — на очереди ТОГО движка, с которым шла эта запись (снимок
    // пары под lock): серийность с уже стоящими там операциями сохраняется,
    // а после подмены зависшего движка конкретный teardown уходит на очередь
    // своего (уже отброшенного) экземпляра и никого больше не держит.
    let slot = captureEngineSlot()
    slot.queue.async { [weak self, engine = slot.engine] in
      guard let self else { return }
      self.teardownOnEngineQueue(using: engine)
    }
    logRecordingFinale(samples: samples, duration: duration, rmsHistory: rms)
    // Незакрытый уттеренс распознаётся как последний сегмент: к моменту
    // стопа речи после его начала больше не было, значит он покрывает
    // финальную фразу целиком.
    if !tail.isEmpty {
      onSpeechSegment?(tail, true)
    }
    return samples
  }

  /// Отменяет запись, отбрасывая данные.
  public func cancel() {
    lock.lock()
    guard isRecordingLocked else {
      lock.unlock()
      return
    }
    let duration = CFAbsoluteTimeGetCurrent() - recordStartTime
    let frames = collectedSamples.count
    setRecording(false)
    collectedSamples = []
    // Отмена отбрасывает ВСЁ, включая незакрытый уттеренс: колбэка
    // onSpeechSegment нет (Esc = данные не доставляются).
    liveLastCutIndex = 0
    resetLiveVADLocked()
    lock.unlock()

    // Разборка — на очереди того же движка (снимок пары под lock), см.
    // комментарий в stop().
    let cancelSlot = captureEngineSlot()
    cancelSlot.queue.async { [weak self, engine = cancelSlot.engine] in
      guard let self else { return }
      self.teardownOnEngineQueue(using: engine)
    }
    // Отмена тоже завершает запись — без отправки в STT; длительность и
    // объём помогают отличать «пустую» отмену от отмены после реальной речи.
    if isDebug {
      Logger.log(
        String(
          format: "record cancel: duration=%.2f s, frames=%d, bytes=%d",
          duration,
          frames,
          frames * 2
        ),
        level: "debug"
      )
    }
  }

  // MARK: - Восстановление после зависания

  /// Замена «зависшего» движка — восстановление после record-start таймаута
  /// (сторож подъёма в Agent зовёт её, когда engine.start() не вернулся за
  /// отведённое время; типичный сценарий — смена аудио-устройства после
  /// TCC-гранта блокирует старт в HAL навсегда). Старый экземпляр
  /// отбрасывается, в свойство встаёт СВЕЖИЙ AVAudioEngine — следующий
  /// start() переустановит tap/формат/конвертер с нуля.
  /// Подмена идёт СИНХРОННО на вызывающем потоке (не через очередь движка!):
  /// очередь зависшего экземпляра может быть заблокирована навсегда его
  /// engine.start() — постановка подмены в ту же очередь означала бы, что
  /// восстановление не наступит НИКОГДА (ровно та дефектная схема, ради
  /// которой метод и существует). Под lock меняется вся пара
  /// (движок + его очередь): свежий движок из фабрики получает СВОЮ очередь,
  /// старая пара отбрасывается целиком. Разборка и отпускание СТАРОГО движка —
  /// на отдельной глобальной очереди: его stop() может застрять на том же
  /// HAL, что завис в start(), и не должен держать ничью очередь.
  /// Безопасен в любом состоянии, идемпотентен: повторный вызов просто
  /// заменяет уже свежий движок ещё раз.
  public func replaceEngineAfterWedge() {
    let oldEngine: AudioEngineLike
    lock.lock()
    oldEngine = engine
    engine = engineFactory()
    engineQueue = DispatchQueue(label: "nanodictate.audio.engine", qos: .userInitiated)
    // Новое поколение: операции и tap-блоки старого движка (если его start()
    // разблокируется позже) видят расхождение поколений и не трогают state,
    // а новые старты получают свежую метку.
    session.advanceGeneration()
    // tap и конвертер принадлежали старому движку — свежий старт ставит их
    // с нуля (повторный installTap на занятом bus = NSException).
    tapInstalled = false
    converter = nil
    lock.unlock()
    // Подписка на смену устройства принадлежала СТАРОМУ движку: его
    // configuration-change не должен гасить запись на свежей паре.
    removeConfigurationObserver()
    Logger.log(
      "record engine: wedged engine replaced — fresh AVAudioEngine installed", level: "info")
    // Разборка старого движка вне очередей движка (см. комментарий метода).
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      _ = self.guardedEngineCall {
        oldEngine.stop()
      }
      // oldEngine отпускается по выходу из блока — dealloc вдали от очередей движка.
    }
  }

  // MARK: - Private

  /// Выполняет блок операций движка под ObjC-шлюзом: NSException AVFAudio
  /// превращается в NSError, Swift-ошибка (engine.start() throws) пробрасывается
  /// как есть. nil — операция прошла без ошибок.
  func guardedEngineCall(_ body: @escaping () throws -> Void) -> Error? {
    final class ErrorBox {
      var captured: Error?
    }
    let box = ErrorBox()
    let nsError = NanoDictateRunAudioEngineBlockGuarded {
      do {
        try body()
      } catch {
        box.captured = error
      }
    }
    return nsError ?? box.captured
  }

  /// Разборка движка — строго на очереди ЭТОГО движка. Идемпотентна: снять
  /// не установленный tap / остановить не запущенный движок безопасно (все
  /// вызовы под шлюзом NSException). Движок передаётся явно (снимок пары), а
  /// не берётся из свойства: teardown может выполняться для экземпляра, уже
  /// отброшенного подменой.
  private func teardownOnEngineQueue(using engine: AudioEngineLike) {
    if isTapInstalled {
      _ = guardedEngineCall {
        engine.makeInputNode().removeTap(onBus: 0)
      }
      setTapInstalled(false)
    }
    _ = guardedEngineCall {
      engine.stop()
    }
    setRecording(false)
    // Подписку на смену устройства снимаем ДО сброса state: уведомление —
    // про сеанс записи, после разборки ему нечего делать.
    removeConfigurationObserver()
    lock.lock()
    converter = nil
    collectedSamples = []
    rmsHistory = []
    liveLastCutIndex = 0
    session.clearAutoStop()
    autoStopDetector.reset()
    resetLiveVADLocked()
    lock.unlock()
  }

  /// Разборка ТОЛЬКО устаревшего движка (снять его tap, остановить его) —
  /// без трогания глобального состояния сеанса (isRecording, буферы,
  /// конвертер). Для стартов, завершившихся после подмены поколения: полная
  /// разборка (teardownOnEngineQueue) сбросила бы живую новую сессию на
  /// свежем движке.
  private func teardownEngineOnly(using engine: AudioEngineLike) {
    _ = guardedEngineCall {
      engine.makeInputNode().removeTap(onBus: 0)
    }
    _ = guardedEngineCall {
      engine.stop()
    }
  }

  /// Подписка на смену аудиоустройства для сеанса записи. В заголовках AVFAudio
  /// НЕТ свойства `configurationChangeHandler` — единственный канал это
  /// `AVAudioEngineConfigurationChangeNotification` (AVAudioEngine.h, macOS 10.10+).
  /// Уведомление наблюдаем через NotificationCenter с объектом ЭТОГО сеанса:
  /// чужие движки (подмена после wedge) своих наблюдателей не будят.
  /// `userInfo` уведомления не разбираем — решение принимает
  /// `handleConfigurationChange` (запись останавливается с явной ошибкой).
  /// Токен наблюдателя живёт под lock: `replaceEngineAfterWedge` снимает
  /// подписку с вызывающего потока, а не с очереди движка.
  private func observeConfigurationChanges(for engine: AudioEngineLike) {
    let token = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: (engine as? AVAudioEngine) ?? nil,
      queue: nil
    ) { [weak self] _ in
      self?.handleConfigurationChange()
    }
    lock.lock()
    let stale = configChangeObserver
    configChangeObserver = token
    lock.unlock()
    // Снятие старого токена — вне lock: NotificationCenter чужой код, под
    // блокировкой state ему делать нечего.
    if let stale = stale { NotificationCenter.default.removeObserver(stale) }
  }

  /// Снятие подписки на смену устройства. Вызывают: точки разборки
  /// (teardownOnEngineQueue), подмена движка после wedge, запись нового
  /// сеанса (через observeConfigurationChanges).
  private func removeConfigurationObserver() {
    lock.lock()
    let token = configChangeObserver
    configChangeObserver = nil
    lock.unlock()
    if let token = token { NotificationCenter.default.removeObserver(token) }
  }

  /// Обработчик смены аудиоустройства во время записи: tap и конвертер привязаны
  /// к СТАРОМУ формату входа, движок пересобрал граф. Безопасное восстановление
  /// tap/конвертера наживую НЕВОЗМОЖНО: tap висит на старом input node, а
  /// повторный installTap на пересобранном bus бросает NSException; конвертер
  /// resample рассчитан из старого hwFormat. Поэтому запись останавливается, а
  /// пользователю отдаётся ЯВНАЯ ошибка `.deviceChanged` через onDeviceChange
  /// (колбэк — UI сам решает: тост/алерт/автозапись заново).
  /// Блокировка: читаем isRecording под lock, сбрасывать state НЕ ЗДЕСЬ —
  /// stop() сам гасит флаги и разбирает tap/движок. Двойная остановка
  /// безопасна (stop идемпотентен через тот же guard isRecording).
  private func handleConfigurationChange() {
    // Чтение флага записи без NSLock: уведомление может прийти на чужой
    // очереди, а регистр `session` не удерживает блокировку state.
    guard isRecordingLocked else { return }
    Logger.log("record engine: configuration changed — stopping, user must restart", level: "warn")
    // Сэмплы сеанса отдаёт сам stop() (его путь финализации) — здесь они не нужны.
    _ = stop()
    onDeviceChange?(AudioServiceError.deviceChanged)
  }

  /// Сброс live-VAD — строго под блокировкой (начало сеанса, teardown,
  /// доставка сегмента, остановка записи).
  private func resetLiveVADLocked() {
    liveUtteranceStart = nil
    liveUtteranceEnd = 0
    liveSilenceStart = nil
    liveSpeechDurationSamples = 0
  }

  /// Снимок незакрытого уттеренса («хвоста») под блокировкой. Хвост — речь
  /// от начала уттеренса до последней порции РЕЧИ (без хвостовой тишины);
  /// когда пауза длится до самого стопа, это скрывает «молчание» после фразы.
  /// Пустой, если речь не начиналась. VAD-состояние сбрасывается. Общий
  /// буфер записи не трогается — хвост передаётся КОПИЕЙ.
  private func takeLiveTailLocked() -> [Int16] {
    defer { resetLiveVADLocked() }
    guard let start = liveUtteranceStart else { return [] }
    let end = min(liveUtteranceEnd, collectedSamples.count)
    guard end > start else { return [] }
    return Array(collectedSamples[start..<end])
  }

  /// Значение фактически принадлежит записи (взводится `begin`), параметр
  /// оставлен ради симметрии вызовов на точках старта.
  private func setRecording(_ value: Bool) {
    if value {
      session.begin(generation: session.snapshot.generation)
    } else {
      session.end()
    }
  }

  private var isRecordingLocked: Bool {
    session.isRecording
  }

  /// Проверка поколения с realtime-пути, без NSLock: tap-блок отброшенного
  /// движка не должен трогать state нового сеанса (см. SessionLedger).
  private func isCurrentGeneration(_ generation: Int) -> Bool {
    session.isCurrentGeneration(generation)
  }

  private var isAutoStopScheduled: Bool {
    session.snapshot.autoStopScheduled
  }

  private func setTapInstalled(_ value: Bool) {
    lock.lock()
    tapInstalled = value
    lock.unlock()
  }

  private var isTapInstalled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return tapInstalled
  }

  /// Снимок состояния приёма под одной блокировкой: признак записи,
  /// флаги принудительных остановок и конвертер. Закрывает гонку
  /// старт/стоп/подмена — process видит согласованную тройку.
  private struct BufferedSnapshot {
    var alive: Bool
    var converter: AVAudioConverter?
  }

  private func takeBufferedSnapshot() -> BufferedSnapshot {
    // Флаги сеанса читаем ПЕРВЫМИ и без NSLock: на заблокированном lock
    // (например, во время пересборки VAD в stop/performForcedStop) realtime
    // tap-поток успевает увидеть «записи нет» и выйти, не вставая в очередь
    // за блокировкой. Счётчик защёлкивается в начале сеанса, так что живой
    // буфер после снятия флага уже не нужен. Дальше полновесный снимок
    // (конвертер) — под NSLock; оба источника согласованы, потому что
    // пишутся одним потоком-владельцем сеанса.
    guard isRecordingLocked else {
      return BufferedSnapshot(alive: false, converter: nil)
    }
    lock.lock()
    defer { lock.unlock() }
    let alive = !limit.isExhausted && !isAutoStopScheduled
    return BufferedSnapshot(alive: alive, converter: converter)
  }

  /// Регистр жизненного цикла сеанса: убирает NSLock (mutex с возможным
  /// syscall и инверсией приоритета) с realtime-пути tap-колбэка. Примитив —
  /// `os_unfair_lock`: в неспорном случае это один атомарный CAS в userspace
  /// без системных вызовов и ObjC-рантайма (raw C11-атомики потребовали бы
  /// правок вне зоны — C-обёртки в AudioEngineGuard; зависимости swift-atomics
  /// в пакете нет). Слово состояния упаковывает тройку
  /// (generation/isRecording/autoStopScheduled): поколение — в старшем слове,
  /// флаги — в младших двух битах; снимается пакетно под одним захватом.
  /// Захваты короткие (несколько инструкций), вложенности нет, порядок всегда
  /// ledger→NSLock (обратного не бывает — дедлока нет). Полновесные снимки
  /// буферов/конвертера — по-прежнему NSLock в `takeBufferedSnapshot`.
  final class SessionLedger: @unchecked Sendable {
    private var unfair = os_unfair_lock()
    private var word: UInt64 = 0
    /// Бит 0 — идёт запись; бит 1 — защёлка планировщика автостопа.
    private static let recordingBit: UInt64 = 1
    private static let autoStopBit: UInt64 = 2
    /// Старшее слово счётчика поколений; младшее — флаговое.
    private static let generationShift: UInt64 = 32

    /// Начальное поколение наследуют от сервиса, флаги — нулевые.
    init(generation: Int) {
      word = UInt64(clamping: generation) << Self.generationShift
    }

    /// Снимок тройки (generation/isRecording/autoStopScheduled) пакетно.
    var snapshot: (generation: Int, isRecording: Bool, autoStopScheduled: Bool) {
      os_unfair_lock_lock(&unfair)
      defer { os_unfair_lock_unlock(&unfair) }
      return unpack(word)
    }

    /// Чтение `isRecording` вне NSLock для раннего выхода realtime-thread
    /// (полный снимок — см. `takeBufferedSnapshot`).
    var isRecording: Bool {
      os_unfair_lock_lock(&unfair)
      defer { os_unfair_lock_unlock(&unfair) }
      return word & Self.recordingBit != 0
    }

    /// Сверка поколения без NSLock (tap-блок, терминальные ветки старта).
    func isCurrentGeneration(_ generation: Int) -> Bool {
      os_unfair_lock_lock(&unfair)
      defer { os_unfair_lock_unlock(&unfair) }
      return Int(word >> Self.generationShift) == generation
    }

    /// Переход старта: поколение + флаг recording. Флаг записи читается из
    /// регистра без блокировки — `begin` вызывается на потоке, который уже
    /// владеет сеансом (очередь движка либо main).
    func begin(generation: Int) {
      os_unfair_lock_lock(&unfair)
      defer { os_unfair_lock_unlock(&unfair) }
      word =
        (UInt64(clamping: generation) << Self.generationShift)
        | (word & Self.autoStopBit) | Self.recordingBit
    }

    /// Переход останова: сброс recording + autoStop, поколение сохранить.
    func end() {
      os_unfair_lock_lock(&unfair)
      defer { os_unfair_lock_unlock(&unfair) }
      word &= ~(Self.recordingBit | Self.autoStopBit)
    }

    /// Снятие защёлки автостопа — новый сеанс стартует без «финализация уже
    /// запланирована» (флаг записи не трогаем: его взводит `begin`).
    func clearAutoStop() {
      os_unfair_lock_lock(&unfair)
      defer { os_unfair_lock_unlock(&unfair) }
      word &= ~Self.autoStopBit
    }

    /// Защёлка автостопа: бит планировщика; поколение/запись сохранить.
    func latchAutoStop() {
      os_unfair_lock_lock(&unfair)
      defer { os_unfair_lock_unlock(&unfair) }
      word |= Self.autoStopBit
    }

    /// Шаг поколения подмены wedge: счётчик +1, сброс recording/autoStop.
    @discardableResult
    func advanceGeneration() -> Int {
      os_unfair_lock_lock(&unfair)
      defer { os_unfair_lock_unlock(&unfair) }
      let generation = Int(word >> Self.generationShift) + 1
      word = UInt64(clamping: generation) << Self.generationShift
      return generation
    }

    /// Распаковка слова в тройку — только под захватом unfair.
    private func unpack(_ packed: UInt64) -> (
      generation: Int, isRecording: Bool, autoStopScheduled: Bool
    ) {
      (
        generation: Int(packed >> Self.generationShift),
        isRecording: packed & Self.recordingBit != 0,
        autoStopScheduled: packed & Self.autoStopBit != 0
      )
    }
  }


  /// Реальный объём выхода при ресемплинге пропорционален частотам:
  /// `inputFrames × outputRate / inputRate` + запас (¼), чтобы конвертер
  /// наполнил выход за один проход из одного входного буфера.
  static func outputFrameCapacity(
    forInputFrames inputFrames: AVAudioFrameCount,
    inputRate: Double,
    outputRate: Double
  ) -> AVAudioFrameCount {
    // Защита от деления на ноль: в проде недостижимо, но helper внутренний
    // и тестируемый.
    guard inputRate > 0, outputRate > 0 else { return 0 }
    let base = Int(Double(inputFrames) * outputRate / inputRate)
    return AVAudioFrameCount(base + max(1, base / 4))
  }

  /// Один проход конвертера (драйв входа). Входной буфер отдаётся РОВНО один
  /// раз (`.haveData`), при всех последующих запросах — `nil` + `.noDataNow`:
  /// конвертер не тянет один и тот же кусок повторно, а `.noDataNow` (в отличие
  /// от `.endOfStream`) не защёлкивает конвертер — он остаётся живым для
  /// следующих буферов.
  /// Непустой выход валиден при `.haveData`/`.inputRanDry`/`.endOfStream`;
  /// отбрасываются только пустые результаты и ошибки.
  static func convertOnce(
    input: AVAudioPCMBuffer,
    inputFormat: AVAudioFormat,
    converter: AVAudioConverter,
    targetFormat: AVAudioFormat
  ) -> (converted: AVAudioPCMBuffer, status: AVAudioConverterOutputStatus)? {
    guard
      let converted = AVAudioPCMBuffer(
        pcmFormat: targetFormat,
        frameCapacity: outputFrameCapacity(
          forInputFrames: input.frameLength,
          inputRate: inputFormat.sampleRate,
          outputRate: targetFormat.sampleRate
        )
      )
    else { return nil }

    var fedInput = false
    let status = converter.convert(to: converted, error: nil) { _, outStatus in
      if fedInput {
        outStatus.pointee = .noDataNow
        return nil
      }
      fedInput = true
      outStatus.pointee = .haveData
      return input
    }
    guard converted.frameLength > 0, status != .error else { return nil }
    return (converted, status)
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func process(_ buffer: AVAudioPCMBuffer) {
    // Ранний гард «идёт ли запись» ДО конвертации и AGC: после stop()/start()
    // поздний буфер старого тапа не должен трогать state InputGain — reset()
    // нового сеанса (engineQueue, под lock) и apply (аудио-поток) не
    // пересекаются (гард ниже на 635 остаётся — защита задублирована).
    // Все флаги и конвертер снимаются под lock одним снимком: безлочный
    // гард убран — гонка старт/стоп закрыта (см. takeBufferedSnapshot).
    let snapshot = takeBufferedSnapshot()
    guard snapshot.alive else { return }
    guard let converter = snapshot.converter else {
      logDroppedBuffer(reason: "converter is nil (stopped?)", frames: buffer.frameLength)
      return
    }
    guard
      let result = AudioService.convertOnce(
        input: buffer,
        inputFormat: buffer.format,
        converter: converter,
        targetFormat: targetFormat
      )
    else {
      logDroppedBuffer(
        reason: "convertOnce -> nil (empty output or error)", frames: buffer.frameLength)
      return
    }
    guard let channel = result.converted.floatChannelData?[0] else {
      logDroppedBuffer(reason: "converted buffer has no float channel", frames: buffer.frameLength)
      return
    }
    let converted = result.converted
    let frameLength = Int(converted.frameLength)

    // RMS ДО усиления — вход AGC: «сколько дБ не хватает до целевого
    // уровня речи» (метеорология по сырому сигналу тапа).
    var sum: Float = 0
    for i in 0..<frameLength {
      let sample = channel[i]
      sum += sample * sample
    }
    let rms = frameLength > 0 ? sqrt(sum / Float(frameLength)) : 0
    // Цифровое усиление (AGC) — здесь, изменением буфера на месте: все
    // потребители ниже (метрика уровня, live-VAD, автостоп, запись в Int16)
    // видят уже усиленный сигнал. Уровень для метрик пересчитывается из
    // усиленного буфера (с учётом клампа пиков); при выключенном AGC
    // (`NANODICTATE_GAIN_DISABLED=1`) буфер проходит без изменений, метрика = rms.
    let meteredRms = gain.apply(
      to: channel,
      frameLength: frameLength,
      rms: rms,
      sampleRate: Int(targetFormat.sampleRate)
    )
    levelDelegate?.audioLevelChanged(rms: meteredRms)

    // Вся общая память (isRecording, collectedSamples, rmsHistory, лимит,
    // live-VAD) — под блокировкой: stop()/cancel() снимают снимок на
    // главном потоке синхронно с накоплением здесь.
    var deliveredSegment: [Int16]?
    lock.lock()
    guard isRecordingLocked else {
      lock.unlock()
      return
    }
    // История RMS по буферам — для сводных метрик уровня в конце записи.
    // 60 c при буфере 4096 фреймов и 48 кГц ≈ 700 значений — памятью не жертвуем.
    rmsHistory.append(meteredRms)

    // Первый буфер сеанса — доказательство, что звук реально пошёл в движок
    // (длительность куска и его энергия; при сломанном микрофоне rms ≈ 0).
    if !didLogFirstBuffer {
      didLogFirstBuffer = true
      if isDebug {
        Logger.log(
          String(
            format:
              "record first buffer: inFrames=%d (%.3f s @ %.0f Hz), outFrames=%d, rms=%.4f (%.1f dBFS)",
            buffer.frameLength,
            Double(buffer.frameLength) / buffer.format.sampleRate,
            buffer.format.sampleRate,
            frameLength,
            meteredRms,
            AudioMetrics.dbfs(meteredRms)
          ),
          level: "debug"
        )
      }
    }

    // Ограничение памяти: добавляем не больше, чем укладывается в лимит
    // (960 000 сэмплов на 60 с). Буфер никогда не превышает этот предел.
    let sampleStart = collectedSamples.count
    let appendCount = min(frameLength, limit.remainingSamples(after: collectedSamples.count))
    collectedSamples.reserveCapacity(
      min(collectedSamples.count + frameLength, limit.maxSamples)
    )
    for i in 0..<appendCount {
      let sample = channel[i]
      if sample > 1.0 {
        collectedSamples.append(Int16(32767))
      } else if sample < -1.0 {
        collectedSamples.append(Int16(-32768))
      } else {
        collectedSamples.append(Int16(sample * 32767))
      }
    }
    let sampleEnd = collectedSamples.count

    // Live-VAD поверх только что посчитанного RMS: непрерывная речь — один
    // уттеренс; пауза ≥ pauseDuration (в сэмплах) закрывает его сегментом,
    // а при накопленной речи ≥ liveChunkWindowSamples тот же сегмент
    // вырезает микро-пауза liveMicroPauseSamples — текст идёт во время
    // говорения, не дожидаясь длинной паузы. Пороги те же, что у
    // оффлайн-сегментера (silenceRMS, pauseDuration). Доставка сегмента —
    // КОПИЕЙ наружу (onSpeechSegment ПОСЛЕ unlock); сам collectedSamples
    // не трогается и продолжает собирать всю запись для финального прохода.
    //
    // Общий код доставки для обеих веток (полная пауза и чанк): пост-ролл
    // 0.25 c тишины к последней порции речи (индекс клампится концом
    // буфера — пост-ролл не выходит за запись), запоминание индекса среза
    // (pre-roll следующего уттеренса не заедет в уже доставленный кусок)
    // и сброс VAD. Диапазон заведомо непуст: уттеренс содержит ≥1 сэмпла
    // речи (liveUtteranceEnd > liveUtteranceStart), пост-ролл неотрицателен
    // — срез без пустой-диапазонной ветки.
    let deliverSegment: () -> Void = {
      // Вызывается только при liveUtteranceStart != nil (см. ниже) — nil
      // невозможен по инварианту, гард — страховка для компайлера.
      guard let start = self.liveUtteranceStart else { return }
      let postEnd = min(
        self.liveUtteranceEnd + self.livePostRollSamples, self.collectedSamples.count)
      let cutIndex = postEnd
      deliveredSegment = Array(self.collectedSamples[start..<postEnd])
      self.liveLastCutIndex = cutIndex
      self.resetLiveVADLocked()
    }

    if meteredRms < liveSilenceRMS {
      if liveUtteranceStart != nil {
        // Пауза внутри уттеренса: открываем. Уттеренс закрывается
        // ПОЛНОЙ паузой pauseDuration (как раньше) — либо микро-паузой
        // liveMicroPauseSamples, если непрерывная речь накопила окно
        // liveChunkWindowSamples (чанк вырезается при ближайшем
        // межсловном пробеле). Пауза короче обоих порогов — внутренний
        // пробел (мнимый «вздох» не рвёт фразу): накопленная речь при
        // этом НЕ сбрасывается, прогресс чанка сохраняется.
        if liveSilenceStart == nil {
          liveSilenceStart = sampleStart
        }
        // nil невозможен: только что инициализирован sampleStart (либо был
        // установлен ранее) — ?? здесь страховка для компайлера.
        let silenceStart = liveSilenceStart ?? sampleStart
        let pauseLen = sampleEnd - silenceStart
        let dueForChunk = liveSpeechDurationSamples >= liveChunkWindowSamples
        if (dueForChunk && pauseLen >= liveMicroPauseSamples) || pauseLen >= livePauseSamples {
          deliverSegment()
        }
      }
    } else {
      // Речь: начинаем уттеренс (или продлеваем последнюю порцию речи),
      // накопленная пауза сбрасывается, длительность РЕЧИ растёт — счётчик
      // чанков, межсловные микро-паузы его не обнуляют. Pre-roll отступает
      // от старта речи на 0.5 c, но не заезжает в уже доставленный сегмент
      // (liveLastCutIndex) и не уходит в отрицательные индексы.
      if liveUtteranceStart == nil {
        liveUtteranceStart = max(sampleStart - livePreRollSamples, liveLastCutIndex)
      }
      liveUtteranceEnd = sampleEnd
      liveSilenceStart = nil
      liveSpeechDurationSamples += sampleEnd - sampleStart
    }

    // Жёсткий лимит по времени (60 c) и/или по объёму буфера — принудительный
    // стоп тем же путём, которым запись останавливается пользователем.
    let elapsed = CFAbsoluteTimeGetCurrent() - recordStartTime
    let shouldStop = limit.shouldStop(elapsed: elapsed, totalSamples: collectedSamples.count)
    // Автоостановка по непрерывной тишине (~3 c): детектор кормим ТОЛЬКО
    // если фича включена (`autoStopConfig.enabled` — рубильник из окружения,
    // см. AutoStopConfig.fromEnvironment) и лимит в этом буфере не сработал
    // (лимит имеет приоритет — запись в любом случае заканчивается, а тип
    // финализации один). Длительность буфера — фактическая: конвертированные
    // фреймы делим на целевую частоту 16 кГц. Накопление идёт по времени
    // аудио, а не по числу буферов — частота колбэков зависит от частоты
    // железа (~85 мс @ 48 кГц, ~93 мс @ 44.1 кГц), а «3 секунды тишины»
    // меряются по звуку.
    let autoStopFired =
      autoStopConfig.enabled && !shouldStop
      && autoStopDetector.feed(
        rms: meteredRms,
        duration: Double(frameLength) / Double(targetFormat.sampleRate)
      )
    lock.unlock()
    if shouldStop {
      scheduleLimitStop()
    } else if autoStopFired {
      scheduleAutoStop()
    }
    if let segment = deliveredSegment, !segment.isEmpty {
      onSpeechSegment?(segment, false)
    }
  }

  /// Диагностика молчаливого отбрасывания входного буфера в `process`
  /// (debug-only, поведение не меняет): причина + размер куска.
  private func logDroppedBuffer(reason: String, frames: AVAudioFrameCount) {
    guard isDebug else { return }
    Logger.log("record drop buffer: \(reason) frames=\(frames)", level: "debug")
  }

  /// Планирует принудительную остановку ровно один раз. Снимок сэмплов и
  /// «хвоста» (незакрытый уттеренс) берётся в `performForcedStop` на главной
  /// очереди под одной блокировкой — между планированием и финализацией
  /// буферы продолжают накапливаться, хвост ничего не теряет.
  private func scheduleLimitStop() {
    lock.lock()
    guard !limitStopScheduled else {
      lock.unlock()
      return
    }
    limitStopScheduled = true
    lock.unlock()

    // removeTap/engine.stop нельзя вызывать из колбэка tap (риск дедлока
    // и повторного входа) — переносим на главную очередь, откуда teardown
    // уйдёт на engineQueue, как обычный stop().
    DispatchQueue.main.async { [weak self] in
      self?.performForcedStop(reason: .limit)
    }
  }

  /// Планирует автоостановку по тишине ровно один раз — тот же поздний снимок
  /// в `performForcedStop`, что у `scheduleLimitStop`: «хвост» незакрытого
  /// уттеренса и полные сэмплы берутся на главной очереди, teardown движка
  /// уходит туда же (из колбэка tap removeTap вызывать нельзя).
  private func scheduleAutoStop() {
    lock.lock()
    // Защёлка живёт в регистре `session` (бит autoStop), но проверяется под
    // NSLock: планировщик вызывается с realtime-пути, где важна и ранняя
    // отсечка без входа в буферы (автостоп — событие, не каждый буфер).
    guard !isAutoStopScheduled else {
      lock.unlock()
      return
    }
    session.latchAutoStop()
    lock.unlock()

    DispatchQueue.main.async { [weak self] in
      self?.performForcedStop(reason: .autoStopSilence)
    }
  }

  /// Причина принудительной остановки: лимит длительности или автоостановка
  /// по непрерывной тишине. Механика финализации одна — различается только
  /// колбэк, который получает сэмплы.
  private enum ForcedStopReason {
    case limit
    case autoStopSilence
  }

  /// Тех же путь, что и `stop()`: снятие tap, остановка движка, «drain»
  /// конвертера, доставка собранных сэмплов через колбэк финализации.
  /// «Хвост» отдаётся ДО колбэка — клиент успевает поставить его в очередь
  /// распознавания раньше финализации всей записи.
  /// Снимок — на главной очереди, максимально поздно: между `schedule*`
  /// (аудиопоток) и финализацией tap успевает добрать ~100-200 мс, иначе
  /// хвост последней фразы терялся.
  private func performForcedStop(reason: ForcedStopReason) {
    lock.lock()
    // Пользователь уже остановил запись — не дублируем финализацию.
    guard isRecordingLocked else {
      lock.unlock()
      return
    }
    let duration = CFAbsoluteTimeGetCurrent() - recordStartTime
    setRecording(false)
    let rms = rmsHistory
    rmsHistory = []
    let tail = takeLiveTailLocked()
    let samples = collectedSamples
    lock.unlock()

    if isDebug {
      Logger.log(
        "record forced stop (\(reason == .limit ? "limit" : "silence auto-stop")): "
          + "tearing engine down (samples=\(samples.count))",
        level: "debug"
      )
    }
    // Разборка — на очереди того же движка (снимок пары под lock), см.
    // комментарий в stop().
    let forcedSlot = captureEngineSlot()
    forcedSlot.queue.async { [weak self, engine = forcedSlot.engine] in
      guard let self else { return }
      self.teardownOnEngineQueue(using: engine)
    }
    logRecordingFinale(samples: samples, duration: duration, rmsHistory: rms)
    if !tail.isEmpty {
      onSpeechSegment?(tail, true)
    }
    switch reason {
    case .limit:
      onRecordingLimitReached?(samples)
    case .autoStopSilence:
      onAutoStop?(samples)
    }
  }

  /// Единый финальный лог записи для `stop()` и принудительной остановки по
  /// лимиту: lifecycle (всегда, `info`) + метрологию уровня (только при
  /// `logLevel == "debug"`). Ошибок не бросает: логирование не должно ронять
  /// запись.
  private func logRecordingFinale(samples: [Int16], duration: TimeInterval, rmsHistory: [Float]) {
    Logger.log(
      String(
        format: "record stop: duration=%.2f s, sampleRate=%d, channels=%d, frames=%d, bytes=%d",
        duration,
        16000,
        1,
        samples.count,
        samples.count * 2
      ),
      level: "info"
    )

    guard isDebug else { return }
    let summary = AudioMetrics.summarize(rmsValues: rmsHistory)
    Logger.log(
      String(
        format:
          "record metering: rms min=%.4f (%.1f dBFS), avg=%.4f (%.1f dBFS), max=%.4f (%.1f dBFS), nearSilence=%@",
        Double(summary.minRMS),
        Double(AudioMetrics.dbfs(summary.minRMS)),
        Double(summary.avgRMS),
        Double(AudioMetrics.dbfs(summary.avgRMS)),
        Double(summary.maxRMS),
        Double(AudioMetrics.dbfs(summary.maxRMS)),
        summary.nearSilence ? "true" : "false"
      ),
      level: "debug"
    )
  }
}

public enum AudioServiceError: Error, LocalizedError {
  case unsupportedFormat
  /// Экземпляр AudioService уничтожен до завершения старта (в проде недостижимо).
  case engineGone
  /// Старт завершился, когда движок уже подменён (wedge после таймаута
  /// сторожа): сессия устарела. Пользователю НЕ показывается — completion
  /// устаревшего старта агент игнорирует. Главное: такой старт не приводит
  /// к audio.cancel()/переходу в .recording на живой свежей паре.
  case engineSuperseded
  /// Смена аудио-устройства во время записи: живой tap-конвертер собран под
  /// старый входной формат и пересоздан быть не может без разрыва сеанса.
  /// Понятная ошибка пользователю вместо тишины в записи.
  case deviceChanged
  public var errorDescription: String? {
    switch self {
    case .unsupportedFormat: return L10n.tr("error.unsupportedAudioFormat")
    case .engineGone: return L10n.tr("error.audioServiceUnavailable")
    case .engineSuperseded: return L10n.tr("error.audioServiceUnavailable")
    case .deviceChanged:
      // Ключ error.audioDeviceChanged заведён в roadmap L10n-таблиц; пока
      // таблиц нет — явная строка по L10n.language, не raw key в UI.
      switch L10n.language {
      case .ru: return "Аудио-устройство изменилось — запись остановлена. Начните запись заново."
      case .en: return "Audio device changed — recording stopped. Please start recording again."
      }
    }
  }
}

// swiftlint:disable file_length
// Причина отключения: AudioService — единый аудио-конвейер (старт/стоп/VAD/
// лимиты/метрики); сокращение тела без удаления кода контракты не сохраняет.
