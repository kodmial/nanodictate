import Foundation
import AVFoundation
import AudioEngineGuard

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
        return inputNode
    }
}

// MARK: - ObjC-шлюз для NSException AVFAudio

/// Тач-функции модуля AudioEngineGuard (см. AudioEngineExceptionGuard.h/m):
/// DictationRunAudioEngineBlockGuarded выполняет блок под ObjC @try/@catch и
/// возвращает NSError вместо NSException, которое AVFAudio умеет поднимать
/// внутри installTap/prepare/start (SetOutputFormat) и которое в Swift не
/// ловится через try — падает SIGABRT.

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
        self.maxSamples = max(1, Int(Double(sampleRate) * maxDuration))
    }

    /// Достигнут ли лимит (по времени ИЛИ по объёму). После первого срабатывания
    /// метод всегда возвращает `true` — остановка необратима в рамках сеанса.
    public mutating func shouldStop(elapsed: TimeInterval, totalSamples: Int) -> Bool {
        if isExhausted { return true }
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
public final class AudioService {
    public weak var levelDelegate: AudioLevelDelegate?

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

    private let engine: AudioEngineLike
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var collectedSamples: [Int16] = []
    private var isRecording = false
    private var tapInstalled = false
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
    /// Первый буфер сеанса логируется отдельно (debug): длительность и энергия
    /// показывают, пошёл ли реально звук в движок после старта.
    private var didLogFirstBuffer = false

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
    private let engineQueue = DispatchQueue(label: "dictation.audio.engine", qos: .userInitiated)
    /// Фоновая очередь движка или главная — определяется движком, не потоком
    /// вызова. Используется только для диагностики.
    private var isDebug: Bool { logLevel.lowercased() == "debug" }

    public init(
        logLevel: String = "info",
        engine: AudioEngineLike? = nil,
        segmenterConfig: AudioSegmenterConfig = .defaults
    ) {
        self.logLevel = logLevel
        self.engine = engine ?? AVAudioEngine()
        // Live-VAD живёт на тех же порогах, что оффлайн-сегментация записи:
        // один и тот же `silenceRMS`, одна и та же пауза `pauseDuration`.
        self.liveSilenceRMS = segmenterConfig.silenceRMS
        self.livePauseSamples = max(1, Int((segmenterConfig.pauseDuration * 16000).rounded()))
        // Pre-roll 0.5 c (8000 сэмплов) и post-roll 0.25 c (4000 сэмплов)
        // при 16 кГц — запас, который не даёт срезать атаку и хвост слова.
        self.livePreRollSamples = Int((0.5 * 16000).rounded())
        self.livePostRollSamples = Int((0.25 * 16000).rounded())
        // Режим «чанков» при непрерывной речи: окно 3.0 c (48000 сэмплов)
        // накопленной РЕЧИ + микро-пауза 0.25 c (4000 сэмплов) разрешают
        // выдачу текста во время говорения — не дожидаясь полной паузы 1 c.
        self.liveChunkWindowSamples = Int((3.0 * 16000).rounded())
        self.liveMicroPauseSamples = Int((0.25 * 16000).rounded())
        // Формат, в который пересэмплируем всё аудио: 16 кГц, моно, Float32.
        // Данный init гарантированно валиден на macOS 12+.
        // swiftlint:disable:next force_unwrapping
        self.targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16000,
            channels: 1,
            interleaved: false
        )!
    }

    // MARK: - Старт

    /// Начинает запись. Асинхронно: подъём движка идёт на фоновой очереди
    /// (`engineQueue`), completion вызывается на главном потоке. При недоступности
    /// микрофона или сбое движка — `.failure` (движок при этом разобран и готов
    /// к повторному старту, см. `startOnEngineQueue`).
    public func start(completion: @escaping (Result<Void, Error>) -> Void) {
        engineQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion(.failure(AudioServiceError.engineGone)) }
                return
            }
            let result = self.startOnEngineQueue()
            DispatchQueue.main.async { completion(result) }
        }
    }

    /// Весь подъём движка — строго на engineQueue.
    private func startOnEngineQueue() -> Result<Void, Error> {
        // Новый сеанс: чистые буферы, чистый лимит (после принудительной
        // остановки или аварийной ветки).
        collectedSamples = []
        rmsHistory = []
        didLogFirstBuffer = false
        limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
        recordStartTime = CFAbsoluteTimeGetCurrent()
        lock.lock()
        limitStopScheduled = false
        liveLastCutIndex = 0
        resetLiveVADLocked()
        lock.unlock()

        // Безопасный старт с нуля: если предыдущая сессия оставила движок с
        // установленным tap (аварийная ветка), снимаем его ДО installTap —
        // повторный installTap на тот же bus поднимает NSException (краш).
        if isTapInstalled {
            teardownOnEngineQueue()
        }

        let input = engine.makeInputNode()
        let hwFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            Logger.log("record engine: AVAudioConverter init failed (hw=\(Int(hwFormat.sampleRate)) Hz -> target=\(Int(targetFormat.sampleRate)) Hz)", level: "error")
            return .failure(AudioServiceError.unsupportedFormat)
        }
        self.converter = converter

        // Доступ к микрофону (TCC) при каждом создании/повторном старте записи.
        // Повторный системный запрос доступа (главная жалоба) выглядит в логе
        // как статус notDetermined перед стартом — сразу видно, что грант теряется.
        let mic = MicrophoneAuth.statusText(AVCaptureDevice.authorizationStatus(for: .audio))
        Logger.log("mic permission: \(mic) (record start)", level: "info")
        Logger.log("record start: sampleRate=\(Int(targetFormat.sampleRate)) Hz, channels=\(targetFormat.channelCount), hwFormat=\(Int(hwFormat.sampleRate)) Hz", level: "info")

        // Хлебные крошки перед каждым шагом старта движка: если следующий вызов
        // AVFoundation крэшнет, последняя строка лога укажет точное место.
        if isDebug {
            let inFmt = input.outputFormat(forBus: 0)
            Logger.log(String(
                format: "record engine: inputNode format=%.0f Hz, %d ch, commonFormat=%@, interleaved=%@; target=%.0f Hz, %d ch",
                inFmt.sampleRate, inFmt.channelCount,
                String(describing: inFmt.commonFormat), inFmt.isInterleaved ? "yes" : "no",
                targetFormat.sampleRate, targetFormat.channelCount
            ), level: "debug")
            Logger.log("record engine: installing tap (bus 0, bufferSize 4096, hwFormat=\(Int(hwFormat.sampleRate)) Hz)", level: "debug")
        }

        // Tap вешается на аппаратный формат; конвертация выполняется в блоке.
        var failure = guardedEngineCall {
            input.installTap(
                onBus: 0,
                bufferSize: 4096,
                format: hwFormat
            ) { [weak self] buffer, _ in
                self?.process(buffer)
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
                self.engine.prepare()
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
                try self.engine.start()
            }
        }
        if let failure = failure {
            // Терминальная ветка: движок обязан быть разобран (tap снят, движок
            // остановлен, буферы очищены) — иначе следующий Alt+Alt упадёт на
            // повторном installTap на занятом bus.
            setRecording(false)
            teardownOnEngineQueue()
            Logger.log("record engine: start failed: \(failure.localizedDescription)", level: "error")
            return .failure(failure)
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
        guard isRecording else {
            lock.unlock()
            return []
        }
        let duration = CFAbsoluteTimeGetCurrent() - recordStartTime
        isRecording = false
        // «Хвост» (незакрытый уттеренс) забираем тем же снимком, под той же
        // блокировкой — VAD-состояние и буфер записи согласованы.
        let tail = takeLiveTailLocked()
        let samples = collectedSamples
        collectedSamples = []
        let rms = rmsHistory
        rmsHistory = []
        lock.unlock()

        engineQueue.async { [weak self] in
            self?.teardownOnEngineQueue()
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
        guard isRecording else {
            lock.unlock()
            return
        }
        let duration = CFAbsoluteTimeGetCurrent() - recordStartTime
        let frames = collectedSamples.count
        isRecording = false
        collectedSamples = []
        // Отмена отбрасывает ВСЁ, включая незакрытый уттеренс: колбэка
        // onSpeechSegment нет (Esc = данные не доставляются).
        liveLastCutIndex = 0
        resetLiveVADLocked()
        lock.unlock()

        engineQueue.async { [weak self] in
            self?.teardownOnEngineQueue()
        }
        // Отмена тоже завершает запись — без отправки в STT; длительность и
        // объём помогают отличать «пустую» отмену от отмены после реальной речи.
        if isDebug {
            Logger.log(String(
                format: "record cancel: duration=%.2f s, frames=%d, bytes=%d",
                duration, frames, frames * 2
            ), level: "debug")
        }
    }

    // MARK: - Private

    /// Выполняет блок операций движка под ObjC-шлюзом: NSException AVFAudio
    /// превращается в NSError, Swift-ошибка (engine.start() throws) пробрасывается
    /// как есть. nil — операция прошла без ошибок.
    internal func guardedEngineCall(_ body: @escaping () throws -> Void) -> Error? {
        final class ErrorBox {
            var captured: Error?
        }
        let box = ErrorBox()
        let nsError = DictationRunAudioEngineBlockGuarded {
            do {
                try body()
            } catch {
                box.captured = error
            }
        }
        return nsError ?? box.captured
    }

    /// Разборка движка — строго на engineQueue. Идемпотентна: снять не
    /// установленный tap / остановить не запущенный движок безопасно (все
    /// вызовы под шлюзом NSException).
    private func teardownOnEngineQueue() {
        if isTapInstalled {
            let _ = guardedEngineCall {
                self.engine.makeInputNode().removeTap(onBus: 0)
            }
            setTapInstalled(false)
        }
        let _ = guardedEngineCall {
            self.engine.stop()
        }
        setRecording(false)
        converter = nil
        lock.lock()
        collectedSamples = []
        rmsHistory = []
        liveLastCutIndex = 0
        resetLiveVADLocked()
        lock.unlock()
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

    private func setRecording(_ value: Bool) {
        lock.lock()
        isRecording = value
        lock.unlock()
    }

    private var isRecordingLocked: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isRecording
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

    /// Реальный объём выхода при ресемплинге пропорционален частотам:
    /// `inputFrames × outputRate / inputRate` + запас (¼), чтобы конвертер
    /// наполнил выход за один проход из одного входного буфера.
    internal static func outputFrameCapacity(
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
    internal static func convertOnce(
        input: AVAudioPCMBuffer,
        inputFormat: AVAudioFormat,
        converter: AVAudioConverter,
        targetFormat: AVAudioFormat
    ) -> (converted: AVAudioPCMBuffer, status: AVAudioConverterOutputStatus)? {
        guard let converted = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: outputFrameCapacity(
                forInputFrames: input.frameLength,
                inputRate: inputFormat.sampleRate,
                outputRate: targetFormat.sampleRate
            )
        ) else { return nil }

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

    private func process(_ buffer: AVAudioPCMBuffer) {
        // После принудительной остановки по лимиту «хвост» не записываем:
        // буфер в памяти дальше не растёт.
        guard !limit.isExhausted else { return }
        guard let converter = converter else {
            logDroppedBuffer(reason: "converter is nil (stopped?)", frames: buffer.frameLength)
            return
        }
        guard let result = AudioService.convertOnce(
            input: buffer,
            inputFormat: buffer.format,
            converter: converter,
            targetFormat: targetFormat
        ) else {
            logDroppedBuffer(reason: "convertOnce -> nil (empty output or error)", frames: buffer.frameLength)
            return
        }
        guard let channel = result.converted.floatChannelData?[0] else {
            logDroppedBuffer(reason: "converted buffer has no float channel", frames: buffer.frameLength)
            return
        }
        let converted = result.converted
        let frameLength = Int(converted.frameLength)

        // RMS для анимации
        var sum: Float = 0
        for i in 0..<frameLength {
            let s = channel[i]
            sum += s * s
        }
        let rms = frameLength > 0 ? sqrt(sum / Float(frameLength)) : 0
        levelDelegate?.audioLevelChanged(rms: rms)

        // Вся общая память (isRecording, collectedSamples, rmsHistory, лимит,
        // live-VAD) — под блокировкой: stop()/cancel() снимают снимок на
        // главном потоке синхронно с накоплением здесь.
        var deliveredSegment: [Int16]?
        lock.lock()
        guard isRecording else {
            lock.unlock()
            return
        }
        // История RMS по буферам — для сводных метрик уровня в конце записи.
        // 60 c при буфере 4096 фреймов и 48 кГц ≈ 700 значений — памятью не жертвуем.
        rmsHistory.append(rms)

        // Первый буфер сеанса — доказательство, что звук реально пошёл в движок
        // (длительность куска и его энергия; при сломанном микрофоне rms ≈ 0).
        if !didLogFirstBuffer {
            didLogFirstBuffer = true
            if isDebug {
                Logger.log(String(
                    format: "record first buffer: inFrames=%d (%.3f s @ %.0f Hz), outFrames=%d, rms=%.4f (%.1f dBFS)",
                    buffer.frameLength, Double(buffer.frameLength) / buffer.format.sampleRate,
                    buffer.format.sampleRate, frameLength, rms,
                    AudioMetrics.dbfs(rms)
                ), level: "debug")
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
            let s = channel[i]
            if s > 1.0 {
                collectedSamples.append(Int16(32767))
            } else if s < -1.0 {
                collectedSamples.append(Int16(-32768))
            } else {
                collectedSamples.append(Int16(s * 32767))
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
            let postEnd = min(self.liveUtteranceEnd + self.livePostRollSamples, self.collectedSamples.count)
            let cutIndex = postEnd
            deliveredSegment = Array(self.collectedSamples[self.liveUtteranceStart!..<postEnd])
            self.liveLastCutIndex = cutIndex
            self.resetLiveVADLocked()
        }

        if rms < liveSilenceRMS {
            if liveUtteranceStart != nil {
                // Пауза внутри уттеренса: открываем. Уттеренс закрывается
                // ПОЛНОЙ паузой pauseDuration (как раньше) — либо микро-паузой
                // liveMicroPauseSamples, если непрерывная речь накопила окно
                // liveChunkWindowSamples (чанк вырезается при ближайшем
                // межсловном пробеле). Пауза короче обоих порогов — внутренний
                // пробел (мнимый «вздох» не рвёт фразу): накопленная речь при
                // этом НЕ сбрасывается, прогресс чанка сохраняется.
                if liveSilenceStart == nil { liveSilenceStart = sampleStart }
                let pauseLen = sampleEnd - liveSilenceStart!
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
        lock.unlock()
        if shouldStop {
            scheduleLimitStop()
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

    /// Планирует принудительную остановку ровно один раз. Сэмплы и «хвост»
    /// (незакрытый уттеренс) снимаются здесь (на аудиопотоке) синхронно, под
    /// одной блокировкой — клиент получает законченный буфер: и всю запись,
    /// и последнюю фразу для live-распознавания.
    private func scheduleLimitStop() {
        lock.lock()
        guard !limitStopScheduled else {
            lock.unlock()
            return
        }
        limitStopScheduled = true
        let tail = takeLiveTailLocked()
        let samples = collectedSamples
        lock.unlock()

        // removeTap/engine.stop нельзя вызывать из колбэка tap (риск дедлока
        // и повторного входа) — переносим на главную очередь, откуда teardown
        // уйдёт на engineQueue, как обычный stop().
        DispatchQueue.main.async { [weak self] in
            self?.performLimitStop(samples: samples, tail: tail)
        }
    }

    /// Тех же путь, что и `stop()`: снятие tap, остановка движка, «drain»
    /// конвертера, доставка собранных сэмплов через колбэк финализации.
    /// «Хвост» отдаётся ДО колбэка лимита — клиент успевает поставить его в
    /// очередь распознавания раньше финализации всей записи.
    private func performLimitStop(samples: [Int16], tail: [Int16]) {
        lock.lock()
        // Пользователь уже остановил запись — не дублируем финализацию.
        guard isRecording else {
            lock.unlock()
            return
        }
        let duration = CFAbsoluteTimeGetCurrent() - recordStartTime
        isRecording = false
        let rms = rmsHistory
        rmsHistory = []
        lock.unlock()

        if isDebug {
            Logger.log("record limit stop: tearing engine down (samples=\(samples.count))", level: "debug")
        }
        engineQueue.async { [weak self] in
            self?.teardownOnEngineQueue()
        }
        logRecordingFinale(samples: samples, duration: duration, rmsHistory: rms)
        if !tail.isEmpty {
            onSpeechSegment?(tail, true)
        }
        onRecordingLimitReached?(samples)
    }

    /// Единый финальный лог записи для `stop()` и принудительной остановки по
    /// лимиту: lifecycle (всегда, `info`) + метрологию уровня (только при
    /// `logLevel == "debug"`). Ошибок не бросает: логирование не должно ронять
    /// запись.
    private func logRecordingFinale(samples: [Int16], duration: TimeInterval, rmsHistory: [Float]) {
        Logger.log(String(
            format: "record stop: duration=%.2f s, sampleRate=%d, channels=%d, frames=%d, bytes=%d",
            duration, 16000, 1, samples.count, samples.count * 2
        ), level: "info")

        guard isDebug else { return }
        let m = AudioMetrics.summarize(rmsValues: rmsHistory)
        Logger.log(String(
            format: "record metering: rms min=%.4f (%.1f dBFS), avg=%.4f (%.1f dBFS), max=%.4f (%.1f dBFS), nearSilence=%@",
            Double(m.minRMS), Double(AudioMetrics.dbfs(m.minRMS)),
            Double(m.avgRMS), Double(AudioMetrics.dbfs(m.avgRMS)),
            Double(m.maxRMS), Double(AudioMetrics.dbfs(m.maxRMS)),
            m.nearSilence ? "true" : "false"
        ), level: "debug")
    }
}

public enum AudioServiceError: Error, LocalizedError {
    case unsupportedFormat
    /// Экземпляр AudioService уничтожен до завершения старта (в проде недостижимо).
    case engineGone
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "Неподдерживаемый аудиоформат"
        case .engineGone: return "Аудио-сервис недоступен"
        }
    }
}