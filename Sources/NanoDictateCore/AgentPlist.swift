// swiftlint:disable file_length
import Darwin
import Foundation

// MARK: - Каноническая спецификация службы агента

/// Один демон при любом способе установки (brew/port/dev-сборка): службу
/// регистрирует САМ запущенный бинарь. Канонический plist один навсегда —
/// ~/Library/LaunchAgents/com.nanodictate.agent.plist, Label com.nanodictate.agent.
/// Упаковка (Homebrew/MacPorts) службу НЕ регистрирует.
public enum AgentService {
  /// Label службы (уникален в gui-домене launchd).
  public static let name = "com.nanodictate.agent"

  /// GUI-домен launchctl: "gui/<uid>".
  public static func guiDomain(uid: uid_t = getuid()) -> String {
    return "gui/\(uid)"
  }

  /// Канонический путь plist (~/Library/LaunchAgents/com.nanodictate.agent.plist).
  public static func canonicalURL(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser)
    -> URL
  {
    return homeDirectory
      .appendingPathComponent("Library/LaunchAgents")
      .appendingPathComponent("\(name).plist")
  }
}

// MARK: - Реальный путь бинаря

/// realpath: путь со всеми симлинками resolved (URL.resolvingSymlinksInPath).
/// Если файла нет (симлинк битый) — возвращает normalised абсолютный путь
/// (resolvingSymlinksInPath идемпотентен на несуществующих путях).
public func agentRealPath(_ path: String) -> String {
  return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
}

/// Путь к бинарю агента, под которым служба будет зарегистрирована:
/// 1) env NANODICTATE_AGENT_BIN (явный оверрайд, например установленный
///    в /opt/local/bin вариант; realpath завершает разрешение симлинков);
/// 2) NanoDictateAgent рядом с РЕАЛЬНЫМ (после разрешения симлинков) путём
///    вызванного CLI — переживает вызов через /opt/homebrew/bin или симлинк;
/// 3) фолбэк — sibling-путь рядом с вызванным бинарём (брат в .build/debug).
/// Возврат пустым невозможен: последняя ветка всегда даёт путь.
public func resolveAgentBinaryPath(
  invokedBinary: String,
  environment: [String: String] = ProcessInfo.processInfo.environment,
  fileManager: FileManager = .default
) -> String {
  let name = "NanoDictateAgent"
  if let env = environment["NANODICTATE_AGENT_BIN"], !env.isEmpty {
    return agentRealPath(env)
  }
  let invoked = agentRealPath(invokedBinary)
  let sibling = URL(fileURLWithPath: invoked).deletingLastPathComponent()
    .appendingPathComponent(name)
  if fileManager.fileExists(atPath: sibling.path) {
    return agentRealPath(sibling.path)
  }
  // Фолбэк: брат рядом с исходным (не resolved) вызовом — покрывает dev-сборку,
  // где argv[0] уже реальный путь.
  let rawSibling = URL(fileURLWithPath: invokedBinary).deletingLastPathComponent()
    .appendingPathComponent(name)
  return agentRealPath(rawSibling.path)
}

// MARK: - Генерация канонического plist

public enum AgentPlist {
  /// Экранирование XML-спецсимволов (пути могут содержать &, ", <, >).
  public static func xmlEscape(_ value: String) -> String {
    return value
      .replacingOccurrences(of: "&", with: "&amp;")
      .replacingOccurrences(of: "<", with: "&lt;")
      .replacingOccurrences(of: ">", with: "&gt;")
      .replacingOccurrences(of: "\"", with: "&quot;")
  }

