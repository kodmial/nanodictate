import Foundation
import AVFoundation
import AudioEngineGuard
@testable import NanoDictateCore

/// Тесты веток вокруг зависаний движка (регрессия фикса replaceEngineAfterWedge):
///   • зависший engine.start() держит только СВОЮ очередь — подмена движка
///     синхронная, свежий движок получает СВОЮ очередь, следующий старт
///     проходит, не дожидаясь заблокированной;
///   • сбой подъёма входного узла (NSException под ObjC-шлюзом) — терминальная
///     ошибка с разборкой движка и успешным повторным стартом;
///   • не-создавшийся конвертер (AVAudioFormat() → nil из
///     AVAudioConverter(from:to:)) — .unsupportedFormat ДО установки tap и БЕЗ
///     teardown; повторный старт после «починки» формата успешен;
///   • разблок устаревшего старта ПОСЛЕ подмены (гонка поколений) — .failure
///     (.engineSuperseded), новый сеанс не тронут, старый движок разобран;
///   • разблок устаревшего старта со СБОЕМ engine.start() после подмены —
///     .failure(сбой старта), новая сессия жива, разобран только свой движок;
///   • старт из очереди зависшего движка, упавший в setup на устаревшем
///     поколении, — .failure(сбой подъёма), разобран только свой движок,
///     текущая пара не тронута.
final class AudioServiceWedgeTests: XCTestCase {

    /// Восстановление после зависшего старта: подмена движка возвращается
    /// немедленно, повторный старт успешен на свежей паре, teardown идёт на
    /// очереди свежего движка, старый разобран на глобальной очереди.
    @objc func testWedgeRecoveryReplacesEngineAndRestarts() {
        let hanging = FakeEngine()
        let working = FakeEngine()
        var factoryCalls = 0
        let service = AudioService(
            logLevel: "info",
            engine: hanging,
            makeEngine: {
                factoryCalls += 1
                return working
            }
        )
        let hangSignal = DispatchSemaphore(value: 0)
        hanging.hangStart = hangSignal

        // Старт уходит на очередь зависшего движка и застревает в start().
        service.start { _ in }
        // Дождаться, что старт РЕАЛЬНО завис (startCount == 1 → поток в
        // semaphore.wait(), очередь движка заблокирована навсегда).
        XCTAssertTrue(
            eventually { hanging.startCount == 1 },
            "старт обязан дойти до engine.start() и заблокироваться"
        )

        // Уже висим: подмена обязана вернуться немедленно (она НЕ идёт через
        // очередь движка — иначе восстановление не наступило бы никогда).
        service.replaceEngineAfterWedge()
        XCTAssertEqual(factoryCalls, 1, "подмена создаёт ровно один свежий движок")

        // Повторный старт — на свежей паре (движок + СВОЯ очередь): успешен,
        // несмотря на навсегда заблокированную очередь старого движка.
        guard case .success = runStart(service) else {
            XCTFail("повторный старт после подмены обязан пройти")
            return
        }
        XCTAssertEqual(working.node.tapCount, 1, "свежий движок ставит свой tap")
        XCTAssertEqual(working.startCount, 1, "свежий движок реально стартовал")
        XCTAssertEqual(hanging.startCount, 1, "зависший движок стартовал ровно один раз")

        // stop() после восстановления уходит на очередь СВЕЖЕГО движка и
        // доезжает до teardown, хотя очередь старого всё ещё заблокирована.
        let samples = service.stop()
        XCTAssertTrue(
            eventually { working.stopCount == 1 },
            "teardown свежего движка обязан дойти"
        )

        // Старый движок разобран на глобальной очереди (не на своей
        // заблокированной): stop() старого экземпляра вызван.
        XCTAssertTrue(
            eventually { hanging.stopCount == 1 },
            "зависший движок обязан быть остановлен вне своих очередей"
        )

        // Освободить зависший поток, чтобы тестовый процесс завершился чисто.
        hangSignal.signal()
        XCTAssertEqual(samples, [])
    }

