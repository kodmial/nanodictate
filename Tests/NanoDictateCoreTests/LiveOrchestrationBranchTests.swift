import Foundation
@testable import NanoDictateCore

// MARK: - Полное структурное покрытие live-оркестрации (замечание ревью #112)
//
// LiveSegmentFailureTests покрыл только ветку segmentCount == 0. Здесь —
// остальные ветки finishLiveRun и обработчиков (main.swift:832-1090):
//   1) single-segment-skip (единственный сегмент + «хвост», без сбоев);
//   2) tail-порядок («хвост» доставляется ДО finishLiveRun);
//   3) watchdog-бюджет (превышение времени → failTranscription);
//   4) отмена live-цикла (Esc: liveSession += 1, liveRunState = nil);
//   5) пустой текст сегмента (STT вернул "" — НЕ выставляет anySegmentFailed).
//
// Логика приватная и живёт в executable-таргете NanoDictateAgent (тест-таргет
// зависит только от NanoDictateCore), поэтому тестируется структурно — по
// исходнику Sources/NanoDictateAgent/main.swift (тот же приём, что в
// OverlayLifecycleTests / LiveSegmentFailureTests). Пустой STT-результат
// дополнительно проверяется поведенчески напрямую в NanoDictateCore
// (ChunkedPipeline.recognizeSegment — публичный).

final class LiveOrchestrationBranchTests: XCTestCase {

    // MARK: - 1. single-segment-skip (finishLiveRun)

    /// «Один сегмент без пауз»: единственный сегмент + «хвост» покрывает
    /// запись до конца + не было сбоев → финальный проход ПРОПУСКАЕТСЯ,
    /// но накопленный текст сегмента НЕ теряется (insertedText берётся из
    /// runState.insertedText и уходит в completeChunkedInsertion).
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

    /// Паритет single-segment-skip: если «хвост» НЕ доставлен или сегмент
    /// сбоил — условие пропуска не выполнено, и путь обязан упасть в общий
    /// финальный проход ChunkedPipeline.finalize (который докрутит фразу по
    /// всему WAV). В finishLiveRun ровно один такой разветвитель.
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

