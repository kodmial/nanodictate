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
            "(no providers — legacy config)"
        )
        XCTAssertEqual(
            AgentScreen.providerLine(providerName: nil, providerID: nil, providersEmpty: false),
            "(not selected — dictatorctl provider use <name>)"
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
        XCTAssertTrue(screen.contains("Recording:  active"))
        XCTAssertTrue(screen.contains("Groq [groq]"))
        XCTAssertTrue(screen.contains("Log tail:"))
        XCTAssertTrue(screen.contains("record start"))
        XCTAssertTrue(screen.contains("errors: no"))
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
        XCTAssertTrue(screen.contains("Recording:  idle"))
        XCTAssertTrue(screen.contains("legacy config"))
        XCTAssertTrue(screen.contains("errors: yes"))
    }

    // MARK: - Пара: таблицы L10n (en/ru идентичны по ключам и плейсхолдерам)

    @objc func testL10nTableParity() {
        let en = L10n.table(.en)
        let ru = L10n.table(.ru)
        XCTAssertEqual(Set(en.keys), Set(ru.keys), "наборы ключей en/ru должны совпадать")
        XCTAssertGreaterThanOrEqual(en.count, 90, "таблица должна содержать ~90+ ключей")
    }

    @objc func testL10nPlaceholderParity() {
        let en = L10n.table(.en)
        let ru = L10n.table(.ru)
        let placeholders = ["{n}", "{message}", "{path}", "{error}"]
        for key in en.keys {
            for ph in placeholders where en[key]!.contains(ph) {
                XCTAssertTrue(ru[key]!.contains(ph), "RU: у ключа \(key) нет плейсхолдера \(ph)")
            }
            for ph in placeholders where ru[key]!.contains(ph) {
                XCTAssertTrue(en[key]!.contains(ph), "EN: у ключа \(key) нет плейсхолдера \(ph)")
            }
        }
    }

    // MARK: - Экран статуса: выравнивание колонки значений (13-я колонка)

    @objc func testStatusScreenColumn13BothLanguages() {
        let data = AgentStatusData(
            agentRunning: true, agentPID: "123",
            recordingActive: true,
            providerName: "Groq", providerID: "groq",
            logPath: "/tmp/agent.log", logSizeBytes: 1024,
            logTail: [], logHasErrors: false
        )
        defer { L10n.language = .en }
        for lang in AppLanguage.allCases {
            L10n.language = lang
            let screen = AgentScreen.statusScreen(data)
            let lines = screen.split(separator: "\n").prefix(5).map(String.init)
            for line in lines {
                XCTAssertGreaterThanOrEqual(line.count, 13, "\(lang): строка короче 13 символов: '\(line)'")
                XCTAssertTrue(String(line[String.Index(utf16Offset: 11, in: line)]) == " ",
                              "\(lang): в 12-й колонке должен быть пробел-отступ: '\(line)'")
                XCTAssertTrue(String(line[String.Index(utf16Offset: 12, in: line)]) != " ",
                              "\(lang): значение должно начинаться с 13-й колонки: '\(line)'")
            }
        }
    }

    // MARK: - Пункты меню (выбор пункта)

    @objc func testStatusMenuItemsWhenAgentRunning() {
        let items = AgentScreen.statusMenuItems(agentRunning: true)
        // 0 — язык; 4/5/6 — пункты UX-улучшений: последний текст, retry другим
        // провайдером, тумблер ревью. Базовые 1/2/3/q сохраняют места.
        XCTAssertEqual(items.map { $0.key }, ["0", "1", "2", "3", "4", "5", "6", "q"])
        XCTAssertEqual(items[0].label, "Language")
        XCTAssertEqual(items[1].label, "Providers")
        XCTAssertEqual(items[2].label, "Logs")
        XCTAssertEqual(items[3].label, "Stop agent")
        XCTAssertEqual(items[4].label, "Show last recognition text")
        XCTAssertEqual(items[5].label, "Re-recognize with different provider")
        XCTAssertEqual(items[6].label, "Review before insert (on/off)")
        XCTAssertEqual(items[7].label, "Quit")
    }

    @objc func testStatusMenuItemsWhenAgentStopped() {
        let items = AgentScreen.statusMenuItems(agentRunning: false)
        XCTAssertEqual(items[3].label, "Start agent")
        XCTAssertEqual(items.last?.key, "q")
        XCTAssertEqual(items.last?.label, "Quit")
    }

    @objc func testTitlesAndHints() {
        XCTAssertEqual(AgentScreen.statusTitle(), "AltDictation — status")
        XCTAssertEqual(AgentScreen.providersTitle(), "Providers")
        XCTAssertEqual(AgentScreen.logsTitle(lineCount: 7), "Logs — agent.log (7 lines total)")
        XCTAssertTrue(AgentScreen.statusHint().contains("q/esc"))
        XCTAssertTrue(AgentScreen.providersHint().contains("r — refresh"))
        // Подсказка честно обещает подтверждение смены: y/Enter — да.
        XCTAssertTrue(AgentScreen.providersHint().contains("y/Enter — confirm"))
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

    // MARK: - L10n.tr(): fallback на ключ для неизвестных ключей

    @objc func testTrFallbackReturnsKeyForUnknown() {
        defer { L10n.language = .en }
        let key = "no.such.key.xyz"
        L10n.language = .en
        XCTAssertEqual(L10n.tr(key), key, "EN: tr() должен вернуть сам ключ при отсутствии перевода")
        L10n.language = .ru
        XCTAssertEqual(L10n.tr(key), key, "RU: tr() должен вернуть сам ключ при отсутствии перевода")
    }

    // MARK: - L10n.toggled(): переключение языка

    @objc func testToggleLanguageFlipsEnRu() {
        defer { L10n.language = .en }
        L10n.language = .en
        XCTAssertEqual(L10n.toggled(), .ru)
        L10n.language = .ru
        XCTAssertEqual(L10n.toggled(), .en)
    }

    // MARK: - statusMenuAction(forKey:): ключ "0" = toggleLanguage, НЕ quit

    @objc func testStatusMenuKeyZeroTogglesLanguageNotQuit() {
        XCTAssertEqual(AgentScreen.statusMenuAction(forKey: "0"), .toggleLanguage,
                       "Ключ 0 должен переключать язык, а не выходить")
        XCTAssertEqual(AgentScreen.statusMenuAction(forKey: "1"), .showProviders)
        XCTAssertEqual(AgentScreen.statusMenuAction(forKey: "2"), .showLogs)
        XCTAssertEqual(AgentScreen.statusMenuAction(forKey: "3"), .toggleAgent)
        XCTAssertEqual(AgentScreen.statusMenuAction(forKey: "4"), .showLastResult)
        XCTAssertEqual(AgentScreen.statusMenuAction(forKey: "5"), .retryTranscribe)
        XCTAssertEqual(AgentScreen.statusMenuAction(forKey: "6"), .toggleReview)
        XCTAssertEqual(AgentScreen.statusMenuAction(forKey: "q"), .quit)
        XCTAssertEqual(AgentScreen.statusMenuAction(forKey: ""), .quit)
    }

    // MARK: - ui_language: roundtrip через AppConfig.writeKeyValue

    @objc func testUiLanguageReadAndWrite() {
        guard let url = try? tmpFile("lang_roundtrip", """
        ui_language = "en"
        [providers.groq]
        base_url = "https://groq.test/v1"
        """) else {
            XCTFail("tmpFile failed")
            return
        }
        defer {
            try? FileManager.default.removeItem(at: url)
        }

        let saved = L10n.language
        defer { L10n.language = saved }

        do {
            try AppConfig.writeKeyValue(key: "ui_language", value: "\"ru\"", to: url.path)
            let config = try AppConfig.load(from: url.path)
            XCTAssertEqual(config.uiLanguage, "ru", "writeKeyValue должен записать 'ru', а load прочитать его")

            try AppConfig.writeKeyValue(key: "ui_language", value: "\"en\"", to: url.path)
            let config2 = try AppConfig.load(from: url.path)
            XCTAssertEqual(config2.uiLanguage, "en", "roundtrip обратно на en")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}