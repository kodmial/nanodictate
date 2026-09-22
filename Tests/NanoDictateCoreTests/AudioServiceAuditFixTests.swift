import Foundation
import AVFoundation
@testable import NanoDictateCore

/// Тесты фиксов ревью ветки fix/audit/audio (коммит be4f93a):
///   • SessionLedger — атомарность слова, begin/end/advanceGeneration,
///     clearAutoStop/latchAutoStop, согласованность снимка;
///   • takeBufferedSnapshot — ранний безлочный выход при не-записи и изоляция
///     сеансов (буфер после stop() не перетекает в новую запись);
///   • смена аудио-устройства — уведомление с object: nil (фейковый движок
///     подписывается на nil-объект, см. фикс-заметку #6 ревью): запись
///     останавливается, onDeviceChange(.deviceChanged) приходит на главной
///     очереди; вне записи колбэка нет.
final class AudioServiceAuditFixTests: XCTestCase {

    // MARK: - SessionLedger: атомарность слова

    /// Новый регистр: нулевое поколение, флаги сброшены.
    @objc func testSessionLedgerStartsClean() {
        let ledger = AudioService.SessionLedger(generation: 0)
        let snap = ledger.snapshot
        XCTAssertEqual(snap.generation, 0)
        XCTAssertFalse(snap.isRecording)
        XCTAssertFalse(snap.autoStopScheduled)
        XCTAssertFalse(ledger.isRecording)
        XCTAssertTrue(ledger.isCurrentGeneration(0), "нулевое поколение — текущее")
    }

    /// begin() взводит ТОЛЬКО бит записи одной атомарной операцией: поколение
    /// не пишется (TOCTOU «снимок→запись поколения» устранён), защёлка
    /// автостопа сохраняется.
    @objc func testBeginSetsRecordingOnlyAndPreservesWord() {
        let ledger = AudioService.SessionLedger(generation: 7)
        ledger.begin()
        var snap = ledger.snapshot
        XCTAssertTrue(snap.isRecording)
        XCTAssertFalse(snap.autoStopScheduled)
        XCTAssertEqual(snap.generation, 7, "begin не должен писать поколение")

        ledger.latchAutoStop()
        ledger.begin()  // повторный begin — единственная атомарная операция OR
        snap = ledger.snapshot
        XCTAssertTrue(snap.isRecording)
        XCTAssertTrue(snap.autoStopScheduled, "begin сохраняет защёлку автостопа")
        XCTAssertEqual(snap.generation, 7, "поколение не откатывается повторным begin")
    }

    /// end() гасит запись И защёлку автостопа, поколение сохраняет.
    @objc func testEndClearsRecordingAndAutoStop() {
        let ledger = AudioService.SessionLedger(generation: 3)
        ledger.begin()
        ledger.latchAutoStop()
        ledger.end()
        let snap = ledger.snapshot
        XCTAssertFalse(snap.isRecording, "end обязан снять запись")
        XCTAssertFalse(snap.autoStopScheduled, "end обязан снять защёлку автостопа")
        XCTAssertEqual(snap.generation, 3, "end не трогает поколение")
    }

    /// advanceGeneration() инкрементирует поколение И сбрасывает флаги записи
    /// и автостопа: свежая сессия после wedge стартует с чистыми флагами.
    @objc func testAdvanceGenerationResetsFlagsAndBumpsGeneration() {
        let ledger = AudioService.SessionLedger(generation: 5)
        ledger.begin()
        ledger.latchAutoStop()
        let newGeneration = ledger.advanceGeneration()
        XCTAssertEqual(newGeneration, 6, "advanceGeneration возвращает новое поколение")
        let snap = ledger.snapshot
        XCTAssertEqual(snap.generation, 6)
        XCTAssertFalse(snap.isRecording, "advanceGeneration обязан снять запись старого сеанса")
        XCTAssertFalse(snap.autoStopScheduled, "advanceGeneration обязан снять защёлку")
        XCTAssertTrue(ledger.isCurrentGeneration(6))
        XCTAssertFalse(ledger.isCurrentGeneration(5), "старое поколение — не текущее")
    }

    /// clearAutoStop снимает ТОЛЬКО защёлку: запись и поколение сохраняются.
    @objc func testClearAutoStopKeepsRecording() {
        let ledger = AudioService.SessionLedger(generation: 2)
        ledger.begin()
        ledger.latchAutoStop()
        ledger.clearAutoStop()
        let snap = ledger.snapshot
        XCTAssertFalse(snap.autoStopScheduled)
        XCTAssertTrue(snap.isRecording, "clearAutoStop не трогает запись")
        XCTAssertEqual(snap.generation, 2)
    }

    /// latchAutoStop взводит защёлку, не гася запись: снимок видит «автостоп
    /// запланирован» при живой записи — поздние буферы takeBufferedSnapshot
    /// дропает по этому биту.
    @objc func testLatchAutoStopVisibleInSnapshotWhileRecording() {
        let ledger = AudioService.SessionLedger(generation: 1)
        ledger.begin()
        ledger.latchAutoStop()
        let snap = ledger.snapshot
        XCTAssertTrue(snap.autoStopScheduled, "защёлка обязана быть видна снимком")
        XCTAssertTrue(snap.isRecording, "защёлка не гасит запись — её гасит только end/advanceGeneration")
        XCTAssertEqual(snap.generation, 1)
    }

