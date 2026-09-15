import Foundation
@testable import DictationCore

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

    private func tone(_ seconds: Double, sampleRate: Int, value: Int16 = 100) -> [Int16] {
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
                sendOne: { attempt, wav, index in
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

    @objc func testRunEmptySamplesNoCalls() throws {
        var calls = 0
        let outcome = try runAsync {
            try await BatchTranscriber.run(
                samples: [],
                sampleRate: 16000,
                providerID: "gigaam",
                sourceFile: "x.wav",
                sendOne: { _, _, _ in calls += 1; return "nope" },
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
                sendOne: { _, _, index in
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
                sendOne: { _, _, index in "текст \(index)" },
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
                sendOne: { _, _, index in firstCalls += 1; return "текст \(index)" },
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
                sendOne: { _, _, index in resumedCalls += 1; return "НЕ ДОЛЖЕН ВЫЗЫВАТЬСЯ" },
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
                sendOne: { _, _, index in "a \(index)" },
                delay: { _ in try await self.instantDelay(0) }
            )
        }
        var calls = 0
        let outcome = try runAsync {
            try await BatchTranscriber.run(
                samples: samples, sampleRate: 1000, maxSegment: 2, overlap: 0.5,
                providerID: "gigaam", sourceFile: "x.wav",
                checkpointPath: path, resume: true,
                sendOne: { _, _, index in calls += 1; return "b \(index)" },
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
                sendOne: { _, _, index in
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
                sendOne: { _, _, index in "старый \(index)" },
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
                sendOne: { _, _, index in calls += 1; return "новый \(index)" },
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