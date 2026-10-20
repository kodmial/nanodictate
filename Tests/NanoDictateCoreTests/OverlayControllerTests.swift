import Foundation
import AppKit
import NanoDictateRustBridge
@testable import NanoDictateCore

/// Tests of functionality that DISPLAYS something: overlay (mic panel).
///
/// Their task — never let overlay "disappear" again: user reported the
/// recording indicator was not visible anywhere. Here show() must build
/// panel with correct frame and phases.
///
/// IMPORTANT: in test runner (NANODICTATE_TESTS=1) panel NOT shown on
/// screen — OverlayController skips orderFront/NSApp activation so runs
/// don't flash overlay at user. Tests check state/frame via
/// testPanel/testPanelFrame/testState and separately prove panel did NOT
/// appear on screen (isVisible == false).
final class OverlayControllerTests: XCTestCase {

    override func setUp() {
        // XCTest runner — plain CLI process without NSApp; without AppKit-init
        // NSPanel won't create, so the "overlay shown" test fails with a clear
        // error instead of silently returning "false".
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Позиционирование (чистая логика)

    @objc func testPanelFrameIsAboveCaret_WhenSpaceAvailable() {
        // AppKit y растёт вверх: «над точкой» = больший y. Панель должна
        // встать ВЫШЕ точки (нижний край на 12pt выше неё), если влезает
        // под верхний отступ экрана.
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let caret = CGPoint(x: 700, y: 500)
        let frame = OverlayLayout.panelFrame(near: caret, inside: screen, panelSize: CGSize(width: 260, height: 120))

        // Panel above caret: bottom edge 12pt above caret, top edge within
        // screen's top margin.
        XCTAssertEqual(frame.minY, 500 + 12, accuracy: 0.001)
        XCTAssertFalse(frame.contains(caret))
        XCTAssertGreaterThanOrEqual(frame.minY, caret.y)
        // Horizontally centered on caret.
        XCTAssertEqual(frame.midX, caret.x, accuracy: 0.001)
        // Does not leave screen.
        XCTAssertGreaterThanOrEqual(frame.minX, screen.minX)
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY)
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY)
    }

    @objc func testPanelFrameMovesBelowCaret_WhenNoRoomAbove() {
        // Caret near the screen TOP — nothing fits above (top margin would
        // be crossed). Panel must go BELOW the caret with a 12pt gap.
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        let caret = CGPoint(x: 700, y: 880) // above needs y >= 900-8-120-12
        let frame = OverlayLayout.panelFrame(near: caret, inside: screen, panelSize: CGSize(width: 260, height: 120))

        XCTAssertEqual(frame.maxY, 880 - 12, accuracy: 0.001)
        XCTAssertFalse(frame.contains(caret))
        XCTAssertLessThanOrEqual(frame.maxY, caret.y)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY + 8)
        XCTAssertLessThanOrEqual(frame.maxY, screen.maxY)
    }

    @objc func testPanelFrameClampsToBottomMargin_WhenBelowCrossesEdge() {
        // Short screen AND caret low enough that "below" placement would
        // sink under the bottom margin — the frame is clamped to it.
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 200)
        let caret = CGPoint(x: 700, y: 100) // above: 112+120 > 192; below raw: -32
        let frame = OverlayLayout.panelFrame(near: caret, inside: screen, panelSize: CGSize(width: 260, height: 120))

        XCTAssertEqual(frame.minY, screen.minY + 8, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(frame.minY, screen.minY + 8)
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX)
    }

    @objc func testPanelFrameClampedToScreenEdges_Horizontal() {
        // Caret at far left edge — panel must not overflow left.
        let screen = CGRect(x: 100, y: 0, width: 800, height: 600)
        let caret = CGPoint(x: 102, y: 300)
        let frame = OverlayLayout.panelFrame(near: caret, inside: screen, panelSize: CGSize(width: 260, height: 120))

        XCTAssertGreaterThanOrEqual(frame.minX, 108, accuracy: 0.001) // screen.minX + 8
        XCTAssertLessThanOrEqual(frame.maxX, screen.maxX)
    }

    @objc func testScreenContaining_FallsBackToMainScreen() {
        // Points outside real screens: canvas must fall back to non-empty
        // frame (NSScreen.main) — panel never left without screen,
        // so never "lost" due to coordinates.
        let caret = CGPoint(x: -5000, y: -5000)
        let screen = OverlayLayout.screenContaining(caret)
        XCTAssertTrue(screen.width > 0)
        XCTAssertTrue(screen.height > 0)
    }

    // MARK: - resolvePoint (чистая цепочка фоллбэков позиционирования)

    @objc func testResolvePoint_UsesCaret_WhenValid() {
        // Valid caret → exactly its point taken.
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
        // Caret nil or off-screen → mouse position.
        let mouse = CGPoint(x: 300, y: 400)
        let center = CGPoint(x: 720, y: 450)
        let isValid = { (point: CGPoint) -> Bool in
            point.x > 0 && point.x < 2000 && point.y > 0 && point.y < 2000
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
        // Mouse off-screen (and caret missing) → main screen center.
        let mouse = CGPoint(x: -9999, y: -9999)
        let center = CGPoint(x: 720, y: 450)
        let isValid = { (point: CGPoint) -> Bool in
            if point == mouse { return false }
            return point.x > 0 && point.y > 0
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

        // Test runner: panel not shown on screen (see class doc), but must
        // be created and framed — that's what we check.
        XCTAssertNotNil(controller.testPanel, "Панель должна создаваться при show()")
        XCTAssertNotNil(controller.testPanelFrame)

        // Frame really near the show point: panel stands ABOVE it (AppKit y up).
        if let frame = controller.testPanelFrame {
            XCTAssertEqual(frame.midX, 700, accuracy: 2)
            XCTAssertGreaterThanOrEqual(frame.minY, 500)
        }

        // Panel NOT on screen: test runs don't flash overlay at user.
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

        // Level beyond [0,1] clamps; panel stays in scene.
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
        // Requirement: "0:00"/"0:07" — minutes no padding, seconds leading zero.
        XCTAssertEqual(OverlayTimeFormat.format(0), "0:00")
        XCTAssertEqual(OverlayTimeFormat.format(7), "0:07")
        XCTAssertEqual(OverlayTimeFormat.format(65), "1:05")
        XCTAssertEqual(OverlayTimeFormat.format(599), "9:59")
        // Fractional seconds floor-down, as the timer ticks.
        XCTAssertEqual(OverlayTimeFormat.format(7.4), "0:07")
        XCTAssertEqual(OverlayTimeFormat.format(7.9), "0:07")
    }

    @objc func testTimeFormat_ClampsNegative() {
        XCTAssertEqual(OverlayTimeFormat.format(-3), "0:00")
    }

    @objc func testSetRecordingPhase_StoresStartAndSetsRecording() {
        let controller = OverlayController()
        // Start-time comes from outside (view counts seconds from it —
        // not from its own "when it happened").
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
        // Heights depend on phase: idle ~150 (compact slab), recording
        // ~178 (timer "0:07" under icon); panel reframes on phase change,
        // staying anchored to show point.
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
        // Width no longer fixed 280: computed from content fittingSize and
        // clamped to [180, 240] — compact slab, not fixed for "header".
        let controller = OverlayController()
        controller.show(at: CGPoint(x: 700, y: 500))
        let width = controller.testPanelFrame?.width ?? 0
        XCTAssertGreaterThanOrEqual(width, 180, "автоширина не уже мин-клампа 180")
        XCTAssertLessThanOrEqual(width, 240, "автоширина не шире макс-клампа 240")

        // Phase change alters only height — width stays same.
        controller.setRecordingPhase()
        XCTAssertEqual(controller.testPanelFrame?.width ?? 0, width,
                       accuracy: 0.001, "recording не меняет ширину")
        controller.setProcessingPhase()
        XCTAssertEqual(controller.testPanelFrame?.width ?? 0, width,
                       accuracy: 0.001, "processing не меняет ширину")
        controller.hide()
    }

    @objc func testClampedPanelWidth_BoundsAutofit() {
        // Pure autowidth clamp: min 180 / max 240.
        XCTAssertEqual(OverlayLayout.clampedPanelWidth(from: -50), 180)
        XCTAssertEqual(OverlayLayout.clampedPanelWidth(from: 0), 180)
        XCTAssertEqual(OverlayLayout.clampedPanelWidth(from: 100), 180)
        XCTAssertEqual(OverlayLayout.clampedPanelWidth(from: 200), 200)
        XCTAssertEqual(OverlayLayout.clampedPanelWidth(from: 240), 240)
        XCTAssertEqual(OverlayLayout.clampedPanelWidth(from: 500), 240)
    }

    // MARK: - Маппинг сетевых ошибок на текст оверлея (OverlayErrorText)

    @objc func testOverlayErrorText_NoInternet() {
        // No internet → short "No internet" (not featureless error text).
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
        // HTTP/JSON errors overlay does NOT touch — text from message(for:) as usual.
        XCTAssertNil(OverlayErrorText.text(for: TranscribeError.http(500, "boom")))
        XCTAssertNil(OverlayErrorText.text(for: TranscribeError.invalidResponse("no text")))
        XCTAssertNil(OverlayErrorText.networkText("some arbitrary network error"))
        XCTAssertNil(OverlayErrorText.text(for: NSError(domain: "x", code: 1)))
    }

    // MARK: - Гарантия завершения фазы «обработка»

    @objc func testProcessingMaxDuration_BoundsProcessingPhase() {
        // Dot animation cannot outlive hard request timeout + margin.
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


    // MARK: - Versioned HUD contract fixture (presentation scenarios)
    //
    // Each scenario's fixture event timeline is replayed against the real
    // controller at its recorded `at_ms`, then every golden checkpoint is
    // checked. The fixture supplies the expected observable state; it is not
    // a second presentation state machine.

    @objc func testHUDContract_PresentationScenariosReplayGoldenTrace() {
        let fixture = HUDContractFixtureLoader.load()
        XCTAssertFalse(fixture.presentationScenarios.isEmpty)
        for scenario in fixture.presentationScenarios {
            HUDScenarioReplay(scenario: scenario).run()
        }
    }

    @objc func testHUDContract_CancelDuringProcessingLeavesRustOwnerTranscribing() {
        let fixture = HUDContractFixtureLoader.load()
        guard
          let scenario = fixture.requiredScenario(
            named: "cancel_during_processing_owner_settles_rust")
        else { return }
        guard let rustSession = try? RustSession() else {
            XCTFail("Rust session must be available on the shipping link")
            return
        }
        guard let generation = try? rustSession.start() else {
            XCTFail("Rust session start must succeed")
            return
        }
        try? rustSession.onEvent(.firstBuffer, generation: generation)
        try? rustSession.onEvent(.stopRequested, generation: generation)
        XCTAssertEqual(rustSession.state, 2, "Rust is Transcribing while the dots show")

        // Escape cancels only the HUD; the Rust owner stays Transcribing.
        try? rustSession.onEvent(.cancelled, generation: generation)
        XCTAssertEqual(
            rustSession.state, 2,
            "Cancelled is Recording-only; Transcribing waits for its owner")

        guard let hidden = scenario.checkpoints.first(where: { $0.atMs == 2000 }),
              let settled = scenario.checkpoints.first(where: { $0.atMs == 2200 })
        else {
            XCTFail("cancel-during-processing fixture is missing its hide/settle checkpoints")
            return
        }
        XCTAssertFalse(hidden.visible, "the HUD hides before the Rust owner settles")
        XCTAssertEqual(hidden.rustState, "transcribing")
        XCTAssertEqual(settled.rustState, "idle")

        try? rustSession.onEvent(.transcriptionDone, generation: generation)
        XCTAssertEqual(rustSession.state, 0, "owner completion settles Rust to Idle")
    }

    /// Reduce Motion is a native presentation decision: the VU envelope and
    /// all pulses are bypassed, while the 50 ms ring tick and status changes
    /// still update. Rendering itself is not reachable headlessly, so the
    /// view branches are pinned structurally like the existing ProcessingDots
    /// test; the fixture carries the expected passthrough traces.
    @objc func testHUDContract_ReduceMotionBypassesEnvelopeAndPulses() {
        let fixture = HUDContractFixtureLoader.load()
        XCTAssertTrue(
            fixture.vuTraces.contains { $0.reduceMotion },
            "fixture must carry reduce-motion VU passthrough vectors")
        guard let source = Self.overlayControllerSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateCore/OverlayController.swift")
            return
        }
        XCTAssertTrue(
            source.contains("guard !reduceMotion else"),
            "the meter loop must bypass the envelope when Reduce Motion is on")
        XCTAssertTrue(
            source.contains("peak = fresh"),
            "Reduce Motion keeps peak on the current target instead of holding")
        guard let recStart = source.range(of: "private struct RECDot: View") else {
            XCTFail("RECDot not found")
            return
        }
        let recTail = source[recStart.upperBound...]
        let recEnd = recTail.range(of: "\n/// Анимация") ?? (recTail.startIndex..<recTail.endIndex)
        let recView = String(recTail[..<recEnd.lowerBound])
        XCTAssertTrue(
            recView.contains("reduceMotion ? nil : Animation.easeInOut"),
            "REC dot must be static when Reduce Motion is enabled")
    }

    // MARK: - onChange(of: state.recordingStart): таймер жив только в фазе .recording (CR12 №4)

    /// Структурный тест (как OverlayLifecycleTests): поведенчески ветки
    /// onChange(of: state.recordingStart) из раннера недостижимы — колбэк
    /// отрабатывает только в display-цикле реально показанного окна, а панель
    /// в тестах на экран не выводится (док. класса выше). Поэтому контракт
    /// фикса (часы заводятся ТОЛЬКО при newStart != nil И phase == .recording;
    /// сброс/не-запись — stopClock) охраняется структурно: блок обработчика
    /// обязан содержать gating-условие, оба пути и вызов ensureMeterLoopRunning.
    @objc func testRecordingStartChange_ClockGatedOnPhase() {
        guard let source = Self.overlayControllerSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateCore/OverlayController.swift")
            return
        }
        guard let blockStart = source.range(of: ".onChange(of: state.recordingStart)") else {
            XCTFail("onChange(of: state.recordingStart) не найден в OverlayController.swift")
            return
        }
        let tail = source[blockStart.lowerBound...]
        let end = tail.range(of: "\n  // MARK: ") ?? (tail.startIndex..<tail.endIndex)
        let block = String(tail[..<end.lowerBound])

        XCTAssertTrue(
            block.contains("if newStart != nil, state.phase == .recording"),
            "часы заводятся только при newStart != nil И фазе .recording"
        )
        XCTAssertTrue(block.contains("} else {"), "вне .recording предусмотрен путь stopClock()")
        XCTAssertTrue(block.contains("stopClock()"), "сброс времени — через stopClock()")

        // startClock() обязан стоять ПОСЛЕ gating-условия, а не вызываться безусловно.
        if let gateRange = block.range(of: "if newStart != nil, state.phase == .recording"),
           let startRange = block.range(of: "startClock()") {
            XCTAssertTrue(
                gateRange.lowerBound < startRange.lowerBound,
                "startClock() вызывается только внутри gating-ветки"
            )
        }

        XCTAssertTrue(
            block.contains("ensureMeterLoopRunning()"),
            "метр-луп обновляется в обоих путях обработчика"
        )
    }

    /// Reduce Motion (CodeRabbit #5317407957): ProcessingDots — единственная
    /// вью-ветка оверлея, которая крутила бесконечный scale/opacity-пульс без
    /// учёта accessibilityDisplayShouldReduceMotion. SwiftUI-рендер в юнит-
    /// раннере недостижим, поэтому контракт охраняется структурно — тем же
    /// приёмом, что onChange-тест выше: тело вью обязано содержать геттер
    /// NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, константные
    /// scale/opacity при нём и nil-анимацию вместо бесконечного пульса.
    @objc func testProcessingDots_StaticWhenReduceMotionEnabled() {
        guard let source = Self.overlayControllerSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateCore/OverlayController.swift")
            return
        }
        guard let start = source.range(of: "private struct ProcessingDots: View") else {
            XCTFail("ProcessingDots не найдена в OverlayController.swift")
            return
        }
        let tail = source[start.upperBound...]
        let end = tail.range(of: "\n// MARK: ") ?? (tail.startIndex..<tail.endIndex)
        let view = String(tail[..<end.lowerBound])

        XCTAssertTrue(
            view.contains("NSWorkspace.shared.accessibilityDisplayShouldReduceMotion"),
            "ProcessingDots обязана читать настройку Reduce Motion, как RECDot и VU-метр"
        )
        XCTAssertTrue(
            view.contains(".scaleEffect(reduceMotion ?"),
            "scaleEffect при Reduce Motion — константа, а не пульс по animate"
        )
        XCTAssertTrue(
            view.contains(".opacity(reduceMotion ?"),
            "opacity при Reduce Motion — константа, а не пульс по animate"
        )
        XCTAssertTrue(
            view.contains("reduceMotion\n              ? nil"),
            "animation при Reduce Motion — nil (без repeatForever)"
        )
    }


    // MARK: - HUD fixture helpers

    /// Загрузка исходника OverlayController для структурных проверок вью-веток,
    /// недостижимых из раннера (тот же приём, что agentMainSource() в
    /// OverlayLifecycleTests / LiveOrchestrationBranchTests).
    private static func overlayControllerSource() -> String? {
        let fileDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let candidates = [
            fileDir.deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/NanoDictateCore/OverlayController.swift"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/NanoDictateCore/OverlayController.swift"),
        ]
        guard let sourceURL = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            return nil
        }
        guard let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            return nil
        }
        return source
    }
}

