import Darwin
import Foundation
import DictationCore

// MARK: - TTY-гейт

/// Терминал ли stdout: меню рисуется только при интерактивном выводе.
/// В пайпах/скриптах main.swift показывает usage, как раньше.
func isTTY() -> Bool {
    isatty(STDOUT_FILENO) == 1
}

// MARK: - Вывод: ANSI + raw-режим ввода

private let ansiHome = "\u{1B}[H"
private let ansiClear = "\u{1B}[2J"
private let ansiBold = "\u{1B}[1m"
private let ansiReset = "\u{1B}[0m"
private let ansiHideCursor = "\u{1B}[?25l"
private let ansiShowCursor = "\u{1B}[?25h"

/// Печатает кадр меню, стирая предыдущий.
private func render(_ text: String) {
    fputs(ansiHome + ansiClear + text + "\n", stdout)
    fflush(stdout)
}

/// Raw-режим stdin: клавиша читается без Enter и без эха.
private func setRawMode(_ on: Bool) {
    guard isatty(STDIN_FILENO) == 1 else { return }
    var t = termios()
    guard tcgetattr(STDIN_FILENO, &t) == 0 else { return }
    if on {
        t.c_lflag &= ~(tcflag_t(ICANON) | tcflag_t(ECHO))
        t.c_cc.16 = 1 // VMIN (Darwin)
        t.c_cc.17 = 0 // VTIME (Darwin)
    } else {
        t.c_lflag |= tcflag_t(ICANON) | tcflag_t(ECHO)
    }
    tcsetattr(STDIN_FILENO, TCSANOW, &t)
}

// MARK: - Восстановление терминала по сигналу (SIGINT/SIGTERM)

/// Снимок исходного termios до raw-режима — чтобы Ctrl+C / kill не оставили
/// терминал без эха (raw-режим ISIG: сигнал убивает процесс, defer не успевает).
private var originalTermios: termios?

/// Статический буфер «показать курсор + перевод строки»: безопасен даже в
/// async-signal контексте (без аллокаций).
private let showCursorPlusNewline: [UInt8] = Array("\u{1B}[?25h\n".utf8)

/// Восстанавливает termios и курсор, затем завершает процесс.
/// Нормальный путь выхода чистит defer в runMenu; этот хендлер — сигнальный.
private func restoreTerminalAndExit(_ sig: Int32) {
    if var t = originalTermios {
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &t)
    }
    _ = showCursorPlusNewline.withUnsafeBytes {
        write(STDOUT_FILENO, $0.baseAddress, $0.count)
    }
    _exit(sig)
}

/// Ставит обработчики SIGINT/SIGTERM. Делает снимок termios ДО raw-режима.
private func installSignalHandlers() {
    if isatty(STDIN_FILENO) == 1 {
        var t = termios()
        if tcgetattr(STDIN_FILENO, &t) == 0 { originalTermios = t }
    }
    let handler: @convention(c) (Int32) -> Void = { sig in
        restoreTerminalAndExit(sig)
    }
    var action = sigaction()
    sigemptyset(&action.sa_mask)
    action.sa_flags = 0 // без SA_RESTART: блокирующее чтение входа прерывается сигналом
    action.__sigaction_u.__sa_handler = handler
    _ = sigaction(SIGINT, &action, nil)
    _ = sigaction(SIGTERM, &action, nil)
}

/// Есть ли данные в stdin в течение ms (нужно отличить одиночный Esc от стрелки).
private func inputReady(_ ms: Int) -> Bool {
    var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
    return poll(&pfd, 1, Int32(ms)) > 0
}

// MARK: - Клавиши

private enum MenuKey {
    case quit, unknown, enter, up, down, refresh, yes
    case number(Int)
}

private func readMenuKey() -> MenuKey {
    var byte: UInt8 = 0
    guard read(STDIN_FILENO, &byte, 1) > 0 else { return .quit } // EOF — pipe закрыт
    switch byte {
    case 0x1B: // Esc или префикс стрелок "ESC [ A/B"
        if inputReady(50) {
            var b2: UInt8 = 0
            guard read(STDIN_FILENO, &b2, 1) > 0 else { return .quit }
            if b2 == 0x5B, inputReady(20) {
                var b3: UInt8 = 0
                if read(STDIN_FILENO, &b3, 1) > 0 {
                    switch b3 {
                    case 0x41: return .up
                    case 0x42: return .down
                    default: return .unknown
                    }
                }
            }
        }
        return .quit // одиночный Esc
    case 0x0A, 0x0D: return .enter
    case 0x71, 0x51: return .quit    // q / Q
    case 0x79, 0x59: return .yes     // y / Y
    case 0x72, 0x52: return .refresh // r / R
    case 0x30: return .number(0)
    case 0x31...0x39: return .number(Int(byte - 0x30))
    default: return .unknown
    }
}

