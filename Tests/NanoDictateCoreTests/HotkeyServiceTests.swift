import Foundation
import CoreGraphics
@testable import NanoDictateCore

// MARK: - Spy-делегат для проверки срабатываний HotkeyService без event-тапа.

private final class SpyDelegate: HotkeyDelegate {
    var altDoubleTapCount = 0
    var cancelPressedCount = 0
    var enterPressedCount = 0
    /// Ответ предиката «глотать ли Return» (по умолчанию false — как .idle).
    var swallowReturnKey = false
    func altDoubleTapped() { altDoubleTapCount += 1 }
    func cancelKeyPressed() { cancelPressedCount += 1 }
    func enterKeyPressed() { enterPressedCount += 1 }
    func shouldSwallowReturnKeyEvent() -> Bool { swallowReturnKey }
}

final class HotkeyServiceTests: XCTestCase {

    // MARK: - DoubleAltDetector

    @objc func testTwoTapsWithinIntervalIsDoubleTap() {
        var detector = DoubleAltDetector(maxInterval: 0.4)
        XCTAssertFalse(detector.registerTap(at: 1.0))
        XCTAssertTrue(detector.registerTap(at: 1.25)) // 0.25s < 0.4s
    }

    @objc func testTwoTapsWithLargerIntervalIsNotDoubleTap() {
        var detector = DoubleAltDetector(maxInterval: 0.4)
        XCTAssertFalse(detector.registerTap(at: 1.0))
        XCTAssertFalse(detector.registerTap(at: 1.5)) // 0.5s > 0.4s
    }

    @objc func testSingleTapIsNeverDoubleTap() {
        var detector = DoubleAltDetector(maxInterval: 0.4)
        XCTAssertFalse(detector.registerTap(at: 1.0))
    }

    @objc func testThreeFastTapsDetectPairAndReset() {
        var detector = DoubleAltDetector(maxInterval: 0.4)
        XCTAssertFalse(detector.registerTap(at: 1.0))
        // Второй тап в пределах интервала — двойной тап...
        XCTAssertTrue(detector.registerTap(at: 1.1))
        // ...а после срабатывания детектор сброшен: третий тап начинает новое окно.
        XCTAssertFalse(detector.registerTap(at: 1.2))
        // Четвёртый в пределах окна от третьего — снова двойной тап (доказательство сброса).
        XCTAssertTrue(detector.registerTap(at: 1.25))
    }

    @objc func testDetectorIsResetAfterDoubleTap() {
        var detector = DoubleAltDetector(maxInterval: 0.4)
        XCTAssertFalse(detector.registerTap(at: 0.0))
        XCTAssertTrue(detector.registerTap(at: 0.1))
        detector.reset()
        XCTAssertFalse(detector.registerTap(at: 0.2)) // после reset — одиночное нажатие
    }

    @objc func testTapExactlyAtIntervalBoundaryIsDoubleTap() {
        var detector = DoubleAltDetector(maxInterval: 0.4)
        XCTAssertFalse(detector.registerTap(at: 5.0))
        XCTAssertTrue(detector.registerTap(at: 5.4)) // ровно maxInterval
    }

    // MARK: - DoubleAltDetector.cancelPendingTap

    /// «Alt + что угодно ещё» на уровне детектора: первый тап аннулирован —
    /// второй тап даже в окне не считается двойным Alt.
    @objc func testCancelPendingTapBreaksPair() {
        var detector = DoubleAltDetector(maxInterval: 0.4)
        XCTAssertFalse(detector.registerTap(at: 1.0))
        detector.cancelPendingTap() // между нажатиями была другая клавиша
        XCTAssertFalse(detector.registerTap(at: 1.2)) // не двойной Alt
    }