/// Replays a fixture scenario's event timeline against the real
/// `OverlayController` and checks every golden checkpoint in order. The
/// fixture's `at_ms` values drive when events are applied, and its event
/// generations drive the cycle token; checkpoints are never looked up by a
/// free-standing constant supplied by the test.
private final class HUDScenarioReplay {
    private let scenario: HUDContractFixture.PresentationScenario
    private let presentation: HUDScenarioPresentation
    private var eventIndex = 0
    private var generation: UInt64
    private var started = false
    private var elapsedMs: Double = 0

    init(
        scenario: HUDContractFixture.PresentationScenario,
        presentation: HUDScenarioPresentation = HUDScenarioPresentation()
    ) {
        self.scenario = scenario
        self.presentation = presentation
        self.generation = scenario.events.first?.generation ?? 0
    }

    func run(file: StaticString = #file, line: UInt = #line) {
        for (index, checkpoint) in scenario.checkpoints.enumerated() {
            XCTAssertTrue(
                scenario.events.contains { $0.atMs == checkpoint.atMs },
                "\(scenario.name)@\(checkpoint.atMs) must be anchored to a fixture event",
                file: file, line: line)
            applyEvents(upTo: checkpoint.atMs, beforeFirstCheckpoint: index == 0)
            XCTAssertGreaterThanOrEqual(
                checkpoint.atMs, elapsedMs,
                "\(scenario.name) checkpoints must advance on the timeline",
                file: file, line: line)
            elapsedMs = checkpoint.atMs
            assertCheckpoint(checkpoint, file: file, line: line)
        }
        XCTAssertEqual(
            eventIndex, scenario.events.count,
            "\(scenario.name) must replay every fixture event",
            file: file, line: line)
        XCTAssertEqual(
            generation, scenario.sessionGeneration,
            "\(scenario.name) must end in the fixture's session generation",
            file: file, line: line)
    }

