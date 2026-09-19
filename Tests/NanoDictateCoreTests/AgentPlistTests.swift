import Foundation
@testable import NanoDictateCore

/// Тесты канонической регистрации службы (AgentPlist + Launchctl +
/// AgentInstaller): «один демон при любом способе установки» — бинарь сам
/// пишет ~/Library/LaunchAgents/com.nanodictate.agent.plist с realpath агента,
/// takeover при смене менеджера, TCC-подсказка при смене пути. launchctl
/// замокан (моковый run) — launchd в тестах не вызывается.
final class AgentPlistTests: XCTestCase {

  // MARK: - Helpers

  private func tmpDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("agentplist_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  private func makeFile(_ path: URL) throws {
    try Data("x".utf8).write(to: path)
  }

  private func makeSymlink(at link: URL, to target: URL) throws {
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: target)
  }

  private func installer(
    home: URL,
    mock: MockLaunchctl
  ) -> AgentInstaller {
    return AgentInstaller(
      launchctl: mock.makeLaunchctl(), homeDirectory: home)
  }

  // MARK: - Канон: путь plist, Label, gui-домен

  @objc func testServiceCanonicalValues() {
    XCTAssertEqual(AgentService.name, "com.nanodictate.agent")
    XCTAssertEqual(AgentService.guiDomain(uid: 501), "gui/501")

    let home = URL(fileURLWithPath: "/Users/test")
    let url = AgentService.canonicalURL(homeDirectory: home)
    XCTAssertEqual(
      url.path, "/Users/test/Library/LaunchAgents/com.nanodictate.agent.plist")
    // Единственный канон: путь тот же независимо от способа установки.
    XCTAssertEqual(
      AgentService.canonicalURL(homeDirectory: URL(fileURLWithPath: "/Users/other")).path
        .hasSuffix("/Library/LaunchAgents/com.nanodictate.agent.plist"),
      true)
  }

  // MARK: - realpath

  @objc func testRealPathResolvesSymlink() throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let realDir = dir.appendingPathComponent("real")
    let linkDir = dir.appendingPathComponent("link")
    try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)
    let target = realDir.appendingPathComponent("NanoDictateAgent")
    try makeFile(target)
    let link = linkDir.appendingPathComponent("nanodictate")
    try makeSymlink(at: link, to: target)

    XCTAssertEqual(agentRealPath(link.path), target.path)
    XCTAssertEqual(agentRealPath(target.path), target.path)  // без симлинка — без изменений
  }

  @objc func testRealPathNoFileStillNormalizes() {
    let p = "/tmp/abc/def"
    XCTAssertEqual(agentRealPath(p), p)
  }

  // MARK: - resolveAgentBinaryPath

  @objc func testResolveEnvOverrideWinsAndResolvesSymlink() throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = dir.appendingPathComponent("NanoDictateAgent")
    try makeFile(target)
    let link = dir.appendingPathComponent("linkedAgent")
    try makeSymlink(at: link, to: target)
    // NANODICTATE_AGENT_BIN разрешается до реального пути (share/opt/local).
    let resolved = resolveAgentBinaryPath(
      invokedBinary: "/usr/local/bin/nanodictate",
      environment: ["NANODICTATE_AGENT_BIN": link.path])
    XCTAssertEqual(resolved, target.path)
  }

  @objc func testResolveFindsSiblingNextToRealInvokedPath() throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let binDir = dir.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    let cli = binDir.appendingPathComponent("nanodictate")
    let agent = binDir.appendingPathComponent("NanoDictateAgent")
    try makeFile(cli)
    try makeFile(agent)
    // Вызов через симлинк (brew/port): sibling ищется у REALPATH вызванного.
    let linkDir = dir.appendingPathComponent("links")
    try FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)
    let link = linkDir.appendingPathComponent("nanodictate")
    try makeSymlink(at: link, to: cli)

    let resolved = resolveAgentBinaryPath(invokedBinary: link.path, environment: [:])
    XCTAssertEqual(resolved, agent.path)
  }

  @objc func testResolveWithoutSiblingFallsBackToSiblingPath() {
    // Dev-сборка: бинаря рядом может не быть — фолбэк не nil, путь рядом с CLI.
    let resolved = resolveAgentBinaryPath(
      invokedBinary: "/tmp/x/nanodictate", environment: [:])
    XCTAssertEqual(resolved, "/tmp/x/NanoDictateAgent")
  }

  // MARK: - plist-контент

  @objc func testPlistContentHasAllKeysAndArguments() {
    let content = AgentPlist.plistContent(
      agentBinary: "/opt/homebrew/Cellar/nanodictate/0.1.0/bin/NanoDictateAgent",
      flags: ["--debug"],
      logPath: "/Users/test/Library/Logs/NanoDictate/agent.log")
    XCTAssertTrue(content.contains("<string>com.nanodictate.agent</string>"))
    XCTAssertTrue(content.contains("NanoDictateAgent</string>"))
    XCTAssertTrue(content.contains("<string>--debug</string>"))
    XCTAssertTrue(content.contains("<true/>"))  // RunAtLoad + KeepAlive
    XCTAssertTrue(content.contains("StandardOutPath"))
    XCTAssertTrue(content.contains("StandardErrorPath"))
    XCTAssertTrue(content.contains("agent.log"))
  }

  @objc func testPlistContentRoundTripsViaPropertyList() throws {
    let binary = "/opt/macports/libexec/nanodictate/NanoDictateAgent"
    let log = "/Users/u/Library/Logs/NanoDictate/agent.log"
    let content = AgentPlist.plistContent(agentBinary: binary, logPath: log)
    let args = AgentPlist.programArguments(
      fromPlistData: Data(content.utf8))
    XCTAssertEqual(args, [binary])

    let plist = try PropertyListSerialization.propertyList(
      from: Data(content.utf8), format: nil) as? [String: Any]
    XCTAssertNotNil(plist)
    XCTAssertEqual(plist?["Label"] as? String, "com.nanodictate.agent")
    XCTAssertEqual(plist?["ProgramArguments"] as? [String], [binary])
    XCTAssertEqual(plist?["RunAtLoad"] as? Bool, true)
    XCTAssertEqual(plist?["KeepAlive"] as? Bool, true)
    XCTAssertEqual(plist?["StandardOutPath"] as? String, log)
    XCTAssertEqual(plist?["StandardErrorPath"] as? String, log)
  }

  @objc func testPlistContentEscapesXmlSpecials() throws {
    let binary = "/tmp/agent & co<Nano>Dictate\"Agent"
    let content = AgentPlist.plistContent(agentBinary: binary, logPath: "/tmp/l.log")
    XCTAssertFalse(content.contains("& co<"))  // сырые спецсимволы не проходят
    XCTAssertTrue(content.contains("&amp; co&lt;"))
    XCTAssertTrue(content.contains("&gt;"))  // ">" → &gt;
    XCTAssertTrue(content.contains("&quot;"))  // "\"" → &quot;
    XCTAssertFalse(content.contains("Nano>Dictate"))
    XCTAssertFalse(content.contains("Dictate\"Agent"))
    let args = AgentPlist.programArguments(fromPlistData: Data(content.utf8))
    XCTAssertEqual(args, [binary])  // roundtrip возвращает исходный путь
  }

  @objc func testResolveEmptyEnvBinFallsThroughToSibling() throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let binDir = dir.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    let cli = binDir.appendingPathComponent("nanodictate")
    let agent = binDir.appendingPathComponent("NanoDictateAgent")
    try makeFile(cli)
    try makeFile(agent)
    // NANODICTATE_AGENT_BIN задан ПУСТЫМ — трактуется как «не задан»,
    // разрешение идёт через sibling у realpath вызванного CLI.
    let resolved = resolveAgentBinaryPath(
      invokedBinary: cli.path, environment: ["NANODICTATE_AGENT_BIN": ""])
    XCTAssertEqual(resolved, agent.path)
    XCTAssertFalse(resolved.isEmpty)
  }

  @objc func testProgramArgumentsFromMissingOrInvalidPlist() {
    XCTAssertNil(AgentPlist.programArguments(fromPlistAt: "/nonexistent/x.plist"))
    XCTAssertNil(AgentPlist.programArguments(fromPlistData: Data("not a plist".utf8)))
    XCTAssertNil(
      AgentPlist.programArguments(fromPlistData: Data("<plist version=\"1.0\"><dict></dict></plist>".utf8)))
  }

  @objc func testWritePlistCreatesDirAnd0600() throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("LaunchAgents/com.nanodictate.agent.plist")
    try AgentPlist.writePlist(
      agentBinary: "/bin/agent", logPath: "/tmp/agent.log", to: url)
    XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
    XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
    XCTAssertEqual(
      AgentPlist.programArguments(fromPlistAt: url.path), ["/bin/agent"])
  }

  // MARK: - Launchctl-обёртка (аргументы в мок)

  @objc func testLaunchctlSubcommandsPassExpectedArgs() {
    let mock = MockLaunchctl()
    let lc = mock.makeLaunchctl()
    _ = lc.isLoaded(target: "gui/501/com.nanodictate.agent")
    _ = lc.bootout(target: "gui/501/com.nanodictate.agent")
    _ = lc.bootstrap(plistPath: "/p/a.plist", domain: "gui/501")
    _ = lc.load(plistPath: "/p/a.plist")
    _ = lc.kickstart(target: "gui/501/com.nanodictate.agent")
    XCTAssertEqual(
      mock.calls,
      [
        ("/bin/launchctl", ["print", "gui/501/com.nanodictate.agent"]),
        ("/bin/launchctl", ["bootout", "gui/501/com.nanodictate.agent"]),
        ("/bin/launchctl", ["bootstrap", "gui/501", "/p/a.plist"]),
        ("/bin/launchctl", ["load", "/p/a.plist"]),
        ("/bin/launchctl", ["kickstart", "-k", "gui/501/com.nanodictate.agent"]),
      ])
    XCTAssertEqual(lc.serviceTarget, "gui/\(getuid())/com.nanodictate.agent")
  }

  // MARK: - install: полный takeover

  @objc func testInstallWriteThenBootoutThenBootstrap() throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mock = MockLaunchctl()
    let inst = installer(home: dir, mock: mock)

    let result = inst.install(agentBinary: "/bin/agent", logPath: "/tmp/agent.log")

    XCTAssertTrue(result.registered)
    XCTAssertTrue(result.bootoutSucceeded)
    XCTAssertFalse(result.binaryPathChanged)
    // Порядок launchctl: bootout → bootstrap; plist записан на диск ДО bootout.
    XCTAssertEqual(mock.commandNames(), ["bootout", "bootstrap"])
    XCTAssertTrue(FileManager.default.fileExists(atPath: inst.plistURL.path))
    XCTAssertEqual(AgentPlist.programArguments(fromPlistAt: inst.plistURL.path), ["/bin/agent"])
  }

  @objc func testInstallWhenAlreadyRunningStillTakesOver() throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mock = MockLaunchctl()
    let inst = installer(home: dir, mock: mock)
    _ = inst.install(agentBinary: "/old", logPath: "/tmp/l.log")

    let again = inst.install(agentBinary: "/new", logPath: "/tmp/l.log")
    XCTAssertTrue(again.registered)
    XCTAssertTrue(again.bootoutSucceeded)
    XCTAssertTrue(again.binaryPathChanged)  // смена менеджера/пути → TCC-подсказка
    XCTAssertEqual(AgentPlist.programArguments(fromPlistAt: inst.plistURL.path), ["/new"])
  }

  @objc func testInstallNoHintOnSamePathAndFirstRun() throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mock = MockLaunchctl()
    let inst = installer(home: dir, mock: mock)

    let first = inst.install(agentBinary: "/bin/agent", logPath: "/tmp/l.log")
    XCTAssertFalse(first.binaryPathChanged)  // первый запуск — плана не было

    let same = inst.install(agentBinary: "/bin/agent", logPath: "/tmp/l.log")
    XCTAssertFalse(same.binaryPathChanged)  // тот же путь — подсказки нет
  }

  @objc func testInstallBootoutTolerantWhenServiceMissing() throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mock = MockLaunchctl()
    mock.bootoutStatus = 1  // службы нет — bootout обязан упасть терпимо
    let inst = installer(home: dir, mock: mock)

    let result = inst.install(agentBinary: "/bin/agent", logPath: "/tmp/l.log")

    XCTAssertTrue(result.registered)  // bootstrap всё равно прошёл
    XCTAssertFalse(result.bootoutSucceeded)
    XCTAssertTrue(FileManager.default.fileExists(atPath: inst.plistURL.path))
  }

  @objc func testInstallFallbackToLoadWhenBootstrapFails() throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mock = MockLaunchctl()
    mock.bootstrapStatus = 1
    mock.stderr = "launchctl: bootstrap failed"
    let inst = installer(home: dir, mock: mock)

    let result = inst.install(agentBinary: "/bin/agent", logPath: "/tmp/l.log")

    XCTAssertTrue(result.registered)
    XCTAssertFalse(result.bootstrapError.isEmpty)
    XCTAssertEqual(mock.commandNames(), ["bootout", "bootstrap", "load"])
  }

  @objc func testInstallReportsFailureWhenBothBootstrapAndLoadFail() throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mock = MockLaunchctl()
    mock.bootstrapStatus = 1
    mock.loadStatus = 1
    mock.stderr = "boom"
    let inst = installer(home: dir, mock: mock)

    let result = inst.install(agentBinary: "/bin/agent", logPath: "/tmp/l.log")

    XCTAssertFalse(result.registered)
    XCTAssertEqual(result.bootstrapError, "boom")
    XCTAssertEqual(result.loadError, "boom")
  }

  @objc func testInstallReportsWriteErrorAndSkipsLaunchctl() throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let blocker = dir.appendingPathComponent("blocker")
    try makeFile(blocker)  // файл на месте будущего каталога → запись не пройдёт
    let mock = MockLaunchctl()
    let inst = installer(home: blocker, mock: mock)  // plistURL уйдёт ПОД файл

    let result = inst.install(agentBinary: "/bin/agent", logPath: "/tmp/l.log")

    XCTAssertFalse(result.registered)
    XCTAssertNotNil(result.writeError)
    // Запись идёт ДО bootout: при ошибке записи launchctl не дёргается ВООБЩЕ
    // (bootout в т.ч.) — работавшая служба не останавливается.
    XCTAssertTrue(mock.calls.isEmpty)
    XCTAssertFalse(result.bootoutSucceeded)
  }

  // MARK: - restart: переписать plist + kickstart (фолбэк на полную установку)

  @objc func testRestartRewriteThenKickstart() throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mock = MockLaunchctl()
    let inst = installer(home: dir, mock: mock)
    _ = inst.install(agentBinary: "/bin/agent", logPath: "/tmp/l.log")
    mock.clear()

    let result = inst.restart(agentBinary: "/bin/agent", logPath: "/tmp/l.log")

    XCTAssertTrue(result.registered)
    XCTAssertFalse(result.binaryPathChanged)
    XCTAssertEqual(mock.commandNames(), ["kickstart"])
    XCTAssertEqual(AgentPlist.programArguments(fromPlistAt: inst.plistURL.path), ["/bin/agent"])
  }

  @objc func testRestartFallsBackToFullInstallWhenKickstartFails() throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mock = MockLaunchctl()
    mock.kickStatus = 1
    mock.stderr = "kickstart: no such process"
    let inst = installer(home: dir, mock: mock)

    let result = inst.restart(agentBinary: "/bin/agent", logPath: "/tmp/l.log")

    XCTAssertTrue(result.registered)
    XCTAssertFalse(result.kickError.isEmpty)
    XCTAssertEqual(mock.commandNames(), ["kickstart", "bootout", "bootstrap"])
  }

  @objc func testRestartReportsWriteError() throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let blocker = dir.appendingPathComponent("blocker")
    try makeFile(blocker)
    let mock = MockLaunchctl()
    let inst = installer(home: blocker, mock: mock)

    let result = inst.restart(agentBinary: "/bin/agent", logPath: "/tmp/l.log")

    XCTAssertFalse(result.registered)
    XCTAssertNotNil(result.writeError)
    XCTAssertTrue(mock.calls.isEmpty)
  }
}

// MARK: - Мок launchctl (launchd не вызывается)

private final class MockLaunchctl {
  var bootoutStatus: Int32 = 0
  var bootstrapStatus: Int32 = 0
  var loadStatus: Int32 = 0
  var kickStatus: Int32 = 0
  var printStatus: Int32 = 0
  var stderr = ""
  var calls: [(String, [String])] = []

  func clear() {
    calls.removeAll()
  }

  func makeLaunchctl() -> Launchctl {
    return Launchctl { [self] launchPath, args in
      calls.append((launchPath, args))
      let status: Int32
      switch args.first {
      case "bootout": status = bootoutStatus
      case "bootstrap": status = bootstrapStatus
      case "load": status = loadStatus
      case "kickstart": status = kickStatus
      default: status = printStatus
      }
      return (status: status, stdout: "", stderr: stderr)
    }
  }

  func commandNames() -> [String] {
    return calls.compactMap { $0.1.first }
  }
}