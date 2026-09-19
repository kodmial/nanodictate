import Foundation
@testable import NanoDictateCore

// MARK: - Маршрутизация [routing] по ролям в агентных путях
//
// Routing review: processChunked gave segments AND final whole-WAV pass the
// same stt closure (segment role); final pass must go to final_provider.
// ChunkedPipeline marks passes by filename ("segment-N.wav" / "final.wav").
// Role logic is private to executable NanoDictateAgent (tests reach only Core),
// so we assert structurally on main.swift source (same as LiveSegmentFailureTests).

final class RoutingRoleTests: XCTestCase {

    /// Filename picks role (segment/final); both branches fall back to active
    /// transcriber — same behavior without [routing].
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
        // Both branches fall back to active transcriber; no failover on roles.
        XCTAssertEqual(
            body.components(separatedBy: "?? self.transcriber").count - 1, 2,
            "обе ветки ролей фолбэчат на активный transcriber"
        )
    }

    /// Live-path roles were already correct post-review; guard regression.
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

    /// Body from "func NAME(" to next top-level func/MARK; empty if missing.
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