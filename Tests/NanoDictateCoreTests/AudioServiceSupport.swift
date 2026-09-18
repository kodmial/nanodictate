import Foundation
import AVFoundation
import AudioEngineGuard
@testable import NanoDictateCore

// MARK: - Общие фейки AudioService (инъекция движка в тестах)

/// Тестовый входной узел. Формат МУТАБЕЛЬНЫЙ (в отличие от константного
/// формата настоящего движка): ветки nil-конвертера и повторного старта после
/// «починки» формата меняют `format` на лету.
final class FakeInputNode: AudioInputNodeLike {
    var format: AVAudioFormat
    var tapBlock: AVAudioNodeTapBlock?
    private(set) var tapCount = 0
    private(set) var removeTapCount = 0

    init(format: AVAudioFormat? = nil, sampleRate: Double = 44100) {
        if let format = format {
            self.format = format
        } else {
            // Стандартный 44.1 кГц/моно — как в «боевых» тестах lifecycle.
            self.format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        }
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

/// Тестовый движок с переключателями отказов:
///   • `failStart` — engine.start() бросает ошибку (путь «движок не поднялся»);
///     проверяется ПОСЛЕ hangStart.wait() — тот же переключатель даёт ветку
///     «вис → throw» (разблокировавшийся после подмены старт падает сбоем);
///   • `hangStart` — engine.start() БЛОКИРУЕТСЯ на семафоре: модель HAL-wedge,
///     когда start() не возвращается никогда (очередь движка зависает);
///   • `failSetup` — makeInputNode() поднимает NSException под ObjC-шлюзом
///     (ветка «сбой подъёма входного узла»);
///   • `overrideNode` — подмена входного узла (для nil-конвертера: формат
///     AVAudioFormat() даёт nil из AVAudioConverter(from:to:)).
final class FakeEngine: AudioEngineLike {
    let node = FakeInputNode()
    var failStart = false
    var hangStart: DispatchSemaphore?
    var failSetup = false
    var overrideNode: AudioInputNodeLike?
    private(set) var prepareCount = 0
    private(set) var startCount = 0
    private(set) var stopCount = 0

    func makeInputNode() -> AudioInputNodeLike {
        if failSetup {
            // NSException под шлюзом (см. testEngineExceptionGuardConvertsExceptionToError).
            NanoDictateRaiseAudioEngineTestException()
        }
        return overrideNode ?? node
    }

    func prepare() {
        prepareCount += 1
    }

    func start() throws {
        startCount += 1
        if let hangStart = hangStart {
            // Блокирует ДО проверки failStart: счётчик уже вырос — тест
            // отличает «успел зависнуть» от «вообще не стартовал». Очередь
            // движка застревает навсегда, пока тест не отпустит семафор.
            hangStart.wait()
        }
        if failStart {
            // Проверка ПОСЛЕ wait(): «вис → throw» — движок, разблокировавшийся
            // после wedge-подмены, завершает старт СБОЕМ engine.start(), а не
            // успехом (покрывает stale-guard ветки сбоя старта).
            // Любая ошибка: путь «движок не поднялся» в AudioService.
            throw AudioServiceError.unsupportedFormat
        }
    }

    func stop() {
        stopCount += 1
    }
}

// MARK: - Общие helpers тестов

/// `runStart`/`drainEngineQueue`/`eventually` в extension, чтобы не дублировать
/// их в каждом suite (мини-XCTest без общего базового класса).

typealias AudioStartResult = Result<Void, Error>

extension XCTestCase {

    /// Ждёт completion асинхронного старта (RunLoop крутится — как в проде
    /// главный поток). Возвращает результат старта.
    func runStart(_ service: AudioService, file: StaticString = #file, line: UInt = #line) -> AudioStartResult {
        let done = expectation(description: "audio start completion")
        var result: AudioStartResult = .failure(AudioServiceError.engineGone)
        service.start { r in
            result = r
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return done.isFulfilled ? result : .failure(AudioServiceError.engineGone)
    }

    /// Даёт engineQueue несколько проходов RunLoop для асинхронного teardown.
    func drainEngineQueue() {
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Поллинг условия с прогоном RunLoop (для событий на фоновых очередях
    /// и глобальной queue разборки движка). Возвращает true, если условие
    /// выполнилось в пределах таймаута.
    @discardableResult
    func eventually(
        timeout: TimeInterval = 2.0,
        file: StaticString = #file,
        line: UInt = #line,
        _ condition: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return condition()
    }
}