import Foundation
@testable import DictationCore

final class InserterTests: XCTestCase {

    // MARK: - Existing

    @objc func testFinalizeCapitalizesAndAddsPeriod() {
        XCTAssertEqual(TextRefinement.finalize("привет мир"), "Привет мир.")
    }

    @objc func testFinalizeKeepsExistingPeriod() {
        XCTAssertEqual(TextRefinement.finalize("уже есть точка."), "Уже есть точка.")
    }

    @objc func testFinalizeEmptyText() {
        XCTAssertEqual(TextRefinement.finalize(""), "")
    }

    // MARK: - NEW: Empty / whitespace only

    @objc func testFinalizeWhitespaceOnly() {
        XCTAssertEqual(TextRefinement.finalize("   "), "")
    }

    @objc func testFinalizeNewlinesOnly() {
        XCTAssertEqual(TextRefinement.finalize("\n\n\n"), "")
    }

    // MARK: - NEW: Period preserved

    @objc func testFinalizePeriodPreserved() {
        XCTAssertEqual(TextRefinement.finalize("привет."), "Привет.")
    }

    // MARK: - NEW: Period added when missing

    @objc func testFinalizePeriodAdded() {
        XCTAssertEqual(TextRefinement.finalize("привет"), "Привет.")
    }

    // MARK: - NEW: Exclamation preserved, no period added

    @objc func testFinalizeExclamationNoExtraPeriod() {
        XCTAssertEqual(TextRefinement.finalize("привет!"), "Привет!")
    }

    // MARK: - NEW: Question mark preserved

    @objc func testFinalizeQuestionNoExtraPeriod() {
        XCTAssertEqual(TextRefinement.finalize("привет?"), "Привет?")
    }

    // MARK: - NEW: Ellipsis preserved

    @objc func testFinalizeEllipsisPreserved() {
        XCTAssertEqual(TextRefinement.finalize("привет…"), "Привет…")
    }

    // MARK: - NEW: Leading/trailing spaces trimmed

    @objc func testFinalizeTrimsSpaces() {
        XCTAssertEqual(TextRefinement.finalize("  привет мир  "), "Привет мир.")
    }

    @objc func testFinalizeTrimsNewlines() {
        XCTAssertEqual(TextRefinement.finalize("\nпривет\n"), "Привет.")
    }

    // MARK: - NEW: Cyrillic capitalization

    @objc func testFinalizeCyrillicCapitalizes() {
        XCTAssertEqual(TextRefinement.finalize("яблоко"), "Яблоко.")
    }

    // MARK: - NEW: Latin capitalization

    @objc func testFinalizeLatinCapitalizes() {
        XCTAssertEqual(TextRefinement.finalize("hello"), "Hello.")
    }

    // MARK: - NEW: Multiline — only first letter of first word

    @objc func testFinalizeMultilineFirstLetterOnly() {
        let input = "первое слово\nвторое слово"
        let result = TextRefinement.finalize(input)
        XCTAssertEqual(result, "Первое слово\nвторое слово.")
    }

    @objc func testFinalizeMultilineMultipleNewlines() {
        let input = "строка один\nстрока два\nстрока три"
        let result = TextRefinement.finalize(input)
        XCTAssertEqual(result, "Строка один\nстрока два\nстрока три.")
    }

    // MARK: - NEW: Already capitalized — no double capitalization

    @objc func testFinalizeAlreadyCapitalized() {
        XCTAssertEqual(TextRefinement.finalize("Привет мир"), "Привет мир.")
    }

    // MARK: - NEW: Single character

    @objc func testFinalizeSingleChar() {
        XCTAssertEqual(TextRefinement.finalize("а"), "А.")
    }

    @objc func testFinalizeSingleCharLatin() {
        XCTAssertEqual(TextRefinement.finalize("a"), "A.")
    }

    // MARK: - NEW: Multiple punctuation at end

    @objc func testFinalizeMultiplePunctuation() {
        XCTAssertEqual(TextRefinement.finalize("привет!!"), "Привет!!")
    }
}
