import Foundation
import AVFoundation
import AudioEngineGuard
@testable import DictationCore

/// Тесты жизненного цикла AudioService с инъектированным фейковым движком
/// (железа нет, AVFoundation-крэши недостижимы — тесты проверяют логику):
///   • ошибка старта (движок не поднялся) обязана дать терминальный .failure,
///     снять tap и остановить движок (cleanup) и позволить ПОВТОРНЫЙ старт на
///     том же экземпляре — регрессия краша «повторный installTap на том же bus»;
///   • старт поверх уже записывающего сервиса снимает старый tap ДО установки
///     нового (тот же краш-сценарий, вход через рестарт);
///   • stop()/cancel() разбирают движок асинхронно (совсем не блокируют
///     главный поток) и позволяют следующий старт;
///   • process() собирает сэмплы из tap-колбэка, stop() возвращает их;
///   • ObjC-шлюз (AudioEngineExceptionGuard.m) превращает NSException AVFAudio
///     в NSError — вместо SIGABRT процесса.
final class AudioServiceLifecycleTests: XCTestCase {

    // MARK: - Фейковый движок

    private final class FakeInputNode: AudioInputNodeLike {
        let format: AVAudioFormat
        var tapBlock: AVAudioNodeTapBlock?
        private(set) var tapCount = 0
        private(set) var removeTapCount = 0

        init(sampleRate: Double = 44100) {
            format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        }

        func outputFormat(forBus bus: AVAudioNodeBus) -> AVAudioFormat {
            format
        }

        func installTap(
            onBus bus: AVAudioNodeBus,
            bufferSize: AVAudioFrameCount,
            format: AVAudioFormat?,
            block tapBlock: @escaping AVAudioNodeTapBlock
        ) {
            tapCount += 1
            self.tapBlock = tapBlock
        }

        func removeTap(onBus bus: AVAudioNodeBus) {
            removeTapCount += 1
        }

        /// Эмитирует один буфер из tap-колбэка (в проде это делает аудио-поток).
        func emit(_ buffer: AVAudioPCMBuffer) {
            tapBlock?(buffer, AVAudioTime())
        }
    }

    private final class FakeEngine: AudioEngineLike {
        let node = FakeInputNode()
        var failStart = false
        private(set) var prepareCount = 0
        private(set) var startCount = 0
        private(set) var stopCount = 0

        func makeInputNode() -> AudioInputNodeLike { node }

        func prepare() {
            prepareCount += 1
        }

        func start() throws {
            startCount += 1
            if failStart {
                // Любая ошибка: путь «движок не поднялся» в AudioService.
                throw AudioServiceError.unsupportedFormat
            }
        }

        func stop() {
            stopCount += 1
        }
    }

    // MARK: - Helpers

    private typealias StartResult = Result<Void, Error>

