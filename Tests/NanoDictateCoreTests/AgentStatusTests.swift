import Foundation
@testable import NanoDictateCore

/// Pure interactive-menu logic tests (AgentStatus + MenuGate): no real IO —
/// strings, structures, ProviderStore over tmp-config (configPathOverride).
final class AgentStatusTests: XCTestCase {

    private func tmpFile(_ name: String, _ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)_\(UUID().uuidString).toml")
        try content.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: - Гейт меню (fallback на usage при не-TTY)

    @objc func testMenuGateRequiresNoCommandAndTTY() {
        XCTAssertTrue(MenuGate.shouldRunMenu(hasCommand: false, tty: true))
        // Pipe without command → legacy behavior (usage + exit 0).
        XCTAssertFalse(MenuGate.shouldRunMenu(hasCommand: false, tty: false))
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
        // Recording restarted after previous cycle completed → active.
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

    @objc func testRecordingInactiveAfterNewEndMarkers() {
        XCTAssertFalse(AgentScreen.isRecordingActive(
            logLines: ["record start", "microphone unavailable: boom"]
        ))
        XCTAssertFalse(AgentScreen.isRecordingActive(
            logLines: ["record start", "empty transcription result — not inserted"]
        ))
        XCTAssertFalse(AgentScreen.isRecordingActive(
            logLines: ["record start", "transcription cancelled by review gate"]
        ))
        XCTAssertFalse(AgentScreen.isRecordingActive(
            logLines: ["record start", "chunked transcription cancelled by review gate"]
        ))
    }

    @objc func testRecordingStartRequiresSuffixNotSubstring() {
        XCTAssertFalse(AgentScreen.isRecordingActive(logLines: ["mic permission: authorized (record start)"]))
        XCTAssertFalse(AgentScreen.isRecordingActive(logLines: ["record start ignored: already starting"]))
        XCTAssertFalse(AgentScreen.isRecordingActive(logLines: ["record start timed out after 30 s"]))
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
            "(not selected — nanodictate provider use <name>)"
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
        let placeholders = ["{n}", "{message}", "{path}", "{error}", "<out>"]
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
        // 0 = language; 4/5/6 = UX items (last text, retry provider, review
        // toggle); base 1/2/3/q keep their slots.
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
        XCTAssertEqual(AgentScreen.statusTitle(), "NanoDictate — status")
        XCTAssertEqual(AgentScreen.providersTitle(), "Providers")
        XCTAssertEqual(AgentScreen.logsTitle(lineCount: 7), "Logs — agent.log (7 lines total)")
        XCTAssertTrue(AgentScreen.statusHint().contains("q/esc"))
        XCTAssertTrue(AgentScreen.providersHint().contains("r — refresh"))
        // Hint truthfully promises y/Enter confirmation.
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
        // Empty name → fallback to id.
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
        XCTAssertEqual(AgentScreen.validateProviderSwitch(targetID: "ya", providers: providers), .isValid(targetID: "ya"))
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
        XCTAssertEqual(AgentScreen.validateProviderSwitch(targetID: "ya", providers: providers), .isValid(targetID: "ya"))
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