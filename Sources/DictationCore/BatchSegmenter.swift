import Foundation

// MARK: - Ответственность: пакетная сегментация файла (без микрофонного пути)
// Чистое разбиение PCM-сэмплов файла на чанки ФИКСИРОВАННОЙ длины (maxSegment
// секунд) с оверлэпом. По образцу AudioSegmenter.segments: чанк = последние
// overlap секунд ТЕЛА предыдущего чанка + тело текущего чанка. Тела чанков
// идут подряд без пропусков и перекрытий — файл покрыт полностью, каждый
// сэмпл транскрибируется ровно один раз как «тело», а оверлэп даёт контекст
// на границе. Никакого I/O и никакого VAD: пакетное распознавание файла не
// зависит от пауз речи, границы задаются только временем.

/// Один чанк пакетного распознавания.
public struct BatchChunk: Equatable {
    /// Порядковый номер (0-based).
    public let index: Int
    /// Начало тела чанка от начала файла, секунды (без оверлэпа).
    public let bodyStart: TimeInterval
    /// Конец тела чанка от начала файла, секунды (без оверлэпа).
    public let bodyEnd: TimeInterval
    /// PCM-сэмплы: последние `overlap` секунд тела предыдущего чанка (или
    /// целиком предыдущее тело, если оно короче оверлэпа) + тело текущего.
    /// У первого чанка — только тело.
    public let samples: [Int16]

    public init(index: Int, bodyStart: TimeInterval, bodyEnd: TimeInterval, samples: [Int16]) {
        self.index = index
        self.bodyStart = bodyStart
        self.bodyEnd = bodyEnd
        self.samples = samples
    }
}

public enum BatchSegmenter {

    /// Нарезает Int16 PCM-сэмплы (16 кГц) на чанки фиксированной длины с
    /// оверлэпом. Гарантии:
    /// - тела чанков покрывают файл подряд без пропусков и перекрытий;
    /// - каждый чанк (кроме первого) начинает сэмплы с хвоста тела
    ///   предыдущего чанка длиной `overlap` секунд (контекст границы);
    /// - пустые входные сэмплы дают пустой результат.
    public static func segments(
        samples: [Int16],
        sampleRate: Int = 16000,
        maxSegment: TimeInterval = 30,
        overlap: TimeInterval = 2.5
    ) -> [BatchChunk] {
        guard !samples.isEmpty else { return [] }
        let bodySize = max(1, Int((maxSegment * Double(sampleRate)).rounded()))
        let overlapCount = max(0, min(Int((overlap * Double(sampleRate)).rounded()), samples.count))

        var result: [BatchChunk] = []
        var bodyStart = 0
        var prevBodyEnd: Int? = nil
        var index = 0

        while bodyStart < samples.count {
            let bodyEnd = min(bodyStart + bodySize, samples.count)
            let body = Array(samples[bodyStart..<bodyEnd])

            var chunkSamples = body
            if let prevBodyEnd = prevBodyEnd, overlapCount > 0 {
                let overlapFrom = max(0, prevBodyEnd - overlapCount)
                chunkSamples = Array(samples[overlapFrom..<prevBodyEnd]) + body
            }

            result.append(BatchChunk(
                index: index,
                bodyStart: TimeInterval(bodyStart) / Double(sampleRate),
                bodyEnd: TimeInterval(bodyEnd) / Double(sampleRate),
                samples: chunkSamples
            ))

            index += 1
            prevBodyEnd = bodyEnd
            bodyStart = bodyEnd
        }
        return result
    }
}