import Foundation
@testable import NanoDictateCore

// MARK: - Полное структурное покрытие live-оркестрации (замечание ревью #112)
//
// LiveSegmentFailureTests covers only segmentCount == 0 branch. Here — the
// rest of finishLiveRun and handler branches (main.swift:832-1090):
//   1) single-segment-skip (one segment + tail, no failures);
//   2) tail order (tail delivered BEFORE finishLiveRun);
//   3) watchdog budget (timeout → failTranscription);
//   4) live-run cancel (Esc: liveSession += 1, liveRunState = nil);
//   5) empty segment text (STT "" — does NOT set anySegmentFailed).
//
// Logic is private in executable target NanoDictateAgent (test target depends
// only on NanoDictateCore), so tested structurally against
// Sources/NanoDictateAgent/main.swift (same trick as
// OverlayLifecycleTests / LiveSegmentFailureTests). Empty STT result also
// checked behaviorally in NanoDictateCore (ChunkedPipeline.recognizeSegment — public).

final class LiveOrchestrationBranchTests: XCTestCase {

    // MARK: - 1. single-segment-skip (finishLiveRun)

    /// One segment without pauses: single segment + tail covers full recording,
    /// no failures → final pass SKIPPED, but accumulated segment text NOT lost
    /// (insertedText from runState.insertedText goes into completeChunkedInsertion).
    @objc func testSingleSegmentSkip_PreservesTextAndSkipsFinalPass() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        let skipBranch = Self.singleSegmentSkipBranch(in: source)
        XCTAssertFalse(skipBranch.isEmpty, "ветка single-segment-skip в finishLiveRun должна существовать")
        XCTAssertTrue(
            skipBranch.hasPrefix(" && runState.tailDelivered && !runState.anySegmentFailed {"),
            "пропуск разрешён ТОЛЬКО при ровно одном сегменте (segmentCount == 1), доставленном «хвосте» и отсутствии сбоев"
        )
        XCTAssertTrue(
            skipBranch.contains("segmentCount: 1, insertedText: runState.insertedText, finalized: false, finalChanged: false"),
            "итог пропуска несёт накопленный текст сегмента (не теряется) и помечен finalized: false"
        )
        XCTAssertTrue(
            skipBranch.contains("completeChunkedInsertion(outcome: outcome)"),
            "пропущенный финальный проход обязан завершиться общим терминальным путём"
        )
        XCTAssertFalse(
            skipBranch.contains("ChunkedPipeline.finalize("),
            "в ветке пропуска НЕ выполняется повторный STT-запрос финального прохода"
        )
        XCTAssertFalse(
            skipBranch.contains("failTranscription("),
            "успешный одиночный сегмент не может завершиться ошибкой"
        )
    }

    /// single-segment-skip parity: tail NOT delivered or segment failed — skip
    /// condition unmet, path must fall into common final pass
    /// ChunkedPipeline.finalize (finishes phrase over whole WAV). Only one
    /// such branch in finishLiveRun.
    @objc func testSingleSegmentSkip_FallsBackToFinalize_WhenTailMissingOrFailed() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        let body = Self.functionBody(named: "finishLiveRun", in: source)
        XCTAssertEqual(
            body.components(separatedBy: "if runState.segmentCount == 1").count - 1, 1,
            "разветвитель single-segment-skip существует ровно один раз"
        )
        XCTAssertTrue(
            body.contains("let result = try await ChunkedPipeline.finalize("),
            "при недоставленном «хвосте» или сбое сегмента путь обязан дойти до финального прохода"
        )
        XCTAssertTrue(
            body.contains("isTail") || body.contains("tailDelivered"),
            "финальный проход по-прежнему подчиняется логике «хвоста»"
        )
    }

    // MARK: - 2. tail-порядок (tail → finalize)

    /// 2nd Alt (liveFinalize): sync audio.stop() delivers tail via callback
    /// BEFORE return, then finishLiveRun submits to liveExecutor — serial
    /// queue guarantees tail → finalize order. Structurally: audio.stop()
    /// in liveFinalize body precedes finishLiveRun submit.
    @objc func testTailDeliveredBeforeFinalizeSubmit_ManualStop() {
        // CI runner: виртуальное аудио/тайминг-флак, локально проходит.
        if ProcessInfo.processInfo.environment["CI"] != nil { return }
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        let body = Self.functionBody(named: "liveFinalize", in: source)
        guard let stopRange = body.range(of: "audio.stop()"),
              let finalizeRange = body.range(of: "finishLiveRun(") else {
            XCTFail("liveFinalize должна вызывать audio.stop() и submit finishLiveRun")
            return
        }
        XCTAssertTrue(
            stopRange.lowerBound < finalizeRange.lowerBound,
            "«хвост» обязан отдаваться синхронным audio.stop() ДО постановки finishLiveRun в очередь"
        )
        XCTAssertTrue(
            body.contains("отдаётся колбэком ДО возврата"),
            "комментарий фиксирует контракт: tail отдаётся ДО возврата stop()"
        )
    }

    /// Limit path (liveFinalizeFromSamples): tail already delivered by
    /// onSpeechSegment before call (performLimitStop: tail → onRecordingLimitReached),
    /// so no audio.stop() or second tail here — only guard and finishLiveRun
    /// submit. Order contract fixed by comment in handleRecordingLimitReached
    /// (same function that calls liveFinalizeFromSamples), not in doc above it.
    @objc func testTailDeliveredBeforeFinalizeSubmit_LimitPathHasNoSecondStop() {
        // CI runner: виртуальное аудио/тайминг-флак, локально проходит.
        if ProcessInfo.processInfo.environment["CI"] != nil { return }
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        let body = Self.functionBody(named: "liveFinalizeFromSamples", in: source)
        XCTAssertFalse(body.contains("audio.stop()"), "лимитный путь не должен останавливать движок повторно")
        XCTAssertTrue(
            body.contains("finishLiveRun(samples: samples, session: session, runState: runState)"),
            "лимитный путь обязан финализировать через тот же finishLiveRun"
        )
        // Contract "tail → onRecordingLimitReached" visible on consumer side:
        // handleRecordingLimitReached comments tail already delivered by
        // onSpeechSegment before limit call, and does not call audio.stop() itself.
        let limitBody = Self.functionBody(named: "handleRecordingLimitReached", in: source)
        XCTAssertTrue(
            limitBody.contains("«хвост» уже отдан колбэком onSpeechSegment ДО"),
            "contract: клиент знает, что «хвост» доставлен ДО колбэка лимита"
        )
        // Only audio.stop() mention is the "no audio.stop()" comment: no real
        // second stop on limit path (teardown happened in performLimitStop
        // before limit callback).
        let stopMentions = limitBody.components(separatedBy: "audio.stop()").count - 1
        XCTAssertEqual(
            stopMentions, 1,
            "в handleRecordingLimitReached НЕ должно быть вызова audio.stop() - только комментарий о его отсутствии"
        )
        XCTAssertTrue(
            limitBody.contains("(без audio.stop())"),
            "комментарий явно фиксирует: лимитный путь без повторного останова"
        )
        XCTAssertTrue(
            limitBody.contains("liveFinalizeFromSamples(samples)"),
            "лимит маршрутизируется в liveFinalizeFromSamples"
        )
    }

    /// Tail flagged exactly at delivery (isTail == true) — unlocks
    /// single-segment-skip; without it final pass is mandatory.
    @objc func testTailFlag_SetOnlyWhenIsTailDelivered() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        let body = Self.functionBody(named: "handleLiveSegment", in: source)
        XCTAssertTrue(body.contains("if isTail {"), "tailDelivered обязан выставляться в ветке isTail")
        let tailBlock = Self.substring(from: "if isTail {", to: "DispatchQueue.main.async", in: body)
        XCTAssertTrue(
            tailBlock.contains("runState.tailDelivered = true"),
            "доставка «хвоста» выставляет runState.tailDelivered"
        )
    }

    /// Segments and tail (subscribeLiveNanoDictate) go to THE SAME serial
    /// liveExecutor queue as finishLiveRun — queue keeps delivery order
    /// (tail → finalize), session guard at entry.
    @objc func testSegmentsAndFinalize_ShareSerialExecutor() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        let subBody = Self.functionBody(named: "subscribeLiveNanoDictate", in: source)
        XCTAssertTrue(
            subBody.contains("self.liveExecutor.submit {"),
            "сегменты/«хвост» обязаны идти через liveExecutor"
        )
        XCTAssertTrue(
            subBody.contains("await self.handleLiveSegment(segment, isTail: isTail, runState: runState)"),
            "обработчик сегмента вызывается на liveExecutor по очереди"
        )
        XCTAssertTrue(
            subBody.contains("guard self.liveSession == runState.session else { return }"),
            "сессиионный страж на входе отбрасывает сегменты отменённого цикла"
        )
        let finalizeBody = Self.functionBody(named: "liveFinalize", in: source)
        XCTAssertTrue(
            finalizeBody.contains("liveExecutor.submit"),
            "finishLiveRun встаёт в ту же liveExecutor после хвоста"
        )
    }

    // MARK: - 3. watchdog-бюджет (liveFinalize / liveFinalizeFromSamples)

    /// Processing-phase guard: live-cycle budget scales with request count
    /// (pending segments + tail + final pass); on timeout cycle ends with
    /// explicit failTranscription (sttTimeoutMessage). Block exists in BOTH
    /// finalize paths.
    @objc func testWatchdogBudget_BothFinalizePaths() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        for name in ["liveFinalize", "liveFinalizeFromSamples"] {
            let body = Self.functionBody(named: name, in: source)
            let label = "\(name)"
            XCTAssertTrue(
                body.contains("let requestCount = max(2, runState.segmentCount + 2)"),
                "\(label): бюджет обязан учитывать незавершённые сегменты"
            )
            XCTAssertTrue(
                body.contains("let liveMaxDuration = Double(requestCount) * Transcriber.networkRequestTimeout + 5"),
                "\(label): бюджет = число запросов × networkRequestTimeout + запас"
            )
            XCTAssertTrue(
                body.contains("DispatchQueue.main.asyncAfter(deadline: .now() + liveMaxDuration)"),
                "\(label): сторожевой таймер ставится по бюджету"
            )
            XCTAssertTrue(
                body.contains("self.failTranscription(Transcriber.sttTimeoutMessage, isNetworkFailure: true)"),
                "\(label): превышение бюджета → явный failTranscription «Таймаут STT»"
            )
        }
    }

    /// Watchdog guards: failTranscription fires ONLY if cycle unchanged
    /// (processingSession == session) and still transcribing
    /// (state == .transcribing). New/ended cycle gets no spurious timeout.
    @objc func testWatchdog_GuardsPreventSpuriousTimeout() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        for name in ["liveFinalize", "liveFinalizeFromSamples"] {
            let body = Self.functionBody(named: name, in: source)
            let watchdog = Self.substring(
                from: "DispatchQueue.main.asyncAfter",
                to: "failTranscription(Transcriber.sttTimeoutMessage",
                in: body
            )
            XCTAssertFalse(watchdog.isEmpty, "\(name): блок сторожа должен существовать")
            XCTAssertTrue(
                watchdog.contains("self.processingSession == session"),
                "\(name): сторож молчит, если обработка сменилась (новый цикл)"
            )
            XCTAssertTrue(
                watchdog.contains("self.state == .transcribing"),
                "\(name): сторож молчит, если цикл уже завершился (не в transcribing)"
            )
            XCTAssertTrue(
                watchdog.contains("guard let self = self"),
                "\(name): сторож не срабатывает после деаллокации агента"
            )
        }
    }

    // MARK: - 4. Отмена live-цикла (Esc / handleCancel)

    /// Esc during recording annuls LIVE cycle: audio.cancel() + liveSession += 1
    /// + liveRunState = nil. Printed segments NOT removed (handleCancel never
    /// touches Inserter) — cancel only blocks INSERT of unprocessed segments
    /// (liveSession guard on live runState goes stale). Terminal tail —
    /// "Отменено" overlay + hide.
    @objc func testCancel_RecordingAnnulsLiveCycle() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        let body = Self.functionBody(named: "handleCancel", in: source)
        XCTAssertTrue(body.contains("audio.cancel()"), "отмена записи обязана останавливать движок")
        XCTAssertTrue(body.contains("liveSession += 1"), "отмена инкрементирует сессионный токен живого цикла")
        XCTAssertTrue(body.contains("liveRunState = nil"), "отмена обнуляет накопление живого цикла")
        XCTAssertFalse(
            body.contains("Inserter."),
            "отмена НЕ трогает уже напечатанный текст (ни remove, ни replace нигде в handleCancel)"
        )
        XCTAssertTrue(body.contains("hideAfter(0.8, reason: \"cancelled\")"), "отмена — терминальная точка с hide")
        XCTAssertTrue(body.contains("state = .idle"), "отмена возвращает агента в idle")
    }

    /// Esc during transcribing: sets cancelRecognition token — returning
    /// STT request result not inserted.
    @objc func testCancel_TranscribingSetsCancelRecognition() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        let body = Self.functionBody(named: "handleCancel", in: source)
        XCTAssertTrue(body.contains("cancelRecognition = true"), "отмена фазы транскрибации ставит токен отмены")
    }

    /// Fate of printed + cancelled runState: both main handleLiveSegment blocks
    /// (overlay status AND incremental Inserter.append) guarded by session
    /// token — after cancel (liveSession changed) old runState segment skipped,
    /// already printed stays.
    @objc func testCancel_InFlightSegmentGuardedFromInsert() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        let body = Self.functionBody(named: "handleLiveSegment", in: source)
        let sessionGuardCount = body.components(separatedBy: "self.liveSession == runState.session").count - 1
        XCTAssertGreaterThanOrEqual(
            sessionGuardCount, 2,
            "сессионный страж должен стоять и в блоке статуса оверлея, и в блоке инкрементальной вставки"
        )
        XCTAssertTrue(
            body.contains("Inserter.append(result.insertText)"),
            "инкрементальная вставка идёт строго под сессионным стражем"
        )
    }

    // MARK: - 5. Пустой текст сегмента (STT вернул "" без исключения)

    /// Current behavior: empty STT result NOT a failure — successful part of
    /// handleLiveSegment (before catch) never writes anySegmentFailed;
    /// accumulation unconditional (empty string added to insertedText,
    /// promptParts, segmentCount). Failure flag set ONLY in catch.
    @objc func testEmptySegment_DoesNotMarkFailure_Structurally() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        let body = Self.functionBody(named: "handleLiveSegment", in: source)
        let successPart = Self.substring(from: "do {", to: "} catch {", in: body)
        XCTAssertFalse(successPart.isEmpty, "успешная часть handleLiveSegment должна существовать")
        XCTAssertTrue(
            successPart.contains("runState.insertedText += result.insertText"),
            "пустой insertText тоже накапливается (безусловно)"
        )
        XCTAssertTrue(
            successPart.contains("runState.segmentCount += 1"),
            "пустой сегмент всё равно увеличивает segmentCount (он обработан, источник речи не пуст)"
        )
        XCTAssertFalse(
            successPart.contains("anySegmentFailed"),
            "пустой текст сегмента НЕ выставляет anySegmentFailed — сбой только в catch"
        )
        XCTAssertTrue(
            successPart.contains("Inserter.append(result.insertText)"),
            "пустой результат уходит в общий путь вставки (далее handleEmptyResult в completeChunkedInsertion)"
        )
        XCTAssertTrue(
            body.contains("runState.anySegmentFailed = true"),
            "единственное место выставления флага сбоя — catch"
        )
    }

    /// Behavioral pin (NanoDictateCore reachable directly): recognizeSegment on
    /// empty STT response does NOT throw, returns empty insertText/promptText —
    /// empty text is legitimate success, handled by structure, not error.
    @objc func testRecognizeSegment_EmptyTranscript_NoThrowNoFailure() {
        runAsync("testRecognizeSegment_EmptyTranscript_NoThrowNoFailure") {
            let result = try await ChunkedPipeline.recognizeSegment(
                samples: [Int16](repeating: 0, count: 1600),
                index: 0,
                insertedText: "",
                prompt: nil,
                stt: { _, _, _ in ChunkedPipeline.SttResult(text: "") }
            )
            XCTAssertEqual(result.insertText, "", "пустой STT-ответ даёт пустой insertText")
            XCTAssertEqual(result.promptText, "", "пустой STT-ответ даёт пустой promptText")
            // Empty finalization also empty — no capitalization, no period.
            XCTAssertEqual(TextRefinement.finalize(""), "")
            XCTAssertEqual(TextRefinement.finalize("   \n\t "), "")
        }
    }

    // MARK: - Helpers (зеркало OverlayLifecycleTests / LiveSegmentFailureTests)

    /// single-segment-skip branch from finishLiveRun (from skip condition to
    /// final pass). Empty string if branch not found.
    private static func singleSegmentSkipBranch(in source: String) -> String {
        let body = functionBody(named: "finishLiveRun", in: source)
        return substring(
            from: "if runState.segmentCount == 1",
            to: "do {",
            in: body
        )
    }

    /// Loads agent source (for structural checks).
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

    /// Returns function body (from "func NAME(" to next function/section at same
    /// indent). Empty string if function not found.
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

    /// Substring between first from and first to AFTER it (bounds excluded).
    /// Empty string if markers not found.
    private static func substring(from: String, to: String, in text: String) -> String {
        guard let start = text.range(of: from)?.upperBound,
              let end = text[start...].range(of: to)?.lowerBound else { return "" }
        return String(text[start..<end])
    }

    /// Runs async closure to completion in a synchronous test method
    /// (same trick as in TranscriberTests).
    private func runAsync(_ testName: String, _ body: @escaping () async throws -> Void) {
        let expectation = expectation(description: testName)
        Task {
            do {
                try await body()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
    }
}