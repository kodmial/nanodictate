import Foundation
import Foundation
@testable import NanoDictateCore

final class LoggerTests: XCTestCase {

    private var tempDirs: [String] = []

    /// Создаёт временный каталог, направляет туда Logger и запоминает его для очистки.
    private func setUpTempLogDirectory() -> String {
        let dir = NSTemporaryDirectory() + "nanodictate-logger-test-\(UUID().uuidString)"
        Logger.logDirectory = dir
        tempDirs.append(dir)
        return dir
    }

    override func tearDown() {
        for dir in tempDirs {
            try? FileManager.default.removeItem(atPath: dir)
        }
        tempDirs = []
        // Восстанавливаем значение по умолчанию.
        Logger.logDirectory = "~/Library/Logs/NanoDictate"
        super.tearDown()
    }

    @objc func testLogCreatesFileWithMessageAndLevel() throws {
        let dir = setUpTempLogDirectory()

        Logger.log("test message", level: "error")

        let fileURL = URL(fileURLWithPath: dir).appendingPathComponent("agent.log")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "log file должен быть создан")

        let content = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("test message"), "содержимое должно включать сообщение")
        XCTAssertTrue(content.contains("[error]"), "содержимое должно включать уровень")
    }

    @objc func testLogLineMatchesDateFormat() throws {
        let dir = setUpTempLogDirectory()

        Logger.log("date check", level: "info")

        let fileURL = URL(fileURLWithPath: dir).appendingPathComponent("agent.log")
        let content = try String(contentsOf: fileURL, encoding: .utf8)

        // Формат: yyyy-MM-dd HH:mm:ss [level] message
        let pattern = #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \[info\] date check\n$"#
        XCTAssertNotNil(
            content.range(of: pattern, options: .regularExpression),
            "строка должна соответствовать формату yyyy-MM-dd HH:mm:ss [level] message, было: \(content)"
        )
    }

    @objc func testAppendWritesSecondLine() throws {
        let dir = setUpTempLogDirectory()

        Logger.log("first line", level: "info")
        Logger.log("second line", level: "error")

        let fileURL = URL(fileURLWithPath: dir).appendingPathComponent("agent.log")
        let content = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertTrue(content.contains("first line"))
        XCTAssertTrue(content.contains("second line"))

        let lines = content.split(separator: "\n")
        XCTAssertEqual(lines.count, 2, "обе строки должны быть дописаны")
    }

    @objc func testLogDoesNotThrowWithUnwritableDirectory() {
        Logger.logDirectory = "/nonexistent-dir-\(UUID().uuidString)/logs"
        // Не должно быть ни краха, ни исключения.
        Logger.log("no crash", level: "error")
    }
}