import Foundation

// MARK: - Статус агента: чистая логика меню (без ввода-вывода и AppKit)

/// Срез данных о состоянии агента для построения экрана «Статус».
/// Собирается в menu.swift (процессы/файлы), здесь — только отображение.
public struct AgentStatusData: Equatable {
    public var agentRunning: Bool
    public var agentPID: String?
    public var recordingActive: Bool
    public var providerName: String?
    public var providerID: String?
    public var providersEmpty: Bool
    public var logPath: String
    public var logSizeBytes: Int64
    public var logTail: [String]
    public var logHasErrors: Bool

    public init(
        agentRunning: Bool,
        agentPID: String? = nil,
        recordingActive: Bool = false,
        providerName: String? = nil,
        providerID: String? = nil,
        providersEmpty: Bool = false,
        logPath: String = "",
        logSizeBytes: Int64 = 0,
        logTail: [String] = [],
        logHasErrors: Bool = false
    ) {
        self.agentRunning = agentRunning
        self.agentPID = agentPID
        self.recordingActive = recordingActive
        self.providerName = providerName
        self.providerID = providerID
        self.providersEmpty = providersEmpty
        self.logPath = logPath
        self.logSizeBytes = logSizeBytes
        self.logTail = logTail
        self.logHasErrors = logHasErrors
    }
}

/// Один пункт меню: клавиша («1», «q»…) и подпись.
public struct MenuItem: Equatable {
    public let key: String
    public let label: String
    public init(key: String, label: String) {
        self.key = key
        self.label = label
    }
}

/// Действие пункта экрана «Статус» по ключу (чистая логика, без I/O).
/// I/O-слой (menu.swift) только исполняет возвращённый экшен.
public enum StatusMenuAction: Equatable {
    case toggleLanguage
    case showProviders
    case showLogs
    case toggleAgent
    case showLastResult
    case retryTranscribe
    case toggleReview
    case quit
}

/// Жест подтверждения в диалоге смены провайдера (уже отделён от терминала):
/// `.yes` — клавиша y, `.enter` — Enter, `.other` — любая иная клавиша.
public enum ConfirmationGesture: Equatable {
    case yes
    case enter
    case other
}

/// Гейт запуска меню: показывается ТОЛЬКО без команды И в интерактивном
/// терминале (tty). В пайпах/скриптах — прежнее поведение: usage + exit 0.
public enum MenuGate {
    public static func shouldRunMenu(hasCommand: Bool, tty: Bool) -> Bool {
        !hasCommand && tty
    }
}

/// Построение экранов и текстов меню. Никакого ввода/вывода — только строки.
public enum AgentScreen {

    /// Маппинг ключа экрана «Статус» в действие меню. Единый источник правды:
    /// именно он не даёт ключу "0" попасть в default (.quit) — пункт языка
    /// обязан переключать язык, а не выходить из меню.
    public static func statusMenuAction(forKey key: String) -> StatusMenuAction {
        switch key {
        case "0": return .toggleLanguage
        case "1": return .showProviders
        case "2": return .showLogs
        case "3": return .toggleAgent
        case "4": return .showLastResult
        case "5": return .retryTranscribe
        case "6": return .toggleReview
        default:  return .quit
        }
    }

    /// Заголовки и подсказки (владеет текстом меню; ANSI добавляет menu.swift).
    public static func statusTitle() -> String { L10n.tr("status.title") }
    public static func providersTitle() -> String { L10n.tr("menu.providers") }
    public static func logsTitle(lineCount: Int) -> String {
        L10n.tr("status.logs").replacingOccurrences(of: "{n}", with: "\(lineCount)")
    }

    public static func statusHint() -> String {
        L10n.tr("status.hintNav")
    }
    public static func providersHint() -> String {
        L10n.tr("status.hintProviders")
    }

    /// Принимает ли жест подтверждение смены провайдера: y и Enter — да,
    /// любая другая клавиша — нет (чистая логика, без чтения терминала).
    public static func confirmationAccepts(key: ConfirmationGesture) -> Bool {
        switch key {
        case .yes, .enter: return true
        case .other: return false
        }
    }
    public static func logsHint() -> String {
        L10n.tr("status.hintLogs")
    }

    /// События лога, после которых запись завершена (запись НЕ активна).
    private static let recordingEndMarkers = [
        "transcribe submit",     // запись остановлена и отправлена на распознавание
        "record cancelled",
        "record limit reached",  // жёсткий лимит — запись финализирована
        "transcription inserted",
        "transcription failed",
    ]