// MARK: - Экраны и действия

private enum MenuAction {
    case quit, back, refresh, showProviders, showLogs, toggleAgent, toggleLanguage
    case switchProvider(String)
    case showLastResult, retryTranscribe, toggleReview
}

private struct MenuEntry {
    let key: MenuKey?
    let label: String
    let action: MenuAction
}

private enum MenuPage {
    case status, providers, logs
}

private struct MenuView {
    var page: MenuPage = .status
    var cursor = 0
    var providers: [STTProvider] = []
    var logLines: [String] = []
    var notice: String?
    /// Закэшированный статус агента: стрелки/Enter в цикле не должны делать
    /// 5 I/O-операций (pgrep, ProviderStore, лог, launchctl, stat) на КАЖДОЕ
    /// нажатие — см. lastStatusRefresh (обновление не чаще 1 раза в 2 секунды).
    var cachedStatus: AgentStatusData?
    var lastStatusRefresh = Date.distantPast
}

private func entryKeyText(_ key: MenuKey?) -> String {
    guard let key = key else { return "•" }
    switch key {
    case .number(let n): return "\(n)"
    case .quit: return "q"
    case .refresh: return "r"
    default: return "•"
    }
}

private func statusPageText(status: AgentStatusData, entries: [MenuEntry], cursor: Int, notice: String?) -> String {
    var lines = [ansiBold + AgentScreen.statusTitle() + ansiReset, String(repeating: "─", count: 28)]
    lines += AgentScreen.statusScreen(status).components(separatedBy: "\n")
    lines.append(String(repeating: "─", count: 28))
    lines.append(L10n.tr("menu.items"))
    for (i, e) in entries.enumerated() {
        let mark = i == cursor ? "›" : " "
        lines.append("\(mark) \(entryKeyText(e.key)) — \(e.label)")
    }
    lines.append("  " + AgentScreen.statusHint())
    if let n = notice { lines.append(ansiBold + n + ansiReset) }
    return lines.joined(separator: "\n")
}

private func providersPageText(providers: [STTProvider], cursor: Int, notice: String?) -> String {
    var lines = [ansiBold + AgentScreen.providersTitle() + ansiReset, String(repeating: "─", count: 28)]
    if providers.isEmpty {
        lines.append(L10n.tr("menu.empty.providers"))
    } else {
        for (i, p) in providers.enumerated() {
            let mark = i == cursor ? "›" : " "
            lines.append("\(mark) \(i + 1)) \(AgentScreen.providerItemLine(p))")
        }
    }
    lines.append(String(repeating: "─", count: 28))
    lines.append("  " + AgentScreen.providersHint())
    if let n = notice { lines.append(ansiBold + n + ansiReset) }
    return lines.joined(separator: "\n")
}

private func logsPageText(lines: [String], window: Int, top: Int) -> String {
    var out = [ansiBold + AgentScreen.logsTitle(lineCount: lines.count) + ansiReset,
               String(repeating: "─", count: 28)]
    if lines.isEmpty {
        out.append(L10n.tr("menu.empty.log"))
    } else {
        let end = min(top + window, lines.count)
        for i in top..<end { out.append(lines[i]) }
    }
    out.append(String(repeating: "─", count: 28))
    out.append("  " + AgentScreen.logsHint())
    return out.joined(separator: "\n")
}

// MARK: - Пункты

