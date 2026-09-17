import Foundation
@testable import NanoDictateCore

/// Cooldown микрофонных ошибок: первый показ всегда разрешён, повторные
/// в пределах интервала подавляются, по истечении интервала — снова разрешены.
final class MicErrorCooldownTests: XCTestCase {

    /// Первый вызов всегда разрешён — даже в момент 0.0 (sentinel-ноль не
    /// должен «съедать» следующий тап, ср. DoubleAltDetector).
    @objc func testFirstCallAlwaysAllowed() {
        var cooldown = MicErrorCooldown(interval: 3.0)
        XCTAssertTrue(cooldown.allow(at: 0))
    }

    /// Повторный вызов в пределах интервала подавляется и не меняет состояние.
    @objc func testSecondWithinIntervalIsSuppressed() {
        var cooldown = MicErrorCooldown(interval: 3.0)
        XCTAssertTrue(cooldown.allow(at: 100))
        XCTAssertFalse(cooldown.allow(at: 100.5))
        XCTAssertFalse(cooldown.allow(at: 102.999))
    }

    /// Событие ровно на границе интервала разрешено (допуск на Double).
    @objc func testExactlyAtIntervalIsAllowed() {
        var cooldown = MicErrorCooldown(interval: 3.0)
        XCTAssertTrue(cooldown.allow(at: 100))
        XCTAssertTrue(cooldown.allow(at: 103))
    }

    /// После истечения интервала событие снова разрешено и интервал
    /// отсчитывается заново от этого момента.
    @objc func testAfterIntervalIsAllowedAndResets() {
        var cooldown = MicErrorCooldown(interval: 3.0)
        XCTAssertTrue(cooldown.allow(at: 100))
        XCTAssertTrue(cooldown.allow(at: 103.5))
        XCTAssertFalse(cooldown.allow(at: 104))   // 0.5 с < 3 с от 103.5
        XCTAssertTrue(cooldown.allow(at: 106.5))  // 3 с прошло
    }

    /// Подавленные вызовы НЕ сдвигают «последний показ»: частые Alt+Alt не
    /// растягивают окно подавления бесконечно.
    @objc func testSuppressedCallsDoNotExtendWindow() {
        var cooldown = MicErrorCooldown(interval: 3.0)
        XCTAssertTrue(cooldown.allow(at: 10))
        _ = cooldown.allow(at: 10.1) // подавлен
        _ = cooldown.allow(at: 10.2) // подавлен
        XCTAssertTrue(cooldown.allow(at: 13)) // ровно 3 с от 10.0 — разрешено
    }
}