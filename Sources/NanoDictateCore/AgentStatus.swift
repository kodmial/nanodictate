import Foundation

// MARK: - Статус агента: чистая логика меню (без ввода-вывода и AppKit)

/// Agent state snapshot for Status screen; gathered in menu.swift, rendered here.
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

/// Menu row: shortcut key ("1", "q") + label.
public struct MenuItem: Equatable {
  public let key: String
  public let label: String
  public init(key: String, label: String) {
    self.key = key
    self.label = label
  }
}

/// Status-screen action by key; pure — menu.swift only executes it.
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

/// Provider-switch confirm gesture: .yes = y, .enter = Enter, .other = rest.
public enum ConfirmationGesture: Equatable {
  case yes
  case enter
  case other
}

/// Menu only when no command AND tty; in pipes — usage + exit 0.
public enum MenuGate {
  public static func shouldRunMenu(hasCommand: Bool, tty: Bool) -> Bool {
    !hasCommand && tty
  }
}

/// Menu screens/text builders; pure strings, no I/O.
public enum AgentScreen {
  /// Key→action map; keeps "0" out of default .quit — language must switch, not quit.
  public static func statusMenuAction(forKey key: String) -> StatusMenuAction {
    switch key {
    case "0": return .toggleLanguage
    case "1": return .showProviders
    case "2": return .showLogs
    case "3": return .toggleAgent
    case "4": return .showLastResult
    case "5": return .retryTranscribe
    case "6": return .toggleReview
    default: return .quit
    }
  }

  /// Titles/hints; owns menu text, ANSI added by menu.swift.
  public static func statusTitle() -> String {
    L10n.tr("status.title")
  }

  public static func providersTitle() -> String {
    L10n.tr("menu.providers")
  }

  public static func logsTitle(lineCount: Int) -> String {
    L10n.tr("status.logs").replacingOccurrences(of: "{n}", with: "\(lineCount)")
  }

  public static func statusHint() -> String {
    L10n.tr("status.hintNav")
  }

  public static func providersHint() -> String {
    L10n.tr("status.hintProviders")
  }

  /// y/Enter confirm; other keys reject (pure, no terminal read).
  public static func confirmationAccepts(key: ConfirmationGesture) -> Bool {
    switch key {
    case .yes, .enter: return true
    case .other: return false
    }
  }

  public static func logsHint() -> String {
    L10n.tr("status.hintLogs")
  }

  /// Log events marking recording end (recording NOT active).
  private static let recordingEndMarkers = [
    "transcribe submit",  // recording stopped, sent to STT
    "record cancelled",
    "record limit reached",  // hard limit — recording finalized
    "transcription inserted",
    // swiftlint:disable:next trailing_comma
    "transcription failed",
  ]

  /// Recording active if after last "record start" no terminal event followed.
  public static func isRecordingActive(logLines: [String]) -> Bool {
    var lastStart = -1
    var lastEnd = -1
    for (index, line) in logLines.enumerated() {
      if line.contains("record start") {
        lastStart = index
      }
      if recordingEndMarkers.contains(where: { line.contains($0) }) {
        lastEnd = index
      }
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

  /// Provider line matching `nanodictate status`.
  public static func providerLine(providerName: String?, providerID: String?, providersEmpty: Bool)
    -> String
  {  // swiftlint:disable:this opening_brace
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

  /// Pad label to 12 chars; values start at col 13 regardless of EN/RU label length.
  private static func padCol12(_ label: String) -> String {
    label + String(repeating: " ", count: max(0, 12 - label.count))
  }

  /// Status screen: agent, recording, provider, log (size/errors/tail).
  public static func statusScreen(_ status: AgentStatusData) -> String {
    let agent =
      status.agentRunning
      ? L10n.tr("status.running") + (status.agentPID.map { " (pid \($0))" } ?? "")
      : L10n.tr("status.stopped")
    let recording = status.recordingActive ? L10n.tr("status.active") : L10n.tr("status.idle")
    let errorsText = status.logHasErrors ? L10n.tr("status.hasErrors") : L10n.tr("status.noErrors")
    let providerText = providerLine(
      providerName: status.providerName,
      providerID: status.providerID,
      providersEmpty: status.providersEmpty
    )
    var lines = [
      "\(padCol12(L10n.tr("status.agent") + ":"))\(agent)",
      "\(padCol12(L10n.tr("status.recording") + ":"))\(recording)",
      "\(padCol12(L10n.tr("status.provider") + ":"))\(providerText)",
      "\(padCol12(L10n.tr("status.log") + ":"))\(status.logPath)",
      // swiftlint:disable:next trailing_comma
      "\(padCol12(L10n.tr("status.size") + ":"))\(byteCountText(status.logSizeBytes)) · \(errorsText)",
    ]
    if !status.logTail.isEmpty {
      lines.append("")
      lines.append(L10n.tr("status.logTail"))
      lines += status.logTail.map { "  " + $0 }
    }
    return lines.joined(separator: "\n")
  }

  /// Status menu rows: key + label; actions wired by menu.swift.
  public static func statusMenuItems(agentRunning: Bool) -> [MenuItem] {
    [
      MenuItem(key: "0", label: L10n.tr("menu.language")),
      MenuItem(key: "1", label: L10n.tr("menu.providers")),
      MenuItem(key: "2", label: L10n.tr("menu.logs")),
      MenuItem(
        key: "3", label: agentRunning ? L10n.tr("menu.stopAgent") : L10n.tr("menu.startAgent")),
      MenuItem(key: "4", label: L10n.tr("menu.showLastText")),
      MenuItem(key: "5", label: L10n.tr("menu.retryOther")),
      MenuItem(key: "6", label: L10n.tr("menu.reviewToggle")),
      // swiftlint:disable:next trailing_comma
      MenuItem(key: "q", label: L10n.tr("menu.quit")),
    ]
  }

  /// Providers screen row: `* Groq [groq] — model`.
  public static func providerItemLine(_ provider: STTProvider) -> String {
    let marker = provider.isActive ? "*" : " "
    let name = provider.name.isEmpty ? provider.id : provider.name
    return "\(marker) \(name) [\(provider.id)] — \(provider.model)"
  }

  public static func providersBody(providers: [STTProvider]) -> String {
    providers.map { providerItemLine($0) }.joined(separator: "\n")
  }

  /// Provider-switch validation result (no IO).
  public enum ProviderSwitchResult: Equatable {
    case isValid(targetID: String)
    case unknownProvider(id: String, available: [String])
    case empty
  }

  /// Pure check: provider id exists, before writing config.
  public static func validateProviderSwitch(targetID: String, providers: [STTProvider])
    -> ProviderSwitchResult
  {  // swiftlint:disable:this opening_brace
    guard !providers.isEmpty else { return .empty }
    guard providers.contains(where: { $0.id == targetID }) else {
      return .unknownProvider(id: targetID, available: providers.map(\.id))
    }
    return .isValid(targetID: targetID)
  }
}
