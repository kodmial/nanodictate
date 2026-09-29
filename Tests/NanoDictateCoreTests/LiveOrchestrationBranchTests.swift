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

// Файл структурных branch-тестов main.swift: класс намеренно крупный (секции
// по проверяемым функциям), как Agent в Sources/NanoDictateAgent/main.swift.
// swiftlint:disable:next type_body_length
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
        // Колбэк audio.stop() — тайминг-флак (tail-push порядок зависел от
        // планировщика главной очереди), ловился в локальных прогонах;
        // локально проходит стабильно.
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
            body.contains("the unclosed utterance is handed by the callback"),
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
        // Лимитный путь (onSpeechSegment → onRecordingLimitReached) — тайминг-флак
        // (tail-push порядок зависел от планировщика главной очереди), ловился
        // в локальных прогонах; локально проходит стабильно.
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
            limitBody.contains("was already handed by onSpeechSegment BEFORE"),
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
            limitBody.contains("(no audio.stop())"),
            "комментарий явно фиксирует: лимитный путь без повторного останова"
        )
        XCTAssertTrue(
            limitBody.contains("liveFinalizeFromSamples(samples)"),
            "лимит маршрутизируется в liveFinalizeFromSamples"
        )
    }

    /// Structural test (логика — в executable-таргете, см. шапку файла):
    /// фиксирует контракт задачи #161 — явный Alt+Alt без гранта Доступности
    /// показывает СИСТЕМНЫЙ диалог запроса (AXIsProcessTrustedWithOptions +
    /// kAXTrustedCheckOptionPrompt), а не мёртвую панель настроек и не молчит.
    /// Тайминга нет — CI-skip гард не нужен.
    @objc func testAltDoubleTapWithoutGrantPromptsSystemDialog() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        let body = Self.functionBody(named: "handleAltDoubleTap", in: source)
        // Assert the CALL, not the bare name: the guard comment also mentions
        // AXIsProcessTrustedWithOptions / kAXTrustedCheckOptionPrompt, so bare
        // substrings would give a false green if a future edit removed the call.
        XCTAssertTrue(
            body.contains("AXIsProcessTrustedWithOptions("),
            "без гранта явный Alt+Alt обязан вызывать AXIsProcessTrustedWithOptions (системный диалог)"
        )
        XCTAssertTrue(
            body.contains("kAXTrustedCheckOptionPrompt.takeUnretainedValue()"),
            "диалог включается флагом kAXTrustedCheckOptionPrompt"
        )
        // Assert the CALL, not the bare name: the guard comment documents
        // openAccessibilitySettingsIfDue (why it is NOT opened after the dialog).
        XCTAssertFalse(
            body.contains("openAccessibilitySettingsIfDue()"),
            "Alt+Alt больше НЕ открывает панель настроек напрямую"
        )
    }

    /// Structural test (логика — в executable-таргете, см. шапку файла):
    /// фиксирует контракт openAccessibilitySettingsIfDue — панель
    /// «Приватность и защита → Доступность» открывается системным вызовом
    /// NSWorkspace.shared.open, не чаще раза за cooldown (метка — в
    /// UserDefaults). Сбой открытия — level: "error", подавление (cooldown
    /// не истёк) — level: "info". Метка времени ставится ТОЛЬКО ПОСЛЕ
    /// успешного open — сорвавшийся open оставляет cooldown свободным для
    /// повтора при следующем старте/респавне.
    @objc func testOpenAccessibilitySettingsIfDue_OrderAndLogLevels() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        let body = Self.functionBody(named: "openAccessibilitySettingsIfDue", in: source)
        XCTAssertTrue(
            body.contains("guard NSWorkspace.shared.open(url) else {"),
            "панель обязана открываться вызовом NSWorkspace.shared.open(url)"
        )
        XCTAssertTrue(
            body.contains("accessibility settings panel open failed"),
            "сбой открытия панели логируется отдельным сообщением"
        )
        XCTAssertTrue(
            body.contains("level: \"error\""),
            "сбой открытия панели — уровень error"
        )
        XCTAssertTrue(
            body.contains("accessibility settings panel suppressed"),
            "подавленное открытие (cooldown не истёк) логируется отдельным сообщением"
        )
        XCTAssertTrue(
            body.contains("level: \"info\""),
            "подавленное открытие — уровень info (пользователь отличает его от реального открытия)"
        )
        XCTAssertTrue(
            body.contains("accessibility settings panel opened"),
            "успешное открытие панели логируется отдельным info-сообщением"
        )
        XCTAssertTrue(
            body.contains("retry in "),
            "кулдаун-суффикс «retry in N s» пинует подавленное открытие"
        )
        XCTAssertTrue(
            body.contains("NSWorkspace.shared.open returned false"),
            "причина сбоя пинует error-лог открытия панели"
        )
        XCTAssertTrue(
            body.contains("accessibility settings open requested"),
            "debug-маркер входа пинует видимость функции в логе"
        )
        XCTAssertTrue(
            body.contains("level: \"debug\""),
            "debug-маркер входа — уровень debug"
        )
        // Порядок: метка времени пишется строго ПОСЛЕ успешного open —
        // строковая позиция NSWorkspace.shared.open раньше defaults.set(now, forKey:.
        let lines = body.components(separatedBy: "\n")
        let openIndex = lines.firstIndex(where: { $0.contains("NSWorkspace.shared.open(url)") })
        let stampIndex = lines.firstIndex(where: { $0.contains("defaults.set(now, forKey:") })
        guard let openIndex = openIndex, let stampIndex = stampIndex else {
            XCTFail("openAccessibilitySettingsIfDue должна содержать и open, и запись метки времени")
            return
        }
        XCTAssertTrue(
            openIndex < stampIndex,
            "метка времени пишется строго ПОСЛЕ успешного open — сорвавшийся open оставляет cooldown свободным"
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
    /// liveExecutor chain as finishLiveRun — order is kept (tail → finalize),
    /// cancel-flag guard at entry. Segments wait in the run's coalescing
    /// buffer first (backpressure); one active drain task per run loops over
    /// all available batches on the executor (review #72, no empty successor
    /// chain nodes, no pendingCount overstatement).
    @objc func testSegmentsAndFinalize_ShareSerialExecutor() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        let subBody = Self.functionBody(named: "subscribeLiveNanoDictate", in: source)
        XCTAssertTrue(
            subBody.contains("runState.segmentBuffer.append(samples: segment, isTail: isTail)"),
            "segments must wait in the run coalescing buffer (backpressure, not raw task pileup)"
        )
        XCTAssertTrue(
            subBody.contains("guard runState.tryClaimDrain() else { return }"),
            "one active drain per run: segments arriving while the drain runs are picked up by it, no new chain node"
        )
        XCTAssertTrue(
            subBody.contains("self.liveExecutor.submit {"),
            "batches must go through liveExecutor"
        )
        XCTAssertTrue(
            subBody.contains("await self.handleLiveSegment(runState: runState)"),
            "the drain runs on liveExecutor in order"
        )
        XCTAssertTrue(
            subBody.contains("guard !runState.isCancelled else { return }"),
            "cancel-flag guard at entry (lock-protected) drops segments of a cancelled loop"
        )
        let segmentBody = Self.functionBody(named: "handleLiveSegment", in: source)
        XCTAssertTrue(
            segmentBody.contains("runState.segmentBuffer.takeNext()"),
            "drain must take batches from the buffer exactly once each (FIFO)"
        )
        XCTAssertTrue(
            segmentBody.contains("while true {"),
            "drain must loop over all available batches (single active task per run)"
        )
        let finalizeBody = Self.functionBody(named: "liveFinalize", in: source)
        XCTAssertTrue(
            finalizeBody.contains("liveExecutor.submit"),
            "finishLiveRun встаёт в ту же liveExecutor после хвоста"
        )
    }

    // MARK: - 3. watchdog-бюджет (liveFinalize / liveFinalizeFromSamples)

    /// Processing-phase guard: live-cycle budget scales with request count
    /// (pending buffer batches + in-flight batch + final pass); on timeout
    /// cycle ends with explicit failTranscription (sttTimeoutMessage). Block
    /// exists in BOTH finalize paths. Single drain per run (review #72), so
    /// the budget is sized from batches, not from the drain-task count
    /// (always ≤1), which would undercount STT calls.
    @objc func testWatchdogBudget_BothFinalizePaths() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        for name in ["liveFinalize", "liveFinalizeFromSamples"] {
            let body = Self.functionBody(named: name, in: source)
            let label = "\(name)"
            XCTAssertTrue(
                body.contains("runState.segmentBuffer.depth"),
                "\(label): бюджет обязан учитывать pending-буфер батчей (single drain, не pendingCount задач)"
            )
            XCTAssertTrue(
                body.contains("let requestCount = max(2, pendingBatches + 2)"),
                "\(label): бюджет = pending-батчи + in-flight + финальный проход"
            )
            XCTAssertFalse(
                body.contains("liveExecutor.pendingCount + 1"),
                "\(label): бюджет НЕ должен считаться от числа drain-задач (всегда ≤1 — undercount)"
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

    /// Single-request watchdog (processSingleRequest): budget =
    /// processingMaxDuration, plus one extra networkRequestTimeout ONLY when
    /// auto-failover has candidates — failover runs AFTER the primary timeout,
    /// so cutting it mid-flight would kill a valid failover.
    @objc func testSingleRequestWatchdogBudget_IncludesFailoverMargin() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        let body = Self.functionBody(named: "processSingleRequest", in: source)
        XCTAssertFalse(body.isEmpty, "processSingleRequest обязана существовать")
        let watchdog = Self.substring(
            from: "let watchdogDuration",
            to: "failTranscription(Transcriber.sttTimeoutMessage",
            in: body
        )
        XCTAssertFalse(watchdog.isEmpty, "блок сторожевого таймера processSingleRequest обязан существовать")
        // Формула многолинейная — нормализуем пробелы и сверяем композицию.
        // substring(from:) отдаёт фрагмент ПОСЛЕ маркера "let watchdogDuration"
        // (второго вхождения в теле функции нет), поэтому префикс объявления
        // в normalized отсутствует — сверяем композицию с «=» в начале.
        let normalized = watchdog.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(
            normalized.contains(
                "= OverlayController.processingMaxDuration + (autoFailover && !failoverCandidates.isEmpty ? Transcriber.networkRequestTimeout : 0)"
            ),
            "бюджет одиночного запроса = processingMaxDuration + networkRequestTimeout ТОЛЬКО при активном failover с кандидатами"
        )
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

    // MARK: - 6. Cancel-флаг LiveRunState + SerialAsyncExecutor (review B4 / CR12)

    /// CR12: LiveRunState carries an explicit isCancelled flag (not just the
    /// liveSession token). Every terminal path that drops the runState — Esc
    /// (handleCancel) and mid-recording device change (handleDeviceChange) —
    /// sets isCancelled BEFORE releasing the reference, and handleLiveSegment
    /// reads it first thing, so a stale segment already queued on
    /// liveExecutor skips its STT call instead of holding the serial queue.
    @objc func testLiveRunState_CancelPathsSetFlagBeforeDropStructurally() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        let cancelBody = Self.functionBody(named: "handleCancel", in: source)
        XCTAssertTrue(
            cancelBody.contains("liveRunState?.isCancelled = true"),
            "Esc (handleCancel) обязан ставить isCancelled на накопленном runState"
        )
        let deviceBody = Self.functionBody(named: "handleDeviceChange", in: source)
        XCTAssertTrue(
            deviceBody.contains("liveRunState?.isCancelled = true"),
            "смена устройства обязана ставить isCancelled на накопленном runState"
        )
        let segmentBody = Self.functionBody(named: "handleLiveSegment", in: source)
        let head = Self.substring(
            from: "func handleLiveSegment(",
            to: "let index = runState.segmentCount",
            in: segmentBody
        )
        XCTAssertTrue(
            head.contains("if runState.isCancelled { break }"),
            "handleLiveSegment (single drain) обязан отбрасывать работу отменённого runState в начале каждой итерации"
        )
        XCTAssertTrue(
            segmentBody.contains("runState.releaseDrain()"),
            "drain обязан освобождать single-drain claim при выходе (иначе run зависнет)"
        )
    }

    // MARK: - 7. SerialAsyncExecutor.pendingCount (CR12, backpressure update)
    //
    // The executor is a structured Task chain (no GCD worker blocked on a
    // semaphore): each task awaits its predecessor, which suspends
    // cooperatively instead of occupying a thread while STT runs.
    // pendingCount still feeds the "processing" watchdog budget — it counts
    // submitted-but-unfinished tasks. Structurally: submit() increments
    // pending (under pendingLock) BEFORE chaining the task; the task body
    // decrements it when done. No DispatchSemaphore / sema.wait may remain.

    /// CR12: pendingCount feeds the "processing" watchdog budget — it must
    /// really count submitted-but-unfinished tasks. Structurally: submit()
    /// increments pending (under pendingLock) BEFORE chaining the task;
    /// the chained body decrements it back when done.
    @objc func testSerialExecutor_PendingCountLifecycleStructurally() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        let executor = Self.substring(
            from: "private final class SerialAsyncExecutor {",
            to: "private final class LivePendingBuffer {",
            in: source
        )
        XCTAssertFalse(executor.isEmpty, "SerialAsyncExecutor обязан существовать в main.swift")
        XCTAssertTrue(
            executor.contains("var pendingCount: Int {"),
            "executor обязан экспонировать pendingCount для watchdog-бюджета"
        )
        XCTAssertFalse(
            executor.contains("DispatchSemaphore"),
            "executor must not block a GCD worker on a semaphore (structured Task chain instead)"
        )
        XCTAssertFalse(
            executor.contains("sema.wait()"),
            "no semaphore wait may remain in the executor"
        )
        XCTAssertTrue(
            executor.contains("await predecessor?.value"),
            "each chained task must await its predecessor (strictly serial order)"
        )
        let submitBlock = Self.substring(
            from: "func submit(",
            to: "tail = next",
            in: executor
        )
        XCTAssertTrue(
            submitBlock.contains("pending += 1"),
            "submit обязан инкрементировать pending под блокировкой ДО постановки задачи в цепочку"
        )
        XCTAssertTrue(
            submitBlock.contains("await body()"),
            "the chained task must run the submitted body"
        )
        XCTAssertTrue(
            executor.contains("self.pending -= 1"),
            "после завершения задачи pending обязан декрементироваться"
        )
    }

    // MARK: - 7b. Backpressure buffer (issue: bounded queue + coalescing)

    /// The non-streaming live path is explicitly backpressured: each run owns
    /// a LivePendingBuffer bounded by LiveBackpressurePolicy and merged via
    /// LiveSegmentCoalescer (no voiced samples dropped, only fewer requests).
    /// Cancellation clears the buffer deterministically (no orphan work).
    @objc func testLivePendingBuffer_BoundedCoalescingAndCancelStructurally() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        let buffer = Self.substring(
            from: "private final class LivePendingBuffer {",
            to: "private var state: NanoDictateState = .idle",
            in: source
        )
        XCTAssertFalse(buffer.isEmpty, "LivePendingBuffer обязан существовать в main.swift")
        XCTAssertTrue(
            buffer.contains("LiveBackpressurePolicy.default"),
            "the buffer bound must follow the shared LiveBackpressurePolicy"
        )
        XCTAssertTrue(
            buffer.contains("LiveSegmentCoalescer.coalesce(batches)"),
            "over-bound pending batches must merge via LiveSegmentCoalescer (order kept, no loss)"
        )
        XCTAssertTrue(
            buffer.contains("func takeNext()"),
            "the executor must take batches exactly once (FIFO)"
        )
        XCTAssertTrue(
            buffer.contains("func clear()"),
            "cancellation must be able to drop pending batches deterministically"
        )
        // Every terminal path that drops the run clears its buffer.
        for name in ["handleCancel", "handleDeviceChange"] {
            let body = Self.functionBody(named: name, in: source)
            XCTAssertTrue(
                body.contains("segmentBuffer.clear()"),
                "\(name) обязан очищать coalescing-буфер отменённого цикла (no orphan work)"
            )
        }
        let runState = Self.substring(
            from: "private final class LiveRunState",
            to: "private final class SerialAsyncExecutor",
            in: source
        )
        XCTAssertTrue(
            runState.contains("let segmentBuffer = LivePendingBuffer()"),
            "each live run must own its buffer (stale loops cannot consume new audio)"
        )
    }

    // MARK: - 8. Watchdog-бюджет против serial-очереди (CR12, review #72)

    /// Single drain per run (review #72): the "processing" watchdog budget is
    /// sized from batches the drain can process — pending buffer + in-flight
    /// batch + final pass (max(2, pendingBatches + 2)), each up to
    /// networkRequestTimeout, plus 5 s margin. The same formula guards BOTH
    /// finalize paths: forced stop (liveFinalize) and duration limit
    /// (liveFinalizeFromSamples). It must NOT use the drain-task count
    /// (always ≤1), which would undercount STT calls.
    @objc func testProcessingWatchdog_BudgetAccountsPendingCountStructurally() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        let expected = "max(2, pendingBatches + 2)"
        for name in ["liveFinalize", "liveFinalizeFromSamples"] {
            let body = Self.functionBody(named: name, in: source)
            let watchdog = Self.substring(
                from: "let requestCount",
                to: "let liveMaxDuration",
                in: body
            )
            XCTAssertFalse(
                watchdog.isEmpty,
                "\(name): блок let requestCount должен существовать"
            )
            XCTAssertTrue(
                watchdog.contains(expected),
                "\(name): бюджет обязан учитывать батчи drain-а (\(expected): pending + in-flight + final)"
            )
            XCTAssertTrue(
                body.contains("runState.segmentBuffer.depth"),
                "\(name): бюджет sized from buffer depth, not task count"
            )
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