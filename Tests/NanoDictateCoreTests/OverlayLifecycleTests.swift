import Foundation
@testable import NanoDictateCore

/// Тесты жизненного цикла оверлея (замечание №2 ревью):
/// hide разрешён только вне активного цикла (idle), запрещён во время
/// recording/transcribing; каждая терминальная точка планирует ровно один hide.
///
/// Планирование (`scheduleHide`) тестируется через мок-счётчик: инъецируются
/// stateProvider (что вернёт состояние к моменту срабатывания) и hide
/// (считает вызовы) — без реального оверлея и Agent-таргета.
final class OverlayLifecycleTests: XCTestCase {

    // MARK: - shouldHide (чистое решение)

    @objc func testShouldHide_Idle() {
        XCTAssertTrue(OverlayLifecycle.shouldHide(currentState: .idle))
    }

    @objc func testShouldHide_Recording() {
        XCTAssertFalse(OverlayLifecycle.shouldHide(currentState: .recording))
    }

    @objc func testShouldHide_Transcribing() {
        XCTAssertFalse(OverlayLifecycle.shouldHide(currentState: .transcribing))
    }

    // MARK: - scheduleHide (одно планирование → один hide)

    /// Один вызов scheduleHide при idle-состоянии даёт РОВНО один hide:
    /// сразу после срабатывания — один, и повторных срабатываний нет.
    @objc func testScheduleHide_FiresExactlyOnce() {
        var hideCount = 0
        let fired = expectation(description: "hide должен сработать один раз")
        OverlayLifecycle.scheduleHide(after: 0.05, stateProvider: { .idle }) {
            hideCount += 1
            fired.fulfill()
        }
        wait(for: [fired], timeout: 1.0)
        XCTAssertEqual(hideCount, 1, "Одна терминальная точка → один hide")

        // Ещё время — повторного hide быть не должно.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(hideCount, 1, "Повторный hide после первого срабатывания запрещён")
    }

