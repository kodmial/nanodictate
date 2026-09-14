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

    // MARK: - NEW: delete-батчинг (undo не спит на каждый символ)
    //
    // Мок-таймер: хуки Inserter.sleepHook / postHook подменяют usleep и post
    // CGEvent-ов — тест считает паузы и события, ничего не печатая в активное
    // приложение (isTestRun и так заглушил бы пост).

    /// Длинное стирание (500 графем) спит паузами между пачками по chunkSize,
    /// а не на каждый backspace: ceil(500/16) = 32 пачки → 31 пауза вместо 499.
    /// Время undo падает с ~2.5 с до ~155 мс — главный поток агента не
    /// блокируется на секунды.
    @objc func testDeleteLongBatchSleepsPerChunk() {
        let count = 500
        var sleeps = 0
        var posts = 0
        Inserter.sleepHook = { _ in sleeps += 1 }
        Inserter.postHook = { _, _ in posts += 1 }
        defer {
            Inserter.sleepHook = nil
            Inserter.postHook = nil
        }

        Inserter.delete(count: count)

        let chunks = (count + Inserter.chunkSize - 1) / Inserter.chunkSize // 32
        XCTAssertEqual(sleeps, chunks - 1) // паузы только между пачками (как в insert)
        XCTAssertTrue(sleeps < count)      // главное: НЕ count пауз
        XCTAssertEqual(posts, count * 2)   // стёрто ровно count графем (keyDown+keyUp)
    }

    /// Стирание в пределах одной пачки — без пауз вообще: удаление короткого
    /// текста не затягивается ни на миллисекунду.
    @objc func testDeleteShortNoSleep() {
        var sleeps = 0
        Inserter.sleepHook = { _ in sleeps += 1 }
        Inserter.postHook = { _, _ in }
        defer {
            Inserter.sleepHook = nil
            Inserter.postHook = nil
        }

        Inserter.delete(count: 10)

        XCTAssertEqual(sleeps, 0)
        XCTAssertEqual(Inserter.chunkSize, 16) // страж: формула теста про пачки завязана на размер
    }

    /// count = 0 / отрицательный — no-op: ни пауз, ни событий.
    @objc func testDeleteZeroIsNoOp() {
        var posts = 0
        var sleeps = 0
        Inserter.sleepHook = { _ in sleeps += 1 }
        Inserter.postHook = { _, _ in posts += 1 }
        defer {
            Inserter.sleepHook = nil
            Inserter.postHook = nil
        }

        Inserter.delete(count: 0)
        Inserter.delete(count: -5)

        XCTAssertEqual(posts, 0)
        XCTAssertEqual(sleeps, 0)
    }

    /// delete(characters:) делегирует в delete(count:) — публичная сигнатура,
    /// которую зовёт main.swift/undo, сохранена и стирает по символам строки.
    @objc func testDeleteCharactersDelegatesToCount() {
        var posts = 0
        Inserter.sleepHook = { _ in }
        Inserter.postHook = { _, _ in posts += 1 }
        defer {
            Inserter.sleepHook = nil
            Inserter.postHook = nil
        }

        Inserter.delete(characters: "привет")

        XCTAssertEqual(posts, 6 * 2) // 6 графем → 6 backspace'ов (keyDown+keyUp)
    }
}
