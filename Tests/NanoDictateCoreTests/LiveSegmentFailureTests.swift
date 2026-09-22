import Foundation
@testable import NanoDictateCore

// MARK: - Полный сбой STT в live-ветке не маскируется под «Пустой результат»
// Замечание ревью #112: offline all live segments fail → segmentCount == 0 branch
// builds EMPTY Outcome → handleEmptyResult («Пустой результат»), user spoke;
// offline paths would give explicit failTranscription. Logic is private in
// NanoDictateAgent executable (test target depends on NanoDictateCore only), so it
// is tested structurally from main.swift (same trick as
// OverlayLifecycleTests.testEachTerminalPoint_SchedulesExactlyOneHide).

final class LiveSegmentFailureTests: XCTestCase {

    // MARK: - finishLiveRun: ветка segmentCount == 0

    /// All segments failed → explicit failTranscription with error text, not empty Outcome.
    @objc func testAllSegmentsFailed_CallsFailTranscription() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
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

    /// No failure → empty Outcome preserved; silence must not become an error.
    @objc func testNoFailure_EmptyOutcomePreserved() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
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

    /// Segment catch stores error text in runState.lastErrorText for the final report.
    @objc func testSegmentCatch_StoresLastErrorText() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        let body = Self.functionBody(named: "handleLiveSegment", in: source)
        XCTAssertFalse(body.isEmpty, "handleLiveSegment должна существовать")
        XCTAssertTrue(body.contains("anySegmentFailed = true"), "сбой сегмента по-прежнему ставит anySegmentFailed")
        XCTAssertTrue(body.contains("lastErrorText = message"), "текст последней ошибки обязан запоминаться в runState")
    }

    /// lastErrorText carries the error into failTranscription on total failure.
    @objc func testLiveRunState_HasLastErrorTextField() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
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

    /// segmentCount == 0 branch of finishLiveRun (both halves); empty if not found.
    private static func segmentZeroBranch(in source: String) -> String {
        let body = functionBody(named: "finishLiveRun", in: source)
        return substring(
            from: "if runState.segmentCount == 0",
            to: "if runState.segmentCount == 1",
            in: body
        )
    }

    /// Load agent source for structural checks.
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

    /// Function body from "func NAME(" to next function/MARK; empty if missing.
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

    /// Substring after "from" up to next "to" (exclusive); empty if missing.
    private static func substring(from: String, to: String, in text: String) -> String {
        guard let start = text.range(of: from)?.upperBound,
              let end = text[start...].range(of: to)?.lowerBound else { return "" }
        return String(text[start..<end])
    }
}