    /// Если к моменту срабатывания цикл уже начат заново (.recording) —
    /// оверлей НЕ прячется: новый цикл держит панель видимой.
    @objc func testScheduleHide_Skipped_WhenCycleRestarted() {
        var hideCount = 0
        var currentState: NanoDictateState = .idle
        OverlayLifecycle.scheduleHide(after: 0.05, stateProvider: { currentState }) {
            hideCount += 1
        }
        // Пользователь начал новую запись раньше (0.01s), чем пришёл таймер
        // hide (0.05s) — к моменту срабатывания состояние уже .recording.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
            currentState = .recording
        }

        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(hideCount, 0, "Новый цикл записи не должен дать скрыть оверлей")
    }

    // MARK: - scheduleHide: привязка к циклу (isCurrentCycle)

    /// isCurrentCycle=false (таймер чужого, уже завершённого цикла):
    /// hide отбрасывается — панель остаётся видимой для нового цикла.
    @objc func testScheduleHide_Skipped_WhenCycleNotCurrent() {
        var hideCount = 0
        OverlayLifecycle.scheduleHide(
            after: 0.05,
            stateProvider: { .idle },
            isCurrentCycle: { false }
        ) {
            hideCount += 1
        }
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(hideCount, 0, "hide не должен сработать, если цикл-планировщик уже не текущий")
    }

    /// isCurrentCycle=true: hide срабатывает как раньше (дефолт { true }).
    @objc func testScheduleHide_Fires_WhenCycleCurrent() {
        var hideCount = 0
        let fired = expectation(description: "hide должен сработать")
        OverlayLifecycle.scheduleHide(
            after: 0.05,
            stateProvider: { .idle },
            isCurrentCycle: { true }
        ) {
            hideCount += 1
            fired.fulfill()
        }
        wait(for: [fired], timeout: 1.0)
        XCTAssertEqual(hideCount, 1)
    }

    // MARK: - Терминальные точки (структура main.swift)

    /// Каждая прямая терминальная точка (mic denied, insert done, transcription
    /// failed, cancelled) вызывает hideAfter ровно один раз; лимит идёт через
    /// processSamples к тем же терминальным точкам (тоже один hide).
    @objc func testEachTerminalPoint_SchedulesExactlyOneHide() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }

        // Прямые терминальные точки: каждая планирует hide ровно один раз.
        // completeInsertion — 2 точки вызова: ветка отмены ревью (review cancelled)
        // и штатная (insert done); по-настоящему срабатывает ровно одна из них.
        let directTerminals: [String: Int] = [
            "showMicrophoneError": 1,   // mic denied
            "completeInsertion": 2,     // insert done / review cancelled
            "failTranscription": 1,     // transcription failed
            "handleCancel": 1,          // cancelled
        ]
        for (name, expected) in directTerminals {
            let body = Self.functionBody(named: name, in: source)
            let occurrences = body.components(separatedBy: "hideAfter(").count - 1
            XCTAssertEqual(occurrences, expected, "Терминальная точка \(name) должна планировать hide ровно \(expected) раз")
        }

        // Лимит: сам hide не планирует, а маршрутизируется в processSamples,
        // откуда финализация (insert done / transcription failed) даёт один hide.
        let limitBody = Self.functionBody(named: "handleRecordingLimitReached", in: source)
        XCTAssertEqual(
            limitBody.components(separatedBy: "hideAfter(").count - 1, 0,
            "handleRecordingLimitReached не должен планировать hide напрямую"
        )
        XCTAssertGreaterThanOrEqual(
            limitBody.components(separatedBy: "processSamples(").count - 1, 1,
            "Лимит обязан маршрутизироваться в processSamples (terminal-path hide)"
        )
    }

    /// Минор #1: подавленная (cooldown) ветка showMicrophoneError тоже обязана
    /// скрывать оверлей — панель, показанная неудавшимся startRecording, не
    /// должна зависать со статусом «Записываю…» до следующего Alt+Alt. Структурно:
    /// в теле showMicrophoneError нет ни одного раннего return — все пути
    /// (разрешённая И подавленная ветки) доходят до единственного hideAfter.
    /// Логика приватная и живёт в executable-таргете, поэтому тестируется
    /// структурно, как и остальные терминальные точки (см. выше).
    @objc func testMicError_SuppressedBranchStillSchedulesHide() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        let body = Self.functionBody(named: "showMicrophoneError", in: source)
        XCTAssertFalse(body.contains("return"), "Ни одна ветка showMicrophoneError не должна выходить раньше hideAfter")
        XCTAssertEqual(
            body.components(separatedBy: "hideAfter(").count - 1, 1,
            "showMicrophoneError планирует ровно один hide (в т.ч. в подавленной ветке)"
        )
    }


    // MARK: - Versioned HUD contract fixture (timing and generations)

    /// The fixture records the same grace window the shipping `OverlayLifecycle`
    /// uses. Below the threshold the deferred Starting phase must stay hidden;
    /// at and above it the panel shows the not-yet-capturing state.
    @objc func testHUDContract_StartingGraceBoundary() {
        let fixture = HUDContractFixtureLoader.load()
        let grace = fixture.constants.startingGraceSeconds
        XCTAssertEqual(
            grace, OverlayLifecycle.StartingUIDefer.graceInterval, accuracy: 0.0001)
        XCTAssertFalse(
            OverlayLifecycle.StartingUIDefer.shouldShowStarting(
                elapsed: grace - 0.001, threshold: grace))
        XCTAssertTrue(
            OverlayLifecycle.StartingUIDefer.shouldShowStarting(
                elapsed: grace, threshold: grace))
        XCTAssertTrue(
            OverlayLifecycle.StartingUIDefer.shouldShowStarting(
                elapsed: grace + 0.5, threshold: grace))

        let quick = fixture.requiredScenario(named: "quick_start_skips_starting_phase")
        XCTAssertNotNil(quick)
        XCTAssertFalse(
            quick?.checkpoints.contains { $0.phase == "starting" } ?? true,
            "a first buffer inside the grace window must never expose Starting")
        let slow = fixture.requiredScenario(named: "slow_start_then_record_and_cancel")
        XCTAssertTrue(
            slow?.checkpoints.contains { $0.phase == "starting" } ?? false,
            "a slow start must expose Starting without a recording timer")
    }

    /// A hide timer belongs to the cycle that scheduled it. Restarting before
    /// its deadline (the fixture's stale_hide_after_rapid_restart scenario)
    /// must leave the new cycle's panel visible.
    @objc func testHUDContract_StaleHideAfterRestartIsDropped() {
        let fixture = HUDContractFixtureLoader.load()
        guard let scenario = fixture.requiredScenario(named: "stale_hide_after_rapid_restart")
        else { return }
        XCTAssertEqual(scenario.sessionGeneration, 2)

        var hideCount = 0
        var currentGeneration: UInt64 = 1
        let scheduledGeneration: UInt64 = 1
        OverlayLifecycle.scheduleHide(
            after: 0.05,
            stateProvider: { .recording },
            isCurrentCycle: { currentGeneration == scheduledGeneration }
        ) {
            hideCount += 1
        }
        // Generation 2 starts before the old deadline.
        currentGeneration = 2
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(hideCount, 0, "a stale cycle's hide must not dismiss the new panel")

        // The new cycle's own terminal hide still fires.
        let fired = expectation(description: "new cycle hide")
        OverlayLifecycle.scheduleHide(
            after: 0.05,
            stateProvider: { .idle },
            isCurrentCycle: { currentGeneration == 2 }
        ) {
            hideCount += 1
            fired.fulfill()
        }
        wait(for: [fired], timeout: 1.0)
        XCTAssertEqual(hideCount, 1)

        // The fixture's checkpoints agree: the panel is still Recording at
        // the old deadline and only hides after generation 2's terminal point.
        guard let oldDeadline = scenario.checkpoints.first(where: { $0.atMs == 1700 }),
              let finalCheckpoint = scenario.checkpoints.last
        else {
            XCTFail("rapid-restart fixture is missing its stale/final checkpoints")
            return
        }
        XCTAssertEqual(oldDeadline.visible, true)
        XCTAssertEqual(oldDeadline.generation, 2)
        XCTAssertEqual(finalCheckpoint.visible, false)
    }

    /// The fixture must keep covering every required normal and exceptional
    /// path, so #212 can consume golden traces instead of inventing new
    /// reference behavior.
    @objc func testHUDContract_ScenarioCoverage() {
        let fixture = HUDContractFixtureLoader.load()
        let required = [
            "quick_start_recording_insert_hide",
            "slow_start_then_record_and_cancel",
            "quick_start_skips_starting_phase",
            "cancel_during_recording",
            "cancel_during_processing_owner_settles_rust",
            "audio_error_after_slow_start",
            "stt_error_no_internet",
            "stt_timeout",
            "empty_result",
            "stale_hide_after_rapid_restart",
        ]
        for name in required {
            XCTAssertNotNil(fixture.scenario(named: name), "missing HUD scenario \(name)")
        }
        XCTAssertTrue(
            fixture.vuTraces.contains { $0.reduceMotion },
            "reduce-motion VU behavior must be part of the golden fixture")
        XCTAssertEqual(
            fixture.timing.terminalHideSeconds.cancelled,
            fixture.timing.terminalHideSeconds.insert,
            accuracy: 0.0001)
        XCTAssertEqual(
            fixture.timing.terminalHideSeconds.error,
            fixture.timing.terminalHideSeconds.microphoneError,
            accuracy: 0.0001)
    }

    // MARK: - Helpers

    /// Загружает исходник агента (для структурных проверок терминальных точек).
    private static func agentMainSource() -> String? {
        let fileDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let candidates = [
            fileDir
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/NanoDictateAgent/main.swift"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/NanoDictateAgent/main.swift"),
        ]
        guard let sourceURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
              let source = try? String(contentsOf: sourceURL, encoding: .utf8) else {
            return nil
        }
        return source
    }

    /// Возвращает тело функции (от «func NAME(» до следующей функции/секции
    /// на том же уровне отступа). Если функция не найдена — пустая строка.
    private static func functionBody(named name: String, in source: String) -> String {
        guard let range = source.range(of: "func \(name)(") else { return "" }
        let tail = source[range.lowerBound...]
        if let end = tail.range(of: "\n  private func ") {
            return String(tail[..<end.lowerBound])
        }
        if let end = tail.range(of: "\n  // MARK: ") {
            return String(tail[..<end.lowerBound])
        }
        return String(tail)
    }
}