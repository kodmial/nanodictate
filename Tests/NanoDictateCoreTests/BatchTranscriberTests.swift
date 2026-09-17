import Foundation
@testable import NanoDictateCore

// MARK: - Тесты BatchTranscriber (ретраи, плейсхолдеры, чекпоинт/resume)
//
// Сеть и сон инъецируются: sendOne/delay — замыкания, чекпоинт — реальный
// JSON во временной папке (как и в проде). Реальных HTTP-запросов нет.

final class BatchTranscriberTests: XCTestCase {

    private func runAsync<T>(_ body: @escaping () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let expect = expectation(description: "runAsync")
        Task {
            do { box.value = try await body() }
            catch { box.error = error }
            expect.fulfill()
        }
        wait(for: [expect], timeout: 10.0)
        if let error = box.error { throw error }
        return box.value!
    }

    private func tone(_ seconds: Double, sampleRate: Int, value: Int16 = 500) -> [Int16] {
        // Дефолт 500 = речь: rms(500)/32767 ≈ 0.0153 > nearSilenceThreshold
        // (~0.00316 ≈ 103.5 в Int16) — тишины нет, plan() с cutAtPauses
        // не сдвигает границы, геометрия фиксированная (чанки по maxSegment).
        // Значение 100 < порога читалось бы как полная тишина → паузная
        // нарезка (~1 с чанки) и сломанные ожидания 2-секундных чанков.
        Array(repeating: value, count: max(0, Int((seconds * Double(sampleRate)).rounded())))
    }

    /// Мгновенная задержка (в проде — Task.sleep).
    private func instantDelay(_ seconds: TimeInterval) async throws {}

