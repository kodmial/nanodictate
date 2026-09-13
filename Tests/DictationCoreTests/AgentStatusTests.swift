import Foundation
@testable import DictationCore

/// Тесты чистой логики интерактивного меню (AgentStatus + MenuGate).
/// Никакого реального ввода/вывода: только строки, структуры и ProviderStore
/// поверх tmp-конфига (configPathOverride — как в ProviderTests).
final class AgentStatusTests: XCTestCase {

    private func tmpFile(_ name: String, _ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)_\(UUID().uuidString).toml")
        try content.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: - Гейт меню (fallback на usage при не-TTY)

    @objc func testMenuGateRequiresNoCommandAndTTY() {
        // Без команды в TTY → меню.
        XCTAssertTrue(MenuGate.shouldRunMenu(hasCommand: false, tty: true))
        // Без команды в pipe/скрипте → прежнее поведение (usage + exit 0).
        XCTAssertFalse(MenuGate.shouldRunMenu(hasCommand: false, tty: false))
        // С командой — меню не мешает командам.
        XCTAssertFalse(MenuGate.shouldRunMenu(hasCommand: true, tty: true))
        XCTAssertFalse(MenuGate.shouldRunMenu(hasCommand: true, tty: false))
    }

    // MARK: - Запись по логу

    @objc func testRecordingActiveAfterRecordStart() {
        let lines = ["mic permission check: authorized", "record start"]
        XCTAssertTrue(AgentScreen.isRecordingActive(logLines: lines))
    }

    @objc func testRecordingInactiveAfterTerminalEvents() {
        XCTAssertFalse(AgentScreen.isRecordingActive(
            logLines: ["record start", "transcribe submit (100 samples, 0.00 s)"]
        ))
        XCTAssertFalse(AgentScreen.isRecordingActive(
            logLines: ["record start", "transcription inserted (42 chars)"]
        ))
        XCTAssertFalse(AgentScreen.isRecordingActive(
            logLines: ["record start", "record cancelled"]
        ))
        XCTAssertFalse(AgentScreen.isRecordingActive(
            logLines: ["record start", "record limit reached (960000 samples)"]
        ))
        XCTAssertFalse(AgentScreen.isRecordingActive(
            logLines: ["record start", "transcribe submit (100 samples, 0.00 s)", "transcription failed: HTTP 500"]
        ))
    }

    @objc func testRecordingActiveAcrossPreviousCycle() {
        // Вторая запись началась после завершения первой — активна.
        let lines = [
            "record start",
            "transcription inserted (10 chars)",
            "record start",
        ]
        XCTAssertTrue(AgentScreen.isRecordingActive(logLines: lines))
    }

    @objc func testRecordingInactiveWhenEmptyLog() {
        XCTAssertFalse(AgentScreen.isRecordingActive(logLines: []))
        XCTAssertFalse(AgentScreen.isRecordingActive(logLines: ["mic denied"]))
    }

    // MARK: - Ошибки в логе

    @objc func testHasErrorsDetectsErrorLevel() {
        XCTAssertTrue(AgentScreen.hasErrors(
            logLines: ["2026-09-13 10:00:00 [error] transcription failed: boom", "2026-09-13 10:00:01 [info] ok"]
        ))
        XCTAssertFalse(AgentScreen.hasErrors(logLines: ["2026-09-13 10:00:00 [info] record start"]))
        XCTAssertFalse(AgentScreen.hasErrors(logLines: []))
    }

    // MARK: - Строка провайдера

    @objc func testProviderLineVariants() {
        XCTAssertEqual(
            AgentScreen.providerLine(providerName: nil, providerID: nil, providersEmpty: true),
            "(нет провайдеров — legacy-конфиг)"
        )
        XCTAssertEqual(
            AgentScreen.providerLine(providerName: nil, providerID: nil, providersEmpty: false),
            "(не выбран — `dictatorctl provider use <имя>`)"
        )
        XCTAssertEqual(
            AgentScreen.providerLine(providerName: "Groq", providerID: "groq", providersEmpty: false),
            "Groq [groq]"
        )
        XCTAssertEqual(
            AgentScreen.providerLine(providerName: "ya", providerID: "ya", providersEmpty: false),
            "ya"
        )
    }

    // MARK: - Экран статуса

    @objc func testStatusScreenRunningActiveWithProvider() {
        let data = AgentStatusData(
            agentRunning: true, agentPID: "123",
            recordingActive: true,
            providerName: "Groq", providerID: "groq",
            logPath: "/tmp/agent.log", logSizeBytes: 1024,
            logTail: ["record start"], logHasErrors: false
        )
        let screen = AgentScreen.statusScreen(data)
        XCTAssertTrue(screen.contains("running (pid 123)"))
        XCTAssertTrue(screen.contains("Запись:     active"))
        XCTAssertTrue(screen.contains("Groq [groq]"))
        XCTAssertTrue(screen.contains("Хвост лога:"))
        XCTAssertTrue(screen.contains("record start"))
        XCTAssertTrue(screen.contains("ошибки: нет"))
        XCTAssertFalse(screen.contains("[error]"))
    }

    @objc func testStatusScreenStoppedIdleLegacy() {
        let data = AgentStatusData(
            agentRunning: false, agentPID: nil,
            recordingActive: false,
            providerName: nil, providerID: nil, providersEmpty: true,
            logPath: "/tmp/x.log", logSizeBytes: 0, logTail: [], logHasErrors: true
        )
        let screen = AgentScreen.statusScreen(data)
        XCTAssertTrue(screen.contains("stopped"))
        XCTAssertTrue(screen.contains("Запись:     idle"))
        XCTAssertTrue(screen.contains("legacy-конфиг"))
        XCTAssertTrue(screen.contains("ошибки: есть"))
    }

