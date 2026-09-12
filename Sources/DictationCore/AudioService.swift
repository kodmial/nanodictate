import Foundation
import AVFoundation

/// Делегат для получения уровня звука (RMS) для анимации.
public protocol AudioLevelDelegate: AnyObject {
    func audioLevelChanged(rms: Float)
}

/// Запись звука с микрофона через AVAudioEngine (16кГц моно).
///
/// Входной узел на macOS работает в аппаратном формате (обычно 48 кГц),
/// и `connect(input, to:format:)` с чужим sample rate кидает исключение
/// (`format.sampleRate == hwFormat.sampleRate`). Поэтому tap ставится на
/// аппаратном формате, а пересэмплинг в 16 кГц/моно делает AVAudioConverter.
public final class AudioService {
    public weak var levelDelegate: AudioLevelDelegate?

    private let engine = AVAudioEngine()
    private let targetFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var collectedSamples: [Int16] = []
    private var isRecording = false

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

        // Float32 → Int16
        collectedSamples.reserveCapacity(collectedSamples.count + frameLength)
        for i in 0..<frameLength {
            let s = channel[i]
            if s > 1.0 {
                collectedSamples.append(Int16(32767))
            } else if s < -1.0 {
                collectedSamples.append(Int16(-32768))
            } else {
                collectedSamples.append(Int16(s * 32767))
            }
        }
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