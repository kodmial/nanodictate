import XCTest
@testable import DictationCore

final class InserterTests: XCTestCase {

    // MARK: - Existing

    func testFinalizeCapitalizesAndAddsPeriod() {
        XCTAssertEqual(TextRefinement.finalize("привет мир"), "Привет мир.")
    }

    func testFinalizeKeepsExistingPeriod() {
        XCTAssertEqual(TextRefinement.finalize("уже есть точка."), "Уже есть точка.")
    }

    func testFinalizeEmptyText() {
        XCTAssertEqual(TextRefinement.finalize(""), "")
    }

    // MARK: - NEW: Empty / whitespace only

    func testFinalizeWhitespaceOnly() {
        XCTAssertEqual(TextRefinement.finalize("   "), "")
    }

    func testFinalizeNewlinesOnly() {
        XCTAssertEqual(TextRefinement.finalize("\n\n\n"), "")
    }

    // MARK: - NEW: Period preserved

    func testFinalizePeriodPreserved() {
        XCTAssertEqual(TextRefinement.finalize("привет."), "Привет.")
    }

    // MARK: - NEW: Period added when missing

    func testFinalizePeriodAdded() {
        XCTAssertEqual(TextRefinement.finalize("привет"), "Привет.")
    }

    // MARK: - NEW: Exclamation preserved, no period added

    func testFinalizeExclamationNoExtraPeriod() {
        XCTAssertEqual(TextRefinement.finalize("привет!"), "Привет!")
    }

    // MARK: - NEW: Question mark preserved

    func testFinalizeQuestionNoExtraPeriod() {
        XCTAssertEqual(TextRefinement.finalize("привет?"), "Привет?")
    }

    // MARK: - NEW: Ellipsis preserved

    func testFinalizeEllipsisPreserved() {
        XCTAssertEqual(TextRefinement.finalize("привет…"), "Привет…")
    }

    // MARK: - NEW: Leading/trailing spaces trimmed

    func testFinalizeTrimsSpaces() {
        XCTAssertEqual(TextRefinement.finalize("  привет мир  "), "Привет мир.")
    }

    func testFinalizeTrimsNewlines() {
        XCTAssertEqual(TextRefinement.finalize("\nпривет\n"), "Привет.")
    }

    // MARK: - NEW: Cyrillic capitalization

    func testFinalizeCyrillicCapitalizes() {
        XCTAssertEqual(TextRefinement.finalize("яблоко"), "Яблоко.")
    }

    // MARK: - NEW: Latin capitalization

    func testFinalizeLatinCapitalizes() {
        XCTAssertEqual(TextRefinement.finalize("hello"), "Hello.")
    }

    // MARK: - NEW: Multiline — only first letter of first word

    func testFinalizeMultilineFirstLetterOnly() {
        let input = "первое слово\nвторое слово"
        let result = TextRefinement.finalize(input)
        XCTAssertEqual(result, "Первое слово\nвторое слово.")
    }

    func testFinalizeMultilineMultipleNewlines() {
        let input = "строка один\nстрока два\nстрока три"
        let result = TextRefinement.finalize(input)
        XCTAssertEqual(result, "Строка один\nстрока два\nстрока три.")
    }

    // MARK: - NEW: Already capitalized — no double capitalization

    func testFinalizeAlreadyCapitalized() {
        XCTAssertEqual(TextRefinement.finalize("Привет мир"), "Привет мир.")
    }

    // MARK: - NEW: Single character

    func testFinalizeSingleChar() {
        XCTAssertEqual(TextRefinement.finalize("а"), "А.")
    }

    func testFinalizeSingleCharLatin() {
        XCTAssertEqual(TextRefinement.finalize("a"), "A.")
    }

    // MARK: - NEW: Multiple punctuation at end

    func testFinalizeMultiplePunctuation() {
        XCTAssertEqual(TextRefinement.finalize("привет!!"), "Привет!!")
    }
}