private func statusEntries(agentRunning: Bool) -> [MenuEntry] {
    // Пункт языка добавляем ровно ОДИН раз: statusMenuItems() тоже возвращает
    // ключ "0" — дублировать его нельзя (раньше маппинг без case "0" уводил
    // дубль в default → .quit, и меню рисовало лишнюю строку "q — Language",
    // Enter по которой ВЫХОДИЛ из меню вместо переключения языка).
    var entries = [MenuEntry(key: .number(0), label: L10n.tr("menu.language"), action: .toggleLanguage)]
    entries += AgentScreen.statusMenuItems(agentRunning: agentRunning).compactMap { item in
        // "0" уже добавлен первым пунктом — не рисуем дубль.
        guard item.key != "0" else { return nil }
        let key: MenuKey = Int(item.key).map(MenuKey.number) ?? .quit
        let action: MenuAction
        switch AgentScreen.statusMenuAction(forKey: item.key) {
        case .toggleLanguage:  action = .toggleLanguage
        case .showProviders:   action = .showProviders
        case .showLogs:        action = .showLogs
        case .toggleAgent:     action = .toggleAgent
        case .showLastResult:  action = .showLastResult
        case .retryTranscribe: action = .retryTranscribe
        case .toggleReview:    action = .toggleReview
        case .quit:            action = .quit
        }
        return MenuEntry(key: key, label: item.label, action: action)
    }
    return entries
}

private func providerEntries(_ providers: [STTProvider]) -> [MenuEntry] {
    providers.enumerated().map { i, p in
        MenuEntry(key: .number(i + 1), label: "", action: .switchProvider(p.id))
    }
}

// MARK: - Сбор данных статуса

private func agentIsRunning() -> Bool {
    runProcess("/bin/launchctl", ["print", "\(guiDomain)/com.dictation.agent"]).status == 0
}

private func logFileURL() -> URL {
    let dir = (Logger.logDirectory as NSString).expandingTildeInPath
    return URL(fileURLWithPath: dir).appendingPathComponent("agent.log")
}

/// Читает хвост лог-файла: последний 1 МБ через FileHandle-seek,
/// возвращает не более `maxLines` непустых строк.  Вместо полного
/// чтения (~23 МБ → 1.7 с) — ≈80 мс (×20 ускорение).
/// `isRecordingActive` и `hasErrors` сканируют хвост — для TUI-статуса
/// этого достаточно: последние start/end markers всегда в хвосте лога.
private func readLogFile(maxLines: Int = 500) -> [String] {
    let url = logFileURL()
    guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
    defer { handle.closeFile() }
    let fileSize = handle.seekToEndOfFile()
    guard fileSize > 0 else { return [] }
    let maxRead: UInt64 = 1_024 * 1_024   // 1 МБ — ≈12 000 строк @ ~80 байт
    let readSize = min(fileSize, maxRead)
    handle.seek(toFileOffset: fileSize - readSize)
    let data = handle.readData(ofLength: Int(readSize))
    let text = String(data: data, encoding: .utf8) ?? ""
    var lines = text.components(separatedBy: .newlines)
    // Первая строка может быть обрезана (начинались с середины строки) — пропускаем.
    if readSize < fileSize && !lines.isEmpty { lines.removeFirst() }
    return Array(lines.filter { !$0.isEmpty }.suffix(maxLines))
}

