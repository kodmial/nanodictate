import AppKit
import Foundation
@testable import NanoDictateCore

final class ClipboardInsertTests: XCTestCase {

    // MARK: - Helpers

    /// Аналог ClipboardInsertBridge.snapshot(containingText:) (не публичный API,
    /// в тестах строится вручную): один item, один .string-тип; "" — пустой слепок.
    private func snapshot(containingText text: String) -> ClipboardSnapshot {
        guard !text.isEmpty else { return [] }
        return [[(NSPasteboard.PasteboardType.string, Data(text.utf8))]]
    }

    /// Текст из .string-данных первого item'а слепка (nil — строки в слепке нет).
    private func text(from snapshot: ClipboardSnapshot) -> String? {
        guard let item = snapshot.first,
              let data = item.first(where: { $0.0 == .string })?.1 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Поэлементное сравнение слепков: кортежи (PasteboardType, Data) не Equatable,
    /// поэтому XCTAssertEqual с ClipboardSnapshot не компилируется — сравниваем вручную.
    private func sameSnapshot(_ lhs: ClipboardSnapshot, _ rhs: ClipboardSnapshot) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { a, b in
            guard a.count == b.count else { return false }
            return zip(a, b).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        }
    }

    private func makeMockBridge(
        initialClipboard: String? = nil,
        onPaste: @escaping () -> Void = {}
    ) -> (bridge: ClipboardInsertBridge, getClipboard: () -> String?, restoreHistory: () -> [String]) {
        var clipboard = initialClipboard.map { snapshot(containingText: $0) } ?? []
        var writes: [ClipboardSnapshot] = []
        var pasteCalled = false

        let bridge = ClipboardInsertBridge(
            readClipboard: { clipboard },
            writeClipboard: { snapshot in
                clipboard = snapshot
                writes.append(snapshot)
            },
            sendPaste: {
                pasteCalled = true
                onPaste()
            },
            restoreDelay: 0,
            scheduleRestore: { block, delay in block() }
        )
        let getClipboard: () -> String? = {
            guard !clipboard.isEmpty else { return "" }
            return self.text(from: clipboard)
        }
        let restoreHistory: () -> [String] = {
            writes.map { self.text(from: $0) ?? "" }
        }
        _ = pasteCalled
        return (bridge, getClipboard, restoreHistory)
    }

    /// Мост с полным слепком буфера: для проверки сохранения не-text контента при restore.
    private func makeSnapshotMockBridge(
        initialSnapshot: ClipboardSnapshot,
        onPaste: @escaping () -> Void = {}
    ) -> (bridge: ClipboardInsertBridge, writtenSnapshots: () -> [ClipboardSnapshot]) {
        var clipboard = initialSnapshot
        var writes: [ClipboardSnapshot] = []
        var pasteCalled = false

        let bridge = ClipboardInsertBridge(
            readClipboard: { clipboard },
            writeClipboard: { snapshot in
                clipboard = snapshot
                writes.append(snapshot)
            },
            sendPaste: {
                pasteCalled = true
                onPaste()
            },
            restoreDelay: 0,
            scheduleRestore: { block, delay in block() }
        )
        _ = pasteCalled
        return (bridge, { writes })
    }

    private struct DeferredRestoreHarness {
        let bridge: ClipboardInsertBridge
        let getClipboard: () -> String?
        let restoreHistory: () -> [String]
        let runRestores: () -> Void
    }

    /// Мост с ОТЛОЖЕННЫМ restore: scheduleRestore копит блоки вместо немедленного
    /// запуска — так тест может устроить наложение двух вставок до того, как
    /// первая успела восстановить буфер (синхронный mock такой сценарий
    /// исключает: restore отрабатывает прямо внутри insertViaClipboard).
    private func makeDeferredRestoreBridge(
        initialClipboard: String? = nil
    ) -> DeferredRestoreHarness {
        var clipboard = initialClipboard.map { snapshot(containingText: $0) } ?? []
        var writes: [ClipboardSnapshot] = []
        var restores: [() -> Void] = []

        let bridge = ClipboardInsertBridge(
            readClipboard: { clipboard },
            writeClipboard: { snapshot in
                clipboard = snapshot
                writes.append(snapshot)
            },
            sendPaste: {},
            restoreDelay: 0,
            scheduleRestore: { block, _ in restores.append(block) }
        )
        let getClipboard: () -> String? = {
            guard !clipboard.isEmpty else { return "" }
            return self.text(from: clipboard)
        }
        let restoreHistory: () -> [String] = {
            writes.map { self.text(from: $0) ?? "" }
        }
        let runRestores: () -> Void = {
            for restore in restores { restore() }
            restores.removeAll()
        }
        return DeferredRestoreHarness(
            bridge: bridge,
            getClipboard: getClipboard,
            restoreHistory: restoreHistory,
            runRestores: runRestores
        )
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

        // Buffer already restored (sync scheduleRestore in tests); assert write history instead.
        let writes = harness.restoreHistory()
        XCTAssertEqual(writes.first, "hello")
        XCTAssertEqual(writes.count, 2, "запись текста + восстановление старого буфера")
    }

