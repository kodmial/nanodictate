import Foundation
import NanoDictateCore

// MARK: - Действия

/// Runs a subcommand through this same binary (reuses cmdStart/cmdStop
/// without duplication), returning its printable output in one line.
func runSelfCommand(_ command: String, _ arguments: [String] = []) -> String {
  let exe = CommandLine.arguments.first ?? ""
  let result = runProcess(exe, [command] + arguments)
  let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
  if !out.isEmpty {
    return out
  }
  let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
  return err.isEmpty ? String(format: L10n.tr("menu.agent.notfound"), "\(result.status)") : err
}

/// Maps a menu key to a confirmation gesture (AgentScreen takes the pure logic).
func confirmationGesture(_ key: MenuKey) -> ConfirmationGesture {
  switch key {
  case .yes: return .yes
  case .enter: return .enter
  default: return .other
  }
}

/// Agent restart from the menu: the canonical plist is overwritten with the
/// real binary path (does not go stale after an update), then kickstart -k;
/// if the service is not loaded — a full install. Text for notice.
func restartAgentNow() -> String {
  let agentBinary = findAgentBinaryPath()
  guard !agentBinary.isEmpty else {
    return L10n.tr("cli.agent.notfound")
  }
  let logPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/NanoDictate/agent.log").path
  let installer = AgentInstaller(launchctl: Launchctl(run: runProcess))
  let result = installer.restart(agentBinary: agentBinary, logPath: logPath)
  if let writeError = result.writeError {
    return String(format: L10n.tr("cli.plist.writeerror"), writeError)
  }
  if result.binaryPathChanged {
    return L10n.tr("menu.agent.tccRehint")
  }
  if result.registered {
    return L10n.tr("cli.provider.restart")
  }
  let msg = result.kickError.isEmpty ? result.bootstrapError : result.kickError
  return String(format: L10n.tr("cli.provider.kickfail"), msg.isEmpty ? result.loadError : msg)
}

/// Confirmation + switching the active provider + agent restart
/// (like `nanodictate provider use`, without --no-restart). Returns text
/// for notice.
func confirmAndSwitchProvider(_ provider: STTProvider, _: inout MenuView) -> String {
  let display = provider.name.isEmpty ? provider.id : provider.name
  render(
    ansiBold + String(format: L10n.tr("menu.switch.confirm"), display, provider.id) + ansiReset
      + "\n\(L10n.tr("menu.switch.hint"))")
  guard AgentScreen.confirmationAccepts(key: confirmationGesture(readMenuKey())) else {
    return L10n.tr("menu.switch.cancelled")
  }
  do {
    try ProviderStore.setActive(providerID: provider.id)
  } catch {
    return String(format: L10n.tr("menu.switch.error"), "\(error)")
  }
  return String(format: L10n.tr("menu.switch.ok"), display, restartAgentNow())
}

/// Runs a menu entry action. true — leave the menu.
@discardableResult
func execute(_ action: MenuAction, _ view: inout MenuView) -> Bool {
  switch action {
  case .quit:
    return true
  case .back, .showProviders, .showLogs, .refresh, .toggleAgent, .showLastResult, .toggleLanguage:
    applySimpleAction(action, &view)
  case .switchProvider, .retryTranscribe, .toggleReview:
    applyComplexAction(action, &view)
  }
  return false
}

/// Refreshes the provider/log lists and resets the cursor to the top.
func refreshMenu(_ view: inout MenuView) {
  view.providers = (try? ProviderStore.loadProviders()) ?? []
  view.logLines = readLogFile()
  view.cursor = 0
  view.lastStatusRefresh = .distantPast  // r forces a fresh status
}

/// Simple actions: page transitions and state changes without branches.
func applySimpleAction(_ action: MenuAction, _ view: inout MenuView) {
  switch action {
  case .back:
    view.page = .status
    view.cursor = 0
    view.notice = nil
  case .showProviders:
    view.page = .providers
    view.cursor = 0
    view.notice = nil
  case .showLogs:
    view.page = .logs
    view.cursor = max(0, view.logLines.count - 20)
    view.notice = nil
  case .refresh:
    refreshMenu(&view)
  case .toggleAgent:
    view.notice = agentIsRunning() ? runSelfCommand("stop") : runSelfCommand("start")
    view.page = .status
    view.cursor = 0
    view.lastStatusRefresh = .distantPast  // agent start/stop → status
  case .showLastResult:
    view.notice = runSelfCommand("last")
  case .toggleLanguage:
    let newLang = L10n.language == .en ? "ru" : "en"
    // Materialize the canon first (auto-copy), then patch one key.
    _ = try? AppConfig.load(from: nil)
    do {
      try AppConfig.writeKeyValue(
        key: "ui_language", value: "\"\(newLang)\"", to: AppConfig.defaultPath())
      L10n.language = newLang == "ru" ? .ru : .en
      view.notice =
        L10n.tr("menu.language") + ": "
        + (L10n.language == .en ? L10n.tr("menu.languageEn") : L10n.tr("menu.languageRu"))
    } catch {
      view.notice = String(format: L10n.tr("menu.review.configerror"), "\(error)")
    }
  default:
    break
  }
}

