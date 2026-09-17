import Foundation
import CoreGraphics
@testable import NanoDictateCore

// MARK: - Spy-делегат для проверки срабатываний HotkeyService без event-тапа.

private final class SpyDelegate: HotkeyDelegate {
    var altDoubleTapCount = 0
    var cancelPressedCount = 0
    func altDoubleTapped() { altDoubleTapCount += 1 }
    func cancelKeyPressed() { cancelPressedCount += 1 }
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