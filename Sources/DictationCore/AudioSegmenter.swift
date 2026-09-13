import Foundation

// MARK: - VAD-сегментация записи (пошаговая диктовка)
//
// Чистое разбиение аудио на сегменты по паузам голоса (RMS-порог, как в
// AudioMetrics.nearSilenceThreshold). Никакого I/O: работаем с RMS-таймлайном
// (внутреннее представление AudioService.rmsHistory) либо с Int16 PCM-сэмплами.
// Параметры: пауза ≥ 0.8–1.5 c (default 1.0) — граница; minSegment ~3 c
// (короткие обрывки не отрезаем); maxSegment 45 c (жёсткая граница); overlap
// 1 c — к началу следующего сегмента приклеивается последняя секунда
// предыдущего, чтобы слова на стыке получали контекст.

public struct AudioSegmenterConfig: Equatable {
    /// Длительность непрерывной паузы (RMS ниже порога), после которой режем.
    public var pauseDuration: TimeInterval
    /// Минимальная длина сегмента: короче не отрезаем (нет — сегмент длиннее).
    public var minSegment: TimeInterval
    /// Жёсткая максимальная длина сегмента: по её достижении режем всегда.
    public var maxSegment: TimeInterval
    /// Хвост предыдущего сегмента, приклеиваемый к началу следующего.
    public var overlap: TimeInterval
    /// Порог «тишины» по RMS (линейный 0...1) — reuse AudioMetrics.
    public var silenceRMS: Float

    public init(
        pauseDuration: TimeInterval = 1.0,
        minSegment: TimeInterval = 3.0,
        maxSegment: TimeInterval = 45.0,
        overlap: TimeInterval = 1.0,
        silenceRMS: Float = AudioMetrics.nearSilenceThreshold
    ) {
        self.pauseDuration = pauseDuration
        self.minSegment = minSegment
        self.maxSegment = maxSegment
        self.overlap = overlap
        self.silenceRMS = silenceRMS
    }

    public static let defaults = AudioSegmenterConfig()
}

/// Один распознаваемый кусок: тело сегмента плюс приклеенный оверлэп.
public struct AudioSegment: Equatable {
    /// Начало тела сегмента (без оверлэпа) от начала записи, секунды.
    public let start: TimeInterval
    /// Конец тела сегмента (без оверлэпа) от начала записи, секунды.
    public let end: TimeInterval
    /// PCM-сэмплы: тело сегмента + последние `overlap` секунд предыдущего
    /// (или целый предыдущий, если он короче оверлэпа). У первого — без оверлэпа.
    public let samples: [Int16]

    public init(start: TimeInterval, end: TimeInterval, samples: [Int16]) {
        self.start = start
        self.end = end
        self.samples = samples
    }
}

public enum AudioSegmenter {

    /// Оконная длительность при работе с сэмплами: 85 мс при 16 кГц = 1360
    /// сэмплов (как RMS-буферы AudioService.rmsHistory).
    public static let defaultWindowDuration: TimeInterval = 0.085

    // MARK: - Разбиение по RMS-таймлайну

    /// Делит RMS-таймлайн (одно значение на окно) на диапазоны окон сегментов.
    ///
    /// Гарантии:
    /// - граница только после непрерывной паузы длиной ≥ `pauseDuration`;
    /// - сегмент короче `minSegment` не отрезается (склеивается со следующим);
    /// - при достижении `maxSegment` граница ставится принудительно (даже
    ///   посреди речи — жёсткий потолок);
    /// - на стыке тишина не входит ни в один сегмент (режем у кромок паузы);
    /// - на выходе сегменты покрывают запись без пропусков и перекрытий.
    static func splitRanges(
        rms: [Float],
        windowDuration: TimeInterval,
        config: AudioSegmenterConfig = .defaults
    ) -> [Range<Int>] {
        guard !rms.isEmpty else { return [] }
        let pauseWindows = max(1, Int(round(config.pauseDuration / windowDuration)))

        var segments: [Range<Int>] = []
        var segStart = 0
        var silenceStart: Int?

        for i in 0..<rms.count {
            // Жёсткий потолок: режем по достижении максимальной длины.
            let segmentDuration = TimeInterval(i - segStart + 1) * windowDuration
            if segmentDuration >= config.maxSegment {
                segments.append(segStart..<(i + 1))
                segStart = i + 1
                silenceStart = nil
                continue
            }

            if rms[i] < config.silenceRMS {
                if silenceStart == nil { silenceStart = i }
                continue
            }

            // Окончание паузы: снова речь.
            if let pauseStart = silenceStart {
                silenceStart = nil
                let sustained = (i - pauseStart) >= pauseWindows
                guard sustained else { continue }
                // Кромка паузы закрывает предыдущий сегмент; пауза — ничейная.
                let boundary = pauseStart - 1
                guard boundary >= segStart else { continue }
                let duration = TimeInterval(boundary - segStart + 1) * windowDuration
                guard duration >= config.minSegment else { continue }
                segments.append(segStart..<(boundary + 1))
                segStart = i
            }
        }
        // Хвост записи после последней границы: только если в нём ЕСТЬ речь.
        // Полностью тихий хвост (и вся запись без голоса) в сегменты не входит —
        // иначе молчание порождало бы «пустой» сегмент и лишний STT-запрос.
        if segStart < rms.count, (rms[segStart..<rms.count].max() ?? 0) >= config.silenceRMS {
            segments.append(segStart..<rms.count)
        }
        return segments
    }

    // MARK: - Разбиение по сэмплам

    /// Делит Int16 PCM-сэмплы (16 кГц) на сегменты с оверлэпом.
    /// Сэмплы считаются непрерывными от начала записи.
    public static func segments(
        samples: [Int16],
        sampleRate: Int = 16000,
        config: AudioSegmenterConfig = .defaults
    ) -> [AudioSegment] {
        let windowSize = max(1, Int((defaultWindowDuration * Double(sampleRate)).rounded()))
        var rms: [Float] = []
        var cursor = 0
        while cursor < samples.count {
            let chunk = Array(samples[cursor..<min(cursor + windowSize, samples.count)])
            rms.append(AudioMetrics.rms(samples: chunk))
            cursor += windowSize
        }
        let ranges = splitRanges(rms: rms, windowDuration: defaultWindowDuration, config: config)
        guard !ranges.isEmpty else { return [] }

        let overlapCount = min(
            max(0, Int((config.overlap * Double(sampleRate)).rounded())),
            samples.count
        )

        var result: [AudioSegment] = []
        for (index, range) in ranges.enumerated() {
            let bodyStart = range.lowerBound * windowSize
            let bodyEnd = min(range.upperBound * windowSize, samples.count)
            let body = Array(samples[bodyStart..<bodyEnd])

            var segSamples = body
            if index > 0 {
                let overlapFrom = max(0, bodyStart - overlapCount)
                segSamples = Array(samples[overlapFrom..<bodyStart]) + body
            }

            result.append(AudioSegment(
                start: TimeInterval(bodyStart) / Double(sampleRate),
                end: TimeInterval(bodyEnd) / Double(sampleRate),
                samples: segSamples
            ))
        }
        return result
    }
}