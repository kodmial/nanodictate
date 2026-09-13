import Foundation
@testable import DictationCore

// MARK: - Тесты ChunkedPipeline (пошаговая диктовка)
//
// Моковый STT + Inserter. Никакой сети и I/O.

final class ChunkedPipelineTests: XCTestCase {

    private enum RecordedOperation: Equatable {
        case appendSegment(index: Int, text: String)
        case replaceTail(old: String, new: String)
    }

    // MARK: - Хелперы

    private func makeSamples(_ blocks: [(amplitude: Float, seconds: Double)], sampleRate: Int = 16000) -> [Int16] {
        var out: [Int16] = []
        for block in blocks {
            let count = Int((block.seconds * Double(sampleRate)).rounded())
            let phaseStep = 2 * Double.pi * 440.0 / Double(sampleRate)
            for i in 0..<count {
                let v = block.amplitude * Float(sin(phaseStep * Double(i)))
                out.append(Int16(v * 32767))
            }
        }
        return out
    }

    /// Запись "речь 2 с — тишина 1.5 с — речь 2 с" → два сегмента.
    private func twoSegmentSamples() -> [Int16] {
        makeSamples([(0.1, 2.0), (0.0, 1.5), (0.1, 2.0)])
    }

    /// Запись из речи без пауз → один сегмент.
    private func singleSegmentSamples() -> [Int16] {
        makeSamples([(0.1, 2.0)])
    }

    private let segConfig = AudioSegmenterConfig(
        pauseDuration: 1.0,
        minSegment: 1.0,
        maxSegment: 45.0,
        overlap: 0.0 // без оверлэпа — концы сегментов не дублируются, diff чистый
    )

    /// Мок STT: последовательно отдаёт результаты; записывает вызовы.
    private final class MockSTT {
        private let results: [String]
        private var index = 0
        var calls: [(filename: String, prompt: String?)] = []

        init(results: [String]) { self.results = results }

        func call(_ wav: Data, _ filename: String, _ prompt: String?) async throws -> String {
            calls.append((filename, prompt))
            guard index < results.count else { throw NSError(domain: "MockSTT", code: 1) }
            let r = results[index]
            index += 1
            return r
        }
    }

    private func runPipeline(
        samples: [Int16],
        mockSTT: MockSTT,
        onPhase: ((ChunkedPipeline.Phase) -> Void)? = nil
    ) async throws -> (outcome: ChunkedPipeline.Outcome, steps: [RecordedOperation], phases: [ChunkedPipeline.Phase]) {
        let pipeline = ChunkedPipeline(sampleRate: 16000, segmenterConfig: segConfig)
        var steps: [RecordedOperation] = []
        var phases: [ChunkedPipeline.Phase] = []
        let outcome = try await pipeline.run(
            samples: samples,
            stt: { wav, filename, prompt in try await mockSTT.call(wav, filename, prompt) },
            insert: { op in
                switch op {
                case .appendSegment(let index, let text): steps.append(.appendSegment(index: index, text: text))
                case .replaceTail(let old, let new): steps.append(.replaceTail(old: old, new: new))
                }
            },
            onPhase: { phases.append($0); onPhase?($0) }
        )
        return (outcome, steps, phases)
    }

    // MARK: - Два сегмента: порядок фаз и операций

    @objc func testTwoSegmentPipelineOrder() throws {
        let mockSTT = MockSTT(results: ["Один два.", "Три четыре.", "Один два три четыре."])
        let (outcome, steps, phases) = try runAsync {
            try await self.runPipeline(samples: self.twoSegmentSamples(), mockSTT: mockSTT)
        }

        // Фазы: распознавание сегментов по очереди, затем финальный проход.
        XCTAssertEqual(phases, [.segment(0), .segment(1), .finalizing])

        // Инкрементальные вставки + финальная замена хвоста.
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps[0], .appendSegment(index: 0, text: "Один два."))
        // F2: промежуточная вставка НЕ склеивает слова — разделительный пробел.
        XCTAssertEqual(steps[1], .appendSegment(index: 1, text: " Три четыре."))
        let change = WordDiff.change(old: "Один два. Три четыре.", new: "Один два три четыре.")!
        XCTAssertEqual(steps[2], .replaceTail(old: change.tailOld, new: change.tailNew))

