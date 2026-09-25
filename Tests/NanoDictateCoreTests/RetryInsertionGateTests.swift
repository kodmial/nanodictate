import Foundation
@testable import NanoDictateCore

final class RetryInsertionGateTests: XCTestCase {

    @objc func testIdleAndCurrentSessionAcceptsRetry() {
        XCTAssertFalse(
            RetryInsertionGate.shouldDropRetry(state: .idle, processingSession: 1, session: 1))
    }

    @objc func testNewCycleFinishedDuringConfirmAsyncDropsRetry() {
        XCTAssertTrue(
            RetryInsertionGate.shouldDropRetry(state: .idle, processingSession: 2, session: 1))
    }

    @objc func testRecordingStateDropsRetry() {
        XCTAssertTrue(
            RetryInsertionGate.shouldDropRetry(state: .recording, processingSession: 1, session: 1))
    }

    @objc func testTranscribingStateDropsRetry() {
        XCTAssertTrue(
            RetryInsertionGate.shouldDropRetry(state: .transcribing, processingSession: 1, session: 1))
    }

    @objc func testRecordingWithAdvancedSessionDropsRetry() {
        XCTAssertTrue(
            RetryInsertionGate.shouldDropRetry(state: .recording, processingSession: 2, session: 1))
    }
}