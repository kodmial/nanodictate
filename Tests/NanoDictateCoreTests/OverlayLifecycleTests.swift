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
        if let end = tail.range(of: "\n    private func ") {
            return String(tail[..<end.lowerBound])
        }
        if let end = tail.range(of: "\n    // MARK: ") {
            return String(tail[..<end.lowerBound])
        }
        return String(tail)
    }
}