// swiftlint:disable file_length
import Darwin
import Foundation

// MARK: - Каноническая спецификация службы агента

/// One daemon regardless of install method (brew/port/dev-build): the
/// running binary itself registers the service. Canonical plist single
/// forever — ~/Library/LaunchAgents/com.nanodictate.agent.plist, Label
/// com.nanodictate.agent. Packaging (Homebrew/MacPorts) does NOT register.
public enum AgentService {
  /// Service label (unique in launchd gui-domain).
  public static let name = "com.nanodictate.agent"

  /// launchctl GUI domain: "gui/<uid>".
  public static func guiDomain(uid: uid_t = getuid()) -> String {
    return "gui/\(uid)"
  }

  /// Canonical plist path (~/Library/LaunchAgents/com.nanodictate.agent.plist).
  public static func canonicalURL(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) -> URL {
    return
      homeDirectory
      .appendingPathComponent("Library/LaunchAgents")
      .appendingPathComponent("\(name).plist")
  }
}

// MARK: - Реальный путь бинаря

/// realpath: path with all symlinks resolved (URL.resolvingSymlinksInPath).
/// Missing file (broken symlink) — normalized absolute path returned
/// (resolvingSymlinksInPath idempotent on non-existent paths).
public func agentRealPath(_ path: String) -> String {
  return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

/// Path agent binary the service registers under:
/// 1) env NANODICTATE_AGENT_BIN (explicit override, e.g. installed
///    /opt/local/bin variant; realpath finishes symlink resolution);
/// 2) bare invocation (argv[0] without "/", e.g. `nanodictate start`) —
///    $PATH lookup first; CWD-resolution would point the plist at a
///    non-existent <CWD>/NanoDictateAgent (launchd: EX_CONFIG);
/// 3) NanoDictateAgent next to REAL (post-symlink-resolution) path of the
///    invoked CLI — survives invocation via /opt/homebrew/bin or symlink;
/// 4) fallback — sibling next to invoked binary (brother in .build/debug).
/// Empty return impossible: last branch always yields a path.
public func resolveAgentBinaryPath(
  invokedBinary: String,
  environment: [String: String] = ProcessInfo.processInfo.environment,
  fileManager: FileManager = .default
) -> String {
  let name = "NanoDictateAgent"
  if let env = environment["NANODICTATE_AGENT_BIN"], !env.isEmpty {
    return agentRealPath(env)
  }
  // Голое имя (argv[0] без "/", e.g. `nanodictate start`): резолв от CWD
  // дал бы plist с несуществующим <CWD>/NanoDictateAgent (launchd:
  // EX_CONFIG) — сначала ищем бинарь в $PATH.
  if !invokedBinary.contains("/"),
    let viaPATH = resolveAgentViaPATH(
      invokedBinary, environment: environment, fileManager: fileManager)
  {
    return viaPATH
  }
  let invoked = agentRealPath(invokedBinary)
  let sibling = URL(fileURLWithPath: invoked).deletingLastPathComponent()
    .appendingPathComponent(name)
  if fileManager.fileExists(atPath: sibling.path) {
    return agentRealPath(sibling.path)
  }
  // Fallback: sibling next to raw (unresolved) invocation — covers
  // dev-build, argv[0] already a real path.
  let rawSibling = URL(fileURLWithPath: invokedBinary).deletingLastPathComponent()
    .appendingPathComponent(name)
  return agentRealPath(rawSibling.path)
}

/// PATH-поиск для голого имени argv[0]: перебор каталогов $PATH, первый
/// существующий и исполняемый кандидат — путь CLI; агент — NanoDictateAgent
/// рядом с realpath найденного (brew-канон: симлинк bin/nanodictate на
/// Cellar, где лежит агент). Соседа у кандидата нет — поиск продолжается
/// (канон — пара CLI+агент в одном каталоге). nil — в PATH ничего не
/// нашлось; caller откатывается на резолв от CWD.
private func resolveAgentViaPATH(
  _ invokedBinary: String,
  environment: [String: String],
  fileManager: FileManager
) -> String? {
  let name = "NanoDictateAgent"
  guard let pathValue = environment["PATH"], !pathValue.isEmpty else { return nil }
  // Пустые сегменты PATH split отбрасывает (omittingEmptySubsequences) —
  // CWD-семантика оболочки не воспроизводится; практический эквивалент —
  // CWD-fallback ветка в resolveAgentBinaryPath ниже.
  for dir in pathValue.split(separator: ":") {
    let candidate = "\(dir)/\(invokedBinary)"
    guard fileManager.isExecutableFile(atPath: candidate) else { continue }
    let realCLI = agentRealPath(candidate)
    let sibling = URL(fileURLWithPath: realCLI).deletingLastPathComponent()
      .appendingPathComponent(name)
    if fileManager.fileExists(atPath: sibling.path) {
      return agentRealPath(sibling.path)
    }
  }
  return nil
}

// MARK: - Генерация канонического plist

public enum AgentPlist {
  /// XML-escaping (paths may contain &, ", <, >).
  public static func xmlEscape(_ value: String) -> String {
    return
      value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }

  /// Inline XML of canonical plist: Label, ProgramArguments (binary + flags),
  /// RunAtLoad + KeepAlive (as prior template), log paths in ~/Library/Logs.
  public static func plistContent(
    agentBinary: String, flags: [String] = [], logPath: String
  ) -> String {
    let argsBlock = ([agentBinary] + flags)
      .map { "    <string>\(xmlEscape($0))</string>" }
      .joined(separator: "\n")
    let escapedLog = xmlEscape(logPath)
    return """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
        <key>Label</key>
        <string>\(AgentService.name)</string>
        <key>ProgramArguments</key>
        <array>
      \(argsBlock)
        </array>
        <key>RunAtLoad</key>
        <true/>
        <key>KeepAlive</key>
        <true/>
        <key>StandardOutPath</key>
        <string>\(escapedLog)</string>
        <key>StandardErrorPath</key>
        <string>\(escapedLog)</string>
      </dict>
      </plist>
      """
  }

  /// ProgramArguments of previous plist from disk (path compare at takeover).
  /// nil — plist missing/unreadable/no array.
  public static func programArguments(
    fromPlistAt path: String,
    fileManager: FileManager = .default
  ) -> [String]? {
    guard fileManager.fileExists(atPath: path),
      let data = fileManager.contents(atPath: path)
    else { return nil }
    return programArguments(fromPlistData: data)
  }

  public static func programArguments(fromPlistData data: Data) -> [String]? {
    guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let dict = plist as? [String: Any],
      let args = dict["ProgramArguments"] as? [String]
    else { return nil }
    return args
  }

  /// Atomic plist write with 0600 perms (creates LaunchAgents dir).
  public static func writePlist(
    agentBinary: String,
    flags: [String] = [],
    logPath: String,
    to url: URL,
    fileManager: FileManager = .default
  ) throws {
    let dir = url.deletingLastPathComponent()
    try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
    let data = Data(plistContent(agentBinary: agentBinary, flags: flags, logPath: logPath).utf8)
    try data.write(to: url, options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
  }
}

// MARK: - launchctl-обёртка (инъектируемая для тестов)

/// Injectable launchctl runner: prod — runProcess, tests — mock
/// (launchd not called in tests).
public final class Launchctl {
  // swiftlint:disable large_tuple
  public typealias Run = (String, [String]) -> (status: Int32, stdout: String, stderr: String)
  // swiftlint:enable large_tuple

  public var run: Run

  public init(run: @escaping Run) {
    self.run = run
  }

  public var serviceTarget: String {
    return "\(AgentService.guiDomain())/\(AgentService.name)"
  }

  /// launchctl print — service loaded (status == 0)?
  public func isLoaded(target: String) -> Bool {
    return run("/bin/launchctl", ["print", target]).status == 0
  }

  /// launchctl bootout — unload under target; failure tolerable (service
  /// absent).
  // swiftlint:disable large_tuple
  @discardableResult
  public func bootout(target: String) -> (status: Int32, stdout: String, stderr: String) {
    return run("/bin/launchctl", ["bootout", target])
  }
  // swiftlint:enable large_tuple

  /// launchctl bootstrap gui/uid path — load plan from plist.
  // swiftlint:disable large_tuple
  @discardableResult
  public func bootstrap(plistPath: String, domain: String) -> (
    status: Int32, stdout: String,
    stderr: String
  ) {
    return run("/bin/launchctl", ["bootstrap", domain, plistPath])
  }
  // swiftlint:enable large_tuple

  /// launchctl load path — legacy fallback (old macOS / no gui-domain).
  // swiftlint:disable large_tuple
  @discardableResult
  public func load(plistPath: String) -> (status: Int32, stdout: String, stderr: String) {
    return run("/bin/launchctl", ["load", plistPath])
  }
  // swiftlint:enable large_tuple

  /// launchctl kickstart -k target — restart loaded service.
  // swiftlint:disable large_tuple
  @discardableResult
  public func kickstart(target: String) -> (status: Int32, stdout: String, stderr: String) {
    return run("/bin/launchctl", ["kickstart", "-k", target])
  }
  // swiftlint:enable large_tuple
}

// MARK: - Установщик службы

/// install/restart result — fields for CLI messages and TCC hint.
public struct AgentInstallResult: Equatable {
  /// Service active after op (bootstrap/load/kickstart).
  public var registered: Bool
  /// Old process stopped by bootout (tolerates "no service").
  public var bootoutSucceeded: Bool
  /// ProgramArguments changed vs previous plist → TCC hint.
  public var binaryPathChanged: Bool
  /// bootstrap stderr (failure continued fallback chain).
  public var bootstrapError: String
  /// load stderr (fallback after bootstrap).
  public var loadError: String
  /// kickstart stderr (restart without full install).
  public var kickError: String
  /// plist write error (nil — plist written).
  public var writeError: String?

  public init(
    registered: Bool = false,
    bootoutSucceeded: Bool = false,
    binaryPathChanged: Bool = false,
    bootstrapError: String = "",
    loadError: String = "",
    kickError: String = "",
    writeError: String? = nil
  ) {
    self.registered = registered
    self.bootoutSucceeded = bootoutSucceeded
    self.binaryPathChanged = binaryPathChanged
    self.bootstrapError = bootstrapError
    self.loadError = loadError
    self.kickError = kickError
    self.writeError = writeError
  }
}

/// Register/restart canonical plist. Manager change (different binary,
/// different install method) = takeover: write new plist → bootout old →
/// bootstrap. Idempotent: re-start of already-loaded service changes owner
/// and path correctly (launchd keeps in-memory plan from plist AT
/// bootstrap — rewriting the file alone does not touch the live service).
public struct AgentInstaller {
  public var launchctl: Launchctl
  public var fileManager: FileManager
  public var homeDirectory: URL

  public init(
    launchctl: Launchctl,
    fileManager: FileManager = .default,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.launchctl = launchctl
    self.fileManager = fileManager
    self.homeDirectory = homeDirectory
  }

  public var plistURL: URL {
    return AgentService.canonicalURL(homeDirectory: homeDirectory)
  }

  public var serviceTarget: String {
    return "\(AgentService.guiDomain())/\(AgentService.name)"
  }

  /// Full install (start): write canonical plist (agent realpath) FIRST →
  /// bootout (tolerates absent service) → bootstrap, load fallback.
  /// Order matters: write error — working agent NOT stopped, bootout runs
  /// only after successful new-plan write.
  /// binaryPathChanged = true — old plist pointed at different binary
  /// (manager change/update) — CLI prints TCC hint.
  @discardableResult
  public func install(
    agentBinary: String, flags: [String] = [], logPath: String
  ) -> AgentInstallResult {
    let previous = AgentPlist.programArguments(
      fromPlistAt: plistURL.path, fileManager: fileManager)?.first
    var result = AgentInstallResult(
      binaryPathChanged: previous != nil && previous != agentBinary)

    do {
      try AgentPlist.writePlist(
        agentBinary: agentBinary,
        flags: flags,
        logPath: logPath,
        to: plistURL,
        fileManager: fileManager)
    } catch {
      result.writeError = "\(error)"
      return result
    }

    let bootout = launchctl.bootout(target: serviceTarget)
    result.bootoutSucceeded = bootout.status == 0
    let bootstrap = launchctl.bootstrap(plistPath: plistURL.path, domain: AgentService.guiDomain())
    if bootstrap.status == 0 {
      result.registered = true
      return result
    }
    result.bootstrapError = bootstrap.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let load = launchctl.load(plistPath: plistURL.path)
    result.loadError = load.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    result.registered = load.status == 0
    return result
  }

  /// Restart (provider change, config options, menu): canonical plist
  /// rewritten, then kickstart -k. IMPORTANT: kickstart restarts service per
  /// STALE in-memory launchd plan (ProgramArguments NOT re-read) — real
  /// binary path change applies via fallback-install in this method, full
  /// `nanodictate start`, or re-login. Service not loaded (kickstart failed)
  /// — full install.
  @discardableResult
  public func restart(
    agentBinary: String, flags: [String] = [], logPath: String
  ) -> AgentInstallResult {
    let previous = AgentPlist.programArguments(
      fromPlistAt: plistURL.path, fileManager: fileManager)?.first
    var result = AgentInstallResult(
      binaryPathChanged: previous != nil && previous != agentBinary)
    let previousData = fileManager.contents(atPath: plistURL.path)
    do {
      try AgentPlist.writePlist(
        agentBinary: agentBinary,
        flags: flags,
        logPath: logPath,
        to: plistURL,
        fileManager: fileManager)
    } catch {
      result.writeError = "\(error)"
      return result
    }

    // Any change in the launchd plan (binary, flags, log path) needs
    // bootout + bootstrap.
    let planChanged = previousData != Data(AgentPlist.plistContent(agentBinary: agentBinary, flags: flags, logPath: logPath).utf8)
    if !planChanged {
      let kick = launchctl.kickstart(target: serviceTarget)
      if kick.status == 0 {
        result.registered = true
        return result
      }
      result.kickError = kick.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    result.bootoutSucceeded = launchctl.bootout(target: serviceTarget).status == 0
    let bootstrap = launchctl.bootstrap(plistPath: plistURL.path, domain: AgentService.guiDomain())
    if bootstrap.status == 0 {
      result.registered = true
      return result
    }
    result.bootstrapError = bootstrap.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let load = launchctl.load(plistPath: plistURL.path)
    result.loadError = load.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    result.registered = load.status == 0
    return result
  }
}
