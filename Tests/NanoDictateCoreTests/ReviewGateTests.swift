import Foundation
@testable import NanoDictateCore

final class ReviewGateTests: XCTestCase {

    // MARK: - Helpers

    private func confirmWithInput(_ input: String?) -> ReviewGate.Decision {
        ReviewGate.readLineFunction = { input }
        defer { ReviewGate.readLineFunction = { readLine() } }
        return ReviewGate.confirm(text: "test transcription")
    }

    // MARK: - Accept inputs

    @objc func testEmptyInputInserts() {
        XCTAssertEqual(confirmWithInput(""), .insert)
    }

    @objc func testNewlineInputInserts() {
        XCTAssertEqual(confirmWithInput("\n"), .insert)
    }

    @objc func testYInserts() {
        XCTAssertEqual(confirmWithInput("y"), .insert)
    }

    @objc func testCapitalYInserts() {
        XCTAssertEqual(confirmWithInput("Y"), .insert)
    }

    @objc func testYesStringCancels() {
        // Contract (see ReviewGate): only empty input and y/Y insert; "yes" cancels.
        XCTAssertEqual(confirmWithInput("yes"), .cancel)
    }

    // MARK: - Cancel inputs

    @objc func testEscCancels() {
        XCTAssertEqual(confirmWithInput("esc"), .cancel)
    }

    @objc func testNCancels() {
        XCTAssertEqual(confirmWithInput("n"), .cancel)
    }

    @objc func testRandomTextCancels() {
        XCTAssertEqual(confirmWithInput("maybe"), .cancel)
    }

    // MARK: - Nil input

    @objc func testNilInputCancels() {
        XCTAssertEqual(confirmWithInput(nil), .cancel)
    }

    // MARK: - Async API (CR16)

    /// confirmAsync keeps the same decision contract as confirm(text:), reads
    /// stdin on a BACKGROUND queue and delivers the Decision on the MAIN queue.
    private func confirmAsyncWithInput(_ input: String?) -> ReviewGate.Decision? {
        ReviewGate.readLineFunction = { input }
        defer { ReviewGate.readLineFunction = { readLine() } }
        let exp = expectation(description: "review decision")
        var delivered: ReviewGate.Decision?
        var deliveredOnMain = false
        ReviewGate.confirmAsync(text: "test transcription") { decision in
            deliveredOnMain = Thread.isMainThread
            delivered = decision
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
        XCTAssertTrue(deliveredOnMain, "решение должно доставляться на main queue")
        return delivered
    }

    @objc func testConfirmAsyncEmptyInputInserts() {
        XCTAssertEqual(confirmAsyncWithInput(""), .insert)
    }

    @objc func testConfirmAsyncYInserts() {
        XCTAssertEqual(confirmAsyncWithInput("y"), .insert)
    }

    @objc func testConfirmAsyncNewlineInserts() {
        XCTAssertEqual(confirmAsyncWithInput("\n"), .insert)
    }

    @objc func testConfirmAsyncNilCancels() {
        XCTAssertEqual(confirmAsyncWithInput(nil), .cancel)
    }

    @objc func testConfirmAsyncYesCancels() {
        XCTAssertEqual(confirmAsyncWithInput("yes"), .cancel)
    }

    @objc func testConfirmAsyncReadsOffTheCallingThread() {
        // CR16: the read must NOT block the main thread (the hotkey event tap
        // and overlay live there). A readLineFunction that stays pending until
        // released proves confirmAsync returns while the read is still running
        // on the background queue.
        let readStarted = DispatchSemaphore(value: 0)
        let releaseRead = DispatchSemaphore(value: 0)
        var readOnMain = true
        ReviewGate.readLineFunction = {
            readOnMain = Thread.isMainThread
            readStarted.signal()
            releaseRead.wait()
            return "y"
        }
        defer { ReviewGate.readLineFunction = { readLine() } }
        let exp = expectation(description: "review decision")
        var delivered: ReviewGate.Decision?
        ReviewGate.confirmAsync(text: "test transcription") { decision in
            delivered = decision
            exp.fulfill()
        }
        // If confirmAsync read on the calling thread, main would deadlock here
        // (the read could never start while main waits on the semaphore).
        XCTAssertEqual(readStarted.wait(timeout: .now() + 2), .success,
                       "чтение stdin должно стартовать на фоновой очереди")
        XCTAssertFalse(readOnMain, "чтение stdin должно идти НЕ на main-потоке")
        releaseRead.signal()
        wait(for: [exp], timeout: 2)
        XCTAssertEqual(delivered, .insert)
    }
}