    @objc func testClipboardInsertRestoresOldClipboard() {
        let (bridge, getClipboard, restoreHistory) = makeMockBridge(initialClipboard: "old-text")

        Inserter.insertViaClipboard(text: "new-text", bridge: bridge)

        let writes = harness.restoreHistory()
        XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes[0], "new-text")
        XCTAssertEqual(writes[1], "old-text")
        XCTAssertEqual(getClipboard(), "old-text")
    }

    @objc func testClipboardInsertRestoresEmptyWhenOldWasNil() {
        let (bridge, getClipboard, restoreHistory) = makeMockBridge(initialClipboard: nil)

        Inserter.insertViaClipboard(text: "new", bridge: bridge)

        let writes = harness.restoreHistory()
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
        // Public API without bridge: default .cgevent routes to override.
        var receivedText: String?
        Inserter.cgEventInsertOverride = { text in receivedText = text }
        defer { Inserter.cgEventInsertOverride = nil }

        Inserter.insert(text: "via-cgevent", method: .cgevent)
        XCTAssertEqual(receivedText, "via-cgevent")
    }

    // MARK: - Защита от наложения вставок (pendingOriginal / restoreGeneration)

    @objc func testOverlappingInserts_RestoreOriginalOnce_LastGenerationWins() {
        // Две вставки подряд без промежуточного restore: оригинал запоминается
        // ОДИН раз (вторая вставка переиспользует pendingOriginal, а не читает
        // свой же dictation-текст из буфера); отложенные restore запланированы
        // с поколениями 1 и 2 — первое сдаётся, побеждает последнее, и буфер
        // возвращается к ОРИГИНАЛУ ровно одним restore.
        let harness = makeDeferredRestoreBridge(initialClipboard: "original")
        let bridge = harness.bridge

        Inserter.insertViaClipboard(text: "first", bridge: bridge)
        Inserter.insertViaClipboard(text: "second", bridge: bridge)

        // До срабатывания restore буфер держит dictation-текст второй вставки.
        XCTAssertEqual(harness.restoreHistory(), ["first", "second"])
        XCTAssertEqual(harness.getClipboard(), "second")

        harness.runRestores() // в порядке планирования

        let writes = harness.restoreHistory()
        XCTAssertEqual(writes, ["first", "second", "original"],
                       "восстановлен оригинал, а не текст первой вставки (общий pendingOriginal)")
        XCTAssertEqual(harness.getClipboard(), "original")
        XCTAssertEqual(writes.count, 3, "оригинал восстановлен ровно один раз")
    }

    // MARK: - Не-text контент при restore

    @objc func testClipboardInsertRestoresNonTextContent() {
        let tiffData = Data([0x00, 0x01, 0x02, 0x03])
        let fileURLData = Data("/tmp/report.pdf".utf8)
        let initialSnapshot: ClipboardSnapshot = [
            // item 1: строка + не-text тип (tiff)
            [
                (NSPasteboard.PasteboardType.string, Data("old-text".utf8)),
                (NSPasteboard.PasteboardType.tiff, tiffData),
            ],
            // item 2: только не-string тип (fileURL)
            [
                (NSPasteboard.PasteboardType.fileURL, fileURLData),
            ],
        ]
        let (bridge, writtenSnapshots) = makeSnapshotMockBridge(initialSnapshot: initialSnapshot)

        Inserter.insertViaClipboard(text: "new-text", bridge: bridge)

        let writes = writtenSnapshots()
        XCTAssertEqual(writes.count, 2, "запись текста + восстановление старого буфера")

        // write[0] — единственный .string item с текстом диктовки
        XCTAssertTrue(sameSnapshot(writes[0], snapshot(containingText: "new-text")))

        // restore — полный слепок исходного буфера: все item'ы и все типы, не только строка
        XCTAssertTrue(
            sameSnapshot(writes[1], initialSnapshot),
            "restore должен вернуть все item'ы со всеми типами (включая не-text контент)"
        )
    }
}
