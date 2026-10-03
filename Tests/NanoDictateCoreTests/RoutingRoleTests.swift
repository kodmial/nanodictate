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

    /// Realtime providers never run the chunked/live pipeline: one stateful
    /// session per dictation via processSingleRequest, not one session per
    /// segment plus a final replay.
    @objc func testChunkedRealtimeRoutesThroughSingleRequest() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        XCTAssertTrue(
            source.contains("func chunkedUsesRealtime()"),
            "agent обязан определять realtime-роли для chunked/live"
        )
        let samplesBody = Self.functionBody(named: "processSamples", in: source)
        XCTAssertTrue(
            samplesBody.contains("chunkedUsesRealtime()"),
            "processSamples обязан проверять realtime перед chunked"
        )
        XCTAssertTrue(
            samplesBody.contains("processSingleRequest(samples)"),
            "realtime-запись при chunked обязана идти через processSingleRequest"
        )
        let chunkedBody = Self.functionBody(named: "processChunked", in: source)
        XCTAssertTrue(
            chunkedBody.contains("chunkedUsesRealtime()"),
            "processChunked обязан защищаться от realtime-ролей"
        )
        let liveBody = Self.functionBody(named: "handleLiveSegment", in: source)
        XCTAssertTrue(
            liveBody.contains("chunkedUsesRealtime()"),
            "live-сегменты не должны открывать per-segment realtime-сессии"
        )
    }

    /// Live subscription is skipped for realtime providers: no per-segment
    /// sessions, no live tail buffering for the single-session path.
    @objc func testLiveSubscriptionSkippedForRealtime() {
        guard let source = Self.agentMainSource() else {
            XCTFail("Не удалось прочитать Sources/NanoDictateAgent/main.swift")
            return
        }
        XCTAssertTrue(
            source.contains("if chunked, !chunkedUsesRealtime()"),
            "подписка live-сегментов обязана пропускаться для realtime"
        )
        XCTAssertTrue(
            source.contains("subscribeLiveNanoDictate()"),
            "subscribeLiveNanoDictate обязана существовать для batch"
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