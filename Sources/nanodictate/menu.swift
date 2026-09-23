import Darwin
import Foundation
import NanoDictateCore

// MARK: - TTY-гейт

/// Is stdout a terminal: the menu renders only on interactive output.
/// In pipes/scripts main.swift shows usage, as before.
func isTTY() -> Bool {
  isatty(STDOUT_FILENO) == 1
}

// MARK: - Output: ANSI + raw input mode

private let ansiHome = "\u{1B}[H"
private let ansiClear = "\u{1B}[2J"
let ansiBold = "\u{1B}[1m"
let ansiReset = "\u{1B}[0m"
private let ansiHideCursor = "\u{1B}[?25l"
private let ansiShowCursor = "\u{1B}[?25h"

/// Prints a menu frame, erasing the previous one.
func render(_ text: String) {
  fputs(ansiHome + ansiClear + text + "\n", stdout)
  fflush(stdout)
}

/// Raw stdin mode: a key is read without Enter and without echo.
private func setRawMode(_ enabled: Bool) {
  guard isatty(STDIN_FILENO) == 1 else { return }
  var term = termios()
  guard tcgetattr(STDIN_FILENO, &term) == 0 else { return }
  if enabled {
    term.c_lflag &= ~(tcflag_t(ICANON) | tcflag_t(ECHO))
    term.c_cc.16 = 1  // VMIN (Darwin)
    term.c_cc.17 = 0  // VTIME (Darwin)
  } else {
    term.c_lflag |= tcflag_t(ICANON) | tcflag_t(ECHO)
  }
  tcsetattr(STDIN_FILENO, TCSANOW, &term)
}

// MARK: - Terminal restore on signal (SIGINT/SIGTERM)

/// Snapshot of the original termios before raw mode — so Ctrl+C / kill do not
/// leave the terminal without echo (raw-mode ISIG: the signal kills the
/// process, defer does not get a chance).
private var originalTermios: termios?

/// Static "show cursor + newline" buffer: safe even in an async-signal
/// context (no allocations).
private let showCursorPlusNewline: [UInt8] = Array("\u{1B}[?25h\n".utf8)

/// Restores termios and the cursor, then exits the process.
/// The normal exit path cleans up via defer in runMenu; this handler is
/// for signals.
private func restoreTerminalAndExit(_ sig: Int32) {
  if var term = originalTermios {
    _ = tcsetattr(STDIN_FILENO, TCSANOW, &term)
  }
  _ = showCursorPlusNewline.withUnsafeBytes {
    write(STDOUT_FILENO, $0.baseAddress, $0.count)
  }
  _exit(sig)
}

/// Installs SIGINT/SIGTERM handlers. Takes the termios snapshot BEFORE
/// raw mode.
private func installSignalHandlers() {
  if isatty(STDIN_FILENO) == 1 {
    var term = termios()
    if tcgetattr(STDIN_FILENO, &term) == 0 {
      originalTermios = term
    }
  }
  let handler: @convention(c) (Int32) -> Void = { sig in
    restoreTerminalAndExit(sig)
  }
  var action = sigaction()
  sigemptyset(&action.sa_mask)
  action.sa_flags = 0  // no SA_RESTART: blocking input read is interrupted by a signal
  action.__sigaction_u.__sa_handler = handler
  _ = sigaction(SIGINT, &action, nil)
  _ = sigaction(SIGTERM, &action, nil)
}

/// Is there data in stdin within ms (needed to tell a lone Esc from an arrow).
private func inputReady(_ milliseconds: Int) -> Bool {
  var pfd = pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0)
  return poll(&pfd, 1, Int32(milliseconds)) > 0
}

// MARK: - Keys

enum MenuKey: Equatable {
  case quit, unknown, enter, upArrow, down, refresh, yes
  case number(Int)
}

/// Extra read after ESC: an arrow "ESC [ A/B" or an unknown sequence.
private func readEscapeKey() -> MenuKey {
  var byte2: UInt8 = 0
  guard read(STDIN_FILENO, &byte2, 1) > 0, byte2 == 0x5B, inputReady(20) else { return .quit }
  var byte3: UInt8 = 0
  guard read(STDIN_FILENO, &byte3, 1) > 0 else { return .quit }
  switch byte3 {
  case 0x41: return .upArrow
  case 0x42: return .down
  default: return .unknown
  }
}

