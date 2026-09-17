import Foundation
@testable import NanoDictateCore

final class ClipboardInsertTests: XCTestCase {

    // MARK: - Helpers

    private func makeMockBridge(
        initialClipboard: String? = nil,
        onPaste: @escaping () -> Void = {}
    ) -> (bridge: ClipboardInsertBridge, getClipboard: () -> String?, restoreHistory: () -> [String]) {
        var clipboard = initialClipboard
        var writes: [String] = []
        var pasteCalled = false

        let bridge = ClipboardInsertBridge(
            readClipboard: { clipboard },
            writeClipboard: { text in
                clipboard = text
                writes.append(text)
            },
            sendPaste: {
                pasteCalled = true
                onPaste()
            },
            restoreDelay: 0,
            scheduleRestore: { block, delay in block() }
        )
        let getClipboard: () -> String? = { clipboard }
        let restoreHistory: () -> [String] = { writes }
        _ = pasteCalled
        return (bridge, getClipboard, restoreHistory)
    }

    // MARK: - Прямой вызов insertViaClipboard

    @objc func testClipboardInsertCallsSendPaste() {
        var pasted = false
        let (bridge, _, _) = makeMockBridge(onPaste: { pasted = true })

        Inserter.insertViaClipboard(text: "hello", bridge: bridge)
        XCTAssertTrue(pasted)
    }

    @objc func testClipboardInsertWritesTextToClipboard() {
        let (bridge, _, restoreHistory) = makeMockBridge()

        Inserter.insertViaClipboard(text: "hello", bridge: bridge)

        // Текст пишется в буфер первым действием; к моменту чтения буфер уже
        // восстановлен (scheduleRestore в тестах синхронный), поэтому проверяем
        // историю записей.
        let writes = restoreHistory()
        XCTAssertEqual(writes.first, "hello")
        XCTAssertEqual(writes.count, 2, "запись текста + восстановление старого буфера")
    }

    @objc func testClipboardInsertRestoresOldClipboard() {
        let (bridge, getClipboard, restoreHistory) = makeMockBridge(initialClipboard: "old-text")

        Inserter.insertViaClipboard(text: "new-text", bridge: bridge)

        let writes = restoreHistory()
        // Записи: [new-text, old-text] — вставка, затем восстановление
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0], "new-text")
        XCTAssertEqual(writes[1], "old-text")
        XCTAssertEqual(getClipboard(), "old-text")
    }

    @objc func testClipboardInsertRestoresEmptyWhenOldWasNil() {
        let (bridge, getClipboard, restoreHistory) = makeMockBridge(initialClipboard: nil)

        Inserter.insertViaClipboard(text: "new", bridge: bridge)

        let writes = restoreHistory()
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0], "new")
        XCTAssertEqual(writes[1], "")
        XCTAssertEqual(getClipboard(), "")
    }

    @objc func testClipboardInsertEmptyTextDoesNothing() {
        var pasted = false
        let (bridge, _, restoreHistory) = makeMockBridge(onPaste: { pasted = true })

        Inserter.insertViaClipboard(text: "", bridge: bridge)
        XCTAssertFalse(pasted)
        XCTAssertEqual(restoreHistory().count, 0)
    }

    // MARK: - Выбор ветки по insert_method (без реального Cmd+V / CGEvent)

    @objc func testClipboardMethodUsesBridgeNotCGEventOverride() {
        var overrideCalled = false
        Inserter.cgEventInsertOverride = { text in overrideCalled = true }
        defer { Inserter.cgEventInsertOverride = nil }

        let (bridge, _, restoreHistory) = makeMockBridge(initialClipboard: "old")
        Inserter.insert(text: "test", method: .clipboard, bridge: bridge)

        XCTAssertFalse(overrideCalled, "clipboard-метод не должен идти через CGEvent-ветку")
        XCTAssertEqual(restoreHistory().count, 2, "clipboard-метод должен пользоваться мостом буфера")
    }

    @objc func testCGEventMethodIgnoresBridge() {
        var pasted = false
        let (bridge, _, restoreHistory) = makeMockBridge(onPaste: { pasted = true })
        var overrideCalled = false
        Inserter.cgEventInsertOverride = { text in overrideCalled = true }
        defer { Inserter.cgEventInsertOverride = nil }

        Inserter.insert(text: "test", method: .cgevent, bridge: bridge)

        XCTAssertTrue(overrideCalled, "cgevent-метод должен идти через CGEvent-ветку")
        XCTAssertFalse(pasted, "cgevent-метод не должен клипать буфер обмена")
        XCTAssertEqual(restoreHistory().count, 0, "cgevent-метод не должен писать в буфер")
    }

    @objc func testPublicDefaultMethodSelection() {
        // Публичный API без моста: .cgevent по умолчанию — уходит на override.
        var receivedText: String?
        Inserter.cgEventInsertOverride = { text in receivedText = text }
        defer { Inserter.cgEventInsertOverride = nil }

        Inserter.insert(text: "via-cgevent", method: .cgevent)
        XCTAssertEqual(receivedText, "via-cgevent")
    }
}