    /// Последовательность переходов держит снимок согласованным: тройка
    /// берётся под одним захватом unfair, биты не перепутываются.
    @objc func testSnapshotConsistentAfterMixedTransitions() {
        let ledger = AudioService.SessionLedger(generation: 0)
        ledger.begin()               // (0, запись)
        ledger.latchAutoStop()       // (0, запись, автостоп)
        ledger.end()                 // (0, -, -)
        ledger.begin()               // (0, запись, -)
        ledger.advanceGeneration()   // (1, -, -)
        let snap = ledger.snapshot
        XCTAssertEqual(snap.generation, 1)
        XCTAssertFalse(snap.isRecording)
        XCTAssertFalse(snap.autoStopScheduled)
    }

    /// Конкурентные advanceGeneration из нескольких потоков не теряют шаги:
    /// слово упаковывается под одним захватом unfair — операция атомарна.
    @objc func testSessionLedgerWordIsAtomicAcrossThreads() {
        let ledger = AudioService.SessionLedger(generation: 100)
        let threads = 4
        let stepsPerThread = 250
        DispatchQueue.concurrentPerform(iterations: threads) { _ in
            for _ in 0..<stepsPerThread {
                ledger.advanceGeneration()
            }
        }
        let snap = ledger.snapshot
        XCTAssertEqual(
            snap.generation,
            100 + threads * stepsPerThread,
            "ни одно продвижение поколения не должно теряться"
        )
        XCTAssertFalse(snap.isRecording)
        XCTAssertFalse(snap.autoStopScheduled)
    }

    // MARK: - takeBufferedSnapshot: ранний выход и изоляция сеансов

    /// Буферы, пришедшие ПОСЛЕ stop() (tap ещё висит — teardown ушёл на
    /// фоновую очередь), дропаются ранним безлочным гардом isRecording:
    /// в новую сессию они не перетекают.
    @objc func testBuffersAfterStopAreDroppedBeforeNextStart() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)
        guard case .success = runStart(service) else {
            XCTFail("первый старт должен пройти", file: #file, line: #line)
            return
        }

        engine.node.emit(tone(engine, frames: 4096))
        let first = service.stop()
        XCTAssertGreaterThanOrEqual(first.count, 1410, "первый буфер обязан дать сэмплы (допуск)")
        XCTAssertLessThanOrEqual(first.count, 1560, "сэмплы не раздуваются (допуск)")

        // Публикуем буфер «мёртвому» сеансу. Внутри process() снимок сеанса
        // берётся без NSLock и видит «записи нет» — буфер дропается.
        engine.node.emit(tone(engine, frames: 4096))

        guard case .success = runStart(service) else {
            XCTFail("повторный старт должен пройти", file: #file, line: #line)
            return
        }
        engine.node.emit(tone(engine, frames: 4096))
        let second = service.stop()

        XCTAssertEqual(second.count, first.count, "буфер после stop() не попадает в следующий сеанс")
        XCTAssertGreaterThanOrEqual(second.count, 1410)
        XCTAssertLessThanOrEqual(second.count, 1560)
    }

    // MARK: - Смена аудио-устройства

    /// Уведомление `AVAudioEngineConfigurationChange` во время записи:
    /// запись останавливается штатным stop(), колбэк onDeviceChange получает
    /// явную ошибку `.deviceChanged` на главной очереди, движок разобран.
    /// Фейковый движок подписывается с object: nil — постим с object: nil
    /// (фикс-заметка #6 ревью: в проде объект = конкретный AVAudioEngine).
    @objc func testDeviceChangeStopsRecordingAndFiresCallback() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)
        guard case .success = runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }
        XCTAssertFalse(engine.node.tapBlock == nil, "запись активна: tap установлен")

        var received: AudioServiceError?
        let changed = expectation(description: "onDeviceChange")
        service.onDeviceChange = { error in
            received = error as? AudioServiceError
            changed.fulfill()
        }

        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
        wait(for: [changed], timeout: 2)

        guard case .deviceChanged = received else {
            XCTFail(
                "колбэк обязан получить .deviceChanged, получено \(String(describing: received))",
                file: #file, line: #line
            )
            return
        }
        // Сэмплы сеанса забрал stop() внутри обработчика — повторный stop()
        // пуст (идемпотентен через guard isRecording).
        XCTAssertEqual(service.stop(), [], "после обработчика запись уже остановлена")
        // Teardown дошёл: движок остановлен, tap снят.
        XCTAssertTrue(
            eventually(timeout: 2.0) {
                engine.stopCount == 1 && engine.node.removeTapCount == 1
            },
            "движок обязан быть разобран (stop + removeTap)"
        )
    }

    /// Уведомление вне записи игнорируется: колбэк не зовётся, движок не
    /// разбирается повторно. Дополнительно подтверждает, что teardown снял
    /// наблюдателя (постинг после stop() не находит подписчика).
    @objc func testDeviceChangeIgnoredWhenNotRecording() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)
        guard case .success = runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }
        service.stop()
        drainEngineQueue()
        XCTAssertEqual(engine.stopCount, 1, "stop() обязан остановить движок")

        var fired = false
        service.onDeviceChange = { _ in fired = true }
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
        drainEngineQueue()
        XCTAssertFalse(fired, "вне записи смена устройства не вызывает колбэк")
        XCTAssertEqual(engine.stopCount, 1, "повторной разборки движка нет")
    }

    // MARK: - Helpers

    /// Буфер 0.2 амплитуды (−14 dBFS, не тишина) на формате фейкового движка
    /// (44.1 кГц/моно) — как в боевых тестах lifecycle: 4096 фр. ≈ 1486
    /// сэмплов @16 кГц.
    private func tone(_ engine: FakeEngine, frames: AVAudioFrameCount) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.node.format, frameCapacity: frames)!
        buffer.frameLength = frames
        let channel = buffer.floatChannelData![0]
        for i in 0..<Int(frames) {
            channel[i] = 0.2
        }
        return buffer
    }
}