import Foundation
import AppKit
@testable import NanoDictateCore

/// Тесты на функционал, который ЧТО-ТО ВЫВОДИТ: оверлей (панель с микрофоном).
///
/// Задача этих тестов — не дать оверлею снова «исчезнуть»: пользователь
/// сообщил, что индикатор записи вообще нигде не виден (не в углу, а нигде).
/// Здесь проверяется, что show() строит панель с корректным frame и фазами.
///
/// ВАЖНО: в тестовом раннере (NANODICTATE_TESTS=1) панель НЕ выводится на экран
/// — OverlayController пропускает orderFront/активацию NSApp, чтобы прогоны
/// тестов не тревожили пользователя мигающим оверлеем. Тесты проверяют
/// состояние и frame через testPanel/testPanelFrame/testState и отдельно
/// доказывают, что панель на экране НЕ появилась (isVisible == false).
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

    // MARK: - Создание панели (состояние, без реального вывода на экран)

    @objc func testShowSetsPanelFrame_AndState() {
        let controller = OverlayController()
        controller.show(at: CGPoint(x: 700, y: 500))

        // В тестовом раннере панель на экран не выводится (см. doc-комментарий
        // класса), но обязана создаться и зафреймиться — это и проверяем.
        XCTAssertNotNil(controller.testPanel, "Панель должна создаваться при show()")
        XCTAssertNotNil(controller.testPanelFrame)

        // Frame действительно рядом с точкой показа.
        if let frame = controller.testPanelFrame {
            XCTAssertEqual(frame.midX, 700, accuracy: 2)
            XCTAssertLessThanOrEqual(frame.maxY, 500)
        }

        // Панель НЕ появилась на экране: прогоны тестов не тревожат
        // пользователя мигающим оверлеем.
        XCTAssertFalse(controller.isVisible, "В тестовом раннере панель не должна выводиться на экран")

        controller.hide()
        XCTAssertFalse(controller.isVisible)
    }

    @objc func testShowRepeated_KeepsSinglePanel() {
        let controller = OverlayController()
        controller.show(at: CGPoint(x: 100, y: 100))
        let firstPanel = controller.testPanel
        XCTAssertNotNil(firstPanel)

        controller.show(at: CGPoint(x: 300, y: 500))
        controller.show(at: CGPoint(x: 500, y: 800))

        XCTAssertNotNil(controller.testPanel)
        // Три вызова show() не должны плодить окна: панель одна и та же.
        XCTAssertTrue(controller.testPanel === firstPanel, "Повторный show() не должен создавать новые панели")

        controller.hide()
    }

    @objc func testUpdateLevel_ClampsAndKeepsPanelPresented() {
        let controller = OverlayController()
        controller.show(at: CGPoint(x: 400, y: 400))
        let panel = controller.testPanel
        XCTAssertNotNil(panel)

        // Уровень за пределами [0,1] клампится, панель не «уходит» со сцены.
        controller.updateLevel(3.14)
        XCTAssertEqual(Double(controller.testState?.level ?? 0), 1.0, accuracy: 0.001)
        XCTAssertTrue(controller.testPanel === panel)

        controller.updateLevel(-5)
        XCTAssertEqual(Double(controller.testState?.level ?? 0), 0.0, accuracy: 0.001)
        XCTAssertTrue(controller.testPanel === panel)

        controller.updateLevel(0)
        XCTAssertEqual(Double(controller.testState?.level ?? 0), 0.0, accuracy: 0.001)
        XCTAssertTrue(controller.testPanel === panel)

        controller.hide()
    }

    @objc func testSetStatus_DoesNotHidePanel() {
        let controller = OverlayController()
        controller.show(at: CGPoint(x: 400, y: 400))
        let panel = controller.testPanel
        XCTAssertNotNil(panel)

        controller.setStatus("Записываю…")
        controller.setStatus("Распознаю…")
        controller.setStatus("Завершаю…")

        XCTAssertTrue(controller.testPanel === panel, "Смена статуса не должна прятать оверлей")
        XCTAssertEqual(controller.testState?.status, "Завершаю…")
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

    // MARK: - Таймер записи (форматирование + фазы)

    @objc func testTimeFormat_PadsSecondsAndMinutes() {
        // Требование: «0:00» / «0:07» — минуты без паддинга, секунды с ведущим нулём.
        XCTAssertEqual(OverlayTimeFormat.format(0), "0:00")
        XCTAssertEqual(OverlayTimeFormat.format(7), "0:07")
        XCTAssertEqual(OverlayTimeFormat.format(65), "1:05")
        XCTAssertEqual(OverlayTimeFormat.format(599), "9:59")
        // Дробные секунды обрезаются вниз, как тикает таймер.
        XCTAssertEqual(OverlayTimeFormat.format(7.4), "0:07")
        XCTAssertEqual(OverlayTimeFormat.format(7.9), "0:07")
    }

    @objc func testTimeFormat_ClampsNegative() {
        XCTAssertEqual(OverlayTimeFormat.format(-3), "0:00")
    }

    @objc func testSetRecordingPhase_StoresStartAndSetsRecording() {
        let controller = OverlayController()
        // Старт-тайм передаётся извне (вью считает секунды именно от него —
        // не от локального «когда успели»).
        let start = Date().addingTimeInterval(-65)
        controller.setRecordingPhase(startedAt: start)
        XCTAssertEqual(controller.testState?.phase, .recording)
        XCTAssertEqual(controller.testState?.recordingStart, start)
    }

    @objc func testSetProcessingPhase_SwitchesFromRecording() {
        let controller = OverlayController()
        controller.setRecordingPhase()
        controller.setProcessingPhase()
        XCTAssertEqual(controller.testState?.phase, .processing)
    }

    @objc func testResetPhase_ClearsRecordingState() {
        let controller = OverlayController()
        controller.setRecordingPhase()
        XCTAssertEqual(controller.testState?.phase, .recording)
        controller.resetPhase()
        XCTAssertEqual(controller.testState?.phase, .idle)
        XCTAssertNil(controller.testState?.recordingStart)
    }

    @objc func testHide_ResetsPhase() {
        let controller = OverlayController()
        controller.show(at: CGPoint(x: 400, y: 400))
        controller.setRecordingPhase()
        XCTAssertEqual(controller.testState?.phase, .recording)
        controller.hide()
        XCTAssertEqual(controller.testState?.phase, .idle, "Скрытие сбрасывает фазу — таймер не живёт за кадром")
        XCTAssertNil(controller.testState?.recordingStart)
    }

    @objc func testRecordingPhase_MakesPanelTaller() {
        let controller = OverlayController()
        controller.show(at: CGPoint(x: 700, y: 500))
        let idleHeight = controller.testPanelFrame?.height ?? 0
        controller.setRecordingPhase()
        let recordingHeight = controller.testPanelFrame?.height ?? 0
        XCTAssertTrue(
            recordingHeight > idleHeight,
            "При записи панель выше: под иконкой живёт таймер «0:07» (было \(idleHeight), стало \(recordingHeight))"
        )
        controller.hide()
    }

    @objc func testPanelHeights_FollowPhases() {
        // Высоты зависят от фазы: idle ~150 (компактная плашка), recording
        // ~178 (под иконкой таймер «0:07»); при смене фазы панель пересчитывает
        // frame, оставаясь привязанной к точке показа.
        let controller = OverlayController()
        controller.show(at: CGPoint(x: 700, y: 500))
        XCTAssertEqual(controller.testPanelFrame?.height ?? 0, 150,
                       accuracy: 0.001, "idle: компактная высота плашки")
        controller.setRecordingPhase()
        XCTAssertEqual(controller.testPanelFrame?.height ?? 0, 178,
                       accuracy: 0.001, "recording: таймер делает панель выше")
        controller.setProcessingPhase()
        XCTAssertEqual(controller.testPanelFrame?.height ?? 0, 150,
                       accuracy: 0.001, "processing: снова компактная")
        controller.resetPhase()
        XCTAssertEqual(controller.testPanelFrame?.height ?? 0, 150,
                       accuracy: 0.001, "resetPhase: базовая компактная")
        controller.hide()
    }

    @objc func testPanelWidth_AutofitsWithinClamp() {
        // Ширина больше не жёсткая 280: считается из fittingSize контента и
        // клампится в [180, 240] — компактная плашка, а не фикс под «шапку».
        let controller = OverlayController()
        controller.show(at: CGPoint(x: 700, y: 500))
        let width = controller.testPanelFrame?.width ?? 0
        XCTAssertGreaterThanOrEqual(width, 180, "автоширина не уже мин-клампа 180")
        XCTAssertLessThanOrEqual(width, 240, "автоширина не шире макс-клампа 240")

        // Смена фазы меняет только высоту — ширина остаётся той же.
        controller.setRecordingPhase()
        XCTAssertEqual(controller.testPanelFrame?.width ?? 0, width,
                       accuracy: 0.001, "recording не меняет ширину")
        controller.setProcessingPhase()
        XCTAssertEqual(controller.testPanelFrame?.width ?? 0, width,
                       accuracy: 0.001, "processing не меняет ширину")
        controller.hide()
    }

    @objc func testClampedPanelWidth_BoundsAutofit() {
        // Чистый кламп автоширины: min 180 / max 240.
        XCTAssertEqual(OverlayLayout.clampedPanelWidth(from: -50), 180)
        XCTAssertEqual(OverlayLayout.clampedPanelWidth(from: 0), 180)
        XCTAssertEqual(OverlayLayout.clampedPanelWidth(from: 100), 180)
        XCTAssertEqual(OverlayLayout.clampedPanelWidth(from: 200), 200)
        XCTAssertEqual(OverlayLayout.clampedPanelWidth(from: 240), 240)
        XCTAssertEqual(OverlayLayout.clampedPanelWidth(from: 500), 240)
    }

    // MARK: - Маппинг сетевых ошибок на текст оверлея (OverlayErrorText)

    @objc func testOverlayErrorText_NoInternet() {
        // Нет интернета → короткое сообщение «No internet» (а не безликий текст ошибки).
        XCTAssertEqual(
            OverlayErrorText.text(for: TranscribeError.network(Transcriber.noInternetMessage)),
            "No internet"
        )
        XCTAssertEqual(OverlayErrorText.networkText(Transcriber.noInternetMessage), "No internet")
    }

    @objc func testOverlayErrorText_SttTimeout() {
        XCTAssertEqual(
            OverlayErrorText.text(for: TranscribeError.network(Transcriber.sttTimeoutMessage)),
            "STT timeout"
        )
        XCTAssertEqual(OverlayErrorText.networkText(Transcriber.sttTimeoutMessage), "STT timeout")
    }

    @objc func testOverlayErrorText_NonNetworkErrorsAreNotMapped() {
        // HTTP/JSON-ошибки оверлей НЕ трогает — текст берётся из обычного message(for:).
        XCTAssertNil(OverlayErrorText.text(for: TranscribeError.http(500, "boom")))
        XCTAssertNil(OverlayErrorText.text(for: TranscribeError.invalidResponse("no text")))
        XCTAssertNil(OverlayErrorText.networkText("some arbitrary network error"))
        XCTAssertNil(OverlayErrorText.text(for: NSError(domain: "x", code: 1)))
    }

    // MARK: - Гарантия завершения фазы «обработка»

    @objc func testProcessingMaxDuration_BoundsProcessingPhase() {
        // Анимация точек не может жить дольше жёсткого таймаута запроса + запас.
        XCTAssertEqual(
            OverlayController.processingMaxDuration,
            Transcriber.networkRequestTimeout + 5,
            accuracy: 0.001
        )
        XCTAssertGreaterThanOrEqual(
            OverlayController.processingMaxDuration,
            Transcriber.networkRequestTimeout + 1,
            "запас поверх таймаута должен быть хотя бы 1 с"
        )
    }
}