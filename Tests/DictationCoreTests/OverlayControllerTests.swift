import Foundation
import AppKit
@testable import DictationCore

/// Тесты на функционал, который ЧТО-ТО ВЫВОДИТ: оверлей (панель с микрофоном).
///
/// Задача этих тестов — не дать оверлею снова «исчезнуть»: пользователь
/// сообщил, что индикатор записи вообще нигде не виден (не в углу, а нигде).
/// Поэтому здесь проверяется не просто состояние, а сам факт отображения:
/// `isVisible`, реальный frame окна и попадание его в границы экрана.
final class OverlayControllerTests: XCTestCase {

    override func setUp() {
        // XCTest runner — обычный CLI-процесс без NSApp; без AppKit-init
        // NSPanel не создастся, а значит тест «оверлей выводится» упадёт
        // с понятной ошибкой, а не молча покажет «false».
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Позиционирование (чистая логика)

    @objc func testPanelFrameIsAboveCaret_WhenSpaceAvailable() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let caret = CGPoint(x: 700, y: 500)
        let frame = OverlayLayout.panelFrame(near: caret, inside: screen, panelSize: CGSize(width: 260, height: 120))

        // Панель над кареткой: верхний край не выше каретки, низ — на 12pt выше
        XCTAssertEqual(frame.maxY, 500 - 12, accuracy: 0.001)
        XCTAssertFalse(frame.contains(caret))
        XCTAssertLessThanOrEqual(frame.maxY, caret.y)
        // Горизонтально центрирована по каретке
        XCTAssertEqual(frame.midX, caret.x, accuracy: 0.001)
        // Не вылезает за экран
        XCTAssertGreaterThanOrEqual(frame.minX, screen.minX)
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY)
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY)
    }

    @objc func testPanelFrameMovesBelowCaret_WhenNoRoomAbove() {
        // Каретка у нижнего края экрана — над ней нет места. Панель должна
        // встать ПОД кареткой и НЕ пропасть за экран.
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let caret = CGPoint(x: 700, y: 30) // panel above needs y >= 8; 30-120-12 < 8
        let frame = OverlayLayout.panelFrame(near: caret, inside: screen, panelSize: CGSize(width: 260, height: 120))

        XCTAssertEqual(frame.minY, 30 + 12, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY + 8)
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY)
    }

    @objc func testPanelFrameClampedToScreenEdges_Horizontal() {
        // Каретка у самого левого края — панель не должна вылезти налево.
        let screen = CGRect(x: 100, y: 0, width: 800, height: 600)
        let caret = CGPoint(x: 102, y: 300)
        let frame = OverlayLayout.panelFrame(near: caret, inside: screen, panelSize: CGSize(width: 260, height: 120))

        XCTAssertGreaterThanOrEqual(frame.minX, 108, accuracy: 0.001) // screen.minX + 8
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX)
    }

    @objc func testScreenContaining_FallsBackToMainScreen() {
        // Для точек вне real-экранов канвас должен быть непустым frame
        // (берётся NSScreen.main) — панель никогда не останется без экрана,
        // а значит никогда не «пропадёт» из-за координат.
        let caret = CGPoint(x: -5000, y: -5000)
        let screen = OverlayLayout.screenContaining(caret)
        XCTAssertTrue(screen.width > 0)
        XCTAssertTrue(screen.height > 0)
    }

    // MARK: - resolvePoint (чистая цепочка фоллбэков позиционирования)

    @objc func testResolvePoint_UsesCaret_WhenValid() {
        // Валидная каретка → берётся именно её точка.
        let caret = CGPoint(x: 100, y: 200)
        let mouse = CGPoint(x: 300, y: 400)
        let center = CGPoint(x: 720, y: 450)
        let point = OverlayLayout.resolvePoint(
            caret: caret,
            mouse: mouse,
            screenCenter: center
        ) { $0.x > 0 && $0.y > 0 }
        XCTAssertEqual(point, caret)
    }

    @objc func testResolvePoint_FallsBackToMouse_WhenCaretNilOrOffScreen() {
        // Каретка nil или вне экрана → позиция мыши.
        let mouse = CGPoint(x: 300, y: 400)
        let center = CGPoint(x: 720, y: 450)
        let isValid = { (p: CGPoint) -> Bool in
            p.x > 0 && p.x < 2000 && p.y > 0 && p.y < 2000
        }

        let fromNil = OverlayLayout.resolvePoint(
            caret: nil, mouse: mouse, screenCenter: center, isValid: isValid
        )
        XCTAssertEqual(fromNil, mouse)

        let offScreenCaret = CGPoint(x: -5000, y: -5000)
        let fromOffScreen = OverlayLayout.resolvePoint(
            caret: offScreenCaret, mouse: mouse, screenCenter: center, isValid: isValid
        )
        XCTAssertEqual(fromOffScreen, mouse)
    }

    @objc func testResolvePoint_FallsBackToCenter_WhenMouseOffScreen() {
        // Мышь вне экрана (и каретка отсутствует) → центр главного экрана.
        let mouse = CGPoint(x: -9999, y: -9999)
        let center = CGPoint(x: 720, y: 450)
        let isValid = { (p: CGPoint) -> Bool in
            if p == mouse { return false }
            return p.x > 0 && p.y > 0
        }
        let point = OverlayLayout.resolvePoint(
            caret: nil, mouse: mouse, screenCenter: center, isValid: isValid
        )
        XCTAssertEqual(point, center)
    }

    // MARK: - Реальный вывод (панель)

    @objc func testShowMakesPanelVisible_WithCorrectFrame() {
        let controller = OverlayController()
        controller.show(at: CGPoint(x: 700, y: 500))

        // Главное: после show() панель обязана быть видимой.
        XCTAssertTrue(controller.isVisible, "Оверлей не виден после show() — экран не выводится")
        XCTAssertNotNil(controller.testPanelFrame)

        // Frame действительно рядом с точкой показа.
        if let frame = controller.testPanelFrame {
            XCTAssertEqual(frame.midX, 700, accuracy: 2)
            XCTAssertLessThanOrEqual(frame.maxY, 500)
        }

        controller.hide()
        XCTAssertFalse(controller.isVisible, "Оверлей не скрылся после hide()")
    }

    @objc func testShowRepeated_KeepsSinglePanel() {
        let controller = OverlayController()
        controller.show(at: CGPoint(x: 100, y: 100))
        let firstPanel = controller.testPanel
        XCTAssertNotNil(firstPanel)

        controller.show(at: CGPoint(x: 300, y: 500))
        controller.show(at: CGPoint(x: 500, y: 800))

        XCTAssertTrue(controller.isVisible)
        // Три вызова show() не должны плодить окна: панель одна и та же.
        XCTAssertTrue(controller.testPanel === firstPanel, "Повторный show() не должен создавать новые панели")

        controller.hide()
    }

    @objc func testUpdateLevel_ClampsAndKeepsPanelVisible() {
        let controller = OverlayController()
        controller.show(at: CGPoint(x: 400, y: 400))
        XCTAssertTrue(controller.isVisible)

        // Уровень за пределами [0,1] клампится, панель остаётся видимой.
        controller.updateLevel(3.14)
        XCTAssertTrue(controller.isVisible)

        controller.updateLevel(-5)
        XCTAssertTrue(controller.isVisible)

        controller.updateLevel(0)
        XCTAssertTrue(controller.isVisible)
    }

    @objc func testSetStatus_DoesNotHidePanel() {
        let controller = OverlayController()
        controller.show(at: CGPoint(x: 400, y: 400))

        controller.setStatus("Записываю…")
        controller.setStatus("Распознаю…")
        controller.setStatus("Завершаю…")

        XCTAssertTrue(controller.isVisible, "Смена статуса не должна прятать оверлей")
        controller.hide()
    }

    @objc func testState_LevelClampedToUnitInterval() {
        let state = OverlayState()
        state.updateLevel(2.5)
        XCTAssertEqual(state.level, 1.0, accuracy: 0.001)
        state.updateLevel(-0.3)
        XCTAssertEqual(state.level, 0.0, accuracy: 0.001)
        state.updateLevel(0.42)
        XCTAssertEqual(state.level, 0.42, accuracy: 0.001)
    }
}