    /// Эвристика по логу агента: запись активна, если после последнего
    /// «record start» не было ни одного терминального события.
    public static func isRecordingActive(logLines: [String]) -> Bool {
        var lastStart = -1
        var lastEnd = -1
        for (index, line) in logLines.enumerated() {
            if line.contains("record start") { lastStart = index }
            if recordingEndMarkers.contains(where: { line.contains($0) }) { lastEnd = index }
        }
        return lastStart > lastEnd
    }

    public static func hasErrors(logLines: [String]) -> Bool {
        logLines.contains { $0.contains("[error]") }
    }

    public static func byteCountText(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useBytes]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// Строка провайдера как в `nanodictate status`.
    public static func providerLine(providerName: String?, providerID: String?, providersEmpty: Bool) -> String {
        if let name = providerName {
            if let id = providerID, id != name {
                return "\(name) [\(id)]"
            }
            return name
        }
        return providersEmpty
            ? L10n.tr("menu.noProvidersLegacy")
            : L10n.tr("menu.notSelected")
    }

    /// Выравнивание колонки значений: label + отступ = ровно 12 символов
    /// (значения начинаются с 13-й колонки независимо от длины метки EN/RU).
    private static func padCol12(_ label: String) -> String {
        label + String(repeating: " ", count: max(0, 12 - label.count))
    }

    /// Экран «Статус»: агент, запись, провайдер, лог (размер/ошибки/хвост).
    public static func statusScreen(_ s: AgentStatusData) -> String {
        let agent = s.agentRunning
            ? "running" + (s.agentPID.map { " (pid \($0))" } ?? "")
            : "stopped"
        let recording = s.recordingActive ? "active" : "idle"
        let errorsText = s.logHasErrors ? L10n.tr("status.hasErrors") : L10n.tr("status.noErrors")
        var lines = [
            "\(padCol12(L10n.tr("status.agent") + ":"))\(agent)",
            "\(padCol12(L10n.tr("status.recording") + ":"))\(recording)",
            "\(padCol12(L10n.tr("status.provider") + ":"))\(providerLine(providerName: s.providerName, providerID: s.providerID, providersEmpty: s.providersEmpty))",
            "\(padCol12(L10n.tr("status.log") + ":"))\(s.logPath)",
            "\(padCol12(L10n.tr("status.size") + ":"))\(byteCountText(s.logSizeBytes)) · \(errorsText)",
        ]
        if !s.logTail.isEmpty {
            lines.append("")
            lines.append(L10n.tr("status.logTail"))
            lines += s.logTail.map { "  " + $0 }
        }
        return lines.joined(separator: "\n")
    }

    /// Пункты экрана «Статус»: ключ + подпись (действия назначает menu.swift).
    public static func statusMenuItems(agentRunning: Bool) -> [MenuItem] {
        [
            MenuItem(key: "0", label: L10n.tr("menu.language")),
            MenuItem(key: "1", label: L10n.tr("menu.providers")),
            MenuItem(key: "2", label: L10n.tr("menu.logs")),
            MenuItem(key: "3", label: agentRunning ? L10n.tr("menu.stopAgent") : L10n.tr("menu.startAgent")),
            MenuItem(key: "4", label: L10n.tr("menu.showLastText")),
            MenuItem(key: "5", label: L10n.tr("menu.retryOther")),
            MenuItem(key: "6", label: L10n.tr("menu.reviewToggle")),
            MenuItem(key: "q", label: L10n.tr("menu.quit")),
        ]
    }

    /// Строка провайдера для экрана «Провайдеры»: `* Groq [groq] — model`.
    public static func providerItemLine(_ p: STTProvider) -> String {
        let marker = p.isActive ? "*" : " "
        let name = p.name.isEmpty ? p.id : p.name
        return "\(marker) \(name) [\(p.id)] — \(p.model)"
    }

    public static func providersBody(providers: [STTProvider]) -> String {
        providers.map { providerItemLine($0) }.joined(separator: "\n")
    }

    /// Результат валидации выбора провайдера (без IO).
    public enum ProviderSwitchResult: Equatable {
        case ok(targetID: String)
        case unknownProvider(id: String, available: [String])
        case empty
    }

    /// Чистая проверка: существует ли провайдер с таким id (до реальной правки конфига).
    public static func validateProviderSwitch(targetID: String, providers: [STTProvider]) -> ProviderSwitchResult {
        guard !providers.isEmpty else { return .empty }
        guard providers.contains(where: { $0.id == targetID }) else {
            return .unknownProvider(id: targetID, available: providers.map { $0.id })
        }
        return .ok(targetID: targetID)
    }
}