    // MARK: - Пункты меню (выбор пункта)

    @objc func testStatusMenuItemsWhenAgentRunning() {
        let items = AgentScreen.statusMenuItems(agentRunning: true)
        XCTAssertEqual(items.map { $0.key }, ["1", "2", "3", "q"])
        XCTAssertEqual(items[0].label, "Провайдеры")
        XCTAssertEqual(items[1].label, "Логи")
        XCTAssertEqual(items[2].label, "Остановить агента")
    }

    @objc func testStatusMenuItemsWhenAgentStopped() {
        let items = AgentScreen.statusMenuItems(agentRunning: false)
        XCTAssertEqual(items[2].label, "Запустить агента")
        XCTAssertEqual(items.last?.key, "q")
        XCTAssertEqual(items.last?.label, "Выход")
    }

    @objc func testTitlesAndHints() {
        XCTAssertEqual(AgentScreen.statusTitle(), "AltDictation — статус")
        XCTAssertEqual(AgentScreen.providersTitle(), "Провайдеры")
        XCTAssertEqual(AgentScreen.logsTitle(lineCount: 7), "Логи — agent.log (всего 7 строк)")
        XCTAssertTrue(AgentScreen.statusHint().contains("q/esc"))
        XCTAssertTrue(AgentScreen.providersHint().contains("r — обновить"))
        // Подсказка честно обещает подтверждение смены: y/Enter — да.
        XCTAssertTrue(AgentScreen.providersHint().contains("y/Enter — подтвердить"))
        XCTAssertTrue(AgentScreen.logsHint().contains("↑/↓"))
    }

    // MARK: - Подтверждение смены провайдера (Enter наравне с y)

    @objc func testConfirmationAcceptsEnterAndYes() {
        XCTAssertTrue(AgentScreen.confirmationAccepts(key: .yes))
        XCTAssertTrue(AgentScreen.confirmationAccepts(key: .enter))
        XCTAssertFalse(AgentScreen.confirmationAccepts(key: .other))
    }

    // MARK: - Экран провайдеров

    @objc func testProviderItemLines() {
        let active = STTProvider(id: "groq", name: "Groq", baseURL: "https://groq.test/v1",
                                 model: "whisper-large-v3", isActive: true)
        let idle = STTProvider(id: "ya", name: "", baseURL: "https://ya.test/v1",
                               model: "gigaam-v3", isActive: false)
        XCTAssertEqual(AgentScreen.providerItemLine(active), "* Groq [groq] — whisper-large-v3")
        // Пустое name → fallback на id.
        XCTAssertEqual(AgentScreen.providerItemLine(idle), "  ya [ya] — gigaam-v3")
        let body = AgentScreen.providersBody(providers: [active, idle])
        XCTAssertTrue(body.contains("* Groq"))
        XCTAssertTrue(body.contains("  ya"))
    }

    // MARK: - Валидация переключения провайдера (чистая, без IO)

    @objc func testValidateProviderSwitchOK() {
        let providers = [
            STTProvider(id: "groq", name: "", baseURL: "", model: "", isActive: true),
            STTProvider(id: "ya", name: "", baseURL: "", model: "", isActive: false),
        ]
        XCTAssertEqual(AgentScreen.validateProviderSwitch(targetID: "ya", providers: providers), .ok(targetID: "ya"))
    }

    @objc func testValidateProviderSwitchUnknownAndEmpty() {
        let providers = [STTProvider(id: "groq", name: "", baseURL: "", model: "", isActive: true)]
        XCTAssertEqual(
            AgentScreen.validateProviderSwitch(targetID: "nope", providers: providers),
            .unknownProvider(id: "nope", available: ["groq"])
        )
        XCTAssertEqual(AgentScreen.validateProviderSwitch(targetID: "x", providers: []), .empty)
    }

    // MARK: - Переключение через ProviderStore (реальный IO в tmp-конфиг)

    @objc func testProviderSwitchThroughStoreUpdatesActive() throws {
        let url = try tmpFile("menu_switch", """
        active_provider = "groq"
        [providers.groq]
        base_url = "https://groq.test/v1"
        [providers.ya]
        base_url = "https://ya.test/v1"
        """)
        ProviderStore.configPathOverride = url.path
        defer { ProviderStore.configPathOverride = nil }

        let providers = try ProviderStore.loadProviders()
        // Валидация проходит → реальное переключение через ProviderStore.
        XCTAssertEqual(AgentScreen.validateProviderSwitch(targetID: "ya", providers: providers), .ok(targetID: "ya"))
        try ProviderStore.setActive(providerID: "ya")

        let after = try ProviderStore.loadProviders()
        XCTAssertTrue(after.first { $0.id == "ya" }!.isActive)
        XCTAssertFalse(after.first { $0.id == "groq" }!.isActive)
        XCTAssertEqual(ProviderStore.activeProvider?.id, "ya")
    }

    @objc func testProviderSwitchUnknownViaStoreThrows() throws {
        let url = try tmpFile("menu_unknown", """
        [providers.groq]
        base_url = "https://groq.test/v1"
        """)
        ProviderStore.configPathOverride = url.path
        defer { ProviderStore.configPathOverride = nil }

        let providers = try ProviderStore.loadProviders()
        XCTAssertEqual(
            AgentScreen.validateProviderSwitch(targetID: "nope", providers: providers),
            .unknownProvider(id: "nope", available: ["groq"])
        )
        XCTAssertThrowsError(try ProviderStore.setActive(providerID: "nope")) { error in
            guard case ProviderStoreError.unknownProvider(let id, _) = error else {
                XCTFail("expected unknownProvider, got \(error)")
                return
            }
            XCTAssertEqual(id, "nope")
        }
    }
}