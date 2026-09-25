import Foundation
@testable import NanoDictateCore

/// Mic error cooldown: first always allowed, repeats within interval suppressed,
/// after the interval — allowed again.
final class MicErrorCooldownTests: XCTestCase {

    /// First call allowed even at 0.0: sentinel zero must not eat next tap (cf. DoubleAltDetector).
    @objc func testFirstCallAlwaysAllowed() {
        var cooldown = MicErrorCooldown(interval: 3.0)
        XCTAssertTrue(cooldown.allow(at: 0))
    }

    @objc func testSecondWithinIntervalIsSuppressed() {
        var cooldown = MicErrorCooldown(interval: 3.0)
        XCTAssertTrue(cooldown.allow(at: 100))
        XCTAssertFalse(cooldown.allow(at: 100.5))
        XCTAssertFalse(cooldown.allow(at: 102.999))
    }

    /// Event exactly at the interval boundary is allowed (Double tolerance).
    @objc func testExactlyAtIntervalIsAllowed() {
        var cooldown = MicErrorCooldown(interval: 3.0)
        XCTAssertTrue(cooldown.allow(at: 100))
        XCTAssertTrue(cooldown.allow(at: 103))
    }

    @objc func testAfterIntervalIsAllowedAndResets() {
        var cooldown = MicErrorCooldown(interval: 3.0)
        XCTAssertTrue(cooldown.allow(at: 100))
        XCTAssertTrue(cooldown.allow(at: 103.5))
        XCTAssertFalse(cooldown.allow(at: 104))
        XCTAssertTrue(cooldown.allow(at: 106.5))
    }

    /// Suppressed calls do not shift last-show: rapid Alt+Alt must not stretch the window.
    @objc func testSuppressedCallsDoNotExtendWindow() {
        var cooldown = MicErrorCooldown(interval: 3.0)
        XCTAssertTrue(cooldown.allow(at: 10))
        _ = cooldown.allow(at: 10.1)
        _ = cooldown.allow(at: 10.2)
        XCTAssertTrue(cooldown.allow(at: 13))
    }
}