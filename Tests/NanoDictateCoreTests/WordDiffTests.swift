import Foundation
@testable import NanoDictateCore

// MARK: - Тесты WordDiff

final class WordDiffTests: XCTestCase {

    @objc func testIdenticalReturnsNil() {
        let result = WordDiff.change(old: "Один два три.", new: "Один два три.")
        XCTAssertNil(result)
    }

    @objc func testWhitespaceOnlyDiffReturnsNil() {
        let result = WordDiff.change(old: "Один  два.", new: "Один два.")
        XCTAssertNil(result)
    }

    @objc func testAddWordInMiddle() {
        let result = WordDiff.change(old: "Один три.", new: "Один два три.")
        XCTAssertNotNil(result)
        let change = result!
        XCTAssertEqual(change.spanOld, "")
        XCTAssertEqual(change.spanNew, "два")
        XCTAssertEqual(change.tailOld, " три.")
        XCTAssertEqual(change.tailNew, " два три.")
        XCTAssertEqual(change.spanStartOld, 4)   // после "Один "
        XCTAssertEqual(change.spanStartNew, 4)
    }

    @objc func testDeleteWordInMiddle() {
        let result = WordDiff.change(old: "А Б В.", new: "А В.")
        XCTAssertNotNil(result)
        let change = result!
        XCTAssertEqual(change.spanOld, "Б")
        XCTAssertEqual(change.spanNew, "")
        XCTAssertEqual(change.tailOld, " Б В.")
        XCTAssertEqual(change.tailNew, " В.")
    }

    @objc func testReplaceWordWithSpaceSeparated() {
        let result = WordDiff.change(old: "Было слово.", new: "Стало слово.")
        XCTAssertNotNil(result)
        let change = result!
        // words("Было слово.") = ["Было", "слово."]; words("Стало слово.") = ["Стало", "слово."]
        // prefix = 0 (слова на позиции 0 разные), suffix = 1 (последнее совпадает)
        XCTAssertEqual(change.spanOld, "Было")
        XCTAssertEqual(change.spanNew, "Стало")
        XCTAssertEqual(change.tailOld, "Было слово.") // от spanStartOld=0 до конца
        XCTAssertEqual(change.tailNew, "Стало слово.")
    }

    @objc func testAddAtEnd() {
        // Добавленное слово в конце: префикс совпадает целиком, спан пустой старый.
        let result = WordDiff.change(old: "Один два", new: "Один два три")
        XCTAssertNotNil(result)
        let change = result!
        XCTAssertEqual(change.spanOld, "")
        XCTAssertEqual(change.spanNew, "три")
        XCTAssertEqual(change.spanStartOld, 8)
        XCTAssertEqual(change.spanStartNew, 8)
        XCTAssertEqual(change.tailOld, "")
        XCTAssertEqual(change.tailNew, " три")
    }

    @objc func testDeleteAllNewEmpty() {
        let result = WordDiff.change(old: "Один два три.", new: "")
        XCTAssertNotNil(result)
        let change = result!
        XCTAssertEqual(change.spanOld, "Один два три.")
        XCTAssertEqual(change.spanNew, "")
        XCTAssertEqual(change.tailOld, "Один два три.")
        XCTAssertEqual(change.tailNew, "")
        XCTAssertEqual(change.spanStartOld, 0)
    }

    @objc func testAddToEmptyOld() {
        let result = WordDiff.change(old: "", new: "Привет мир.")
        XCTAssertNotNil(result)
        let change = result!
        XCTAssertEqual(change.spanOld, "")
        XCTAssertEqual(change.spanNew, "Привет мир.")
        XCTAssertEqual(change.spanStartOld, 0)
    }

    @objc func testCaseDifferenceIsDetected() {
        let result = WordDiff.change(old: "Привет мир.", new: "привет мир.")
        XCTAssertNotNil(result)
        let change = result!
        // Слова ["привет", "мир."] vs ["Привет", "мир."] — suffix 1 "мир." совпадает
        XCTAssertEqual(change.spanOld, "Привет")
        XCTAssertEqual(change.spanNew, "привет")
    }
}