  /// Инлайн-XML канонического plist: Label, ProgramArguments (бинарь + флаги),
  /// RunAtLoad + KeepAlive (как в прежнем шаблоне), лог-пути в ~/Library/Logs.
  public static func plistContent(agentBinary: String, flags: [String] = [], logPath: String)
    -> String
  {
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

  /// ProgramArguments прежнего plist с диска (для сравнения путей при takeover).
  /// nil — plist отсутствует, не читается или не содержит массива.
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

  /// Атомарная запись plist с правами 0600 (пишет makeLaunchAgentsDir).
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

/// Инъектируемый исполнитель launchctl: прод — runProcess, тесты — мок
/// (launchd в тестах не вызывается).
public final class Launchctl {
  public typealias Run = (String, [String]) -> (status: Int32, stdout: String, stderr: String)

  public var run: Run

  public init(run: @escaping Run) {
    self.run = run
  }

  public var serviceTarget: String {
    return "\(AgentService.guiDomain())/\(AgentService.name)"
  }

  /// launchctl print — служба загружена (status == 0)?
  public func isLoaded(target: String) -> Bool {
    return run("/bin/launchctl", ["print", target]).status == 0
  }

  /// launchctl bootout — выгрузка под target; обрыв допустим (службы нет).
  @discardableResult
  public func bootout(target: String) -> (status: Int32, stdout: String, stderr: String) {
    return run("/bin/launchctl", ["bootout", target])
  }

  /// launchctl bootstrap gui/uid path — загрузка плана из plist.
  @discardableResult
  public func bootstrap(plistPath: String, domain: String) -> (status: Int32, stdout: String,
    stderr: String) {
    return run("/bin/launchctl", ["bootstrap", domain, plistPath])
  }

  /// launchctl load path — legacy-фолбэк (старые macOS / без gui-домена).
  @discardableResult
  public func load(plistPath: String) -> (status: Int32, stdout: String, stderr: String) {
    return run("/bin/launchctl", ["load", plistPath])
  }

  /// launchctl kickstart -k target — рестарт загруженной службы.
  @discardableResult
  public func kickstart(target: String) -> (status: Int32, stdout: String, stderr: String) {
    return run("/bin/launchctl", ["kickstart", "-k", target])
  }
}

// MARK: - Установщик службы

/// Результат операции install/restart — поля для сообщений CLI и TCC-подсказки.
public struct AgentInstallResult: Equatable {
  /// Служба активна после операции (bootstrap/load/kickstart).
  public var registered: Bool
  /// Прежний процесс остановлен bootout (терпимо к «службы нет»).
  public var bootoutSucceeded: Bool
  /// ProgramArguments изменился относительно прежнего plist → TCC-подсказка.
  public var binaryPathChanged: Bool
  /// stderr bootstrap (неуспех продолжал fallback-цепочку).
  public var bootstrapError: String
  /// stderr load (fallback после bootstrap).
  public var loadError: String
  /// stderr kickstart (restart без полной установки).
  public var kickError: String
  /// Ошибка записи plist (nil — plist записан).
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

/// Регистрация/рестарт канонического plist. Manager-смена (другой бинарь,
/// другой способ установки) = takeover: bootout старого → запись нового →
/// bootstrap. Идемпотентно: повторный start уже загруженной службы меняет
/// владельца и путь корректно (launchd держит в памяти план из plist НА
/// МОМЕНТ bootstrap — перезапись файла сама по себе живой службы не трогает).
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

  /// Полная установка (start): bootout (терпимо к отсутствию службы) → запись
  /// канонического plist (realpath агента) → bootstrap, фолбэк load.
  /// binaryPathChanged = true, если старый plist указывал на другой бинарь
  /// (смена менеджера/обновление) — CLI печатает TCC-подсказку.
  @discardableResult
  public func install(agentBinary: String, flags: [String] = [], logPath: String)
    -> AgentInstallResult
  {
    let previous = AgentPlist.programArguments(
      fromPlistAt: plistURL.path, fileManager: fileManager)?.first
    var result = AgentInstallResult(
      binaryPathChanged: previous != nil && previous != agentBinary)

    let bootout = launchctl.bootout(target: serviceTarget)
    result.bootoutSucceeded = bootout.status == 0
    do {
      try AgentPlist.writePlist(
        agentBinary: agentBinary, flags: flags, logPath: logPath, to: plistURL,
        fileManager: fileManager)
    } catch {
      result.writeError = "\(error)"
      return result
    }

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

  /// Рестарт (Provider-смена, config-опции, меню): канонический plist
  /// перезаписывается (путь не протухает после обновления), затем kickstart -k.
  /// Если служба не загружена (kickstart упал) — полная установка.
  @discardableResult
  public func restart(agentBinary: String, flags: [String] = [], logPath: String)
    -> AgentInstallResult
  {
    let previous = AgentPlist.programArguments(
      fromPlistAt: plistURL.path, fileManager: fileManager)?.first
    var result = AgentInstallResult(
      binaryPathChanged: previous != nil && previous != agentBinary)
    do {
      try AgentPlist.writePlist(
        agentBinary: agentBinary, flags: flags, logPath: logPath, to: plistURL,
        fileManager: fileManager)
    } catch {
      result.writeError = "\(error)"
      return result
    }

    let kick = launchctl.kickstart(target: serviceTarget)
    if kick.status == 0 {
      result.registered = true
      return result
    }
    result.kickError = kick.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
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