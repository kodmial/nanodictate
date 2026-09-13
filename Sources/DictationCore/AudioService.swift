import Foundation
import AVFoundation

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

    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var collectedSamples: [Int16] = []
    private var isRecording = false
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

    public init(logLevel: String = "info") {
        self.logLevel = logLevel
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

    /// Начинает запись. Бросает ошибку при недоступности микрофона.
    public func start() throws {
        collectedSamples = []
        rmsHistory = []
        // Новый сеанс — чистый лимит (после предыдущей принудительной остановки).
        limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
        recordStartTime = CFAbsoluteTimeGetCurrent()
        lock.lock()
        limitStopScheduled = false
        lock.unlock()
        let input = engine.inputNode
        let hwFormat = input.outputFormat(forBus: 0)
        guard let converter = AVAudioConverter(from: hwFormat, to: targetFormat) else {
            throw AudioServiceError.unsupportedFormat
        }
        self.converter = converter

        // Доступ к микрофону (TCC) при каждом создании/повторном старте записи.
        // Повторный системный запрос доступа (главная жалоба) выглядит в логе
        // как статус notDetermined перед стартом — сразу видно, что грант теряется.
        let mic = MicrophoneAuth.statusText(AVCaptureDevice.authorizationStatus(for: .audio))
        Logger.log("mic permission: \(mic) (record start)", level: "info")
        Logger.log("record start: sampleRate=\(Int(targetFormat.sampleRate)) Hz, channels=\(targetFormat.channelCount), hwFormat=\(Int(hwFormat.sampleRate)) Hz", level: "info")

        // Tap вешается на аппаратный формат; конвертация выполняется в блоке.
        input.installTap(
            onBus: 0,
            bufferSize: 4096,
            format: hwFormat
        ) { [weak self] buffer, _ in
            self?.process(buffer)
        }
        engine.prepare()
        try engine.start()
        isRecording = true
    }

    /// Останавливает запись и возвращает собранные сэмплы (Int16, 16кГц).
    public func stop() -> [Int16] {
        guard isRecording else { return [] }
        let duration = CFAbsoluteTimeGetCurrent() - recordStartTime
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        let samples = collectedSamples
        logRecordingFinale(samples: samples, duration: duration)
        return samples
    }

    /// Отменяет запись, отбрасывая данные.
    public func cancel() {
        guard isRecording else { return }
        let duration = CFAbsoluteTimeGetCurrent() - recordStartTime
        let frames = collectedSamples.count
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        collectedSamples = []
        // Отмена тоже завершает запись — без отправки в STT; длительность и
        // объём помогают отличать «пустую» отмену от отмены после реальной речи.
        if logLevel.lowercased() == "debug" {
            Logger.log(String(
                format: "record cancel: duration=%.2f s, frames=%d, bytes=%d",
                duration, frames, frames * 2
            ), level: "debug")
        }
    }

    // MARK: - Private

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
        guard let converter = converter,
              let result = AudioService.convertOnce(
                  input: buffer,
                  inputFormat: buffer.format,
                  converter: converter,
                  targetFormat: targetFormat
              ),
              let channel = result.converted.floatChannelData?[0] else {
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
        // История RMS по буферам — для сводных метрик уровня в конце записи.
        // 60 c при буфере 4096 фреймов и 48 кГц ≈ 700 значений — памятью не жертвуем.
        rmsHistory.append(rms)

        // Ограничение памяти: добавляем не больше, чем укладывается в лимит
        // (960 000 сэмплов на 60 с). Буфер никогда не превышает этот предел.
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

        // Жёсткий лимит по времени (60 c) и/или по объёму буфера — принудительный
        // стоп тем же путём, которым запись останавливается пользователем.
        let elapsed = CFAbsoluteTimeGetCurrent() - recordStartTime
        if limit.shouldStop(elapsed: elapsed, totalSamples: collectedSamples.count) {
            scheduleLimitStop()
        }
    }

    /// Планирует принудительную остановку ровно один раз. Сэмплы снимаются здесь
    /// (на аудиопотоке) синхронно, чтобы клиент получил законченный буфер.
    private func scheduleLimitStop() {
        lock.lock()
        let already = limitStopScheduled
        limitStopScheduled = true
        lock.unlock()
        guard !already else { return }

        let samples = collectedSamples
        // removeTap/engine.stop нельзя вызывать из колбэка tap (риск дедлока
        // и повторного входа) — переносим на главную очередь, как обычный stop().
        DispatchQueue.main.async { [weak self] in
            self?.performLimitStop(samples: samples)
        }
    }

    /// Тех же путь, что и `stop()`: снятие tap, остановка движка, «drain»
    /// конвертера, доставка собранных сэмплов через колбэк финализации.
    private func performLimitStop(samples: [Int16]) {
        // Пользователь уже остановил запись — не дублируем финализацию.
        guard isRecording else { return }
        let duration = CFAbsoluteTimeGetCurrent() - recordStartTime
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        collectedSamples = []
        logRecordingFinale(samples: samples, duration: duration)
        onRecordingLimitReached?(samples)
    }

    /// Единый финальный лог записи для `stop()` и принудительной остановки по
    /// лимиту: lifecycle (всегда, `info`) + метрологию уровня (только при
    /// `logLevel == "debug"`). Ошибок не бросает: логирование не должно ронять
    /// запись.
    private func logRecordingFinale(samples: [Int16], duration: TimeInterval) {
        Logger.log(String(
            format: "record stop: duration=%.2f s, sampleRate=%d, channels=%d, frames=%d, bytes=%d",
            duration, 16000, 1, samples.count, samples.count * 2
        ), level: "info")

        guard logLevel.lowercased() == "debug" else { return }
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
    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat: return "Неподдерживаемый аудиоформат"
        }
    }
}