        XCTAssertEqual(outcome.segmentCount, 2)
        XCTAssertEqual(outcome.insertedText, "Один два три четыре.")
        XCTAssertTrue(outcome.finalized)
        XCTAssertTrue(outcome.finalChanged)

        // Filenames для отладки.
        XCTAssertEqual(mockSTT.calls.map { $0.filename }, ["segment-1.wav", "segment-2.wav", "final.wav"])
    }

    @objc func testFinalIdenticalNoReplace() throws {
        // Финальный текст совпадает с инкрементальным (включая разделительный
        // пробел F2) — замены нет.
        let mockSTT = MockSTT(results: ["Один два.", "Три четыре.", "Один два. Три четыре."])
        let (outcome, steps, _) = try runAsync {
            try await self.runPipeline(samples: self.twoSegmentSamples(), mockSTT: mockSTT)
        }

        XCTAssertEqual(steps, [
            .appendSegment(index: 0, text: "Один два."),
            .appendSegment(index: 1, text: " Три четыре.")
        ])
        XCTAssertEqual(outcome.insertedText, "Один два. Три четыре.")
        XCTAssertTrue(outcome.finalized)
        XCTAssertFalse(outcome.finalChanged)
    }

    // MARK: - Prompt-конкатенация

    @objc func testPromptAccumulation() throws {
        let mockSTT = MockSTT(results: ["Один.", "Два.", "Один.Два."])
        _ = try runAsync {
            try await self.runPipeline(samples: self.twoSegmentSamples(), mockSTT: mockSTT)
        }

        XCTAssertEqual(mockSTT.calls.count, 3)
        // 1-й сегмент: контекста ещё нет.
        XCTAssertNil(mockSTT.calls[0].prompt)
        // 2-й сегмент: prompt = уже распознанный текст.
        XCTAssertEqual(mockSTT.calls[1].prompt, "Один.")
        // Финальный проход по всему WAV: контекст не нужен.
        XCTAssertNil(mockSTT.calls[2].prompt)
    }

    // MARK: - Один сегмент → финальный проход пропускается

    @objc func testSingleSegmentSkipsFinalPass() throws {
        let mockSTT = MockSTT(results: ["Привет мир."])
        let (outcome, steps, phases) = try runAsync {
            try await self.runPipeline(samples: self.singleSegmentSamples(), mockSTT: mockSTT)
        }

        XCTAssertEqual(steps, [.appendSegment(index: 0, text: "Привет мир.")])
        XCTAssertFalse(phases.contains(.finalizing))
        XCTAssertFalse(outcome.finalized)
        XCTAssertEqual(outcome.segmentCount, 1)
        XCTAssertFalse(outcome.finalChanged)
        XCTAssertEqual(mockSTT.calls.count, 1)
    }

    // MARK: - Пустая запись → ни одного запроса

    @objc func testEmptySamplesNoSTTCalls() throws {
        let mockSTT = MockSTT(results: [])
        let (outcome, steps, _) = try runAsync {
            try await self.runPipeline(samples: [], mockSTT: mockSTT)
        }

        XCTAssertEqual(outcome.segmentCount, 0)
        XCTAssertEqual(outcome.insertedText, "")
        XCTAssertFalse(outcome.finalized)
        XCTAssertFalse(outcome.finalChanged)
        XCTAssertTrue(steps.isEmpty)
        XCTAssertTrue(mockSTT.calls.isEmpty)
    }

    // MARK: - E: production-путь (overlap 1.0) — финальный проход счищает дубликаты

    @objc func testDefaultOverlapDedupeOnFinalPass() throws {
        // Два длинных речевых блока (4 c >= minSegment 3 c с дефолтным
        // конфигом): 4 с речи, тишина 1.5 с, 4 с речи. ChunkedPipeline() по
        // умолчанию приклеивает к началу 2-го сегмента последнюю секунду тела
        // 1-го — STT транскрибирует стыковое слово дважды («два» в чанке 1 и в
        // оверлэпе чанка 2). Финальный проход по ВСЕМУ WAV по-словным diff
        // счищает дубликат.
        let samples = makeSamples([
            (amplitude: 0.1, seconds: 4.0),
            (amplitude: 0.0, seconds: 1.5),
            (amplitude: 0.1, seconds: 4.0)
        ])
        let mockSTT = MockSTT(results: ["Один два.", "Два три четыре.", "Один два три четыре."])
        let pipeline = ChunkedPipeline() // production-конфиг: overlap 1.0
        var steps: [RecordedOperation] = []
        let outcome = try runAsync {
            try await pipeline.run(
                samples: samples,
                stt: { wav, filename, prompt in try await mockSTT.call(wav, filename, prompt) },
                insert: { op in
                    switch op {
                    case .appendSegment(let index, let text): steps.append(.appendSegment(index: index, text: text))
                    case .replaceTail(let old, let new): steps.append(.replaceTail(old: old, new: new))
                    }
                }
            )
        }

        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(steps[0], .appendSegment(index: 0, text: "Один два."))
        XCTAssertEqual(steps[1], .appendSegment(index: 1, text: " Два три четыре."))
        // Шов «два» из оверлэпа ушёл по-словным diff финального прохода.
        let change = WordDiff.change(old: "Один два. Два три четыре.", new: "Один два три четыре.")!
        XCTAssertEqual(steps[2], .replaceTail(old: change.tailOld, new: change.tailNew))
        XCTAssertTrue(outcome.finalized)
        XCTAssertTrue(outcome.finalChanged)
        XCTAssertEqual(outcome.insertedText, "Один два три четыре.")
        XCTAssertEqual(outcome.segmentCount, 2)
        XCTAssertEqual(mockSTT.calls.count, 3)
    }

    // MARK: - Вставка/фаза вызываются синхронно в контексте вызывающего

    @objc func testInsertAndPhaseAreSynchronous() throws {
        // Гарантия для main.swift: insert/onPhase не диспатчатся сами на другой
        // поток — конвейер вызывает их в том же контексте, что и run() (все
        // колбэки приходят на одной и той же очереди/исполнителе). Сравнение с
        // конкретной очередью ненадёжно: Task может перепрыгнуть на глобальный
        // cooperative-исполнитель, поэтому проверяем ЕДИНООБРАЗИЕ меток.
        let mockSTT = MockSTT(results: ["Один.", "Два.", "Один.Два."])
        let backgroundLabel = "dictation.test.background"
        let runQueue = DispatchQueue(label: backgroundLabel)
        let observed = StringListBox()

        let expect = expectation(description: "pipeline on background queue")
        runQueue.async { [self] in
            let sema = DispatchSemaphore(value: 0)
            Task {
                let pipeline = ChunkedPipeline(sampleRate: 16000, segmenterConfig: self.segConfig)
                _ = try? await pipeline.run(
                    samples: self.twoSegmentSamples(),
                    stt: { wav, filename, prompt in try await mockSTT.call(wav, filename, prompt) },
                    insert: { _ in observed.append(DispatchQueue.currentLabel) },
                    onPhase: { _ in observed.append(DispatchQueue.currentLabel) }
                )
                sema.signal()
            }
            sema.wait()
            expect.fulfill()
        }
        wait(for: [expect], timeout: 10.0)

        let labels = observed.values
        XCTAssertFalse(labels.isEmpty)
        XCTAssertTrue(labels.allSatisfy { $0 == labels.first }, "got \(labels)")
    }

    /// Модифицируемый из Task: мутация ссылочного типа не триггерит
    /// concurrency-проверку Swift 5.7.
    private final class StringListBox {
        private(set) var values: [String] = []
        func append(_ value: String) { values.append(value) }
    }

    // MARK: - runAsync helper

    /// Прогоняет асинхронное тело до завершения внутри синхронного теста
    /// и возвращает результат (или бросает ошибку тела).
    private final class ResultBox<T> {
        var value: T?
        var error: Error?
    }

    private func runAsync<T>(_ body: @escaping () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let expect = expectation(description: "runAsync")
        Task {
            do { box.value = try await body() }
            catch { box.error = error }
            expect.fulfill()
        }
        wait(for: [expect], timeout: 10.0)
        if let error = box.error { throw error }
        return box.value!
    }
}

// MARK: - Утилиты

private extension DispatchQueue {
    /// Имя очереди, на которой выполняется текущий код.
    static var currentLabel: String {
        String(cString: __dispatch_queue_get_label(nil), encoding: .utf8) ?? "unknown"
    }
}