    /// При 2-м Alt (liveFinalize): синхронный audio.stop() отдаёт «хвост»
    /// колбэком ДО возврата, и только ПОСЛЕ него finishLiveRun встаёт в
    /// liveExecutor — серийная очередь гарантирует порядок tail → finalize.
    /// Структурно: вызов audio.stop() в теле liveFinalize стоит РАНЬШЕ
    /// submit-а finishLiveRun.
    @objc func testTailDeliveredBeforeFinalizeSubmit_ManualStop() {
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

    /// Лимитный путь (liveFinalizeFromSamples): «хвост» уже доставлен
    /// onSpeechSegment ДО вызова (performLimitStop: tail → onRecordingLimitReached),
    /// поэтому здесь НЕ должно быть audio.stop() и повторного снятия «хвоста» —
    /// только страж и submit finishLiveRun. Контракт порядка зафиксирован
    /// комментарием в handleRecordingLimitReached (той же функции, что
    /// вызывает liveFinalizeFromSamples), а не в док-комментарии над ней.
    @objc func testTailDeliveredBeforeFinalizeSubmit_LimitPathHasNoSecondStop() {
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
        // Контракт «tail → onRecordingLimitReached» виден на стороне потребителя:
        // handleRecordingLimitReached комментирует, что «хвост» уже отдан
        // колбэком onSpeechSegment ДО вызова лимита, и сам audio.stop() не зовёт.
        let limitBody = Self.functionBody(named: "handleRecordingLimitReached", in: source)
        XCTAssertTrue(
            limitBody.contains("«хвост» уже отдан колбэком onSpeechSegment ДО"),
            "contract: клиент знает, что «хвост» доставлен ДО колбэка лимита"
        )
        // Единственное упоминание audio.stop() — комментарий «(без audio.stop())»:
        // реального повторного останова в лимитном пути нет (теardown случился
        // в performLimitStop до колбэка лимита).
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

    /// «Хвост» помечается флагом именно при доставке (isTail == true) — этот
    /// флаг разблокирует single-segment-skip; без него финальный проход обязателен.
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

    /// Сегменты и «хвост» (subscribeLiveNanoDictate) идут в ТУ ЖЕ серийную
    /// очередь liveExecutor, что и finishLiveRun — очередь сохраняет порядок
    /// доставки (tail → finalize), и страж сессии стоит на входе.
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

    /// Страж фазы «обработка»: бюджет живого цикла масштабируется числом
    /// запросов (незавершённые сегменты + «хвост» + финальный проход), и по
    /// превышении сторожевого таймера цикл завершается явной failTranscription
    /// («Таймаут STT»). Блок существует в ОБОИХ путях финализации.
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

    /// guard-ы сторожа: failTranscription при превышении бюджета срабатывает
    /// ТОЛЬКО если цикл не сменился (processingSession == session) и всё ещё
    /// фазе транскрибации (state == .transcribing). Новый цикл / уже
    /// завершённый цикл не получают ложный таймаут.
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

    /// Esc во время записи аннулирует ЖИВОЙ цикл: audio.cancel() + liveSession
    /// += 1 + liveRunState = nil. Уже напечатанные сегменты НЕ удаляются
    /// (в handleCancel нет ни одного обращения к Inserter) — отмена лишь
    /// запрещает ВСТАВКУ ещё не обработанных сегментов (страж liveSession у
    /// живого runState протухает). Терминальный хвост — «Отменено» + hide.
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

    /// Esc во время transcribing: ставится токен отмены cancelRecognition —
    /// результат вернувшегося STT-запроса не вставляется.
    @objc func testCancel_TranscribingSetsCancelRecognition() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        let body = Self.functionBody(named: "handleCancel", in: source)
        XCTAssertTrue(body.contains("cancelRecognition = true"), "отмена фазы транскрибации ставит токен отмены")
    }

    /// Судьба уже-напечатанного и отменённого runState: оба main-блока
    /// handleLiveSegment (статус оверлея И инкрементальная вставка Inserter.append)
    /// стражуются сессионным токеном — после отмены (liveSession сменился)
    /// сегмент старого runState пропускается, что уже напечатано — остаётся.
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

    /// Текущее поведение: пустой результат STT НЕ считается сбоем — в успешной
    /// части handleLiveSegment (до catch) нет ни одной записи в anySegmentFailed;
    /// накопление идёт безусловно (пустая строка добавляется к insertedText,
    /// promptParts, segmentCount). Флаг сбоя выставляется ТОЛЬКО в catch.
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

    /// Поведенческая фиксация (NanoDictateCore доступен напрямую): recognizeSegment
    /// при пустом STT-ответе НЕ бросает и возвращает пустые insertText/promptText —
    /// «пустой текст» легитимный успех, обрабатывается структурой, а не ошибкой.
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
            // Финализация пустоты тоже пустая — без капитализации и точки.
            XCTAssertEqual(TextRefinement.finalize(""), "")
            XCTAssertEqual(TextRefinement.finalize("   \n\t "), "")
        }
    }

    // MARK: - Helpers (зеркало OverlayLifecycleTests / LiveSegmentFailureTests)

    /// Ветка single-segment-skip из finishLiveRun (от условия пропуска до
    /// финального прохода). Пустая строка, если ветка не найдена.
    private static func singleSegmentSkipBranch(in source: String) -> String {
        let body = functionBody(named: "finishLiveRun", in: source)
        return substring(
            from: "if runState.segmentCount == 1",
            to: "do {",
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

    /// Подстрока между первым вхождением from и первым вхождением to ПОСЛЕ
    /// него (границы не включаются). Пустая строка — если маркеры не найдены.
    private static func substring(from: String, to: String, in text: String) -> String {
        guard let start = text.range(of: from)?.upperBound,
              let end = text[start...].range(of: to)?.lowerBound else { return "" }
        return String(text[start..<end])
    }

    /// Runs an async closure to completion inside a synchronous test method
    /// (тот же приём, что в TranscriberTests).
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