func readMenuKey() -> MenuKey {
  var byte: UInt8 = 0
  guard read(STDIN_FILENO, &byte, 1) > 0 else { return .quit }  // EOF — pipe closed
  switch byte {
  case 0x1B:  // Esc or the arrow prefix "ESC [ A/B"
    if inputReady(50) {
      return readEscapeKey()
    }
    return .quit  // lone Esc
  case 0x0A, 0x0D: return .enter
  case 0x71, 0x51: return .quit  // q / Q
  case 0x79, 0x59: return .yes  // y / Y
  case 0x72, 0x52: return .refresh  // r / R
  case 0x30...0x39: return .number(Int(byte - 0x30))  // "0" ... "9"
  default: return .unknown
  }
}

// MARK: - Screens and actions

enum MenuAction {
  case quit, back, refresh, showProviders, showLogs, toggleAgent, toggleLanguage
  case switchProvider(String)
  case showLastResult, retryTranscribe, toggleReview
}

struct MenuEntry {
  let key: MenuKey?
  let label: String
  let action: MenuAction
}

enum MenuPage {
  case status, providers, logs
}

struct MenuView {
  var page: MenuPage = .status
  var cursor = 0
  var providers: [STTProvider] = []
  var logLines: [String] = []
  var notice: String?
  /// Cached agent status: arrows/Enter in the loop must not run
  /// 5 I/O ops (pgrep, ProviderStore, log, launchctl, stat) on EACH
  /// keypress — see lastStatusRefresh (refresh not more often than
  /// once per 2 seconds).
  var cachedStatus: AgentStatusData?
  var lastStatusRefresh = Date.distantPast
}

private func entryKeyText(_ key: MenuKey?) -> String {
  guard let key else { return "•" }
  switch key {
  case .number(let number): return "\(number)"
  case .quit: return "q"
  case .refresh: return "r"
  default: return "•"
  }
}

private func statusPageText(
  status: AgentStatusData, entries: [MenuEntry], cursor: Int, notice: String?
) -> String {
  var lines = [ansiBold + AgentScreen.statusTitle() + ansiReset, String(repeating: "─", count: 28)]
  lines += AgentScreen.statusScreen(status).components(separatedBy: "\n")
  lines.append(String(repeating: "─", count: 28))
  lines.append(L10n.tr("menu.items"))
  for (i, entry) in entries.enumerated() {
    let mark = i == cursor ? "›" : " "
    lines.append("\(mark) \(entryKeyText(entry.key)) — \(entry.label)")
  }
  lines.append("  " + AgentScreen.statusHint())
  if let text = notice {
    lines.append(ansiBold + text + ansiReset)
  }
  return lines.joined(separator: "\n")
}

private func providersPageText(providers: [STTProvider], cursor: Int, notice: String?) -> String {
  var lines = [
    // swiftlint:disable:next trailing_comma
    ansiBold + AgentScreen.providersTitle() + ansiReset, String(repeating: "─", count: 28),
  ]
  if providers.isEmpty {
    lines.append(L10n.tr("menu.empty.providers"))
  } else {
    for (i, provider) in providers.enumerated() {
      let mark = i == cursor ? "›" : " "
      lines.append("\(mark) \(i + 1)) \(AgentScreen.providerItemLine(provider))")
    }
  }
  lines.append(String(repeating: "─", count: 28))
  lines.append("  " + AgentScreen.providersHint())
  if let text = notice {
    lines.append(ansiBold + text + ansiReset)
  }
  return lines.joined(separator: "\n")
}

private func logsPageText(lines: [String], window: Int, top: Int) -> String {
  var out = [
    ansiBold + AgentScreen.logsTitle(lineCount: lines.count) + ansiReset,
    // swiftlint:disable:next trailing_comma
    String(repeating: "─", count: 28),
  ]
  if lines.isEmpty {
    out.append(L10n.tr("menu.empty.log"))
  } else {
    let end = min(top + window, lines.count)
    for i in top..<end {
      out.append(lines[i])
    }
  }
  out.append(String(repeating: "─", count: 28))
  out.append("  " + AgentScreen.logsHint())
  return out.joined(separator: "\n")
}

// MARK: - Entries

private func statusEntries(agentRunning: Bool) -> [MenuEntry] {
  // The language entry is added exactly ONCE: statusMenuItems() also
  // returns the key "0" — it cannot be duplicated (previously the mapping
  // without a "0" case sent the duplicate to default → .quit, and the menu
  // drew an extra "q — Language" line which EXITED the menu on Enter
  // instead of toggling the language).
  var entries = [
    MenuEntry(key: .number(0), label: L10n.tr("menu.language"), action: .toggleLanguage)
  ]
  entries += AgentScreen.statusMenuItems(agentRunning: agentRunning).compactMap { item in
    // "0" is already the first entry — do not draw the duplicate.
    guard item.key != "0" else { return nil }
    let key: MenuKey = Int(item.key).map(MenuKey.number) ?? .quit
    let action: MenuAction
    switch AgentScreen.statusMenuAction(forKey: item.key) {
    case .toggleLanguage: action = .toggleLanguage
    case .showProviders: action = .showProviders
    case .showLogs: action = .showLogs
    case .toggleAgent: action = .toggleAgent
    case .showLastResult: action = .showLastResult
    case .retryTranscribe: action = .retryTranscribe
    case .toggleReview: action = .toggleReview
    case .quit: action = .quit
    }
    return MenuEntry(key: key, label: item.label, action: action)
  }
  return entries
}