    /// После cancelPendingTap следующий тап начинает НОВОЕ окно: отменённый
    /// первый тап не образует пару с последующим нажатием даже в старом окне.
    @objc func testCancelPendingTapStartsFreshWindow() {
        var detector = DoubleAltDetector(maxInterval: 0.4)
        XCTAssertFalse(detector.registerTap(at: 5.0))
        detector.cancelPendingTap()
        XCTAssertFalse(detector.registerTap(at: 5.4)) // новый первый тап
        XCTAssertTrue(detector.registerTap(at: 5.6)) // двойной тап от НОВОЙ пары
    }

    /// cancelPendingTap без незавершённого тапа — идемпотентный no-op.
    @objc func testCancelPendingTapWithNoPendingIsNoop() {
        var detector = DoubleAltDetector(maxInterval: 0.4)
        detector.cancelPendingTap()
        XCTAssertFalse(detector.registerTap(at: 1.0))
        XCTAssertTrue(detector.registerTap(at: 1.2))
    }

    // MARK: - Routing: HotkeyService.handleKeyboardEvent (синтетические события)

    private func makeService(delegate: SpyDelegate) -> HotkeyService {
        let service = HotkeyService() // maxInterval 0.4s, logLevel "info" — без debug-логов
        service.delegate = delegate
        return service
    }

    /// Реальный CGEvent Return (36) — с маркером SyntheticReturnMarker или без.
    /// По нему тап отличает СВОЙ синтетический Return от физического нажатия
    /// (событие доходит до session-тапа на следующей итерации run loop —
    /// синхронный флаг к тому моменту уже снят, маркер переживает доставку).
    private func makeReturnEvent(marked: Bool) -> CGEvent {
        let event = CGEvent(keyboardEventSource: CGEventSource(stateID: .hidSystemState),
                            virtualKey: 36,
                            keyDown: true)!
        if marked {
            SyntheticReturnMarker.mark(event)
        }
        return event
    }