    private func tempCheckpointPath(_ name: String) -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dct-test-\(name)-\(UUID().uuidString).checkpoint.json").path
    }

    // MARK: transcribeChunk — ретраи

    @objc func testChunkRetriesThenSucceeds() throws {
        var attempts = 0
        var waits: [TimeInterval] = []
        let text = try runAsync {
            try await BatchTranscriber.transcribeChunk(
                send: { attempt in
                    attempts += 1
                    if attempt < 2 { throw BatchHTTPError.network("сеть упала") }
                    return "ok-\(attempt)"
                },
                retries: 3,
                backoff: [2, 4, 8],
                delay: { waits.append($0); try await self.instantDelay($0) }
            )
        }
        XCTAssertEqual(text, "ok-2")
        XCTAssertEqual(attempts, 3, "две неудачи + успех на третьей попытке")
        XCTAssertEqual(waits, [2, 4], "backoff 2s/4s между попытками")
    }

    @objc func testChunkHonorsRetryAfterHeader() throws {
        var waits: [TimeInterval] = []
        let text = try runAsync {
            try await BatchTranscriber.transcribeChunk(
                send: { attempt in
                    if attempt == 0 { throw BatchHTTPError.http(503, message: "busy", retryAfter: 42) }
                    return "ok"
                },
                retries: 3,
                backoff: [2, 4, 8],
                delay: { waits.append($0); try await self.instantDelay($0) }
            )
        }
        XCTAssertEqual(text, "ok")
        XCTAssertEqual(waits, [42], "Retry-After перекрывает backoff")
    }

    @objc func testChunkNonRetryableThrowsImmediately() throws {
        var waits: [TimeInterval] = []
        var attempts = 0
        do {
            _ = try runAsync {
                try await BatchTranscriber.transcribeChunk(
                    send: { attempt in
                        attempts += 1
                        throw BatchHTTPError.http(400, message: "bad request", retryAfter: nil)
                    },
                    retries: 3,
                    backoff: [2, 4, 8],
                    delay: { waits.append($0); try await self.instantDelay($0) }
                )
            }
            XCTFail("4xx должен выбросить ошибку без ретраев")
        } catch let error as BatchHTTPError {
            XCTAssertEqual(error.kind, .http)
            XCTAssertEqual(error.status, 400)
        } catch {
            XCTFail("неожиданная ошибка: \(error)")
        }
        XCTAssertEqual(attempts, 1, "4xx (кроме 429) не ретраится")
        XCTAssertTrue(waits.isEmpty)
    }

    @objc func testChunkRetriesOnExhaustionThrows() throws {
        var waits: [TimeInterval] = []
        var attempts = 0
        do {
            _ = try runAsync {
                try await BatchTranscriber.transcribeChunk(
                    send: { attempt in
                        attempts += 1
                        throw BatchHTTPError.network("всегда падает")
                    },
                    retries: 3,
                    backoff: [2, 4, 8],
                    delay: { waits.append($0); try await self.instantDelay($0) }
                )
            }
            XCTFail("исчерпание ретраев должно бросать")
        } catch {
            // ожидаемо
        }
        XCTAssertEqual(attempts, 4, "1 + 3 ретрая")
        XCTAssertEqual(waits, [2, 4, 8])
    }

    @objc func testChunkTreatsNonBatchErrorsAsRetryable() throws {
        // Транспортная ошибка (не BatchHTTPError) тоже ретраится.
        var attempts = 0
        let text = try runAsync {
            try await BatchTranscriber.transcribeChunk(
                send: { attempt in
                    attempts += 1
                    if attempt == 0 { throw URLError(.timedOut) }
                    return "ok"
                },
                retries: 3,
                backoff: [2],
                delay: { _ in try await self.instantDelay(0) }
            )
        }
        XCTAssertEqual(text, "ok")
        XCTAssertEqual(attempts, 2)
    }

    // MARK: run — основной прогон

    @objc func testRunJoinsChunksWithDedup() throws {
        // 8 с файла, чанки по 2 с с оверлэпом 0.5 с → 4 чанка.
        let samples = tone(8, sampleRate: 1000)
        let texts = ["alpha beta", "beta gamma", "gamma delta", "delta omega"]
        var sentIndexes: [Int] = []
        let outcome = try runAsync {
            try await BatchTranscriber.run(
                samples: samples,
                sampleRate: 1000,
                maxSegment: 2,
                overlap: 0.5,
                providerID: "gigaam",
                sourceFile: "/tmp/test.wav",
                sendOne: { attempt, wav, index, prompt in
                    sentIndexes.append(index)
                    return texts[index]
                },
                delay: { try await self.instantDelay($0) }
            )
        }
        XCTAssertEqual(outcome.totalSegments, 4)
        XCTAssertEqual(outcome.okCount, 4)
        XCTAssertEqual(outcome.skippedCount, 0)
        XCTAssertTrue(outcome.skippedIndexes.isEmpty)
        XCTAssertEqual(outcome.text, "alpha beta gamma delta omega",
                       "граничный дедуп: beta/gamma/delta не дублируются")
        XCTAssertEqual(sentIndexes, [0, 1, 2, 3], "каждый чанк распознаётся ровно один раз")
    }

    // MARK: Контекстная склейка (chaining) — 4-й параметр sendOne = prompt

    @objc func testSequentialChainingPassesTailOfPreviousChunk() throws {
        let samples = tone(8, sampleRate: 1000)
        var prompts: [String?] = []
        let outcome = try runAsync {
            try await BatchTranscriber.run(
                samples: samples,
                sampleRate: 1000,
                maxSegment: 2,
                overlap: 0.5,
                providerID: "gigaam",
                sourceFile: "x.wav",
                sendOne: { _, _, index, prompt in
                    prompts.append(prompt)
                    return "текст \(index)"
                },
                delay: { try await self.instantDelay($0) }
            )
        }
        XCTAssertEqual(outcome.okCount, 4)
        XCTAssertEqual(prompts.count, 4)
        XCTAssertNil(prompts[0], "первый чанк контекста не имеет")
        XCTAssertEqual(prompts[1], "текст 0", "чанк 1 получает текст предыдущего чанка")
        XCTAssertEqual(prompts[2], "текст 1")
        XCTAssertEqual(prompts[3], "текст 2")
    }

    @objc func testChainingSkipsPlaceholderChunks() throws {
        // Чанк 1 падает → плейсхолдер; чанк 2 должен цеплять текст чанка 0
        // (плейсхолдер "[…]" не участвует в цепочке).
        let samples = tone(6, sampleRate: 1000)
        var prompts: [String?] = []
        let outcome = try runAsync {
            try await BatchTranscriber.run(
                samples: samples,
                sampleRate: 1000,
                maxSegment: 2,
                overlap: 0.5,
                providerID: "gigaam",
                sourceFile: "x.wav",
                sendOne: { _, _, index, prompt in
                    prompts.append(prompt)
                    if index == 1 { throw BatchHTTPError.network("упал") }
                    return "слово \(index)"
                },
                delay: { try await self.instantDelay($0) }
            )
        }
        XCTAssertEqual(outcome.skippedIndexes, [2])
        XCTAssertNil(prompts[0])
        XCTAssertEqual(prompts.count, 1 + 4 + 1,
                       "чанк 0 + 4 попытки чанка 1 + чанк 2: 6 вызовов sendOne")
        XCTAssertTrue(prompts.dropFirst().allSatisfy { $0 == "слово 0" },
                      "плейсхолдер пропускается — цепляется последний успешный текст чанка 0")
    }

    @objc func testParallelPassesNilPrompt() throws {
        // Параллельный путь (maxConcurrent > 1): порядок воркеров произвольный,
        // цепочка не выстраивается — prompt всегда nil.
        let samples = tone(4, sampleRate: 1000)
        var prompts: [String?] = []
        let outcome = try runAsync {
            try await BatchTranscriber.run(
                samples: samples,
                sampleRate: 1000,
                maxSegment: 2,
                overlap: 0.5,
                providerID: "gigaam",
                sourceFile: "x.wav",
                sendOne: { _, _, index, prompt in
                    prompts.append(prompt)
                    return "текст \(index)"
                },
                delay: { try await self.instantDelay($0) },
                maxConcurrent: 2
            )
        }
        XCTAssertEqual(outcome.okCount, 2)
        XCTAssertEqual(prompts.count, 2)
        XCTAssertTrue(prompts.allSatisfy { $0 == nil }, "параллельный путь — контекст не шлётся")
        XCTAssertEqual(outcome.text, "текст 0 текст 1", "порядок итога сохраняется")
    }

    @objc func testChainingUsesResumeSeededRecordsAsContext() throws {
        // Resume: чанк 0 уже в чекпоинте (ok) — sendOne для него не вызывается,
        // но его текст входит в цепочку для следующих чанков.
        let samples = tone(8, sampleRate: 1000)
        let path = tempCheckpointPath("chaining-resume")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let cp = BatchCheckpoint(
            version: BatchCheckpoint.currentVersion,
            providerID: "gigaam",
            sourceFile: "x.wav",
            totalSegments: 4,
            segments: [BatchSegmentRecord(index: 0, bodyStart: 0, bodyEnd: 2,
                                          status: BatchSegmentRecord.statusOK, text: "прелюдия")]
        )
        try BatchTranscriber.saveCheckpoint(cp, to: path)

        var prompts: [String?] = []
        let outcome = try runAsync {
            try await BatchTranscriber.run(
                samples: samples,
                sampleRate: 1000,
                maxSegment: 2,
                overlap: 0.5,
                providerID: "gigaam",
                sourceFile: "x.wav",
                checkpointPath: path,
                resume: true,
                sendOne: { _, _, index, prompt in
                    prompts.append(prompt)
                    return "шаг \(index)"
                },
                delay: { try await self.instantDelay($0) }
            )
        }
        XCTAssertEqual(prompts, ["прелюдия", "шаг 1", "шаг 2"],
                       "чанк 0 распознан из resume; чанк 1 цепляет его текст")
        XCTAssertEqual(outcome.text, "прелюдия шаг 1 шаг 2 шаг 3")
    }

    @objc func testRunEmptySamplesNoCalls() throws {
        var calls = 0
        let outcome = try runAsync {
            try await BatchTranscriber.run(
                samples: [],
                sampleRate: 16000,
                providerID: "gigaam",
                sourceFile: "x.wav",
                sendOne: { _, _, _, _ in calls += 1; return "nope" },
                delay: { _ in try await self.instantDelay(0) }
            )
        }
        XCTAssertEqual(outcome.totalSegments, 0)
        XCTAssertEqual(outcome.text, "")
        XCTAssertEqual(calls, 0)
    }

    @objc func testRunPlaceholderForFailedChunkAndContinues() throws {
        let samples = tone(8, sampleRate: 1000)
        var sent: [Int] = []
        let outcome = try runAsync {
            try await BatchTranscriber.run(
                samples: samples,
                sampleRate: 1000,
                maxSegment: 2,
                overlap: 0.5,
                providerID: "gigaam",
                sourceFile: "x.wav",
                sendOne: { _, _, index, _ in
                    sent.append(index)
                    if index == 2 { throw BatchHTTPError.network("упал") }
                    return "слова \(index)"
                },
                delay: { try await self.instantDelay($0) }
            )
        }
        XCTAssertEqual(outcome.okCount, 3)
        XCTAssertEqual(outcome.skippedCount, 1)
        XCTAssertEqual(outcome.skippedIndexes, [3], "1-based номер пропущенного чанка")
        XCTAssertTrue(outcome.text.contains(BatchTranscriber.placeholder),
                      "плейсхолдер вместо текста упавшего чанка")
        XCTAssertEqual(sent, [0, 1, 2, 2, 2, 2, 3],
                       "чанк 2 ретраится 4 раза (3 ретрая), прогон продолжается после провала")
    }

    @objc func testRunProgressReportsEachChunk() throws {
        let samples = tone(4, sampleRate: 1000)
        var progress: [(Int, String)] = []
        _ = try runAsync {
            try await BatchTranscriber.run(
                samples: samples,
                sampleRate: 1000,
                maxSegment: 2,
                overlap: 0.5,
                providerID: "gigaam",
                sourceFile: "x.wav",
                sendOne: { _, _, index, _ in "текст \(index)" },
                delay: { _ in try await self.instantDelay(0) },
                onProgress: { i, n, _, _, _, status in
                    XCTAssertEqual(n, 2)
                    progress.append((i, status))
                }
            )
        }
        XCTAssertEqual(progress.count, 2)
        XCTAssertEqual(progress[0].0, 1)
        XCTAssertEqual(progress[1].0, 2)
        XCTAssertTrue(progress.allSatisfy { $0.1 == BatchSegmentRecord.statusOK })
    }

    // MARK: Чекпоинт / resume

    @objc func testCheckpointSavedAndResumeSkipsResolved() throws {
        let samples = tone(8, sampleRate: 1000)
        let path = tempCheckpointPath("resume")
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Первый прогон: всё распознаётся, чекпоинт пишется после каждого чанка.
        var firstCalls = 0
        let first = try runAsync {
            try await BatchTranscriber.run(
                samples: samples, sampleRate: 1000, maxSegment: 2, overlap: 0.5,
                providerID: "gigaam", sourceFile: "x.wav",
                checkpointPath: path,
                sendOne: { _, _, index, _ in firstCalls += 1; return "текст \(index)" },
                delay: { _ in try await self.instantDelay(0) }
            )
        }
        XCTAssertEqual(firstCalls, 4)
        XCTAssertEqual(first.text, "текст 0 текст 1 текст 2 текст 3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "чекпоинт написан")

        // Resume: чанки уже разрешены — sendOne НЕ вызывается вообще.
        var resumedCalls = 0
        let second = try runAsync {
            try await BatchTranscriber.run(
                samples: samples, sampleRate: 1000, maxSegment: 2, overlap: 0.5,
                providerID: "gigaam", sourceFile: "x.wav",
                checkpointPath: path, resume: true,
                sendOne: { _, _, index, _ in resumedCalls += 1; return "НЕ ДОЛЖЕН ВЫЗЫВАТЬСЯ" },
                delay: { _ in try await self.instantDelay(0) }
            )
        }
        XCTAssertEqual(resumedCalls, 0, "resume берёт разрешённые чанки из чекпоинта")
        XCTAssertEqual(second.text, first.text)
        XCTAssertEqual(second.okCount, 4)
    }

    @objc func testResumeIgnoresMismatchedCheckpoint() throws {
        let samples = tone(8, sampleRate: 1000)
        let path = tempCheckpointPath("mismatch")
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Чекпоинт другого провайдера — resume его игнорирует.
        _ = try runAsync {
            try await BatchTranscriber.run(
                samples: samples, sampleRate: 1000, maxSegment: 2, overlap: 0.5,
                providerID: "other", sourceFile: "x.wav",
                checkpointPath: path,
                sendOne: { _, _, index, _ in "a \(index)" },
                delay: { _ in try await self.instantDelay(0) }
            )
        }
        var calls = 0
        let outcome = try runAsync {
            try await BatchTranscriber.run(
                samples: samples, sampleRate: 1000, maxSegment: 2, overlap: 0.5,
                providerID: "gigaam", sourceFile: "x.wav",
                checkpointPath: path, resume: true,
                sendOne: { _, _, index, _ in calls += 1; return "b \(index)" },
                delay: { _ in try await self.instantDelay(0) }
            )
        }
        XCTAssertEqual(calls, 4, "чужой чекпоинт не применяется — распознаём всё заново")
        XCTAssertEqual(outcome.text, "b 0 b 1 b 2 b 3")
    }

    @objc func testRunLastChunkFailsPlaceholderSkippedIndex() throws {
        let samples = tone(6, sampleRate: 1000)
        let outcome = try runAsync {
            try await BatchTranscriber.run(
                samples: samples, sampleRate: 1000, maxSegment: 2, overlap: 0.5,
                providerID: "gigaam", sourceFile: "x.wav",
                sendOne: { _, _, index, _ in
                    if index == 2 { throw BatchHTTPError.network("x") }
                    return "текст \(index)"
                },
                delay: { _ in try await self.instantDelay(0) }
            )
        }
        XCTAssertEqual(outcome.skippedIndexes, [3])
        XCTAssertEqual(outcome.text, "текст 0 текст 1 \(BatchTranscriber.placeholder)")
    }

    // MARK: Resume c чужим sourceFile ([1]: sourceFile участвует в валидации)

    @objc func testResumeIgnoresCheckpointOfDifferentSourceFile() throws {
        let samples = tone(8, sampleRate: 1000)
        let path = tempCheckpointPath("source-mismatch")
        defer { try? FileManager.default.removeItem(atPath: path) }

        // Первый прогон — файл /tmp/a.wav: чекпоинт пишется с его sourceFile.
        _ = try runAsync {
            try await BatchTranscriber.run(
                samples: samples, sampleRate: 1000, maxSegment: 2, overlap: 0.5,
                providerID: "gigaam", sourceFile: "/tmp/a.wav",
                checkpointPath: path,
                sendOne: { _, _, index, _ in "старый \(index)" },
                delay: { _ in try await self.instantDelay(0) }
            )
        }

        // Resume с ДРУГИМ файлом (та же нарезка): чекпоинт НЕ применяется —
        // все чанки распознаются заново, тексты чужого чекпоинта не берутся.
        var calls = 0
        let outcome = try runAsync {
            try await BatchTranscriber.run(
                samples: samples, sampleRate: 1000, maxSegment: 2, overlap: 0.5,
                providerID: "gigaam", sourceFile: "/tmp/b.wav",
                checkpointPath: path, resume: true,
                sendOne: { _, _, index, _ in calls += 1; return "новый \(index)" },
                delay: { _ in try await self.instantDelay(0) }
            )
        }
        XCTAssertEqual(calls, 4, "чужой sourceFile — чекпоинт игнорируется, распознаём всё заново")
        XCTAssertEqual(outcome.text, "новый 0 новый 1 новый 2 новый 3",
                       "текст НЕ берётся из старого чекпоинта другого файла")
    }

    // MARK: Отмена ([6]: CancellationError не ретраится)

    @objc func testChunkCancellationStopsImmediately() throws {
        let attempts = AttemptBox()
        let started = DispatchSemaphore(value: 0)
        let expect = expectation(description: "cancelled")
        let worker = Task {
            defer { expect.fulfill() }
            do {
                _ = try await BatchTranscriber.transcribeChunk(
                    send: { attempt in
                        attempts.value += 1
                        started.signal()
                        try await Task.sleep(nanoseconds: 50_000_000)
                        try Task.checkCancellation()
                        return "ok"
                    },
                    retries: 3,
                    backoff: [2],
                    delay: { _ in try await self.instantDelay(0) }
                )
                XCTFail("отменённая задача должна прерваться, а не вернуть текст")
            } catch is CancellationError {
                // ожидаемо
            } catch {
                XCTFail("ожидался CancellationError, получен \(error)")
            }
        }
        started.wait()   // дождались первой попытки, теперь отменяем
        worker.cancel()
        wait(for: [expect], timeout: 10.0)
        XCTAssertEqual(attempts.value, 1, "отмена не ретраится — одна попытка и выход")
    }

    // MARK: BatchRequestBuilder.makeRequest ([2]: покрытие сборки запроса)

    private func makeBatchProvider(baseURL: String = "http://localhost:8080/v1/audio/transcriptions") -> AppConfig.Provider {
        AppConfig.Provider(
            id: "gigaam", name: "",
            baseURL: baseURL,
            model: "gigaam-v2",
            apiKey: "", apiKeyFile: nil, proxyKey: ""
        )
    }

    @objc func testMakeRequestIncludesBearerAuthForNonEmptyKey() throws {
        guard let prepared = BatchRequestBuilder.makeRequest(
            provider: makeBatchProvider(),
            apiKey: "secret-token-123",
            language: "ru",
            timeout: 60,
            wav: Data("RIFFWAVEfmt data".utf8),
            chunkIndex: 2
        ) else {
            XCTFail("запрос с валидным base_url должен собраться")
            return
        }
        XCTAssertEqual(prepared.request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token-123",
                       "непустой ключ → Authorization: Bearer <ключ> в заголовках")
        XCTAssertEqual(prepared.transcriptPath, nil, "openAI-compatible — плоский ключ text, без пути")
    }

    @objc func testMakeRequestOmitsAuthorizationForEmptyKey() throws {
        guard let prepared = BatchRequestBuilder.makeRequest(
            provider: makeBatchProvider(),
            apiKey: "",
            language: "ru",
            timeout: 60,
            wav: Data("RIFFWAVEfmt data".utf8),
            chunkIndex: 0
        ) else {
            XCTFail("запрос с валидным base_url должен собраться")
            return
        }
        XCTAssertNil(prepared.request.value(forHTTPHeaderField: "Authorization"),
                     "пустой ключ — Authorization не отправляется вовсе (никакого «Bearer »)")
        let contentType = prepared.request.value(forHTTPHeaderField: "Content-Type") ?? ""
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary=Boundary-"),
                      "мультипарт остаётся, уходит только пустая авторизация")
    }

    @objc func testMakeRequestSetsProxyHeaderForNonEmptyProxyKey() throws {
        guard let prepared = BatchRequestBuilder.makeRequest(
            provider: makeBatchProvider(),
            apiKey: "secret-token-123",
            language: "ru",
            timeout: 60,
            wav: Data("RIFFWAVEfmt data".utf8),
            chunkIndex: 1,
            proxyKey: "proxy-token-456",
            proxyKeyHeader: "X-Api-Key"
        ) else {
            XCTFail("запрос с валидным base_url должен собраться")
            return
        }
        XCTAssertEqual(prepared.request.value(forHTTPHeaderField: "X-Api-Key"), "proxy-token-456",
                       "непустой proxyKey → заголовок X-Api-Key со значением ключа")
        XCTAssertEqual(prepared.request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token-123",
                       "прокси-заголовок не отменяет Authorization")
    }

    @objc func testMakeRequestOmitsProxyHeaderForEmptyProxyKey() throws {
        guard let prepared = BatchRequestBuilder.makeRequest(
            provider: makeBatchProvider(),
            apiKey: "secret-token-123",
            language: "ru",
            timeout: 60,
            wav: Data("RIFFWAVEfmt data".utf8),
            chunkIndex: 1,
            proxyKey: "",
            proxyKeyHeader: "X-Api-Key"
        ) else {
            XCTFail("запрос с валидным base_url должен собраться")
            return
        }
        XCTAssertNil(prepared.request.value(forHTTPHeaderField: "X-Api-Key"),
                     "пустой proxyKey — прокси-заголовок не отправляется вовсе")
        XCTAssertEqual(prepared.request.value(forHTTPHeaderField: "Authorization"), "Bearer secret-token-123",
                       "пустой proxyKey не влияет на Authorization")
    }

    @objc func testMakeRequestNilForBrokenBaseURL() throws {
        let prepared = BatchRequestBuilder.makeRequest(
            provider: makeBatchProvider(baseURL: "ht tp://bad url"),
            apiKey: "secret-token-123",
            language: "ru",
            timeout: 60,
            wav: Data("RIFF".utf8),
            chunkIndex: 0
        )
        XCTAssertNil(prepared, "битый base_url — запрос собраться не должен")
    }

    @objc func testMakeRequestIncludesProviderFieldsInMultipart() throws {
        guard let prepared = BatchRequestBuilder.makeRequest(
            provider: makeBatchProvider(),
            apiKey: "secret-token-123",
            language: "ru",
            timeout: 60,
            wav: Data("RIFFWAVEfmt data".utf8),
            chunkIndex: 2
        ) else {
            XCTFail("запрос с валидным base_url должен собраться")
            return
        }
        let body = String(data: prepared.request.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("name=\"file\"; filename=\"segment-3.wav\""),
                      "поле file с именем segment-<index+1>.wav")
        XCTAssertTrue(body.contains("name=\"model\"\r\n\r\ngigaam-v2"),
                      "model провайдера попадает в мультипарт")
        XCTAssertTrue(body.contains("name=\"language\"\r\n\r\nru"),
                      "language попадает в мультипарт")
    }

    @objc func testMakeRequestAppendsStableFieldsForBatchParams() throws {
        // Пакетный путь (gigaam = openAICompatible): batchParams → prompt +
        // temperature=0 добавляются в мультипарт; vad_filter не шлётся
        // (гейтинг: только groq).
        guard let prepared = BatchRequestBuilder.makeRequest(
            provider: makeBatchProvider(),
            apiKey: "secret",
            language: "ru",
            timeout: 60,
            wav: Data("RIFFWAVEfmt data".utf8),
            chunkIndex: 2,
            batchParams: BatchSTTParams(prompt: "хвост предыдущего чанка")
        ) else {
            XCTFail("запрос с валидным base_url должен собраться")
            return
        }
        let body = String(data: prepared.request.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\nхвост предыдущего чанка"),
                      "prompt chaining попадает в мультипарт")
        XCTAssertTrue(body.contains("name=\"temperature\"\r\n\r\n0"),
                      "temperature=0 шлётся (стабильная транскрибация)")
        XCTAssertFalse(body.contains("vad_filter"),
                       "gigaam/openAICompatible — vad_filter не шлётся (только groq)")
        XCTAssertFalse(body.contains("no_speech_threshold"),
                       "whisper-пороги не шлются никому из текущих провайдеров")
    }

    @objc func testMakeRequestWithoutBatchParamsHasNoStableFields() throws {
        // Legacy-путь без batchParams: тело запроса байт-в-байт как раньше —
        // никаких temperature/vad_filter/порогов.
        guard let prepared = BatchRequestBuilder.makeRequest(
            provider: makeBatchProvider(),
            apiKey: "secret",
            language: "ru",
            timeout: 60,
            wav: Data("RIFFWAVEfmt data".utf8),
            chunkIndex: 2
        ) else {
            XCTFail("запрос с валидным base_url должен собраться")
            return
        }
        let body = String(data: prepared.request.httpBody ?? Data(), encoding: .utf8) ?? ""
        XCTAssertFalse(body.contains("temperature"), "без batchParams temperature не добавляется")
        XCTAssertFalse(body.contains("vad_filter"))
        XCTAssertFalse(body.contains("no_speech_threshold"))
        XCTAssertFalse(body.contains("prompt"))
    }

    // MARK: Parallel mode (maxConcurrent > 1)

    @objc func testRunParallelDefaultIsSequential() throws {
        // maxConcurrent default = 1 → order always [0,1,2,3] even if chunk 0 has delay
        let samples = tone(8, sampleRate: 1000)
        let order = OrderRecorder()
        let outcome = try runAsync {
            try await BatchTranscriber.run(
                samples: samples, sampleRate: 1000, maxSegment: 2, overlap: 0.5,
                providerID: "gigaam", sourceFile: "x.wav",
                sendOne: { _, _, index, _ in
                    if index == 0 { try await Task.sleep(nanoseconds: 30_000_000) }
                    order.record(index)
                    return "text \(index)"
                },
                delay: { _ in try await self.instantDelay(0) }
            )
        }
        XCTAssertEqual(outcome.okCount, 4)
        XCTAssertEqual(order.snapshot(), [0, 1, 2, 3],
                       "sequential: chunk 0 sleeps 30ms but order is still 0,1,2,3")
    }

    @objc func testRunParallelResultsIdenticalToSequential() throws {
        let samples = tone(8, sampleRate: 1000)
        let send: BatchTranscriber.SendOne = { _, _, index, _ in "текст \(index)" }

        let seq = try runAsync {
            try await BatchTranscriber.run(
                samples: samples, sampleRate: 1000, maxSegment: 2, overlap: 0.5,
                providerID: "gigaam", sourceFile: "x.wav",
                sendOne: send,
                delay: { _ in try await self.instantDelay(0) }, maxConcurrent: 1
            )
        }
        let par = try runAsync {
            try await BatchTranscriber.run(
                samples: samples, sampleRate: 1000, maxSegment: 2, overlap: 0.5,
                providerID: "gigaam", sourceFile: "x.wav",
                sendOne: send,
                delay: { _ in try await self.instantDelay(0) }, maxConcurrent: 2
            )
        }
        XCTAssertEqual(seq.text, par.text, "parallel и sequential дают одинаковый текст")
        XCTAssertEqual(seq.okCount, par.okCount)
    }

    @objc func testRunParallelCheckpointResume() throws {
        let samples = tone(8, sampleRate: 1000)
        let path = tempCheckpointPath("par-resume")
        defer { try? FileManager.default.removeItem(atPath: path) }

        // First run: parallel (maxConcurrent=2), writes checkpoint.
        let first = try runAsync {
            try await BatchTranscriber.run(
                samples: samples, sampleRate: 1000, maxSegment: 2, overlap: 0.5,
                providerID: "gigaam", sourceFile: "x.wav",
                checkpointPath: path, sendOne: { _, _, index, _ in "p \(index)" },
                delay: { _ in try await self.instantDelay(0) }, maxConcurrent: 2
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(first.text, "p 0 p 1 p 2 p 3")

        // Resume: maxConcurrent=2, sendOne NOT called.
        var resumedCalls = 0
        let second = try runAsync {
            try await BatchTranscriber.run(
                samples: samples, sampleRate: 1000, maxSegment: 2, overlap: 0.5,
                providerID: "gigaam", sourceFile: "x.wav",
                checkpointPath: path, resume: true,
                sendOne: { _, _, index, _ in resumedCalls += 1; return "FAIL \(index)" },
                delay: { _ in try await self.instantDelay(0) }, maxConcurrent: 2
            )
        }
        XCTAssertEqual(resumedCalls, 0, "resume с parallel — sendOne не вызывается")
        XCTAssertEqual(second.text, first.text)
    }

    @objc func testRunParallelResumePartialCheckpoint() throws {
        // Чекпоинт с ЧАСТИЧНЫМ префиксом (3 из 4 разрешены): resume в parallel
        // идёт не по раннему выходу (completedCount == total), а по
        // seeded-слотам с остатком работы — воркер распознаёт только
        // недостающий чанк и дописывает префикс до конца.
        let path = tempCheckpointPath("par-resume-partial")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let seeded: [BatchSegmentRecord] = (0..<3).map {
            BatchSegmentRecord(index: $0, bodyStart: Double($0), bodyEnd: Double($0) + 1,
                               status: BatchSegmentRecord.statusOK, text: "p \($0)")
        }
        let partial = BatchCheckpoint(
            version: BatchCheckpoint.currentVersion,
            providerID: "gigaam", sourceFile: "x.wav",
            totalSegments: 4, segments: seeded
        )
        try BatchTranscriber.saveCheckpoint(partial, to: path)

        let samples = tone(8, sampleRate: 1000)
        var resumedCalls: [Int] = []
        let lock = NSLock()
        let outcome = try runAsync {
            try await BatchTranscriber.run(
                samples: samples, sampleRate: 1000, maxSegment: 2, overlap: 0.5,
                providerID: "gigaam", sourceFile: "x.wav",
                checkpointPath: path, resume: true,
                sendOne: { _, _, index, _ in
                    lock.lock(); resumedCalls.append(index); lock.unlock()
                    return "p \(index)"
                },
                delay: { _ in try await self.instantDelay(0) }, maxConcurrent: 2
            )
        }
        XCTAssertEqual(outcome.okCount, 4)
        XCTAssertEqual(resumedCalls, [3],
                       "resume частичного чекпоинта — дослышается только недостающий чанк 3")
        XCTAssertEqual(outcome.text, "p 0 p 1 p 2 p 3")

        // После досылки чекпоинт дописан до полного префикса.
        let full = try BatchTranscriber.loadCheckpoint(from: path)
        XCTAssertEqual(full?.segments.count, 4, "чекпоинт дописан до полного префикса")
        XCTAssertEqual(full?.segments.map { $0.index }, [0, 1, 2, 3])
    }

    @objc func testCheckpointWriterGuardsStalePrefix() throws {
        // Сердце фикса: надежда на то, что МЕНЬШИЙ префикс не перезапишет
        // уже сохранённый БОЛЬШИЙ (это и ломалось гонкой rename'ов).
        // Тест детерминирован — без параллелизма, напрямую на классе.
        let path = tempCheckpointPath("par-ck-writer")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let writer = CheckpointWriter()
        let save: (BatchCheckpoint, String) throws -> Void = { cp, p in
            try BatchTranscriber.saveCheckpoint(cp, to: p)
        }
        let make: (Int) -> BatchCheckpoint = { end in
            BatchCheckpoint(
                version: BatchCheckpoint.currentVersion,
                providerID: "gigaam", sourceFile: "x.wav",
                totalSegments: 4,
                segments: (0..<end).map {
                    BatchSegmentRecord(index: $0, bodyStart: Double($0), bodyEnd: Double($0) + 1,
                                       status: BatchSegmentRecord.statusOK, text: "t \($0)")
                }
            )
        }

        writer.saveIfLonger(end: 3, path: path, saveCheckpoint: save, makeCheckpoint: make)
        var cp = try BatchTranscriber.loadCheckpoint(from: path)
        XCTAssertEqual(cp?.segments.count, 3, "первый префикс сохраняется")

        // Устаревший (меньший) префикс приходит позже — должен быть пропущен.
        writer.saveIfLonger(end: 2, path: path, saveCheckpoint: save, makeCheckpoint: make)
        cp = try BatchTranscriber.loadCheckpoint(from: path)
        XCTAssertEqual(cp?.segments.count, 3,
                       "устаревший меньший префикс не должен перезаписывать больший")

        // Равный префикс — тоже не нужна перезапись (можно: guard end > savedEnd).
        writer.saveIfLonger(end: 3, path: path, saveCheckpoint: save, makeCheckpoint: make)
        cp = try BatchTranscriber.loadCheckpoint(from: path)
        XCTAssertEqual(cp?.segments.count, 3)

        // Новый бОльший префикс — сохраняется и растёт файл.
        writer.saveIfLonger(end: 4, path: path, saveCheckpoint: save, makeCheckpoint: make)
        cp = try BatchTranscriber.loadCheckpoint(from: path)
        XCTAssertEqual(cp?.segments.count, 4, "бОльший префикс дописывает файл")
        XCTAssertEqual(cp?.segments.map { $0.index }, [0, 1, 2, 3])
    }

    @objc func testRunFileURLStreaming() throws {
        let sr = 1000
        let samples = tone(4, sampleRate: sr)
        let wavData = WAVEncoder.encode(samples: samples, sampleRate: sr)

        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("dct-test-stream-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tmpURL) }
        try wavData.write(to: tmpURL)

        let outcome = try runAsync {
            try await BatchTranscriber.run(
                fileURL: tmpURL,
                maxSegment: 2,
                overlap: 0.5,
                providerID: "gigaam",
                sourceFile: "input.wav",
                sendOne: { _, _, index, _ in "chunk \(index)" },
                delay: { _ in try await self.instantDelay(0) }
            )
        }
        XCTAssertEqual(outcome.okCount, 2, "4s файл / 2s чанки = 2 чанка")
        XCTAssertEqual(outcome.text, "chunk 0 chunk 1")
    }
}

/// Коробка для передачи результата async в синхронный тест.
final class ResultBox<T> {
    var value: T?
    var error: Error?
}

/// Счётчик для конкурентных замыканий (прямая мутация захваченного `var`
/// из `Task { }` запрещена компилятором как гонка).
final class AttemptBox {
    var value = 0
}

/// Thread-safe recorder of chunk indices (для проверки порядка в parallel).
final class OrderRecorder {
    private var items: [Int] = []
    private let lock = NSLock()
    func record(_ index: Int) {
        lock.lock()
        items.append(index)
        lock.unlock()
    }
    func snapshot() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return items
    }
}