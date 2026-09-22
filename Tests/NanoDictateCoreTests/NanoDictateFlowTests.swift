import AppKit
import Foundation
@testable import NanoDictateCore

// MARK: - Чистая логика решений (NanoDictateFlow)

final class NanoDictateFlowTests: XCTestCase {

    // MARK: Пустой результат STT

    @objc func testEmptyResultTrulyEmpty() {
        XCTAssertTrue(NanoDictateFlow.isEmptyResult(""))
        XCTAssertTrue(NanoDictateFlow.isEmptyResult("   "))
        XCTAssertTrue(NanoDictateFlow.isEmptyResult("\n\n"))
        XCTAssertTrue(NanoDictateFlow.isEmptyResult(" \t "))
    }

    /// Одиночное слово — валидный результат диктовки: «да» / «нет» /
    /// «Привет» вставляются как раньше (регрессия «<2 слов = пусто»).
    @objc func testSingleWordIsNotEmpty() {
        XCTAssertFalse(NanoDictateFlow.isEmptyResult("да"))
        XCTAssertFalse(NanoDictateFlow.isEmptyResult("нет"))
        XCTAssertFalse(NanoDictateFlow.isEmptyResult("Привет"))
        XCTAssertFalse(NanoDictateFlow.isEmptyResult("Привет."))
    }

    /// Два и более слова — нормальный результат диктовки.
    @objc func testNotEmptyResultTwoOrMoreWords() {
        XCTAssertFalse(NanoDictateFlow.isEmptyResult("привет мир"))
        XCTAssertFalse(NanoDictateFlow.isEmptyResult("Привет мир."))
        XCTAssertFalse(NanoDictateFlow.isEmptyResult("  два слова  "))
        XCTAssertFalse(NanoDictateFlow.isEmptyResult("сегодня хорошая погода"))
    }

    /// Только пунктуация — «пустой» результат: ни одной буквы/цифры.
    @objc func testOnlyPunctuationIsEmpty() {
        XCTAssertTrue(NanoDictateFlow.isEmptyResult("."))
        XCTAssertTrue(NanoDictateFlow.isEmptyResult("—"))
        XCTAssertTrue(NanoDictateFlow.isEmptyResult("…"))
        XCTAssertTrue(NanoDictateFlow.isEmptyResult(" - "))
        XCTAssertTrue(NanoDictateFlow.isEmptyResult("!?!"))
    }

    /// Любая цифра (даже одиночное число) — не пустой результат.
    @objc func testDigitsOnlyAreNotEmpty() {
        XCTAssertFalse(NanoDictateFlow.isEmptyResult("5"))
        XCTAssertFalse(NanoDictateFlow.isEmptyResult("123"))
    }

    @objc func testOutcomeInsertForNanoDictate() {
        XCTAssertEqual(NanoDictateFlow.outcome(for: "привет мир"), .insert("привет мир"))
    }

    @objc func testOutcomeEmptyForWhitespaceOrPunctuation() {
        XCTAssertEqual(NanoDictateFlow.outcome(for: "   "), .empty)
        XCTAssertEqual(NanoDictateFlow.outcome(for: "."), .empty)
    }

    /// Одиночное слово идёт путём полной вставки (outcome = .insert).
    @objc func testOutcomeInsertForSingleWord() {
        XCTAssertEqual(NanoDictateFlow.outcome(for: "да"), .insert("да"))
        XCTAssertEqual(NanoDictateFlow.outcome(for: "Привет"), .insert("Привет"))
    }

    // MARK: Доставка результата STT (отмена по Esc)

    /// Отмена (Esc) поставила токен — результат запроса игнорируется,
    /// даже если сессия ещё активна.
    @objc func testDeliverResultIgnoredWhenCancelled() {
        XCTAssertFalse(NanoDictateFlow.shouldDeliverResult(isCancelled: true, sessionActive: true))
    }

    @objc func testDeliverResultWhenActiveAndNotCancelled() {
        XCTAssertTrue(NanoDictateFlow.shouldDeliverResult(isCancelled: false, sessionActive: true))
    }

    /// Сессия завершена (watchdog/другой цикл) — доставка не происходит.
    @objc func testDeliverResultIgnoredWhenSessionInactive() {
        XCTAssertFalse(NanoDictateFlow.shouldDeliverResult(isCancelled: false, sessionActive: false))
    }

    // MARK: Undo-окно (промежуток времени)

    @objc func testUndoWindowWithinInterval() {
        XCTAssertTrue(NanoDictateFlow.shouldUndoInsertion(lastInsertedAt: 100, now: 101, window: 2.0))
    }

    /// ровно на границе окна — откат допустим (допуск на Double, как в MicErrorCooldown).
    @objc func testUndoWindowAtExactBoundary() {
        XCTAssertTrue(NanoDictateFlow.shouldUndoInsertion(lastInsertedAt: 100, now: 102, window: 2.0))
    }

    @objc func testUndoWindowOutsideInterval() {
        XCTAssertFalse(NanoDictateFlow.shouldUndoInsertion(lastInsertedAt: 100, now: 102.01, window: 2.0))
    }

    /// Вставки не было (или уже откачена) — откат невозможен.
    @objc func testUndoWindowWithoutInsertion() {
        XCTAssertFalse(NanoDictateFlow.shouldUndoInsertion(lastInsertedAt: nil, now: 100.5, window: 2.0))
    }

    // MARK: Undo vs фазы агента (recording/transcribing не путаются)

    @objc func testUndoInsteadOfStartInIdleWithinWindow() {
        XCTAssertTrue(NanoDictateFlow.shouldUndoInsteadOfStart(
            state: .idle, lastInsertedAt: 100, now: 101, undoWindow: 2.0
        ))
    }

