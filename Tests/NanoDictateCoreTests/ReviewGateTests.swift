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
}