/// Actions with branches (confirmation, retries, config) — moved out
/// so they do not bloat the cyclomatic complexity of `execute`.
func applyComplexAction(_ action: MenuAction, _ view: inout MenuView) {
  switch action {
  case .switchProvider(let id):
    switchToProvider(id: id, view: &view)
  case .retryTranscribe:
    retryTranscribe(&view)
  case .toggleReview:
    toggleReview(&view)
  case .quit, .back, .showProviders, .showLogs, .refresh, .toggleAgent, .showLastResult,
    .toggleLanguage:
    break  // never arrives here: execute routes them to applySimpleAction
  }
}

/// Switches the active provider with confirmation and an agent restart.
func switchToProvider(id: String, view: inout MenuView) {
  guard let provider = view.providers.first(where: { $0.id == id }) else {
    view.notice = String(format: L10n.tr("menu.switch.error"), id)
    return
  }
  view.notice = confirmAndSwitchProvider(provider, &view)
  view.page = .providers
  view.cursor = 0
  view.providers = (try? ProviderStore.loadProviders()) ?? []
}

/// Re-transcribes the last audio through the chosen provider.
func retryTranscribe(_ view: inout MenuView) {
  guard !view.providers.isEmpty else {
    view.notice = L10n.tr("menu.no.providers.retry")
    return
  }
  let prompt =
    ansiBold + L10n.tr("menu.retry.prompt") + ansiReset
    + "\n"
    + view.providers.enumerated()
    .map { "  \($0.offset + 1)) \(AgentScreen.providerItemLine($0.element))" }
    .joined(separator: "\n")
    + "\n\(L10n.tr("menu.retry.hint"))"
  render(prompt)
  guard case .number(let number) = readMenuKey(), number >= 1, number <= view.providers.count else {
    view.notice = L10n.tr("menu.switch.cancelled")
    return
  }
  view.notice = runSelfCommand("retry", [view.providers[number - 1].id])
}

/// Toggles the pre-insert review gate + agent restart.
func toggleReview(_ view: inout MenuView) {
  let current = (try? AppConfig.load(from: nil))?.reviewBeforeInsert ?? false
  let newValue = !current
  do {
    try AppConfig.writeReviewBeforeInsert(value: newValue, to: AppConfig.defaultPath())
    let restart = restartAgentNow()
    if newValue {
      // Under launchd the agent has no terminal: the review gate is skipped
      // (see hasInteractiveStdin in main.swift) — warn in advance.
      view.notice = String(format: L10n.tr("menu.review.on"), restart)
    } else {
      view.notice = String(format: L10n.tr("menu.review.off"), restart)
    }
  } catch {
    view.notice = String(format: L10n.tr("menu.review.configerror"), "\(error)")
  }
}

/// Handles a key in the main loop. true — leave the menu (return 0).
func handleMenuKey(_ key: MenuKey, entries: [MenuEntry], _ view: inout MenuView) -> Bool {
  switch key {
  case .quit:
    return handleQuit(view: &view)
  case .unknown, .yes:
    break
  case .refresh:
    refreshMenu(&view)
  case .upArrow:
    view.cursor = max(0, view.cursor - 1)
  case .down:
    moveCursorDown(view: &view, entries: entries)
  case .enter:
    return handleEnter(entries: entries, view: &view)
  case .number(let number):
    return handleNumber(number, entries: entries, view: &view)
  }
  return false
}

/// q/esc on Status — leave the menu; on other pages — return to Status
/// (as the "q/esc — back" hint promises, and the live .back is wired that way).
func handleQuit(view: inout MenuView) -> Bool {
  if view.page == .status {
    return true
  }
  execute(.back, &view)
  return false
}

/// Enter on the current entry: run the action; true — leave the menu.
func handleEnter(entries: [MenuEntry], view: inout MenuView) -> Bool {
  if view.cursor < entries.count, execute(entries[view.cursor].action, &view) {
    return true
  }
  return false
}

/// Digit key: find the entry with that number and run it; true — leave the menu.
func handleNumber(_ number: Int, entries: [MenuEntry], view: inout MenuView) -> Bool {
  if let entry = entries.first(where: { $0.key == .number(number) }), execute(entry.action, &view) {
    return true
  }
  return false
}

/// Down arrow: cursor down, respecting the current page.
func moveCursorDown(view: inout MenuView, entries: [MenuEntry]) {
  switch view.page {
  case .logs:
    let maxTop = max(0, view.logLines.count - 20)
    view.cursor = min(maxTop, view.cursor + 1)
  case .status:
    if view.cursor < entries.count - 1 {
      view.cursor += 1
    }
  case .providers:
    if view.cursor < view.providers.count - 1 {
      view.cursor += 1
    }
  }
}