private func providerEntries(_ providers: [STTProvider]) -> [MenuEntry] {
  providers.enumerated().map { index, provider in
    MenuEntry(key: .number(index + 1), label: "", action: .switchProvider(provider.id))
  }
}

// MARK: - Status data collection

func agentIsRunning() -> Bool {
  runProcess("/bin/launchctl", ["print", "\(guiDomain)/\(agentServiceName)"]).status == 0
}

private func logFileURL() -> URL {
  let dir = (Logger.logDirectory as NSString).expandingTildeInPath
  return URL(fileURLWithPath: dir).appendingPathComponent("agent.log")
}

/// Reads the log-file tail: the last 1 MB via FileHandle-seek,
/// returns at most `maxLines` non-empty lines. Instead of a full
/// read (~23 MB → 1.7 s) — ≈80 ms (×20 speedup).
/// `isRecordingActive` and `hasErrors` scan the tail — for the TUI status
/// that is enough: the latest start/end markers are always in the tail.
func readLogFile(maxLines: Int = 500) -> [String] {
  let url = logFileURL()
  guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
  defer { handle.closeFile() }
  let fileSize = handle.seekToEndOfFile()
  guard fileSize > 0 else { return [] }
  let maxRead: UInt64 = 1024 * 1024  // 1 MB ≈ 12 000 lines @ ~80 bytes
  let readSize = min(fileSize, maxRead)
  handle.seek(toFileOffset: fileSize - readSize)
  let data = handle.readData(ofLength: Int(readSize))
  let text = String(decoding: data, as: UTF8.self)
  var lines = text.components(separatedBy: .newlines)
  // The first line may be cut (started mid-line) — skip it.
  if readSize < fileSize, !lines.isEmpty {
    lines.removeFirst()
  }
  return Array(lines.filter { !$0.isEmpty }.suffix(maxLines))
}

private func collectStatus() -> AgentStatusData {
  var pid: String?
  let pgrep = runProcess("/usr/bin/pgrep", ["-f", "NanoDictateAgent"])
  if pgrep.status == 0,
    let first = pgrep.stdout.split(whereSeparator: \.isWhitespace).map(String.init).first
  {  // swiftlint:disable:this opening_brace
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
  } catch {  // broken/legacy config — "not selected" line
  }
  let logLines = readLogFile()
  let logURL = logFileURL()
  let size =
    ((try? FileManager.default.attributesOfItem(atPath: logURL.path))?[.size] as? NSNumber)?
    .int64Value ?? 0
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

// MARK: - Main loop

func runMenu() -> Int32 {
  // The menu needs a TTY for both output and input; otherwise — a quiet
  // exit to usage in main.swift.
  guard isTTY(), isatty(STDIN_FILENO) == 1 else { return 0 }
  // L10n.language is already set by main.swift (fileExists-guarded probe).
  installSignalHandlers()  // termios snapshot before raw mode + SIGINT/SIGTERM
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
      // collectStatus() = 5 I/O ops (pgrep, ProviderStore.loadProviders,
      // readLogFile, launchctl print, attributesOfItem). Cache with a 2 s TTL:
      // key handling (arrows/Enter) is NOT blocked on I/O — the status
      // refreshes at most once per 2 seconds, redraw is instant.
      if view.cachedStatus == nil || Date().timeIntervalSince(view.lastStatusRefresh) >= 2.0 {
        view.cachedStatus = collectStatus()
        view.lastStatusRefresh = Date()
      }
      guard let status = view.cachedStatus else {
        // Unreachable: the branch above just filled cachedStatus.
        preconditionFailure("cachedStatus должен быть заполнен после refresh")
      }
      entries = statusEntries(agentRunning: status.agentRunning)
      view.cursor = min(view.cursor, max(0, entries.count - 1))
      text = statusPageText(
        status: status, entries: entries, cursor: view.cursor, notice: view.notice)
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

    if handleMenuKey(readMenuKey(), entries: entries, &view) {
      return 0
    }
  }
}