    /// Сбой подъёма входного узла: NSException makeInputNode() → NSError под
    /// шлюзом → терминальный .failure с разборкой движка (stop вызван, tap не
    /// ставился — снимать нечего) и успешный повторный старт на том же сервисе.
    @objc func testSetupFailureRaisesAndAllowsRestart() {
        let engine = FakeEngine()
        engine.failSetup = true
        let service = AudioService(logLevel: "info", engine: engine)

        let first = runStart(service)
        guard case .failure = first else {
            XCTFail("сбой подъёма узла обязан дать терминальный .failure")
            return
        }
        XCTAssertEqual(engine.node.tapCount, 0, "tap не ставился — узел не поднялся")
        XCTAssertEqual(engine.node.removeTapCount, 0, "снимать tap нечего")
        XCTAssertEqual(engine.stopCount, 1, "движок остановлен в teardown терминальной ветки")

        // «Починка» узла — повторный старт на ТОМ ЖЕ сервисе успешен.
        engine.failSetup = false
        guard case .success = runStart(service) else {
            XCTFail("повторный старт после сбоя подъёма обязан пройти")
            return
        }
        XCTAssertEqual(engine.node.tapCount, 1, "повторный старт ставит свежий tap")
    }

    /// Не-создавшийся конвертер: аппаратный формат AVAudioFormat() (rate 0)
    /// даёт nil из AVAudioConverter(from:to:) → .unsupportedFormat ДО установки
    /// tap (снимать нечего, движок не остановлен); после «починки» формата
    /// повторный старт успешен — та же механика, что и у регрессии «формат
    /// рассинхронизировался после смены устройства».
    @objc func testNilConverterFailsBeforeTapAndRetrySucceeds() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)

        // Нулевой формат: AVAudioConverter(from:to:) возвращает nil.
        engine.node.format = AVAudioFormat()

        let first = runStart(service)
        guard case .failure(let error) = first else {
            XCTFail("nil-конвертер обязан дать терминальный .failure")
            return
        }
        XCTAssertEqual(error as? AudioServiceError, .unsupportedFormat, "ожидали .unsupportedFormat")
        XCTAssertEqual(engine.node.tapCount, 0, "tap НЕ установлен — конвертер не создался ДО installTap")
        XCTAssertEqual(engine.node.removeTapCount, 0, "снимать tap нечего")
        XCTAssertEqual(engine.stopCount, 0, "движок не тронут — teardown в этой ветке не нужен")

        // «Починка» формата (как при восстановлении после смены устройства) —
        // повторный старт успешен.
        engine.node.format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        guard case .success = runStart(service) else {
            XCTFail("повторный старт после починки формата обязан пройти")
            return
        }
        XCTAssertEqual(engine.node.tapCount, 1, "повторный старт ставит свежий tap")
        XCTAssertEqual(engine.node.removeTapCount, 0, "старт без аварийной ветки tap не снимал")
    }

    /// Гонка поколений: зависший старт СТАРОГО движка разблокируется только
    /// ПОСЛЕ wedge-подмены и старта новой записи на свежем движке. Устаревший
    /// старт обязан: вернуть .failure(.engineSuperseded) (НЕ .success — иначе
    /// агент вызвал бы audio.cancel() на живой свежей паре), НЕ тронуть state
    /// нового сеанса (isRecording/буферы), разобрать ТОЛЬКО свой движок, а tap
    /// старого поколения — молча дропать буферы, не подмешивая их в новую запись.
    @objc func testStaleStartUnblockAfterWedgeDoesNotTouchNewSession() {
        let hanging = FakeEngine()
        let working = FakeEngine()
        var factoryCalls = 0
        let service = AudioService(
            logLevel: "info",
            engine: hanging,
            makeEngine: {
                factoryCalls += 1
                return working
            }
        )
        let hangSignal = DispatchSemaphore(value: 0)
        hanging.hangStart = hangSignal

        // Старт №1 уходит на очередь зависшего движка и застревает в start().
        // Его completion ловим отдельно — это и есть «устаревший старт».
        var staleResult: AudioStartResult?
        service.start { result in
            if staleResult == nil {
                staleResult = result
            }
        }
        XCTAssertTrue(
            eventually { hanging.startCount == 1 },
            "старт обязан дойти до engine.start() и заблокироваться"
        )

        // Wedge: подмена движка + его очереди + инкремент поколения.
        service.replaceEngineAfterWedge()
        XCTAssertEqual(factoryCalls, 1, "подмена создаёт ровно один свежий движок")

        // Новая запись на свежем движке — успешно пошла.
        guard case .success = runStart(service) else {
            XCTFail("повторный старт после подмены обязан пройти")
            return
        }

        // Сэмплы новой сессии через tap СВЕЖЕГО движка.
        working.node.emit(makeToneBuffer(engine: working))
        // Tap СТАРОГО движка всё ещё установлен и пытается кормить: его
        // поколение устарело — буфер обязан быть молча дропнут, а не попасть
        // в накопление новой сессии.
        hanging.node.emit(makeToneBuffer(engine: hanging))
        // Ещё кусок новой сессии — накопление живо и далее.
        working.node.emit(makeToneBuffer(engine: working))

        // Отпускаем зависший start() старого движка: он завершается, когда его
        // поколение уже НЕ текущее.
        hangSignal.signal()

        // Устаревший старт обязан завершиться .failure(.engineSuperseded).
        XCTAssertTrue(
            eventually { staleResult != nil },
            "разблокированный старт обязан завершиться"
        )
        switch staleResult {
        case .failure(AudioServiceError.engineSuperseded)?:
            break
        default:
            XCTFail("устаревший старт обязан дать .failure(.engineSuperseded), получили \(String(describing: staleResult))")
        }

        // Старый движок разобран устаревшей веткой (tap снят ровно один раз;
        // stop мог прийти и раньше — wedge-разборкой на глобальной очереди).
        XCTAssertTrue(
            eventually { hanging.node.removeTapCount == 1 },
            "устаревший старт обязан снять tap со СВОЕГО движка"
        )
        XCTAssertGreaterThanOrEqual(hanging.stopCount, 1, "устаревший движок обязан быть остановлен")

        // Новая сессия не тронута: сэмплы двух буферов свежего движка на месте,
        // буфер старого tap в них не попал (нет задвоения сверх 2 буферов).
        let samples = service.stop()
        XCTAssertGreaterThanOrEqual(samples.count, 2 * 1410, "сэмплы нового сеанса обязаны сохраниться (два буфера свежего движка)")
        XCTAssertLessThanOrEqual(samples.count, 2 * 1560, "сэмплы не должны задваиваться — буфер старого tap дропнут")

        // stop() разобрал СВЕЖИЙ движок: его teardown дошёл до конца.
        XCTAssertTrue(
            eventually { working.stopCount == 1 },
            "teardown свежего движка обязан дойти"
        )
    }

    /// Гонка поколений + сбой engine.start(): зависший старт СТАРОГО движка
    /// разблокировался ПОСЛЕ wedge-подмены и падает на engine.start() (вис →
    /// throw, см. FakeEngine.start). Устаревшая ветка сбоя обязана: вернуть
    /// .failure(сбой старта) (НЕ .success и НЕ .engineSuperseded-«успех»), НЕ
    /// тронуть state нового сеанса (isRecording/буферы — булевая часть teardown
    /// не выполняется), разобрать ТОЛЬКО свой движок.
    @objc func testStaleStartFailureAfterWedgeDoesNotTouchNewSession() {
        let hanging = FakeEngine()
        let working = FakeEngine()
        hanging.failStart = true
        var factoryCalls = 0
        let service = AudioService(
            logLevel: "info",
            engine: hanging,
            makeEngine: {
                factoryCalls += 1
                return working
            }
        )
        let hangSignal = DispatchSemaphore(value: 0)
        hanging.hangStart = hangSignal

        // Старт №1 уходит на очередь зависшего движка и застревает в start().
        // Его completion ловим отдельно — это и есть «устаревший старт».
        var staleResult: AudioStartResult?
        service.start { result in
            if staleResult == nil {
                staleResult = result
            }
        }
        XCTAssertTrue(
            eventually { hanging.startCount == 1 },
            "старт обязан дойти до engine.start() и заблокироваться"
        )

        // Wedge: подмена движка + его очереди + инкремент поколения.
        service.replaceEngineAfterWedge()
        XCTAssertEqual(factoryCalls, 1, "подмена создаёт ровно один свежий движок")

        // Новая запись на свежем движке — успешно пошла.
        guard case .success = runStart(service) else {
            XCTFail("повторный старт после подмены обязан пройти")
            return
        }

        // Сэмплы новой сессии через tap СВЕЖЕГО движка.
        working.node.emit(makeToneBuffer(engine: working))
        // Tap СТАРОГО движка всё ещё установлен и пытается кормить: его
        // поколение устарело — буфер обязан быть молча дропнут.
        hanging.node.emit(makeToneBuffer(engine: hanging))
        // Ещё кусок новой сессии — накопление живо и далее.
        working.node.emit(makeToneBuffer(engine: working))

        // Отпускаем зависший start() старого движка: он завершается СБОЕМ
        // (failStart проверяется ПОСЛЕ разблокировки), когда его поколение уже
        // НЕ текущее.
        hangSignal.signal()

        // Устаревший старт обязан завершиться .failure(сбой engine.start()).
        XCTAssertTrue(
            eventually { staleResult != nil },
            "разблокированный старт обязан завершиться"
        )
        switch staleResult {
        case .failure(AudioServiceError.unsupportedFormat)?:
            break
        default:
            XCTFail("устаревший старт со сбоем engine.start() обязан дать .failure(.unsupportedFormat), получили \(String(describing: staleResult))")
        }

        // Старый движок разобран устаревшей веткой (tap снят ровно один раз;
        // stop мог прийти и раньше — wedge-разборкой на глобальной очереди).
        XCTAssertTrue(
            eventually { hanging.node.removeTapCount == 1 },
            "устаревший старт обязан снять tap со СВОЕГО движка"
        )
        XCTAssertGreaterThanOrEqual(hanging.stopCount, 2, "устаревший движок обязан быть остановлен (wedge + stale-разборка)")

        // Новая сессия НЕ тронута: булевая часть teardown (setRecording(false)/
        // сброс буферов) НЕ выполнялась — запись всё ещё идёт, stop() отдаёт
        // сэмплы двух буферов свежего движка (буфер старого tap не задваивает).
        let samples = service.stop()
        XCTAssertGreaterThanOrEqual(samples.count, 2 * 1410, "сэмплы нового сеанса обязаны сохраниться — запись не убита устаревшей веткой сбоя")
        XCTAssertLessThanOrEqual(samples.count, 2 * 1560, "сэмплы не должны задваиваться — буфер старого tap дропнут")

        // stop() разобрал СВЕЖИЙ движок: его teardown дошёл до конца.
        XCTAssertTrue(
            eventually { working.stopCount == 1 },
            "teardown свежего движка обязан дойти"
        )
    }

    /// Гонка поколений + сбой подъёма узла: старт №2 ПОСТАВЛЕН В ОЧЕРЕДЬ
    /// зависшего движка (позади «висящего» start №1). После wedge-подмены он
    /// выполняется на устаревшем поколении и падает в setup (makeInputNode под
    /// шлюзом). Stale-guard ветки setup-сбоя обязан: вернуть .failure(сбой
    /// подъёма), разобрать ТОЛЬКО свой (старый) движок, НЕ выполнять булевую
    /// часть teardown (setRecording(false)/сброс буферов/tapInstalled) и НЕ
    /// задеть текущую пару — старт на ней после разборок успешен.
    @objc func testStaleSetupFailureAfterWedgeTearsDownOnlyOldEngine() {
        let hanging = FakeEngine()
        let working = FakeEngine()
        var factoryCalls = 0
        let service = AudioService(
            logLevel: "info",
            engine: hanging,
            makeEngine: {
                factoryCalls += 1
                return working
            }
        )
        let hangSignal = DispatchSemaphore(value: 0)
        hanging.hangStart = hangSignal

        // Старт №1 уходит на очередь зависшего движка и застревает в start().
        service.start { _ in }
        XCTAssertTrue(
            eventually { hanging.startCount == 1 },
            "старт обязан дойти до engine.start() и заблокироваться"
        )

        // Старт №2 — в ту же очередь старого движка, ЗА висящим start №1: он не
        // начнётся, пока очередь не разблокируется, и выполнит setup уже на
        // устаревшем поколении (тот же снимок поколения W).
        var staleSetupResult: AudioStartResult?
        service.start { result in
            if staleSetupResult == nil {
                staleSetupResult = result
            }
        }

        // Wedge: поколение W+1, свежий движок и его очередь.
        service.replaceEngineAfterWedge()
        XCTAssertEqual(factoryCalls, 1, "подмена создаёт ровно один свежий движок")

        // «Поломка» setup до разблокировки очереди: старт №2 упадёт на
        // makeInputNode уже на устаревшем поколении.
        hanging.failSetup = true

        // Разблокируем очередь: сначала доезжает висящий start №1 (устаревший
        // УСПЕХ → .failure(.engineSuperseded), см. тест выше), затем — старт №2.
        hangSignal.signal()

        // Старт №2 обязан завершиться .failure(сбой подъёма узла) — НЕ успеть
        // считаться «текущим» стартом.
        XCTAssertTrue(
            eventually { staleSetupResult != nil },
            "старт из очереди зависшего движка обязан завершиться"
        )
        guard case .failure = staleSetupResult else {
            XCTFail("устаревший setup-сбой обязан дать .failure, получили \(String(describing: staleSetupResult))")
            return
        }

        // Оба устаревших старта разобрали СВОЙ движок: stop вызван наверняка
        // (подмена на глобальной очереди + teardownEngineOnly двух stale-веток).
        // removeTap не счётчик: teardownEngineOnly идёт через makeInputNode, а у
        // фейка failSetup=true он падает ДО removeTap — снимать нечего.
        XCTAssertTrue(
            eventually { hanging.stopCount >= 3 },
            "старый движок обязан быть остановлен (wedge-global + две stale-разборки)"
        )

        // Ключевой гард: stale-ветка setup-сбоя НЕ выполнила булевую часть
        // teardown (setRecording(false)). isRecording остался true (его ставил
        // старт №1 до зависания, wedge его не трогает) — stop() обязан пойти в
        // teardown ТЕКУЩЕЙ пары (working), а не вернуться рано. Незащищённая
        // ветка сбросила бы флаг → stop() вернул бы [] без разборки →
        // working.stopCount остался бы 0 — ассерт ловит регрессию гарда.
        _ = service.stop()
        XCTAssertTrue(
            eventually { working.stopCount == 1 },
            "isRecording не сбит stale-разборками — stop() разобрал текущую пару"
        )

        // Текущая пара жива: следующий старт на ней успешен, tap ставится без
        // коллизии.
        guard case .success = runStart(service) else {
            XCTFail("старт на текущей паре после stale-разборок обязан пройти")
            return
        }
        XCTAssertEqual(working.node.tapCount, 1, "текущая пара ставит свой tap")
        _ = service.stop()
        XCTAssertTrue(
            eventually { working.stopCount == 2 },
            "повторный teardown текущей пары обязан дойти"
        )
    }

    /// Буфер 44.1 кГц/моно с постоянной амплитудой 0.2 («тон», не тишина) —
    /// эмуляция буфера из tap-колбэка в формате узла движка.
    private func makeToneBuffer(engine: FakeEngine) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.node.format, frameCapacity: 4096)!
        buffer.frameLength = 4096
        let channel = buffer.floatChannelData![0]
        for i in 0..<4096 {
            channel[i] = 0.2
        }
        return buffer
    }
}