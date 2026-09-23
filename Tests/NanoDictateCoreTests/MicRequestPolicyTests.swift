import Foundation
@testable import NanoDictateCore

/// Anti-storm TCC mic-prompt guard (MicRequestPolicy): 3 timeouts in a 6h window
/// block requests; recordGranted resets; corrupt/missing state file = fresh;
/// state persists across instances. Tests write temp files only, never the real
/// user Application Support.
final class MicRequestPolicyTests: XCTestCase {

    /// Unique per-test temp URL: no conflicts, no state leaks to the agent.
    private func tempStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mic-request-policy-\(UUID().uuidString).json")
    }

    /// Fixed "now" for determinism (6h window = 21 600 s).
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    @objc func testAllowBelowThreshold() {
        var policy = MicRequestPolicy(fileURL: tempStateURL())
        XCTAssertTrue(policy.allowRequest(now: t0))
        policy.recordTimeout(now: t0)
        XCTAssertTrue(policy.allowRequest(now: t0.addingTimeInterval(1)))
        policy.recordTimeout(now: t0.addingTimeInterval(1))
        XCTAssertTrue(policy.allowRequest(now: t0.addingTimeInterval(2)))
    }

    /// 3+ timeouts in window block requests while the window is live.
    @objc func testBlockAtAndAfterThreeTimeouts() {
        var policy = MicRequestPolicy(fileURL: tempStateURL())
        for i in 0..<3 {
            policy.recordTimeout(now: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertFalse(policy.allowRequest(now: t0.addingTimeInterval(5)))
        // 4th timeout does not unlock — still within window.
        policy.recordTimeout(now: t0.addingTimeInterval(5))
        XCTAssertFalse(policy.allowRequest(now: t0.addingTimeInterval(6)))
    }

    /// recordGranted fully clears the storm; next request allowed.
    @objc func testRecordGrantedResets() {
        var policy = MicRequestPolicy(fileURL: tempStateURL())
        for i in 0..<3 {
            policy.recordTimeout(now: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertFalse(policy.allowRequest(now: t0.addingTimeInterval(5)))
        policy.recordGranted(now: t0.addingTimeInterval(5))
        XCTAssertTrue(policy.allowRequest(now: t0.addingTimeInterval(6)))
    }

    /// Window expires exactly at 6h; one second before still blocks.
    @objc func testWindowExpiryReallows() {
        var policy = MicRequestPolicy(fileURL: tempStateURL())
        for i in 0..<3 {
            policy.recordTimeout(now: t0.addingTimeInterval(Double(i)))
        }
        let justBefore = t0.addingTimeInterval(MicRequestPolicy.windowDuration - 1)
        XCTAssertFalse(policy.allowRequest(now: justBefore))
        let onBoundary = t0.addingTimeInterval(MicRequestPolicy.windowDuration)
        XCTAssertTrue(policy.allowRequest(now: onBoundary))
    }

    /// Timeout в будущем (часы назад): age < 0 — вне окна, не блокирует,
    /// пока now не догонит отметки; после догонания снова считаются, а по
    /// истечении окна (age >= windowDuration) фильтруются и запрос разрешён.
    @objc func testFutureTimeoutOutsideWindowDoesNotBlock() {
        var policy = MicRequestPolicy(fileURL: tempStateURL())
        let future = t0.addingTimeInterval(600)
        for i in 0..<3 {
            policy.recordTimeout(now: future.addingTimeInterval(Double(i)))
        }
        // now раньше всех отметок: отрицательный age отсекается — не блокируем.
        XCTAssertTrue(policy.allowRequest(now: t0))
        // Часы догнали все три отметки (возраст 2, 1, 0) — блокировка восстановлена.
        XCTAssertFalse(policy.allowRequest(now: future.addingTimeInterval(2)))
        // Возраст всех трёх >= windowDuration — снова вне окна.
        XCTAssertTrue(
            policy.allowRequest(
                now: future.addingTimeInterval(2 + MicRequestPolicy.windowDuration)))
    }

    /// Corrupt state file treated as fresh; guard survives garbage.
    @objc func testCorruptStateFileIsFresh() throws {
        let url = tempStateURL()
        try "не json {{{".data(using: .utf8)!.write(to: url)
        let policy = MicRequestPolicy(fileURL: url)
        XCTAssertTrue(policy.allowRequest(now: t0))
    }

    /// Missing state file also treated as fresh.
    @objc func testMissingStateFileIsFresh() {
        let policy = MicRequestPolicy(fileURL: tempStateURL())
        XCTAssertTrue(policy.allowRequest(now: t0))
    }

    /// State persists across instances: agent restart does not clear storm.
    @objc func testPersistenceAcrossInstances() {
        let url = tempStateURL()
        var first = MicRequestPolicy(fileURL: url)
        for i in 0..<3 {
            first.recordTimeout(now: t0.addingTimeInterval(Double(i)))
        }
        let second = MicRequestPolicy(fileURL: url)
        XCTAssertFalse(second.allowRequest(now: t0.addingTimeInterval(10)))
        // recordGranted also persists: grant in one instance clears storm in new.
        var third = MicRequestPolicy(fileURL: url)
        third.recordGranted(now: t0.addingTimeInterval(10))
        let fourth = MicRequestPolicy(fileURL: url)
        XCTAssertTrue(fourth.allowRequest(now: t0.addingTimeInterval(11)))
    }
}