private func collectStatus() -> AgentStatusData {
    var pid: String?
    let pgrep = runProcess("/usr/bin/pgrep", ["-f", "DictatorAgent"])
    if pgrep.status == 0,
       let first = pgrep.stdout.split(whereSeparator: \.isWhitespace).map(String.init).first {
        pid = first
    }
    var providerName: String?
    var providerID: String?
    var providersEmpty = false
    do {
        let list = try ProviderStore.loadProviders()
        if let active = ProviderStore.activeProvider {
            providerName = active.name
            providerID = active.id
        } else if list.isEmpty {
            providersEmpty = true
        }
    } catch { /* сломанный/legacy-конфиг — строка «не выбран» */ }
    let logLines = readLogFile()
    let logURL = logFileURL()
    let size = ((try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? NSNumber)?.int64Value ?? 0
    return AgentStatusData(
        agentRunning: agentIsRunning(),
        agentPID: pid,
        recordingActive: AgentScreen.isRecordingActive(logLines: logLines),
        providerName: providerName,
        providerID: providerID,
        providersEmpty: providersEmpty,
        logPath: logURL.path,
        logSizeBytes: size,
        logTail: Array(logLines.suffix(5)),
        logHasErrors: AgentScreen.hasErrors(logLines: logLines)
    )
}

// MARK: - Действия

/// Выполняет подкоманду через сам бинарь (reuse cmdStart/cmdStop без дублирования),
/// возвращая её печатный вывод одной строкой.
private func runSelfCommand(_ subcommand: String) -> String {
    let exe = CommandLine.arguments.first ?? ""
    let result = runProcess(exe, [subcommand])
    let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if !out.isEmpty { return out }
    let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    return err.isEmpty ? String(format: L10n.tr("menu.agent.notfound"), "\(result.status)") : err
}

/// Перевод клавиши меню в жест подтверждения (чистую логику принимает AgentScreen).
private func confirmationGesture(_ key: MenuKey) -> ConfirmationGesture {
    switch key {
    case .yes: return .yes
    case .enter: return .enter
    default: return .other
    }
}

/// Подтверждение + переключение активного провайдера + рестарт агента
/// (как `dictatorctl provider use`, без --no-restart). Возвращает текст для notice.
private func confirmAndSwitchProvider(_ provider: STTProvider, _ view: inout MenuView) -> String {
    let display = provider.name.isEmpty ? provider.id : provider.name
    render(ansiBold + String(format: L10n.tr("menu.switch.confirm"), display, provider.id) + ansiReset
        + "\n\(L10n.tr("menu.switch.hint"))")
    guard AgentScreen.confirmationAccepts(key: confirmationGesture(readMenuKey())) else { return L10n.tr("menu.switch.cancelled") }
    do {
        try ProviderStore.setActive(providerID: provider.id)
    } catch {
        return String(format: L10n.tr("menu.switch.error"), "\(error)")
    }
    let kick = runProcess("/bin/launchctl", ["kickstart", "-k", "\(guiDomain)/com.dictation.agent"])
    let kickMsg = kick.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let restart = kick.status == 0
        ? L10n.tr("cli.provider.restart")
        : String(format: L10n.tr("cli.provider.kickfail"), kickMsg.isEmpty ? kick.stdout : kickMsg)
    return String(format: L10n.tr("menu.switch.ok"), display, restart)
}

/// Выполняет действие пункта меню. true — нужно выйти из меню.
@discardableResult
private func execute(_ action: MenuAction, _ view: inout MenuView) -> Bool {
    switch action {
    case .quit:
        return true
    case .back:
        view.page = .status
        view.cursor = 0
        view.notice = nil
    case .refresh:
        view.providers = (try? ProviderStore.loadProviders()) ?? []
        view.logLines = readLogFile()
        view.cursor = 0
        view.lastStatusRefresh = .distantPast
    case .showProviders:
        view.page = .providers
        view.cursor = 0
        view.notice = nil
    case .showLogs:
        view.page = .logs
        view.cursor = max(0, view.logLines.count - 20)
        view.notice = nil
    case .toggleAgent:
        view.notice = agentIsRunning() ? runSelfCommand("stop") : runSelfCommand("start")
        view.page = .status
        view.cursor = 0
        view.lastStatusRefresh = .distantPast // агент старт/стоп → статус
    case .switchProvider(let id):
        guard let provider = view.providers.first(where: { $0.id == id }) else {
            view.notice = String(format: L10n.tr("menu.switch.error"), id)
            break
        }
        view.notice = confirmAndSwitchProvider(provider, &view)
        view.page = .providers
        view.cursor = 0
        view.providers = (try? ProviderStore.loadProviders()) ?? []
    case .showLastResult:
        view.notice = runSelfCommand("last")
    case .retryTranscribe:
        guard !view.providers.isEmpty else {
            view.notice = L10n.tr("menu.no.providers.retry")
            break
        }
        let prompt = ansiBold + L10n.tr("menu.retry.prompt") + ansiReset
            + "\n" + view.providers.enumerated()
                .map { "  \($0.offset + 1)) \(AgentScreen.providerItemLine($0.element))" }
                .joined(separator: "\n")
            + "\n\(L10n.tr("menu.retry.hint"))"
        render(prompt)
        guard case .number(let n) = readMenuKey(),
              n >= 1, n <= view.providers.count else {
            view.notice = L10n.tr("menu.switch.cancelled")
            break
        }
        view.notice = runSelfCommand("retry \(view.providers[n - 1].id)")
    case .toggleReview:
        let current = (try? AppConfig.load(from: nil))?.reviewBeforeInsert ?? false
        let newValue = !current
        do {
            try AppConfig.writeReviewBeforeInsert(value: newValue, to: AppConfig.defaultPath())
            let kick = runProcess("/bin/launchctl", ["kickstart", "-k", "\(guiDomain)/com.dictation.agent"])
            let kickMsg = kick.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let restart = kick.status == 0
                ? L10n.tr("cli.provider.restart")
                : String(format: L10n.tr("cli.provider.kickfail"), kickMsg.isEmpty ? kick.stdout : kickMsg)
            if newValue {
                // Под launchd у агента нет терминала: гейт ревью пропускается
                // (см. hasInteractiveStdin в main.swift) — предупреждаем заранее.
                view.notice = String(format: L10n.tr("menu.review.on"), restart)
            } else {
                view.notice = String(format: L10n.tr("menu.review.off"), restart)
            }
        } catch {
            view.notice = String(format: L10n.tr("menu.review.configerror"), "\(error)")
        }
    case .toggleLanguage:
        let newLang = L10n.language == .en ? "ru" : "en"
        try? AppConfig.writeKeyValue(key: "ui_language", value: newLang, to: AppConfig.defaultPath())
        L10n.language = newLang == "ru" ? .ru : .en
        view.notice = L10n.tr("menu.language") + ": " + (L10n.language == .en ? L10n.tr("menu.languageEn") : L10n.tr("menu.languageRu"))
    }
    return false
}

// MARK: - Главный цикл

func runMenu() -> Int32 {
    // Меню требует TTY и на вывод, и на ввод; иначе — тихий выход к usage в main.swift.
    guard isTTY(), isatty(STDIN_FILENO) == 1 else { return 0 }
    let uiLanguage = (try? AppConfig.load(from: nil))?.uiLanguage
    L10n.language = uiLanguage == "ru" ? .ru : .en
    installSignalHandlers() // снимок termios до raw-режима + SIGINT/SIGTERM
    setRawMode(true)
    defer {
        setRawMode(false)
        fputs(ansiShowCursor, stdout)
        fflush(stdout)
    }
    fputs(ansiHideCursor, stdout)

    var view = MenuView()
    view.providers = (try? ProviderStore.loadProviders()) ?? []
    view.logLines = readLogFile()
    view.cursor = 0

    while true {
        var entries: [MenuEntry] = []
        var text = ""
        switch view.page {
        case .status:
            // collectStatus() = 5 I/O-операций (pgrep, ProviderStore.loadProviders,
            // readLogFile, launchctl print, attributesOfItem). Кэш с TTL 2 с:
            // обработка клавиш (стрелки/Enter) НЕ блокируется на I/O — статус
            // обновляется не чаще раза в 2 секунды, перерисовка мгновенная.
            if view.cachedStatus == nil || Date().timeIntervalSince(view.lastStatusRefresh) >= 2.0 {
                view.cachedStatus = collectStatus()
                view.lastStatusRefresh = Date()
            }
            let status = view.cachedStatus!
            entries = statusEntries(agentRunning: status.agentRunning)
            view.cursor = min(view.cursor, max(0, entries.count - 1))
            text = statusPageText(status: status, entries: entries, cursor: view.cursor, notice: view.notice)
        case .providers:
            entries = providerEntries(view.providers)
            view.cursor = min(view.cursor, max(0, entries.count - 1))
            text = providersPageText(providers: view.providers, cursor: view.cursor, notice: view.notice)
        case .logs:
            let maxTop = max(0, view.logLines.count - 20)
            view.cursor = min(view.cursor, maxTop)
            text = logsPageText(lines: view.logLines, window: 20, top: view.cursor)
        }
        render(text)

        switch readMenuKey() {
        case .quit:
            // На Статусе q/esc — выход; на Провайдерах/Логах — возврат на Статус
            // (так обещает подсказка «q/esc — назад», и так подключён живой .back).
            if view.page == .status { return 0 }
            execute(.back, &view)
        case .unknown, .yes:
            continue
        case .refresh:
            view.providers = (try? ProviderStore.loadProviders()) ?? []
            view.logLines = readLogFile()
            view.cursor = 0
            view.lastStatusRefresh = .distantPast // r — принудительно свежий статус
        case .up:
            view.cursor = max(0, view.cursor - 1)
        case .down:
            switch view.page {
            case .logs:
                let maxTop = max(0, view.logLines.count - 20)
                view.cursor = min(maxTop, view.cursor + 1)
            case .status:
                if view.cursor < entries.count - 1 { view.cursor += 1 }
            case .providers:
                if view.cursor < view.providers.count - 1 { view.cursor += 1 }
            }
        case .enter:
            if view.cursor < entries.count, execute(entries[view.cursor].action, &view) {
                return 0
            }
        case .number(let n):
            if let entry = entries.first(where: {
                if case .number(let k) = $0.key { return k == n } else { return false }
            }), execute(entry.action, &view) {
                return 0
            }
        }
    }
}