    /// Чистый Alt+Alt (down/up/down) — ЕДИНСТВЕННЫЙ сценарий, который должен
    /// срабатывать; отпускание Option (flagsChanged без флага) тапом не
    /// считается и пару не рвёт.
    @objc func testRoutingCleanAltAltFires() {
        let delegate = SpyDelegate()
        let service = makeService(delegate: delegate)
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 1.0)   // Alt down
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [], isRepeat: false, at: 1.1)                // Alt up
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 1.2)   // Alt down — в окне
        XCTAssertEqual(delegate.altDoubleTapCount, 1)
    }

    /// Alt зажат + нажат Control — РЕПОРТНУТЫЙ БАГ. macOS при этом шлёт
    /// flagsChanged по клавише Control (59), а в flags остаётся Option.
    /// Это НЕ «второе нажатие Alt»: срабатывать нельзя, и незавершённый
    /// первый тап должен быть аннулирован.
    @objc func testRoutingAltHeldPlusControlDoesNotFire() {
        let delegate = SpyDelegate()
        let service = makeService(delegate: delegate)
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 1.0)             // Alt down
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 59, flags: [.maskAlternate, .maskControl], isRepeat: false, at: 1.1) // Ctrl down
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 59, flags: [.maskAlternate], isRepeat: false, at: 1.2)             // Ctrl up
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [], isRepeat: false, at: 1.3)                          // Alt up
        XCTAssertEqual(delegate.altDoubleTapCount, 0)
        // Следующее быстрое нажатие Alt НЕ образует пару с отменённым первым тапом.
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 1.4)
        XCTAssertEqual(delegate.altDoubleTapCount, 0)
    }

    /// Alt + обычная клавиша ('A', keyCode 0) между нажатиями — не двойной Alt.
    @objc func testRoutingAltPlusNonModifierKeyDoesNotFire() {
        let delegate = SpyDelegate()
        let service = makeService(delegate: delegate)
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 1.0)
        service.handleKeyboardEvent(type: .keyDown, keyCode: 0, flags: [.maskAlternate], isRepeat: false, at: 1.1) // 'A' при зажатом Alt
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 1.2)
        XCTAssertEqual(delegate.altDoubleTapCount, 0)
    }

    /// Одиночный Alt (down + up) — не двойной Alt.
    @objc func testRoutingSingleAltDoesNotFire() {
        let delegate = SpyDelegate()
        let service = makeService(delegate: delegate)
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 1.0)
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [], isRepeat: false, at: 1.1)
        XCTAssertEqual(delegate.altDoubleTapCount, 0)
    }

    /// Автоповтор зажатой Option (keyDown с isRepeat) — не новое нажатие:
    /// одни только повторы не дают ни одного тапа.
    @objc func testRoutingOptionAutorepeatDoesNotFire() {
        let delegate = SpyDelegate()
        let service = makeService(delegate: delegate)
        // Только автоповторы: если бы они считались тапами, пара набралась бы
        // уже на втором событии и срабатывание произошло.
        service.handleKeyboardEvent(type: .keyDown, keyCode: 58, flags: [.maskAlternate], isRepeat: true, at: 1.0)
        service.handleKeyboardEvent(type: .keyDown, keyCode: 58, flags: [.maskAlternate], isRepeat: true, at: 1.1)
        service.handleKeyboardEvent(type: .keyDown, keyCode: 58, flags: [.maskAlternate], isRepeat: true, at: 1.2)
        XCTAssertEqual(delegate.altDoubleTapCount, 0)
        // Первое НЕповторное нажатие — первый тап...
        service.handleKeyboardEvent(type: .keyDown, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 1.3)
        XCTAssertEqual(delegate.altDoubleTapCount, 0)
        // ...второе неповторное в окне (0.35 <= 0.4) — двойной Alt.
        service.handleKeyboardEvent(type: .keyDown, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 1.35)
        XCTAssertEqual(delegate.altDoubleTapCount, 1)
    }

    /// Окно детекта: два нажатия Option дальше maxInterval не образуют пару
    /// (шов управляет временем, поэтому проверка детерминированна).
    @objc func testRoutingTapsOutsideWindowDoNotFire() {
        let delegate = SpyDelegate()
        let service = makeService(delegate: delegate)
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 10.0)
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [], isRepeat: false, at: 10.1)
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 10.5) // 0.5s > 0.4s
        XCTAssertEqual(delegate.altDoubleTapCount, 0)
    }

    /// Cancel-клавиша (Escape) рвёт незавершённый первый тап и шлёт
    /// delegate.cancelKeyPressed() — прежний контракт сохранён.
    @objc func testRoutingCancelKeyCancelsPendingTapAndNotifies() {
        let delegate = SpyDelegate()
        let service = makeService(delegate: delegate)
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 1.0)
        service.handleKeyboardEvent(type: .keyDown, keyCode: 53, flags: [], isRepeat: false, at: 1.1) // Escape
        XCTAssertEqual(delegate.cancelPressedCount, 1)
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 1.2)
        XCTAssertEqual(delegate.altDoubleTapCount, 0) // первый тап аннулирован Escape
    }

    // MARK: - Enter (36) / Keypad Enter (76) — НЕ клавиша отмены

    /// Return (36) больше НЕ зовёт cancelKeyPressed: отдельный колбэк
    /// enterKeyPressed (агент решает по состоянию — стоп записи + латч
    /// синтетического Enter).
    @objc func testRoutingReturnFiresEnterNotCancel() {
        let delegate = SpyDelegate()
        let service = makeService(delegate: delegate)
        service.handleKeyboardEvent(type: .keyDown, keyCode: 36, flags: [], isRepeat: false, at: 1.0)
        XCTAssertEqual(delegate.enterPressedCount, 1)
        XCTAssertEqual(delegate.cancelPressedCount, 0)
    }

    /// Keypad Enter (76) — тот же путь: enterKeyPressed, НЕ cancel.
    @objc func testRoutingKeypadEnterFiresEnterNotCancel() {
        let delegate = SpyDelegate()
        let service = makeService(delegate: delegate)
        service.handleKeyboardEvent(type: .keyDown, keyCode: 76, flags: [], isRepeat: false, at: 1.0)
        XCTAssertEqual(delegate.enterPressedCount, 1)
        XCTAssertEqual(delegate.cancelPressedCount, 0)
    }

    /// Return рвёт незавершённый первый Alt-тап, как любая другая клавиша
    /// между двумя нажатиями Option (это «Alt + что угодно ещё», не двойной Alt).
    @objc func testRoutingReturnBreaksPendingAltTap() {
        let delegate = SpyDelegate()
        let service = makeService(delegate: delegate)
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 1.0)
        service.handleKeyboardEvent(type: .keyDown, keyCode: 36, flags: [], isRepeat: false, at: 1.1) // Return
        XCTAssertEqual(delegate.enterPressedCount, 1)
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 1.2)
        XCTAssertEqual(delegate.altDoubleTapCount, 0) // первый тап аннулирован Return
    }

    // MARK: - Маркер SyntheticReturnMarker: свой синтетический Return (реальный CGEvent)

    /// Предикат-шов HotkeyService.isOwnSyntheticReturnEvent: событие с маркером
    /// распознаётся как СВОЁ (по полю события, а не по синхронному флагу).
    @objc func testIsOwnSyntheticReturnDetectsMarkedEvent() {
        let service = makeService(delegate: SpyDelegate())
        XCTAssertTrue(service.isOwnSyntheticReturnEvent(makeReturnEvent(marked: true)))
        XCTAssertFalse(service.isOwnSyntheticReturnEvent(makeReturnEvent(marked: false)))
    }

    /// Свой синтетический Return (маркер) тап видит повторно: enterKeyPressed
    /// НЕ дублируется — иначе синтетика остановила бы новую запись, начатую
    /// в окне паузы.
    @objc func testRoutingMarkedSyntheticReturnIsIgnored() {
        let delegate = SpyDelegate()
        let service = makeService(delegate: delegate)
        service.handleKeyboardEvent(type: .keyDown, keyCode: 36, flags: [], isRepeat: false, at: 1.0,
                                    event: makeReturnEvent(marked: true))
        XCTAssertEqual(delegate.enterPressedCount, 0)
        XCTAssertEqual(delegate.cancelPressedCount, 0)
    }

    /// Маркированный Return НЕ зовёт cancelPendingTap: пере-просмотр СВОЕГО
    /// синтетического Return между двумя Alt-тапами не съедает первый тап —
    /// двойной Alt срабатывает.
    @objc func testRoutingMarkedSyntheticReturnDoesNotCancelPendingAltTap() {
        let delegate = SpyDelegate()
        let service = makeService(delegate: delegate)
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 1.0) // первый Alt-тап
        service.handleKeyboardEvent(type: .keyDown, keyCode: 36, flags: [], isRepeat: false, at: 1.1,
                                    event: makeReturnEvent(marked: true)) // пере-просмотр синтетики
        XCTAssertEqual(delegate.enterPressedCount, 0)
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 1.2) // второй Alt-тап
        XCTAssertEqual(delegate.altDoubleTapCount, 1) // первый тап жив → двойной Alt
    }

    /// Автоповтор зажатого Return — тоже enterKeyPressed (состояние уже
    /// .transcribing после первого нажатия → агент сам делает no-op; латч
    /// идемпотентный — Enter всегда ровно один).
    @objc func testRoutingReturnAutorepeatStillFiresEnter() {
        let delegate = SpyDelegate()
        let service = makeService(delegate: delegate)
        service.handleKeyboardEvent(type: .keyDown, keyCode: 36, flags: [], isRepeat: true, at: 1.0)
        XCTAssertEqual(delegate.enterPressedCount, 1)
        XCTAssertEqual(delegate.cancelPressedCount, 0)
    }

    // MARK: - Предикат глотания физического Return (shouldSwallowEvent)

    /// Делегат отвечает «глотать» (состояние не .idle) → keyDown Return/
    /// Keypad Enter подавляется.
    @objc func testSwallowHoldsReturnInActiveState() {
        let delegate = SpyDelegate()
        delegate.swallowReturnKey = true
        let service = makeService(delegate: delegate)
        XCTAssertTrue(service.shouldSwallowEvent(type: .keyDown, keyCode: 36))
        XCTAssertTrue(service.shouldSwallowEvent(type: .keyDown, keyCode: 76))
    }

    /// Делегат отвечает «не глотать» (.idle) → Return проходит насквозь.
    @objc func testSwallowAllowsReturnInIdle() {
        let delegate = SpyDelegate()
        delegate.swallowReturnKey = false
        let service = makeService(delegate: delegate)
        XCTAssertFalse(service.shouldSwallowEvent(type: .keyDown, keyCode: 36))
        XCTAssertFalse(service.shouldSwallowEvent(type: .keyDown, keyCode: 76))
    }

    /// Глотается ТОЛЬКО keyDown Return/Keypad Enter: другие клавиши и
    /// flagsChanged не трогаем.
    @objc func testSwallowOnlyKeyDownOfReturnKeys() {
        let delegate = SpyDelegate()
        delegate.swallowReturnKey = true
        let service = makeService(delegate: delegate)
        XCTAssertFalse(service.shouldSwallowEvent(type: .keyDown, keyCode: 0)) // 'A'
        XCTAssertFalse(service.shouldSwallowEvent(type: .keyDown, keyCode: 53)) // Escape
        XCTAssertFalse(service.shouldSwallowEvent(type: .keyDown, keyCode: 58)) // Option
        XCTAssertFalse(service.shouldSwallowEvent(type: .flagsChanged, keyCode: 36))
    }

    /// Синтетический Return (маркер SyntheticReturnMarker в поле события) НЕ
