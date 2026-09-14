import Foundation
@testable import DictationCore

// MARK: - Полный сбой STT в live-ветке не маскируется под «Пустой результат»
//
// Замечание ревью #112: при отключённой сети/провайдере все live-сегменты
// падают (segmentCount == 0, anySegmentFailed == true), и ветка segmentCount
// == 0 строит ПУСТОЙ Outcome → handleEmptyResult («Пустой результат», звук
// Funk) — хотя пользователь реально говорил. Оффлайн-пути дали бы явный
// failTranscription с текстом ошибки.
//
// Логика приватная и живёт в executable-таргете DictatorAgent (тест-таргет
// зависит только от DictationCore), поэтому тестируется структурно — по
// исходнику Sources/DictatorAgent/main.swift (тот же приём, что в
// OverlayLifecycleTests.testEachTerminalPoint_SchedulesExactlyOneHide).

final class LiveSegmentFailureTests: XCTestCase {

    // MARK: - finishLiveRun: ветка segmentCount == 0

    /// Полный сбой всех сегментов (segmentCount == 0 && anySegmentFailed) —
    /// явный failTranscription с текстом ошибки, а не пустой Outcome.
    @objc func testAllSegmentsFailed_CallsFailTranscription() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/DictatorAgent/main.swift")
            return
        }
        let zeroBranch = Self.segmentZeroBranch(in: source)
        XCTAssertFalse(zeroBranch.isEmpty, "ветка segmentCount == 0 в finishLiveRun должна существовать")
        XCTAssertTrue(
            zeroBranch.contains("runState.anySegmentFailed"),
            "сбой сегментов обязан разветвляться внутри ветки segmentCount == 0"
        )
        XCTAssertTrue(
            zeroBranch.contains("self.failTranscription("),
            "полный сбой STT обязан давать явный failTranscription, а не пустой Outcome"
        )
        XCTAssertTrue(
            zeroBranch.contains("isNetworkFailure: true"),
            "полный сбой трактуется как сетевая ошибка (Basso, как в offline-путях)"
        )
        XCTAssertTrue(
            zeroBranch.contains("runState.lastErrorText"),
            "в failTranscription передаётся текст запомненной ошибки (lastErrorText)"
        )
    }

    /// Та же ветка без сбоя: прежнее поведение сохранено — пустой Outcome →
    /// completeChunkedInsertion → handleEmptyResult («Пустой результат»).
    /// «Сбой без речи» и «тишина» не должны превращаться в ошибку.
    @objc func testNoFailure_EmptyOutcomePreserved() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/DictatorAgent/main.swift")
            return
        }
        let zeroBranch = Self.segmentZeroBranch(in: source)
        XCTAssertTrue(
            zeroBranch.contains("completeChunkedInsertion(outcome: outcome)"),
            "пустая запись без сбоя обязана остаться на прежнем пути пустого результата"
        )
        XCTAssertTrue(
            zeroBranch.contains("insertedText: \"\""),
            "пустой Outcome (insertedText: \"\") строится для тишины без сбоя"
        )
        XCTAssertTrue(
            zeroBranch.contains("ChunkedPipeline.Outcome("),
            "пустой Outcome строится только во второй (без-сбойной) половине ветки"
        )
    }

    // MARK: - handleLiveSegment: catch запоминает текст ошибки

    /// catch сбоя сегмента записывает текст ошибки в runState.lastErrorText
    /// (рядом с anySegmentFailed), чтобы финал мог показать её пользователю.
    @objc func testSegmentCatch_StoresLastErrorText() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/DictatorAgent/main.swift")
            return
        }
        let body = Self.functionBody(named: "handleLiveSegment", in: source)
        XCTAssertFalse(body.isEmpty, "handleLiveSegment должна существовать")
        XCTAssertTrue(body.contains("anySegmentFailed = true"), "сбой сегмента по-прежнему ставит anySegmentFailed")
        XCTAssertTrue(body.contains("lastErrorText = message"), "текст последней ошибки обязан запоминаться в runState")
    }

    /// LiveRunState несёт поле lastErrorText (String?) для передачи в
    /// failTranscription при полном сбое.
    @objc func testLiveRunState_HasLastErrorTextField() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/DictatorAgent/main.swift")
            return
        }
        let classBody = Self.substring(
            from: "private final class LiveRunState",
            to: "private final class SerialAsyncExecutor",
            in: source
        )
        XCTAssertFalse(classBody.isEmpty, "LiveRunState должна объявляться в main.swift")
        XCTAssertTrue(
            classBody.contains("var lastErrorText: String?"),
            "LiveRunState должна нести поле lastErrorText"
        )
    }

    // MARK: - Helpers (зеркало OverlayLifecycleTests)

    /// Ветка segmentCount == 0 из finishLiveRun (вся, обе половины: сбойная и
    /// без-сбойная). Пустая строка — если ветка/функция не найдены.
    private static func segmentZeroBranch(in source: String) -> String {
        let body = functionBody(named: "finishLiveRun", in: source)
        return substring(
            from: "if runState.segmentCount == 0",
            to: "if runState.segmentCount == 1",
            in: body
        )
    }

    /// Загружает исходник агента (для структурных проверок).
    private static func agentMainSource() -> String? {
        let fileDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let candidates = [
            fileDir
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/DictatorAgent/main.swift"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/DictatorAgent/main.swift"),
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

    /// Подстрока между первым вхождением from и первым вхождением to ПОСЛЕ
    /// него (границы не включаются). Пустая строка — если маркеры не найдены.
    private static func substring(from: String, to: String, in text: String) -> String {
        guard let start = text.range(of: from)?.upperBound,
              let end = text[start...].range(of: to)?.lowerBound else { return "" }
        return String(text[start..<end])
    }
}