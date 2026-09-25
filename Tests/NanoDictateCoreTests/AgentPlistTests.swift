import Foundation
@testable import NanoDictateCore

/// Canonical service registration (AgentPlist + Launchctl + AgentInstaller):
/// one daemon regardless of install path. Binary writes the LaunchAgents plist
/// with agent realpath; takeover on manager change, TCC hint on path change.
/// launchctl is mocked — launchd never invoked in tests.
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

  /// Executable file (PATH-поиск требует бит исполнения).
  private func makeExecutable(_ path: URL) throws {
    try makeFile(path)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: path.path)
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
    // Single canonical path regardless of install method.
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
    XCTAssertEqual(agentRealPath(target.path), target.path)
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
    // NANODICTATE_AGENT_BIN resolves to real path (share/opt/local).
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
    // Invoked via symlink (brew/port): sibling sought beside realpath of invoked.
    let linkDir = dir.appendingPathComponent("links")
    try FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)
    let link = linkDir.appendingPathComponent("nanodictate")
    try makeSymlink(at: link, to: cli)

    let resolved = resolveAgentBinaryPath(invokedBinary: link.path, environment: [:])
    XCTAssertEqual(resolved, agent.path)
  }

  @objc func testResolveWithoutSiblingFallsBackToSiblingPath() {
    // Dev build lacks sibling; fallback returns path beside CLI, never nil.
    let resolved = resolveAgentBinaryPath(
      invokedBinary: "/tmp/x/nanodictate", environment: [:])
    XCTAssertEqual(resolved, "/tmp/x/NanoDictateAgent")
  }

  @objc func testResolveBareInvocationFindsCLIAndAgentInPATH() throws {
    // argv[0] = "nanodictate" (голое слово, `nanodictate start`): PATH-поиск
    // находит CLI-симлинк, realpath — Cellar-бинарь, агент — сосед рядом
    // (brew-сценарий чистой установки).
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let realDir = dir.appendingPathComponent("real")
    let linkDir = dir.appendingPathComponent("links")
    try FileManager.default.createDirectory(at: realDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: linkDir, withIntermediateDirectories: true)
    let cli = realDir.appendingPathComponent("nanodictate")
    let agent = realDir.appendingPathComponent("NanoDictateAgent")
    try makeExecutable(cli)
    try makeFile(agent)
    let link = linkDir.appendingPathComponent("nanodictate")
    try makeSymlink(at: link, to: cli)

    let resolved = resolveAgentBinaryPath(
      invokedBinary: "nanodictate",
      environment: ["PATH": linkDir.path])
    XCTAssertEqual(resolved, agent.path)
    XCTAssertFalse(resolved.isEmpty)
  }

  @objc func testResolveBareInvocationEnvOverrideBeatsPATH() throws {
    // NANODICTATE_AGENT_BIN приоритетнее PATH-поиска даже при голом argv[0]:
    // PATH указывает на каталог с парой CLI+агент, но override побеждает.
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let target = dir.appendingPathComponent("NanoDictateAgent")
    try makeFile(target)
    let link = dir.appendingPathComponent("linkedAgent")
    try makeSymlink(at: link, to: target)
    let decoyDir = dir.appendingPathComponent("decoy")
    try FileManager.default.createDirectory(at: decoyDir, withIntermediateDirectories: true)
    let decoyCLI = decoyDir.appendingPathComponent("nanodictate")
    let decoyAgent = decoyDir.appendingPathComponent("NanoDictateAgent")
    try makeExecutable(decoyCLI)
    try makeFile(decoyAgent)

    let resolved = resolveAgentBinaryPath(
      invokedBinary: "nanodictate",
      environment: [
        "PATH": decoyDir.path,
        "NANODICTATE_AGENT_BIN": link.path,
      ])
    XCTAssertEqual(resolved, target.path)
  }

  @objc func testResolveAbsolutePathIgnoresPATH() throws {
    // Абсолютный argv[0]: PATH-поиск не задействуется, прежняя логика
    // (сосед агента рядом с realpath вызова) не ухудшена — PATH-каталог
    // с чужим агентом не перебивает sibling.
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let binDir = dir.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    let cli = binDir.appendingPathComponent("nanodictate")
    let agent = binDir.appendingPathComponent("NanoDictateAgent")
    try makeFile(cli)
    try makeFile(agent)
    let decoyDir = dir.appendingPathComponent("decoy")
    try FileManager.default.createDirectory(at: decoyDir, withIntermediateDirectories: true)
    let decoyAgent = decoyDir.appendingPathComponent("NanoDictateAgent")
    try makeFile(decoyAgent)

    let resolved = resolveAgentBinaryPath(
      invokedBinary: cli.path,
      environment: ["PATH": decoyDir.path])
    XCTAssertEqual(resolved, agent.path)
  }

  @objc func testResolveBareInvocationPATHMissFallsBackToCWDSibling() {
    // PATH не содержит бинарь (или PATH пуст): откат на прежнее поведение —
    // резолв от CWD, путь не пуст (контракт «empty impossible»).
    let resolved = resolveAgentBinaryPath(
      invokedBinary: "nanodictate",
      environment: ["PATH": "/nonexistent"])
    let expected = agentRealPath(
      URL(fileURLWithPath: "nanodictate").deletingLastPathComponent()
        .appendingPathComponent("NanoDictateAgent").path)
    XCTAssertEqual(resolved, expected)
    XCTAssertFalse(resolved.isEmpty)
  }

  @objc func testResolveBareInvocationSkipsSiblinglessPATHThenFindsAgent() throws {
    // Первый PATH-каталог содержит исполняемый CLI, но БЕЗ NanoDictateAgent
    // рядом — поиск продолжается (continue) и находит пару во втором
    // каталоге; порядок каталогов важен (decoy идёт первым).
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let decoyDir = dir.appendingPathComponent("decoy")
    try FileManager.default.createDirectory(at: decoyDir, withIntermediateDirectories: true)
    let decoyCLI = decoyDir.appendingPathComponent("nanodictate")
    try makeExecutable(decoyCLI)  // без соседа-агента в этом каталоге
    let binDir = dir.appendingPathComponent("bin")
    try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
    let cli = binDir.appendingPathComponent("nanodictate")
    let agent = binDir.appendingPathComponent("NanoDictateAgent")
    try makeExecutable(cli)
    try makeFile(agent)

    let resolved = resolveAgentBinaryPath(
      invokedBinary: "nanodictate",
      environment: ["PATH": "\(decoyDir.path):\(binDir.path)"])
    XCTAssertEqual(resolved, agent.path)
  }

  // MARK: - Обработа: CLI и агент соседи в .app-бандле

  /// Вспомогатель: NanoDictate.app/Contents/MacOS/{nanodictate, NanoDictateAgent}.
  private func makeBundle(_ dir: URL) throws -> URL {
    let macos = dir
      .appendingPathComponent("NanoDictate.app/Contents/MacOS")
    try FileManager.default.createDirectory(
      at: macos, withIntermediateDirectories: true)
    try makeExecutable(macos.appendingPathComponent("nanodictate"))
    try makeFile(macos.appendingPathComponent("NanoDictateAgent"))
    return macos
  }

  @objc func testResolveBundleSiblingViaAbsoluteSymlink() throws {
    // Cask-сценарий: /usr/local/bin/nanodictate — симлинк на
    // NanoDictate.app/Contents/MacOS/nanodictate; агент — сосед в MacOS/.
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let macos = try makeBundle(dir)
    let usrLocalBin = dir.appendingPathComponent("usr/local/bin")
    try FileManager.default.createDirectory(
      at: usrLocalBin, withIntermediateDirectories: true)
    let link = usrLocalBin.appendingPathComponent("nanodictate")
    try makeSymlink(at: link, to: macos.appendingPathComponent("nanodictate"))

    let resolved = resolveAgentBinaryPath(
      invokedBinary: link.path, environment: [:])
    XCTAssertEqual(
      resolved,
      macos.appendingPathComponent("NanoDictateAgent").path)
  }

  @objc func testResolveBundleSiblingViaBareInvocation() throws {
    // `nanodictate start` с PATH на каталог с cask-симлинком: PATH-поиск
    // находит симлинк → realpath внутрь бандла → агент-сосед в MacOS/.
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let macos = try makeBundle(dir)
    let linksDir = dir.appendingPathComponent("links")
    try FileManager.default.createDirectory(
      at: linksDir, withIntermediateDirectories: true)
    let link = linksDir.appendingPathComponent("nanodictate")
    try makeSymlink(at: link, to: macos.appendingPathComponent("nanodictate"))

    let resolved = resolveAgentBinaryPath(
      invokedBinary: "nanodictate",
      environment: ["PATH": linksDir.path])
    XCTAssertEqual(
      resolved,
      macos.appendingPathComponent("NanoDictateAgent").path)
  }

  @objc func testResolveBundleSiblingDirectInvocation() throws {
    // Прямой вызов CLI из бандла (без симлинка): argv[0] — абсолютный путь
    // внутрь Contents/MacOS, агент — сосед рядом.
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let macos = try makeBundle(dir)
    let cli = macos.appendingPathComponent("nanodictate")

    let resolved = resolveAgentBinaryPath(
      invokedBinary: cli.path, environment: [:])
    XCTAssertEqual(
      resolved,
      macos.appendingPathComponent("NanoDictateAgent").path)
  }

  // MARK: - plist-контент

  @objc func testPlistContentHasAllKeysAndArguments() {
    let content = AgentPlist.plistContent(
      agentBinary: "/opt/homebrew/Cellar/nanodictate/0.0.2/bin/NanoDictateAgent",
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
    XCTAssertFalse(content.contains("& co<"))  // raw specials must not pass
    XCTAssertTrue(content.contains("&amp; co&lt;"))
    XCTAssertTrue(content.contains("&gt;"))  // ">" → &gt;
    XCTAssertTrue(content.contains("&quot;"))  // "\"" → &quot;
    XCTAssertFalse(content.contains("Nano>Dictate"))
    XCTAssertFalse(content.contains("Dictate\"Agent"))
    let args = AgentPlist.programArguments(fromPlistData: Data(content.utf8))
    XCTAssertEqual(args, [binary])  // roundtrip returns the original path
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
    // Empty NANODICTATE_AGENT_BIN = unset; resolve via sibling beside realpath.
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
    let expected: [(String, [String])] = [
      ("/bin/launchctl", ["print", "gui/501/com.nanodictate.agent"]),
      ("/bin/launchctl", ["bootout", "gui/501/com.nanodictate.agent"]),
      ("/bin/launchctl", ["bootstrap", "gui/501", "/p/a.plist"]),
      ("/bin/launchctl", ["load", "/p/a.plist"]),
      ("/bin/launchctl", ["kickstart", "-k", "gui/501/com.nanodictate.agent"]),
    ]
    XCTAssertEqual(mock.calls.count, expected.count)
    for (got, want) in zip(mock.calls, expected) {
      XCTAssertEqual(got.0, want.0)
      XCTAssertEqual(got.1, want.1)
    }
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
    // Launchctl order: bootout then bootstrap; plist written before bootout.
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
    XCTAssertTrue(again.binaryPathChanged)  // manager/path change → TCC hint
    XCTAssertEqual(AgentPlist.programArguments(fromPlistAt: inst.plistURL.path), ["/new"])
  }

  @objc func testInstallNoHintOnSamePathAndFirstRun() throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mock = MockLaunchctl()
    let inst = installer(home: dir, mock: mock)

    let first = inst.install(agentBinary: "/bin/agent", logPath: "/tmp/l.log")
    XCTAssertFalse(first.binaryPathChanged)  // first run: no prior plan

    let same = inst.install(agentBinary: "/bin/agent", logPath: "/tmp/l.log")
    XCTAssertFalse(same.binaryPathChanged)  // same path: no hint
  }

  @objc func testInstallBootoutTolerantWhenServiceMissing() throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mock = MockLaunchctl()
    mock.bootoutStatus = 1  // service missing: bootout must fail tolerantly
    let inst = installer(home: dir, mock: mock)

    let result = inst.install(agentBinary: "/bin/agent", logPath: "/tmp/l.log")

    XCTAssertTrue(result.registered)  // bootstrap still succeeded
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
    try makeFile(blocker)  // file blocks future dir path: write must fail
    let mock = MockLaunchctl()
    let inst = installer(home: blocker, mock: mock)  // plistURL lands under file

    let result = inst.install(agentBinary: "/bin/agent", logPath: "/tmp/l.log")

    XCTAssertFalse(result.registered)
    XCTAssertNotNil(result.writeError)
    // Write precedes bootout; on write error launchctl untouched, so the
    // running service is never stopped.
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

  /// Kickstart fails on an unchanged plan → fallback to full install
  /// (bootout + bootstrap). Plan pre-written (install) so restart takes the
  /// kickstart shortcut (planChanged == false) before the fallback.
  @objc func testRestartFallsBackToFullInstallWhenKickstartFails() throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mock = MockLaunchctl()
    let inst = installer(home: dir, mock: mock)
    // The on-disk plan must match what restart() would generate — otherwise
    // planChanged == true and the kickstart shortcut is never reached.
    _ = inst.install(agentBinary: "/bin/agent", logPath: "/tmp/l.log")
    mock.clear()
    mock.kickStatus = 1
    mock.stderr = "kickstart: no such process"

    let result = inst.restart(agentBinary: "/bin/agent", logPath: "/tmp/l.log")

    XCTAssertTrue(result.registered)
    XCTAssertFalse(result.kickError.isEmpty)
    XCTAssertEqual(mock.commandNames(), ["kickstart", "bootout", "bootstrap"])
  }

  /// Plan change (flags differ from on-disk plist) → full reinstall path
  /// (bootout + bootstrap); kickstart shortcut skipped (planChanged == true).
  @objc func testRestartFlagsChangeTakesFullReinstallPath() throws {
    let dir = try tmpDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let mock = MockLaunchctl()
    let inst = installer(home: dir, mock: mock)
    _ = inst.install(agentBinary: "/bin/agent", logPath: "/tmp/l.log")
    mock.clear()

    let result = inst.restart(agentBinary: "/bin/agent", flags: ["--debug"], logPath: "/tmp/l.log")

    XCTAssertTrue(result.registered)
    XCTAssertTrue(result.kickError.isEmpty)
    XCTAssertEqual(mock.commandNames(), ["bootout", "bootstrap"])
    XCTAssertFalse(mock.commandNames().contains("kickstart"))
    XCTAssertEqual(
      AgentPlist.programArguments(fromPlistAt: inst.plistURL.path),
      ["/bin/agent", "--debug"])
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