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
    /// Гарантирует, что принудительная остановка планируется ровно один раз.
    private let lock = NSLock()
    private var limitStopScheduled = false

    public init() {
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
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        return collectedSamples
    }

    /// Отменяет запись, отбрасывая данные.
    public func cancel() {
        guard isRecording else { return }
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        collectedSamples = []
    }

    // MARK: - Private

    private func process(_ buffer: AVAudioPCMBuffer) {
        // После принудительной остановки по лимиту «хвост» не записываем:
        // буфер в памяти дальше не растёт.
        guard !limit.isExhausted else { return }
        guard let converter = converter,
              let converted = AVAudioPCMBuffer(
                  pcmFormat: targetFormat,
                  frameCapacity: buffer.frameLength
              ) else { return }

        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            outStatus.pointee = .haveData
            return buffer
        }
        guard status == .haveData, let channel = converted.floatChannelData?[0] else {
            return
        }
        let frameLength = Int(converted.frameLength)

        // RMS для анимации
        var sum: Float = 0
        for i in 0..<frameLength {
            let s = channel[i]
            sum += s * s
        }
        let rms = frameLength > 0 ? sqrt(sum / Float(frameLength)) : 0
        levelDelegate?.audioLevelChanged(rms: rms)

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
        isRecording = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        collectedSamples = []
        onRecordingLimitReached?(samples)
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