/// глотается даже когда делегат отвечает «глотать» (вне .idle): маркер
/// исключает событие ДО предиката — синтетика доходит до приложения.
    @objc func testSwallowDoesNotHoldForMarkedSyntheticReturn() {
        let delegate = SpyDelegate()
        delegate.swallowReturnKey = true // предикат «глотать» — как вне .idle
        let service = makeService(delegate: delegate)
        XCTAssertFalse(service.shouldSwallowEvent(type: .keyDown, keyCode: 36,
                                                  event: makeReturnEvent(marked: true)))
    }

    /// Немаркированный (физический) Return при том же предикате глотается —
    /// маркер единственный знак отличия синтетики.
    @objc func testSwallowStillHoldsForUnmarkedReturn() {
        let delegate = SpyDelegate()
        delegate.swallowReturnKey = true
        let service = makeService(delegate: delegate)
        XCTAssertTrue(service.shouldSwallowEvent(type: .keyDown, keyCode: 36,
                                                 event: makeReturnEvent(marked: false)))
    }

    /// Делегат отсутствует — ничего не глотается (безопасный дефолт).
    @objc func testSwallowWithNoDelegateIsFalse() {
        let service = HotkeyService() // delegate не назначен
        XCTAssertFalse(service.shouldSwallowEvent(type: .keyDown, keyCode: 36))
    }

    /// Левая и правая Option (58/61) образуют пару симметрично.
    @objc func testRoutingRightOptionPairsWithLeftOption() {
        let delegate = SpyDelegate()
        let service = makeService(delegate: delegate)
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 58, flags: [.maskAlternate], isRepeat: false, at: 1.0)
        service.handleKeyboardEvent(type: .flagsChanged, keyCode: 61, flags: [.maskAlternate], isRepeat: false, at: 1.2)
        XCTAssertEqual(delegate.altDoubleTapCount, 1)
    }

    // MARK: - HotkeyService public API (конструктор не бросает, свойства доступны)

    @objc func testDefaultMaxInterval() {
        let service = HotkeyService()
        XCTAssertEqual(service.doubleTapMaxInterval, 0.4)
    }

    @objc func testCustomMaxInterval() {
        let service = HotkeyService(doubleTapMaxInterval: 1.0)
        XCTAssertEqual(service.doubleTapMaxInterval, 1.0)
    }
}