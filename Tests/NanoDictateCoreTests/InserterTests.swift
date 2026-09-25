import Foundation
import CoreGraphics
@testable import NanoDictateCore

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

    /// Синтетический Enter (латч Enter-останова): ровно keyDown+keyUp клавиши
    /// Return (36) через общий post() — тестовый postHook считает события,
    /// в активное приложение ничего не печатается. Оба события помечены
    /// маркером SyntheticReturnMarker: пере-просмотр тапом исключает их из
    /// роутинга и глотания.
    @objc func testPostReturnKeyDownUpPostsKeyDownAndKeyUp() {
        var posts: [(keyCode: Int64, isDown: Bool, marker: Int64)] = []
        Inserter.postHook = { event, _ in
            posts.append((
                event.getIntegerValueField(.keyboardEventKeycode),
                event.type == .keyDown,
                event.getIntegerValueField(.eventSourceUserData)
            ))
        }
        defer { Inserter.postHook = nil }

        Inserter.postReturnKeyDownUp()

        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[0].keyCode, 36)
        XCTAssertTrue(posts[0].isDown)
        XCTAssertEqual(posts[1].keyCode, 36)
        XCTAssertFalse(posts[1].isDown)
        XCTAssertTrue(posts.allSatisfy { $0.marker == SyntheticReturnMarker.token })
    }

    /// Постинг идёт через .cghidEventTap (общий post()) — тап-локация
    /// совпадает с типовой эмуляцией клавиатуры Inserter.
    @objc func testPostReturnKeyDownUpUsesHidTap() {
        var taps: [CGEventTapLocation] = []
        Inserter.postHook = { _, tap in taps.append(tap) }
        defer { Inserter.postHook = nil }

        Inserter.postReturnKeyDownUp()

        XCTAssertEqual(taps.count, 2)
        XCTAssertTrue(taps.allSatisfy { $0 == .cghidEventTap })
    }

    // MARK: - NEW: чанкинг insert() (chunkedForEvents через хуки)
    //
    // chunkedForEvents — private, через @testable недоступен; чанки
    // наблюдаются на публичном insert(text:) через postHook/sleepHook:
    // каждая отправка чанка постит keyDown+keyUp с его текстом, пауза — только
    // между чанками.

    /// Прогоняет insert(text:) и возвращает: текст чанков (из keyDown-событий),
    /// паузы и общее число событий. В активное приложение ничего не печатается.
    private func insertChunks(_ text: String) -> (chunks: [String], sleeps: [useconds_t], posts: Int) {
        var chunks: [String] = []
        var sleeps: [useconds_t] = []
        var posts = 0
        Inserter.postHook = { event, _ in
            posts += 1
            guard event.type == .keyDown else { return }
            var actual = 0
            var buf = [UniChar](repeating: 0, count: 64)
            event.keyboardGetUnicodeString(
                maxStringLength: 64, actualStringLength: &actual, unicodeString: &buf)
            chunks.append(String(decoding: buf[..<actual], as: UTF16.self))
        }
        Inserter.sleepHook = { usec in sleeps.append(usec) }
        defer {
            Inserter.postHook = nil
            Inserter.sleepHook = nil
        }
        Inserter.insert(text: text)
        return (chunks, sleeps, posts)
    }

    /// Пустая строка — ни событий, ни пауз.
    @objc func testInsertEmptyTextNoEvents() {
        let (chunks, sleeps, posts) = insertChunks("")
        XCTAssertTrue(chunks.isEmpty)
        XCTAssertTrue(sleeps.isEmpty)
        XCTAssertEqual(posts, 0)
    }

    /// Ровно chunkSize (16) ASCII-графем — один чанк: keyDown+keyUp, без пауз.
    @objc func testInsertASCII16SingleChunk() {
        let text = String(repeating: "a", count: Inserter.chunkSize)
        let (chunks, sleeps, posts) = insertChunks(text)
        XCTAssertEqual(chunks, [text])
        XCTAssertEqual(posts, 2)
        XCTAssertEqual(sleeps.count, 0)
    }

    /// 17 ASCII — два чанка (16 + 1): пауза ровно одна (5 мс), 4 события.
    @objc func testInsertASCII17SplitsAtChunkSize() {
        let text = String(repeating: "a", count: Inserter.chunkSize + 1)
        let (chunks, sleeps, posts) = insertChunks(text)
        XCTAssertEqual(chunks, [String(repeating: "a", count: Inserter.chunkSize), "a"])
        XCTAssertEqual(posts, 4)
        XCTAssertEqual(sleeps.count, 1)
        XCTAssertEqual(sleeps, [5000], "пауза 5 мс только между чанками")
    }

    /// UTF-16-потолок (20 на событие): 10 эмодзи (ровно 20 UTF-16) — один чанк;
    /// 11-й эмодзи переваливает за 20 — новый чанк.
    @objc func testInsertUTF16CeilingWithEmoji() {
        let emoji = "\u{1F600}"  // 😀 = 2 UTF-16
        XCTAssertEqual(emoji.utf16.count, 2)

        let fits = String(repeating: emoji, count: 10)  // ровно 20 UTF-16
        let (chunks10, sleeps10, posts10) = insertChunks(fits)
        XCTAssertEqual(chunks10.count, 1)
        XCTAssertEqual(chunks10[0], fits)
        XCTAssertEqual(sleeps10.count, 0)
        XCTAssertEqual(posts10, 2)

        let overflow = String(repeating: emoji, count: 11)  // 22 UTF-16 > 20
        let (chunks11, sleeps11, posts11) = insertChunks(overflow)
        XCTAssertEqual(chunks11.count, 2)
        XCTAssertEqual(chunks11[0], String(repeating: emoji, count: 10))
        XCTAssertEqual(chunks11[1], emoji)
        XCTAssertEqual(sleeps11.count, 1)
        XCTAssertEqual(posts11, 4)
    }

    /// Графемы не режутся: флаг 🇺🇦 — один Character (4 UTF-16); 5 флагов
    /// помещаются (20 UTF-16), 6-й уходит в новый чанк. Разрез строго между
    /// флагами, никогда внутри графемы.
    @objc func testInsertFlagsStayWholeGraphemes() {
        let flag = "\u{1F1FA}\u{1F1E6}"  // 🇺🇦 — пара regional indicators
        XCTAssertEqual(flag.count, 1)
        XCTAssertEqual(flag.utf16.count, 4)

        let five = String(repeating: flag, count: 5)  // 20 UTF-16 — потолок
        let (chunks5, sleeps5, _) = insertChunks(five)
        XCTAssertEqual(chunks5.count, 1)
        XCTAssertEqual(chunks5[0], five)
        XCTAssertEqual(sleeps5.count, 0)

        let six = String(repeating: flag, count: 6)  // 24 UTF-16 — новый чанк
        let (chunks6, sleeps6, posts6) = insertChunks(six)
        XCTAssertEqual(chunks6.count, 2)
        XCTAssertEqual(chunks6[0], String(repeating: flag, count: 5))
        XCTAssertEqual(chunks6[1], flag)
        XCTAssertEqual(sleeps6.count, 1)
        XCTAssertEqual(posts6, 4)
    }

    /// Одиночная графема > 20 UTF-16 (база + 20 combining-акцентов = 21 UTF-16)
    /// режется по Unicode-scalar границам: чанки не пустые, каждый ≤ 20 UTF-16,
    /// конкатенация == исходник.
    @objc func testOversizedGraphemeCutAtScalarBoundaries() {
        let base = "e" + String(repeating: "\u{0301}", count: 20)  // 1 графема, 21 UTF-16
        XCTAssertEqual(base.count, 1)
        XCTAssertEqual(base.utf16.count, 21)

        let (chunks, sleeps, posts) = insertChunks(base)
        XCTAssertEqual(chunks.count, 2)
        XCTAssertFalse(chunks.contains { $0.isEmpty }, "чанки не пустые")
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 20 }, "каждый чанк ≤ 20 UTF-16")
        XCTAssertEqual(chunks.joined(), base, "конкатенация чанков == исходник")
        XCTAssertEqual(sleeps.count, 1)
        XCTAssertEqual(posts, 4)
    }

    /// Инвариант длинной смешанной строки (кириллица, эмодзи, ZWJ-семейка,
    /// флаги, combining): сумма чанков по содержанию == исходник, каждый чанк
    /// ≤ chunkSize графем и ≤ 20 UTF-16, пауз N-1, событий 2N.
    @objc func testInsertLongMixedTextChunkInvariants() {
        let text = "Привет, мир! 👋 Зв'язок 🇺🇦 та 👨\u{200D}👩\u{200D}👧\u{200D}👦 " +
            String(repeating: "aa", count: 50) + String(repeating: "あ", count: 40) +
            " e\u{0301}\u{0301}\u{0301}"
        let (chunks, sleeps, posts) = insertChunks(text)

        XCTAssertFalse(chunks.isEmpty)
        XCTAssertEqual(chunks.joined(), text, "чанки по содержанию дают исходный текст")
        XCTAssertEqual(
            chunks.reduce(0) { $0 + $1.utf16.count }, text.utf16.count,
            "сумма UTF-16 по чанкам == UTF-16 исходника")
        XCTAssertTrue(chunks.allSatisfy { $0.count <= Inserter.chunkSize },
                      "каждый чанк ≤ chunkSize графем")
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 20 }, "каждый чанк ≤ 20 UTF-16")
        XCTAssertEqual(sleeps.count, chunks.count - 1, "пауз N-1 между N чанками")
        XCTAssertTrue(sleeps.allSatisfy { $0 == 5000 }, "паузы по 5 мс")
        XCTAssertEqual(posts, chunks.count * 2, "keyDown+keyUp на каждый чанк")
    }
}
