import Foundation
@testable import DictationCore

// MARK: - DebugDumpTests

/// Тесты отладочного дампа STT-запросов (включается при log_level == "debug").
final class DebugDumpTests: XCTestCase {

    private var tempDirs: [String] = []
    private var savedDirectory = ""
    private var savedFileName = ""
    private var savedRecordingsDir = ""

    override func setUp() {
        super.setUp()
        savedDirectory = DebugDump.dumpDirectory
        savedFileName = DebugDump.dumpFileName
        savedRecordingsDir = DebugDump.recordingsDirectory
    }

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(atPath: dir)
        }
        tempDirs = []
        DebugDump.dumpDirectory = savedDirectory
        DebugDump.dumpFileName = savedFileName
        DebugDump.recordingsDirectory = savedRecordingsDir
        super.tearDown()
    }

    /// Создаёт временный каталог и направляет туда запись дампа.
    private func redirectDumpToTempDir() -> String {
        let dir = NSTemporaryDirectory() + "dictation-debug-test-\(UUID().uuidString)"
        tempDirs.append(dir)
        DebugDump.dumpDirectory = dir
        return dir
    }

    /// Создаёт временный каталог и направляет туда сохранение аудиозаписей.
    private func redirectRecordingsToTempDir() -> String {
        let dir = NSTemporaryDirectory() + "dictation-recordings-test-\(UUID().uuidString)"
        tempDirs.append(dir)
        DebugDump.recordingsDirectory = dir
        return dir
    }

    private func readDebugLog(in dir: String) -> String? {
        try? String(
            contentsOf: URL(fileURLWithPath: dir).appendingPathComponent("transcriber-debug.log"),
            encoding: .utf8
        )
    }

    /// Прогоняет async-замыкание до завершения внутри синхронного теста.
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

    // MARK: - 1. Маскировка секретов

    @objc func testHeadersAndNestedSecretsAreMasked() {
        let entry = DebugDump.summarize(
            timestamp: Date(timeIntervalSince1970: 0),
            method: "POST",
            url: "https://stt.example/v1/audio/transcriptions",
            headers: [
                (name: "Authorization", value: "Bearer super-secret-token"),
                (name: "X-Proxy-Key", value: "proxy-secret-value"),
                (name: "Content-Type", value: "multipart/form-data; boundary=x")
            ],
            fields: [],
            filePart: nil,
            status: 200,
            responseBody: Data(#"{"text":"ok","api_key":"nested-secret"}"#.utf8)
        )

        XCTAssertTrue(entry.contains("Authorization: Bearer ***"))
        XCTAssertTrue(entry.contains("X-Proxy-Key: ***"))
        XCTAssertTrue(entry.contains("\"api_key\": \"***\""))
        XCTAssertFalse(entry.contains("super-secret-token"), "Authorization не должен светиться")
        XCTAssertFalse(entry.contains("proxy-secret-value"), "X-Proxy-Key не должен светиться")
        XCTAssertFalse(entry.contains("nested-secret"), "вложенный api_key не должен светиться")
    }

    // MARK: - 2. Полнота: поля, file-парт, тело ответа

    @objc func testDumpContainsFieldsFilePartAndResponseBody() {
        let body = #"{"text":"привет мир","usage":{"seconds":1.2}}"#
        let entry = DebugDump.summarize(
            timestamp: Date(timeIntervalSince1970: 0),
            method: "POST",
            url: "https://stt.example/v1/audio/transcriptions",
            headers: [(name: "Content-Type", value: "multipart/form-data; boundary=b1")],
            fields: [
                (name: "model", value: "gigaam-v3"),
                (name: "language", value: "ru")
            ],
            filePart: DebugDump.FilePart(
                fieldName: "file", filename: "audio.wav", contentType: "audio/wav", byteCount: 4096
            ),
            status: 200,
            responseBody: Data(body.utf8)
        )

        XCTAssertTrue(entry.contains("POST https://stt.example/v1/audio/transcriptions"))
        XCTAssertTrue(entry.contains("model = gigaam-v3"))
        XCTAssertTrue(entry.contains("language = ru"))
        XCTAssertTrue(entry.contains("name = file"))
        XCTAssertTrue(entry.contains("filename = audio.wav"))
        XCTAssertTrue(entry.contains("content-type = audio/wav"))
        XCTAssertTrue(entry.contains("size = 4096 bytes"))
        XCTAssertTrue(entry.contains("HTTP 200"))
        XCTAssertTrue(entry.contains(body), "тело ответа должно присутствовать целиком")
    }

    // MARK: - 3. Уровень логирования и запись в файл

    @objc func testAppendWritesToDebugFile() {
        let dir = redirectDumpToTempDir()
        DebugDump.append(entry: "first record\n")

        let content = readDebugLog(in: dir)
        XCTAssertNotNil(content, "файл дампа должен быть создан")
        XCTAssertTrue(content!.contains("first record"))
    }

    @objc func testNonDebugLevelDoesNotWriteDumpFile() {
        let dir = redirectDumpToTempDir()
        let transport = MockTransport(status: 200, body: Data(#"{"text":"ok"}"#.utf8))
        let transcriber = Transcriber(
            baseURL: "https://example.test/v1/audio/transcriptions",
            model: "gigaam-v3",
            apiKey: "k",
            logLevel: "info",
            transport: transport
        )

        runAsync("transcribeInfo") {
            _ = try await transcriber.transcribe(wav: Data([0x52, 0x49, 0x46, 0x46]))
        }

        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: dir).appendingPathComponent("transcriber-debug.log").path
            ),
            "при log_level != debug файла дампа быть не должно"
        )
    }

    @objc func testDebugLevelWritesDumpEndToEnd() {
        let dir = redirectDumpToTempDir()
        let transport = MockTransport(status: 200, body: Data(#"{"text":"привет"}"#.utf8))
        let transcriber = Transcriber(
            baseURL: "https://example.test/v1/audio/transcriptions",
            model: "gigaam-v3",
            apiKey: "secret-key",
            proxyKey: "proxy-key-123",
            logLevel: "debug",
            transport: transport
        )

        runAsync("transcribeDebug") {
            _ = try await transcriber.transcribe(wav: Data([0x52, 0x49, 0x46, 0x46]))
        }

        guard let content = readDebugLog(in: dir) else {
            XCTFail("при log_level == debug файл дампа должен создаваться")
            return
        }
        XCTAssertTrue(content.contains("POST https://example.test/v1/audio/transcriptions"))
        XCTAssertTrue(content.contains("Authorization: Bearer ***"))
        XCTAssertTrue(content.contains("X-Proxy-Key: ***"))
        XCTAssertTrue(content.contains("model = gigaam-v3"))
        XCTAssertTrue(content.contains("language = ru"))
        XCTAssertTrue(content.contains("filename = audio.wav"))
        XCTAssertTrue(content.contains("size = 4 bytes"))
        XCTAssertTrue(content.contains("HTTP 200"))
        XCTAssertTrue(content.contains("привет"))
        XCTAssertFalse(content.contains("secret-key"), "api key не должен попасть в дамп")
        XCTAssertFalse(content.contains("proxy-key-123"), "proxy key не должен попасть в дамп")
    }

    // MARK: - 4. Битые/пустые данные не крашат

    @objc func testEmptyAndBrokenDataDoNotCrash() {
        let empty = DebugDump.summarize(
            method: "",
            url: "",
            headers: [],
            fields: [],
            filePart: nil,
            status: 0,
            responseBody: Data()
        )
        XCTAssertFalse(empty.isEmpty)
        XCTAssertTrue(empty.contains("Multipart fields:"))

        let binary = DebugDump.summarize(
            method: "POST",
            url: "https://x",
            headers: [(name: "Authorization", value: "Bearer k")],
            fields: [],
            filePart: nil,
            status: 500,
            responseBody: Data([0xFF, 0xFE, 0x00, 0x01])
        )
        XCTAssertTrue(binary.contains("HTTP 500"))
        XCTAssertTrue(binary.contains("Authorization: Bearer ***"))

        // Некорректный / неписабельный каталог — не должно быть ни краха, ни исключения.
        DebugDump.dumpDirectory = "/nonexistent-debug-\(UUID().uuidString)/logs"
        DebugDump.append(entry: "no crash")
    }

    // MARK: - 5. Сохранение самих аудиозаписей (WAV) при log_level == "debug"

    @objc func testDebugLevelSavesAudioFileWithMatchingBytes() {
        let recordingsDir = redirectRecordingsToTempDir()
        let wav = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x01, 0x02, 0x03])
        let transport = MockTransport(status: 200, body: Data(#"{"text":"ok"}"#.utf8))
        let transcriber = Transcriber(
            baseURL: "https://example.test/v1/audio/transcriptions",
            model: "gigaam-v3",
            apiKey: "k",
            logLevel: "debug",
            transport: transport
        )

        runAsync("transcribeDebugSavesAudio") {
            _ = try await transcriber.transcribe(wav: wav)
        }

        let files = (try? FileManager.default.contentsOfDirectory(atPath: recordingsDir)) ?? []
        let wavFiles = files.filter { $0.hasSuffix(".wav") }
        XCTAssertEqual(wavFiles.count, 1, "при debug должна сохраниться ровно одна аудиозапись")
        XCTAssertTrue(
            wavFiles[0].hasPrefix("recording-"),
            "имя файла должно начинаться с recording-: \(wavFiles[0])"
        )
        guard wavFiles.count == 1 else { return }
        let saved = try? Data(contentsOf: URL(fileURLWithPath: recordingsDir).appendingPathComponent(wavFiles[0]))
        XCTAssertEqual(saved, wav, "байты сохранённой записи должны совпадать с исходным WAV")
    }

    @objc func testNonDebugLevelDoesNotSaveAudioFile() {
        let recordingsDir = redirectRecordingsToTempDir()
        let transport = MockTransport(status: 200, body: Data(#"{"text":"ok"}"#.utf8))
        let transcriber = Transcriber(
            baseURL: "https://example.test/v1/audio/transcriptions",
            model: "gigaam-v3",
            apiKey: "k",
            logLevel: "info",
            transport: transport
        )

        runAsync("transcribeInfoNoAudio") {
            _ = try await transcriber.transcribe(wav: Data([0x52, 0x49, 0x46, 0x46]))
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: recordingsDir),
            "при log_level != debug каталога записей быть не должно"
        )
    }

    @objc func testDumpContainsRecordingPathAndSize() {
        let dumpDir = redirectDumpToTempDir()
        let recordingsDir = redirectRecordingsToTempDir()
        let wav = Data([0x52, 0x49, 0x46, 0x46])
        let transport = MockTransport(status: 200, body: Data(#"{"text":"ок"}"#.utf8))
        let transcriber = Transcriber(
            baseURL: "https://example.test/v1/audio/transcriptions",
            model: "gigaam-v3",
            apiKey: "k",
            logLevel: "debug",
            transport: transport
        )

        runAsync("transcribeDebugDumpRecording") {
            _ = try await transcriber.transcribe(wav: wav)
        }

        guard let content = readDebugLog(in: dumpDir) else {
            XCTFail("файл дампа должен создаваться")
            return
        }
        XCTAssertTrue(content.contains("Saved audio:"), "дамп должен содержать блок Saved audio")
        XCTAssertTrue(content.contains(recordingsDir), "дамп должен содержать каталог аудиозаписи")
        XCTAssertTrue(content.contains("size = 4 bytes"), "дамп должен содержать размер аудиозаписи")
    }

    @objc func testUnwritableRecordingsDirectoryDoesNotThrow() {
        // Каталог записей — путь, который невозможно создать: родитель — обычный файл.
        let blocker = NSTemporaryDirectory() + "dictation-blocked-\(UUID().uuidString)"
        try? Data("x".utf8).write(to: URL(fileURLWithPath: blocker))
        tempDirs.append(blocker)
        DebugDump.recordingsDirectory = blocker + "/recordings"

        let dumpDir = redirectDumpToTempDir()
        let transport = MockTransport(status: 200, body: Data(#"{"text":"ok"}"#.utf8))
        let transcriber = Transcriber(
            baseURL: "https://example.test/v1/audio/transcriptions",
            model: "gigaam-v3",
            apiKey: "k",
            logLevel: "debug",
            transport: transport
        )

        // runAsync грохает тест, если transcribe бросит исключение.
        runAsync("transcribeDebugUnwritableDir") {
            _ = try await transcriber.transcribe(wav: Data([0x52, 0x49, 0x46, 0x46]))
        }

        // Дамп при этом пишется как обычно.
        XCTAssertNotNil(readDebugLog(in: dumpDir), "неписабильный каталог записей не должен ломать дамп")

        // Прямой вызов враппера с неписабильным путём тоже не бросает.
        DebugDump.saveRecording(data: Data([0x01, 0x02]), to: blocker + "/recordings/x.wav")
    }
}