    /// Ждёт completion асинхронного старта (RunLoop крутится — как в проде
    /// главный поток). Возвращает результат старта.
    private func runStart(_ service: AudioService, file: StaticString = #file, line: UInt = #line) -> StartResult {
        let done = expectation(description: "audio start completion")
        var result: StartResult = .failure(AudioServiceError.engineGone)
        service.start { r in
            result = r
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return (done.isFulfilled) ? result : .failure(AudioServiceError.engineGone)
    }

    /// Даёт engineQueue несколько проходов RunLoop для асинхронного teardown.
    private func drainEngineQueue() {
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - Ошибка старта → cleanup → повторный старт

    /// Главная регрессия: движок отказался подниматься → терминальный
    /// .failure, tap СНЯТ и движок ОСТАНОВЛЕН (cleanup), и повторный старт на
    /// том же сервисе успешен. Раньше: tap оставался висеть → повторный
    /// installTap на том же bus = NSException = SIGABRT (crash-петля).
    @objc func testStartFailureCleansUpAndAllowsRestart() {
        let engine = FakeEngine()
        engine.failStart = true
        let service = AudioService(logLevel: "info", engine: engine)

        let first = runStart(service)
        guard case .failure = first else {
            XCTFail("первый старт должен упасть (без микрофона/движка)", file: #file, line: #line)
            return
        }
        XCTAssertEqual(engine.node.tapCount, 1, "установлен ровно один tap")
        XCTAssertGreaterThanOrEqual(engine.node.removeTapCount, 1, "после ошибки tap обязан быть снят")
        XCTAssertGreaterThanOrEqual(engine.stopCount, 1, "после ошибки движок обязан быть остановлен")

        // Повторный старт на ТОМ ЖЕ сервисе — теперь движок «исправен»:
        // не падает, ставит свежий tap, идёт в .recording.
        engine.failStart = false
        let second = runStart(service)
        guard case .success = second else {
            XCTFail("повторный старт после ошибки должен пройти, получил \(second)", file: #file, line: #line)
            return
        }
        XCTAssertEqual(engine.node.tapCount, 2, "повторный старт ставит свежий tap")
    }

    /// Краш-сценарий «повторный installTap на занятом bus» через рестарт
    /// поверх уже записывающего сервиса: старый tap снимается ДО установки
    /// нового.
    @objc func testRestartWhileActiveRemovesOldTapBeforeInstall() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)

        guard case .success = runStart(service) else {
            XCTFail("первый старт должен пройти", file: #file, line: #line)
            return
        }
        XCTAssertEqual(engine.node.tapCount, 1)
        XCTAssertEqual(engine.node.removeTapCount, 0)

        guard case .success = runStart(service) else {
            XCTFail("повторный старт поверх активного должен пройти (не краш)", file: #file, line: #line)
            return
        }
        XCTAssertEqual(engine.node.tapCount, 2, "второй установленный tap")
        XCTAssertEqual(engine.node.removeTapCount, 1, "старый tap снят ровно один раз — ДО второго install")
    }

    // MARK: - stop/cancel

    /// stop() возвращает сэмплы синхронно, а teardown движка уходит на фоновую
    /// очередь (главный поток не блокируется): tap снят, движок остановлен.
    @objc func testStopTearsDownAsyncAndAllowsRestart() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)

        guard case .success = runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        let samples = service.stop()
        XCTAssertEqual(samples.count, 0, "пока tap ничего не отдал — сэмплов нет")

        drainEngineQueue()
        XCTAssertEqual(engine.node.removeTapCount, 1, "stop() обязан снять tap")
        XCTAssertEqual(engine.stopCount, 1, "stop() обязан остановить движок")

        guard case .success = runStart(service) else {
            XCTFail("старт после stop() должен пройти", file: #file, line: #line)
            return
        }
        XCTAssertEqual(engine.node.tapCount, 2, "старт после stop() ставит свежий tap")
    }

    /// Отмена тоже разбирает движок и не мешает следующему старту.
    @objc func testCancelTearsDownAndAllowsRestart() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)

        guard case .success = runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        service.cancel()
        drainEngineQueue()
        XCTAssertGreaterThanOrEqual(engine.node.removeTapCount, 1, "cancel() обязан снять tap")
        XCTAssertGreaterThanOrEqual(engine.stopCount, 1, "cancel() обязан остановить движок")

        let restart = runStart(service)
        guard case .success = restart else {
            XCTFail("старт после cancel() должен пройти", file: #file, line: #line)
            return
        }
        XCTAssertEqual(engine.node.tapCount, 2)
    }

    // MARK: - Сбор сэмплов

    /// process() из tap-колбэка конвертирует 44.1 кГц → 16 кГц моно, и stop()
    /// возвращает собранные сэмплы — проверяет новую синхронизацию накопления
    /// под блокировкой (и что колбэк tap реально раздаёт буферы движку).
    @objc func testProcessCollectsSamplesAndStopReturnsThem() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)

        guard case .success = runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        // Один буфер 44.1 кГц × 4096 фр. ≈ 92.9 мс → ~1486 фр. @ 16 кГц.
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.node.format, frameCapacity: 4096)!
        buffer.frameLength = 4096
        let channel = buffer.floatChannelData![0]
        for i in 0..<4096 {
            channel[i] = 0.2 // −14 dBFS, не тишина
        }
        engine.node.emit(buffer)

        let samples = service.stop()
        XCTAssertGreaterThanOrEqual(samples.count, 1410, "первый буфер обязан дать ≥ ~1486 сэмплов (допуск)")
        XCTAssertLessThanOrEqual(samples.count, 1560, "сэмплы не должны задваиваться/раздуваться (допуск)")
        // Амплитуда 0.2 прошла конвертацию без клиппинга (max < 32767).
        let maxAbs = samples.map { abs(Int($0)) }.max() ?? 0
        XCTAssertLessThanOrEqual(maxAbs, 32767, "амплитуда не должна клиппиться")
        XCTAssertGreaterThanOrEqual(maxAbs, 3000, "амплитуда 0.2 должна дойти до накопления")
    }

    // MARK: - ObjC-шлюз NSException

    /// NSException AVFAudio (сценарий реального краша SetOutputFormat) внутри
    /// шлюза превращается в NSError, а нормальный блок проходит без ошибки —
    /// это и есть отсутствие SIGABRT при старте движка.
    @objc func testEngineExceptionGuardConvertsExceptionToError() {
        let service = AudioService(logLevel: "info", engine: FakeEngine())

        let raised = service.guardedEngineCall {
            DictationRaiseAudioEngineTestException()
        }
        XCTAssertNotNil(raised, "NSException внутри шлюза обязан стать NSError")

        let clean = service.guardedEngineCall {}
        XCTAssertNil(clean, "блок без исключения — без ошибки")
    }
}