import Foundation
@testable import NanoDictateCore

/// Latch for exactly one synthetic Enter after insert ("Enter stops recording"):
/// arm (in .recording), consume once (post point), cancel on Esc / empty / STT error.
final class EnterSendLatchTests: XCTestCase {

    @objc func testArmThenConsumeReturnsTrueOnce() {
        let latch = EnterSendLatch()
        latch.arm()
        XCTAssertTrue(latch.isPending)
        XCTAssertTrue(latch.consume())
        XCTAssertFalse(latch.isPending)
        XCTAssertFalse(latch.consume())
    }

    @objc func testRepeatedArmStillSingleConsume() {
        let latch = EnterSendLatch()
        latch.arm()
        latch.arm()
        latch.arm()
        XCTAssertTrue(latch.consume())
        XCTAssertFalse(latch.consume())
    }

    @objc func testConsumeWithoutArmIsFalse() {
        let latch = EnterSendLatch()
        XCTAssertFalse(latch.isPending)
        XCTAssertFalse(latch.consume())
    }

    @objc func testCancelClearsPending() {
        let latch = EnterSendLatch()
        latch.arm()
        latch.cancel()
        XCTAssertFalse(latch.isPending)
        XCTAssertFalse(latch.consume())
    }

    @objc func testCancelIsIdempotent() {
        let latch = EnterSendLatch()
        latch.cancel()
        latch.cancel()
        XCTAssertFalse(latch.isPending)
        XCTAssertFalse(latch.consume())
    }

    @objc func testArmAfterCancelWorksAgain() {
        let latch = EnterSendLatch()
        latch.arm()
        latch.cancel()
        latch.arm()
        XCTAssertTrue(latch.consume())
        XCTAssertFalse(latch.consume())
    }

    /// Arm/consume order-independent: dead after a successful consume until re-armed.
    @objc func testConsumeIsOneShotAcrossCycles() {
        let latch = EnterSendLatch()
        latch.arm()
        _ = latch.consume()
        _ = latch.consume()
        latch.arm()
        XCTAssertTrue(latch.consume())
        XCTAssertFalse(latch.consume())
    }
}