import Foundation
@testable import NanoDictateCore

// MARK: - Маршрутизация [routing] по ролям в агентных путях
//
// Ревью (итерация маршрутизации): offline-чанковый путь processChunked отдавал
// ОДНО stt-замыкание (роль segment) и для сегментов, и для финального прохода
// по всему WAV — большой финальный проход должен уходить на final_provider.
// ChunkedPipeline вызывает stt с различимым filename: сегменты "segment-N.wav",
// финальный проход "final.wav" (ChunkedPipeline.swift finalize) — замыкание
// обязано выбирать роль по этому признаку.
//
// Логика приватная и живёт в executable-таргете NanoDictateAgent (тест-таргет
// зависит только от NanoDictateCore), поэтому тестируется структурно — по
// исходнику Sources/NanoDictateAgent/main.swift (тот же приём, что в
// LiveSegmentFailureTests).

final class RoutingRoleTests: XCTestCase {

    /// processChunked: сегменты (filename "segment-N.wav") — роль segment
    /// (segmentRoleProviderID), финальный проход (filename "final.wav") —
    /// роль final (finalRoleProviderID). Обе ветки фолбэчат на активный
    /// transcriber (`?? self.transcriber`) — без [routing] поведение
    /// байт-в-байт прежнее.
    @objc func testProcessChunked_FinalPassUsesFinalRole() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        let body = Self.functionBody(named: "processChunked", in: source)
        XCTAssertFalse(body.isEmpty, "processChunked должна существовать")
        XCTAssertTrue(
            body.contains("filename == \"final.wav\""),
            "stt-замыкание обязано различать финальный проход по filename"
        )
        XCTAssertTrue(
            body.contains("self.roleTranscriber(self.finalRoleProviderID)"),
            "финальный проход по всему WAV идёт ролью final"
        )
        XCTAssertTrue(
            body.contains("self.roleTranscriber(self.segmentRoleProviderID)"),
            "сегменты идут ролью segment"
        )
        // Фолбэк без [routing]/совпадающей роли — активный transcriber (прежнее
        // поведение), failover на ролях не поднимается.
        XCTAssertEqual(
            body.components(separatedBy: "?? self.transcriber").count - 1, 2,
            "обе ветки ролей фолбэчат на активный transcriber"
        )
    }

    /// live-путь уже был корректен (ревью): сегменты — роль segment,
    /// финальный проход — роль final; страхуем от регресса.
    @objc func testLivePathRoles() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        let segmentBody = Self.functionBody(named: "handleLiveSegment", in: source)
        XCTAssertTrue(
            segmentBody.contains("self.roleTranscriber(self.segmentRoleProviderID)"),
            "live-сегменты обязаны идти ролью segment"
        )
        let finalBody = Self.functionBody(named: "finishLiveRun", in: source)
        XCTAssertTrue(
            finalBody.contains("self.roleTranscriber(self.finalRoleProviderID)"),
            "live-финализация обязана идти ролью final"
        )
    }

    // MARK: - Helpers (зеркало LiveSegmentFailureTests)

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
        if let end = tail.range(of: "\n  private func ") {
            return String(tail[..<end.lowerBound])
        }
        if let end = tail.range(of: "\n  // MARK: ") {
            return String(tail[..<end.lowerBound])
        }
        return String(tail)
    }
}