    private func applyEvents(upTo atMs: Double, beforeFirstCheckpoint: Bool) {
        while eventIndex < scenario.events.count {
            let event = scenario.events[eventIndex]
            guard event.atMs <= atMs else { break }
            // The first checkpoint observes the pre-boot state; the
            // same-timestamp double_alt starts the session afterwards.
            if beforeFirstCheckpoint && event.atMs == atMs { break }
            apply(event)
            eventIndex += 1
        }
    }

    private func apply(_ event: HUDContractFixture.PresentationScenario.Event) {
        switch event.event {
        case "double_alt":
            if !started {
                started = true
                generation = event.generation
            } else if event.generation > generation {
                generation = event.generation
                // A new cycle starts hidden; the first buffer or the
                // starting-grace deadline makes it visible.
            } else if presentation.phase == .recording {
                presentation.setProcessing()
                presentation.setStatus(L10n.tr("overlay.recognizing"))
            } else {
                XCTFail(
                    "\(scenario.name)@\(event.atMs) double_alt has no matching HUD transition")
            }
        case "first_buffer":
            if !presentation.presented {
                presentation.show()
            }
            presentation.setRecording(
                startedAt: Date(timeIntervalSince1970: event.atMs / 1000))
            presentation.setStatus(L10n.tr("overlay.recording"))
        case "starting_visible":
            if !presentation.presented {
                presentation.show()
            }
            presentation.setStarting()
            presentation.setStatus(L10n.tr("overlay.starting"))
        case "escape":
            presentation.reset()
            presentation.setStatus(L10n.tr("overlay.cancelled"))
        case "insert_done":
            presentation.reset()
            presentation.setStatus(L10n.tr("overlay.finishing"))
        case "audio_error":
            presentation.setStatus(L10n.tr("error.micEnableFailed"))
        case "stt_error":
            presentation.reset()
            presentation.setStatus(statusText("overlay.error", argument: "error.noInternet"))
        case "stt_timeout":
            presentation.reset()
            presentation.setStatus(statusText("overlay.error", argument: "error.sttTimeout"))
        case "empty_result":
            presentation.reset()
            presentation.setStatus(L10n.tr("overlay.emptyResult"))
        case "hide_deadline":
            XCTAssertEqual(
                event.generation, generation,
                "\(scenario.name)@\(event.atMs) hide must belong to the current generation")
            presentation.hide()
        case "stale_hide_deadline":
            XCTAssertLessThan(
                event.generation, generation,
                "\(scenario.name)@\(event.atMs) stale hide must belong to an older generation")
        case "grace_pending", "starting_deadline", "owner_done", "checkpoint":
            break
        default:
            XCTFail("\(scenario.name)@\(event.atMs) has unknown event \(event.event)")
        }
    }

    private func assertCheckpoint(
        _ checkpoint: HUDContractFixture.PresentationScenario.Checkpoint,
        file: StaticString,
        line: UInt
    ) {
        let label = "\(scenario.name)@\(checkpoint.atMs)"
        XCTAssertEqual(
            presentation.presented, checkpoint.visible,
            "\(label) visible", file: file, line: line)
        XCTAssertEqual(
            hudPhaseName(presentation.phase), checkpoint.phase,
            "\(label) phase", file: file, line: line)
        XCTAssertEqual(
            presentation.recordingStarted, checkpoint.recordingStarted,
            "\(label) recording timer", file: file, line: line)
        XCTAssertEqual(
            generation, checkpoint.generation,
            "\(label) generation", file: file, line: line)
        if let expectedStatus = hudStatusText(for: checkpoint) {
            XCTAssertEqual(
                presentation.status, expectedStatus,
                "\(label) status", file: file, line: line)
        }
    }

    private func statusText(_ key: String, argument: String) -> String {
        L10n.tr(key).replacingOccurrences(of: "{message}", with: L10n.tr(argument))
    }
}