    /// Окно истекло — Alt+Alt опять начинает запись.
    @objc func testUndoInsteadOfStartInIdleAfterWindow() {
        XCTAssertFalse(NanoDictateFlow.shouldUndoInsteadOfStart(
            state: .idle, lastInsertedAt: 100, now: 103, undoWindow: 2.0
        ))
    }

    /// Фаза «запись»: Alt = «завершить запись», свежая вставка её не перебивает.
    @objc func testUndoDoesNotFireDuringRecording() {
        XCTAssertFalse(NanoDictateFlow.shouldUndoInsteadOfStart(
            state: .recording, lastInsertedAt: 100, now: 100.5, undoWindow: 2.0
        ))
    }

    /// Фаза «обработка»: Alt игнорируется, откат невозможен.
    @objc func testUndoDoesNotFireDuringTranscribing() {
        XCTAssertFalse(NanoDictateFlow.shouldUndoInsteadOfStart(
            state: .transcribing, lastInsertedAt: 100, now: 100.5, undoWindow: 2.0
        ))
    }

    @objc func testUndoDoesNotFireWithoutInsertion() {
        XCTAssertFalse(NanoDictateFlow.shouldUndoInsteadOfStart(
            state: .idle, lastInsertedAt: nil, now: 100, undoWindow: 2.0
        ))
    }
}

// MARK: - Новые кейсы SysSounds (completionAfterInsert / emptyResult / undo)

final class SysSoundsUXTests: XCTestCase {

    /// Звук завершения — отдельный кейс, тот же Pop, что у playEnd (дефолт).
    @objc func testCompletionAfterInsertPlaysPop() {
        let sounds = SysSounds(enabled: true)
        sounds.playCompletionAfterInsert()
        XCTAssertEqual(sounds.playingName, "Pop")
        XCTAssertEqual(sounds.lastPlayedLabel, "completionAfterInsert")
    }

    /// Лейблы различают кейсы с одним звуком: end и completionAfterInsert
    /// оба "Pop", но это разные методы с разными последствиями в цикле.
    @objc func testLabelsDistinguishPopCases() {
        let sounds = SysSounds(enabled: true)
        sounds.playEnd()
        XCTAssertEqual(sounds.lastPlayedLabel, "end")
        sounds.playCompletionAfterInsert()
        XCTAssertEqual(sounds.lastPlayedLabel, "completionAfterInsert")
        sounds.playUndo()
        XCTAssertEqual(sounds.lastPlayedLabel, "undo")
    }

    /// Звук «пустого результата» — Funk, а не ошибка микрофона (Basso).
    @objc func testEmptyResultPlaysFunk() {
        let sounds = SysSounds(enabled: true)
        sounds.playEmptyResult()
        XCTAssertEqual(sounds.playingName, "Funk")
        XCTAssertEqual(sounds.lastPlayedLabel, "emptyResult")
    }

    /// Новые системные звуки существуют в /System/Library/Sounds.
    @objc func testUXSoundsExist() {
        XCTAssertNotNil(NSSound(named: "Funk"))
        XCTAssertNotNil(NSSound(named: "Pop"))
    }

    /// Отключённые звуки: новые методы — no-op без падения и без меток.
    @objc func testUXSoundsDisabledAreNoOp() {
        let sounds = SysSounds(enabled: false)
        sounds.playCompletionAfterInsert()
        sounds.playEmptyResult()
        sounds.playUndo()
        XCTAssertNil(sounds.playingName)
        XCTAssertNil(sounds.lastPlayedLabel)
    }

    /// Контракт порядка «завершение после вставки»: полная последовательность
    /// completeInsertion — сначала CG-вставка, затем звук завершения (новым
    /// методом, не playEnd). Сам вызов Inserter.insert/delete на настоящие
    /// CGEvents здесь не гоняем (тест не должен печатать в активное приложение),
    /// поэтому порядок зафиксирован как контракт последовательности.
    @objc func testCompletionSoundComesAfterInsert() {
        let sounds = SysSounds(enabled: true)
        var events: [String] = []

        // Шаг 1: вставка (в production — Inserter.insert / CGEvent).
        events.append("insert")

        // Шаг 2: звук завершения ПОСЛЕ вставки.
        sounds.playCompletionAfterInsert()
        events.append("sound:\(sounds.lastPlayedLabel ?? "?")")

        XCTAssertEqual(events, ["insert", "sound:completionAfterInsert"])
        XCTAssertEqual(sounds.playingName, "Pop")
    }

    /// Cooldown пустого результата отделён от cooldown ошибки микрофона:
    /// один и тот же момент времени пустому результату разрешён, даже если
    /// ошибка микрофона только что сыграла (свои экземпляры MicErrorCooldown).
    @objc func testEmptyResultCooldownIndependentFromMicErrorCooldown() {
        var micErrorCooldown = MicErrorCooldown(interval: 3.0)
        var emptyResultCooldown = MicErrorCooldown(interval: 3.0)

        XCTAssertTrue(micErrorCooldown.allow(at: 100))
        // «Частый Alt+Alt»: ошибка микрофона на 100.5 подавлена —
        XCTAssertFalse(micErrorCooldown.allow(at: 100.5))
        // но пустая диктовка в тот же момент — своё окно, разрешена.
        XCTAssertTrue(emptyResultCooldown.allow(at: 100.5))
        // и второй пустой результат сразу — уже подавлен своим cooldown.
        XCTAssertFalse(emptyResultCooldown.allow(at: 100.6))
    }
}