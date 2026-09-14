import Foundation

// MARK: - Пошаговая (чанковая) диктовка
//
// Конвейер прогрессивной диктовки: VAD-сегментация записи → по-сегментная
// транскрибация (каждый следующий сегмент получает `prompt` = уже распознанный
// текст) → инкрементальная вставка сегментов → финальный проход по ВСЕМУ WAV
// одним запросом → по-словный diff с уже-вставленным текстом → замена только
// изменившегося диапазона (одно действие).
//
// Конвейер ЧИСТЫЙ: STT и клавиатурную вставку инъецируют замыканиями, поэтому
// в тестах — моки без сети и без CGEvent; DictatorAgent прокидывает реальный
// Transcriber и Inserter.

public struct ChunkedPipeline {

    // MARK: - Инъекции (моки в тестах)

    /// Транскрибация WAV → текст. `prompt` — контекст уже распознанных
    /// сегментов (для продолжения); `filename` — для отладки.
    public typealias STTHandler = (_ wav: Data, _ filename: String, _ prompt: String?) async throws -> String
    /// Одно клавиатурное действие, сделанное над активным приложением.
    public typealias InsertHandler = (Operation) -> Void
    /// Статусная фаза конвейера — для оверлея («Распознаю… (часть N)»,
    /// «Финальная обработка…»).
    public typealias PhaseHandler = (Phase) -> Void

    /// Что конвейер делает сейчас (вызывается перед началом соответствующего
    /// шага). Индексы 0-based.
    public enum Phase: Equatable {
        case segment(Int)
        case finalizing
    }

    public enum Operation: Equatable {
        /// Инкрементальная вставка распознанного сегмента (в конец).
        case appendSegment(index: Int, text: String)
        /// Финальный проход: замена хвоста (одно действие).
        /// `old`/`new` — что под backspace и что печатать.
        case replaceTail(old: String, new: String)
    }

    /// Итог прогона: что вставлено, был ли финальный проход и изменил ли он текст.
    public struct Outcome: Equatable {
        public let segmentCount: Int
        /// Итоговый текст (чанки после финального diff).
        public let insertedText: String
        /// Был ли выполнен финальный проход по всему WAV.
        public let finalized: Bool
        /// Изменил ли финальный проход вставленный текст (diff не пуст).
        public let finalChanged: Bool

        public init(segmentCount: Int, insertedText: String, finalized: Bool, finalChanged: Bool) {
            self.segmentCount = segmentCount
            self.insertedText = insertedText
            self.finalized = finalized
            self.finalChanged = finalChanged
        }
    }

    public let sampleRate: Int
    public let segmenterConfig: AudioSegmenterConfig

    public init(sampleRate: Int = 16000, segmenterConfig: AudioSegmenterConfig = .defaults) {
        self.sampleRate = sampleRate
        self.segmenterConfig = segmenterConfig
    }

    // MARK: - Отдельные шаги конвейера (reuse live-диктовкой)

    /// Распознаёт ОДИН речевой сегмент: WAV → STT (с prompt-контекстом уже
    /// распознанного текста) → финализация. Возвращает текст ДЛЯ ВСТАВКИ
    /// (с разделительным пробелом для сегмента i>0, F2) и чистый текст для
    /// накопления в prompt.
    public static func recognizeSegment(
        samples: [Int16],
        index: Int,
        sampleRate: Int = 16000,
        insertedText: String,
        prompt: String?,
        stt: STTHandler,
        filename: String = "segment.wav"
    ) async throws -> (insertText: String, promptText: String) {
        let bytes = WAVEncoder.encode(samples: samples, sampleRate: sampleRate)
        let raw = try await stt(bytes, filename, prompt)
        let text = TextRefinement.finalize(raw)
        var insertText = text
        // F2: между сегментами — разделительный пробел, иначе слова соседних
        // чанков слипаются при инкрементальной вставке.
        if index > 0, !insertedText.isEmpty, !insertedText.hasSuffix(" ") {
            insertText = " " + text
        }
        return (insertText, text)
    }

    /// Финальный проход по ВСЕМУ WAV: один STT-запрос (prompt не нужен),
    /// по-словный diff с уже-вставленным текстом → замена изменившегося
    /// диапазона ОДНИМ действием. `changed == false` — финальный текст совпал
    /// с уже-вставленным, правки нет.
    public static func finalize(
        samples: [Int16],
        sampleRate: Int = 16000,
        insertedText: String,
        stt: STTHandler,
        insert: InsertHandler,
        onFinalizing: (() -> Void)? = nil
    ) async throws -> (finalText: String, changed: Bool) {
        onFinalizing?()
        let finalWAV = WAVEncoder.encode(samples: samples, sampleRate: sampleRate)
        let finalRaw = try await stt(finalWAV, "final.wav", nil)
        let finalText = TextRefinement.finalize(finalRaw)

        guard let change = WordDiff.change(old: insertedText, new: finalText) else {
            return (finalText, false)
        }
        insert(.replaceTail(old: change.tailOld, new: change.tailNew))
        return (finalText, true)
    }

    // MARK: - Прогон

    public func run(
        samples: [Int16],
        stt: STTHandler,
        insert: InsertHandler,
        onPhase: PhaseHandler? = nil
    ) async throws -> Outcome {
        let segments = AudioSegmenter.segments(
            samples: samples, sampleRate: sampleRate, config: segmenterConfig
        )

        // Нет сегментов (пустая запись) — считаем одной пустой вставкой без
        // финального прохода: транскрибация пустоты бессмысленна и дорога.
        guard !segments.isEmpty else {
            return Outcome(segmentCount: 0, insertedText: "", finalized: false, finalChanged: false)
        }

        var insertedText = ""
        var promptParts: [String] = []

        // По-сегментная транскрибация + инкрементальная вставка.
        for (index, segment) in segments.enumerated() {
            onPhase?(.segment(index))
            let result = try await Self.recognizeSegment(
                samples: segment.samples,
                index: index,
                sampleRate: sampleRate,
                insertedText: insertedText,
                prompt: promptParts.isEmpty ? nil : promptParts.joined(separator: " "),
                stt: stt,
                filename: "segment-\(index + 1).wav"
            )
            insert(.appendSegment(index: index, text: result.insertText))
            insertedText += result.insertText
            // В prompt уходит чистый текст без ведущего пробела.
            promptParts.append(result.promptText)
        }

        // Один сегмент — это и есть вся запись целиком: финальный проход не
        // нужен (нечем «полировать»), двойной запрос только удорожает.
        guard segments.count > 1 else {
            return Outcome(segmentCount: 1, insertedText: insertedText, finalized: false, finalChanged: false)
        }

        // Финальный проход: весь WAV одним запросом (полный контекст), затем
        // по-словный diff с уже-вставленным текстом → замена изменившегося
        // диапазона ОДНИМ действием (backspace хвоста + печать хвоста).
        let result = try await Self.finalize(
            samples: samples,
            sampleRate: sampleRate,
            insertedText: insertedText,
            stt: stt,
            insert: insert,
            onFinalizing: { onPhase?(.finalizing) }
        )
        guard result.changed else {
            // Финальный текст совпал с уже-вставленным — ничего не трогаем.
            return Outcome(segmentCount: segments.count, insertedText: insertedText, finalized: true, finalChanged: false)
        }
        return Outcome(
            segmentCount: segments.count,
            insertedText: result.finalText,
            finalized: true,
            finalChanged: true
        )
    }
}