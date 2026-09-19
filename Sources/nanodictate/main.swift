// swiftlint:disable file_length
import Darwin
import Foundation
import NanoDictateCore

// MARK: - Utils

func eprint(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}

func runProcess(_ launchPath: String, _ args: [String]) -> (  // swiftlint:disable:this large_tuple
  status: Int32, stdout: String, stderr: String
) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: launchPath)
  process.arguments = args
  let outPipe = Pipe()
  let errPipe = Pipe()
  process.standardOutput = outPipe
  process.standardError = errPipe
  do {
    try process.run()
  } catch {
    return (-1, "", "Failed to launch \(launchPath): \(error.localizedDescription)")
  }
  process.waitUntilExit()
  let stdout = String(decoding: outPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  let stderr = String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
  return (process.terminationStatus, stdout, stderr)
}

/// User GUI domain for launchctl, e.g. "gui/501".
let guiDomain = "gui/\(getuid())"

/// LaunchAgent service name (plist Label, the target of
/// launchctl print/bootstrap/bootout).
let agentServiceName = "com.nanodictate.agent"

/// Absolute (realpath) path to the agent binary for service registration:
/// NANODICTATE_AGENT_BIN → NanoDictateAgent sibling of the realpath of the
/// invoked CLI → sibling of the raw argv[0] (dev build). One daemon for any
/// install method: brew/port invoke the CLI through a symlink — realpath
/// keeps the Cellar/opt/local path that does not go stale until the next
/// `start`.
func findAgentBinaryPath() -> String {
  return resolveAgentBinaryPath(invokedBinary: CommandLine.arguments[0])
}

// MARK: - Subcommands

func cmdStart() -> Int32 {
  let fileManager = FileManager.default
  let home = fileManager.homeDirectoryForCurrentUser
  let logsDir = home.appendingPathComponent("Library/Logs/NanoDictate")

  do {
    try fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
  } catch {
    eprint(String(format: L10n.tr("cli.dir.error"), "\(error)"))
    return 1
  }

  let agentBinary = findAgentBinaryPath()
  guard !agentBinary.isEmpty else {
    eprint(L10n.tr("cli.agent.notfound"))
    return 1
  }
  let logPath = logsDir.appendingPathComponent("agent.log").path

  // Full takeover: the previous plist is re-read, the old process is
  // unloaded (tolerant to "no such service"), the canonical plist is
  // overwritten and the service is loaded again. A repeated start of an
  // already running agent correctly changes owner/path (launchd keeps the
  // plan from the plist as of bootstrap time).
  let installer = AgentInstaller(launchctl: Launchctl(run: runProcess))
  let result = installer.install(agentBinary: agentBinary, logPath: logPath)

  if let writeError = result.writeError {
    eprint(String(format: L10n.tr("cli.plist.writeerror"), writeError))
    return 1
  }
  if result.binaryPathChanged {
    print(L10n.tr("cli.agent.tccRehint"))
  }
  if result.registered {
    print("NanoDictate agent started")
    return 0
  }
  let msg1 = result.bootstrapError
  let msg2 = result.loadError
  eprint(
    msg1.isEmpty
      ? L10n.tr("cli.bootstrap.nodata") : String(format: L10n.tr("cli.bootstrap.fail"), msg1))
  eprint(msg2.isEmpty ? L10n.tr("cli.load.nodata") : String(format: L10n.tr("cli.load.fail"), msg2))
  return 1
}

func cmdStop() -> Int32 {
  let target = "\(guiDomain)/\(agentServiceName)"
  let bootout = runProcess("/bin/launchctl", ["bootout", target])
  if bootout.status == 0 {
    print("NanoDictate agent stopped")
    return 0
  }
  let unload = runProcess("/bin/launchctl", ["unload", target])
  if unload.status == 0 {
    print("NanoDictate agent stopped")
    return 0
  }
  let msg1 = bootout.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
  let msg2 = unload.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
  eprint(
    msg1.isEmpty ? L10n.tr("cli.bootout.nodata") : String(format: L10n.tr("cli.bootout.fail"), msg1)
  )
  eprint(
    msg2.isEmpty ? L10n.tr("cli.unload.nodata") : String(format: L10n.tr("cli.unload.fail"), msg2))
  return 1
}

func cmdStatus() -> Int32 {
  let printResult = runProcess("/bin/launchctl", ["print", "\(guiDomain)/\(agentServiceName)"])
  let running = printResult.status == 0
  print(running ? "running" : "not running")

  let pgrep = runProcess("/usr/bin/pgrep", ["-f", "NanoDictateAgent"])
  if pgrep.status == 0 {
    let pids = pgrep.stdout.split(whereSeparator: \.isWhitespace).map(String.init)
    print("pid: \(pids.joined(separator: " "))")
  } else {
    print("pid: none")
  }

  do {
    let providers = try ProviderStore.loadProviders()
    if let active = ProviderStore.activeProvider {
      print("provider: \(active.name)")
    } else if providers.isEmpty {
      print("provider: \(L10n.tr("cli.no.providers"))")
    } else {
      print("provider: \(L10n.tr("cli.no.active"))")
    }
  } catch {
    print("provider: (\(error))")
  }

  if !FileManager.default.fileExists(atPath: AppConfig.defaultPath()) {
    print(L10n.tr("cli.config.hint"))
  }

  return running ? 0 : 1
}

/// Masks secrets in a raw config-file text: api_key / proxy_key — values in
/// quotes are replaced with maskSecret (first 4 + "***" + last 4). Empty
/// values stay empty.
func maskFileSecrets(in content: String) -> String {
  var lines: [String] = []
  for line in content.components(separatedBy: .newlines) {
    let key =
      line.split(separator: "=", maxSplits: 1).first
      .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    if key == "api_key" || key == "proxy_key",
      let eqIndex = line.firstIndex(of: "="),
      let open = line[line.index(after: eqIndex)...].firstIndex(of: "\""),
      let close = line[line.index(after: open)...].firstIndex(of: "\"")
    {  // swiftlint:disable:this opening_brace
      let prefix = String(line[..<open])
      let value = String(line[line.index(after: open)..<close])
      let suffix = String(line[close...])
      let masked = value.isEmpty ? "" : AppConfig.maskSecret(value)
      lines.append("\(prefix)\"\(masked)\"\(suffix)")
    } else {
      lines.append(line)
    }
  }
  return lines.joined(separator: "\n")
}

/// "(empty)" for empty secrets, otherwise — first 4 + "***" + last 4 chars.
func secretDisplay(_ secret: String) -> String {
  secret.isEmpty ? L10n.tr("cli.placeholder.empty") : AppConfig.maskSecret(secret)
}

/// Asks in a TTY whether to overwrite the existing config. In a pipe — false.
func configOverwriteConfirmed(_ path: String) -> Bool {
  guard isTTY(), stdinIsTTY() else { return false }
  eprint(String(format: L10n.tr("cli.config.overwrite"), path))
  let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
  return answer == "y" || answer == "yes"
}

/// Writes the canon (config.example.toml) into the config (creating the
/// directory when needed) with 0600 permissions. Canon unavailable — a clear
/// error.
func writeConfigTemplate(path: String) -> Int32 {
  guard let example = AppConfig.exampleContent() else {
    eprint(L10n.tr("cli.config.example.notfound"))
    return 1
  }
  let fileManager = FileManager.default
  let dir = (path as NSString).deletingLastPathComponent
  do {
    try fileManager.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try Data(example.utf8)
      .write(to: URL(fileURLWithPath: path), options: .atomic)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
  } catch {
    eprint(String(format: L10n.tr("cli.config.writeerror"), path, "\(error)"))
    return 1
  }
  print(String(format: L10n.tr("cli.config.template"), path))
  print(L10n.tr("cli.config.fillserts"))
  return 0
}

/// `config set-key <provider> [key] [--stdin]` — api_key by a pointed
/// edit of the `[providers.<id>]` section. Key not passed: read from stdin
/// (with --stdin or in a pipe), otherwise — keyboard input. Warns when the
/// NANODICTATE_API_KEY env variable is active (it takes priority over the
/// file).
func cmdConfigSetKey(path: String, args: [String]) -> Int32 {
  guard let providerID = args.first else {
    eprint(L10n.tr("cli.setkey.usage"))
    return 1
  }
  let rest = Array(args.dropFirst())
  let useStdin = rest.contains("--stdin")
  // swiftlint:disable:next trailing_closure
  let keyArg = rest.first(where: { !$0.hasPrefix("--") })

  let value: String
  if let keyArg {
    value = keyArg
  } else if useStdin || !stdinIsTTY() {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    value = String(decoding: data, as: UTF8.self)
      .trimmingCharacters(in: .whitespacesAndNewlines)
  } else {
    eprint(String(format: L10n.tr("cli.setkey.prompt"), providerID))
    guard let line = readLine() else {
      eprint(L10n.tr("cli.setkey.cancelled"))
      return 1
    }
    value = line.trimmingCharacters(in: .whitespacesAndNewlines)
  }
  guard !value.isEmpty else {
    eprint(L10n.tr("cli.setkey.empty"))
    return 1
  }
  guard !value.contains("\""), !value.contains("\\"), !value.contains("\n") else {
    eprint(L10n.tr("cli.setkey.invalid"))
    return 1
  }

  if let envKey = ProcessInfo.processInfo.environment["NANODICTATE_API_KEY"], !envKey.isEmpty {
    eprint(L10n.tr("cli.setkey.envwarn"))
    eprint(L10n.tr("cli.setkey.envnote"))
  }

  do {
    // writeProviderKeyValue expects a value in config-string format (with
    // quotes), like writeKeyValue for strings (cf. writeActiveProvider).
    try AppConfig.writeProviderKeyValue(
      providerID: providerID, key: "api_key", value: "\"\(value)\"", to: path)
  } catch {
    eprint(String(format: L10n.tr("cli.config.writeerror"), providerID, "\(error)"))
    return 1
  }
  print(String(format: L10n.tr("cli.setkey.updated"), providerID, path))
  return 0
}

/// Is stdin a terminal (for entering a key from the keyboard vs a pipe).
func stdinIsTTY() -> Bool {
  isatty(STDIN_FILENO) == 1
}

func cmdConfig(_ args: [String]) -> Int32 {
  let path = AppConfig.defaultPath()
  let fileManager = FileManager.default
  var exists = fileManager.fileExists(atPath: path)

  // `config path` — an alias of `config --path`.
  if args.first?.lowercased() == "path" || args.contains("--path") {
    print(path)
    return 0
  }

  // `config init [--force]` — create the template (does not overwrite
  // without confirmation).
  if args.first?.lowercased() == "init" {
    guard !exists || args.contains("--force") || configOverwriteConfirmed(path) else {
      eprint(String(format: L10n.tr("cli.config.exists"), path))
      eprint(L10n.tr("cli.config.forcehint"))
      return 1
    }
    return writeConfigTemplate(path: path)
  }

  // `config set-key <provider> [key]` — a pointed api_key edit in a section.
  if args.first?.lowercased() == "set-key" {
    return cmdConfigSetKey(path: path, args: Array(args.dropFirst()))
  }

  do {
    let config = try AppConfig.load(from: nil)
    // load() on a fresh machine creates the file itself (auto-copy of the
    // canon) — exists, computed above BEFORE load, is stale; re-read it for
    // the --show-file branch and the info output, otherwise we would print
    // "Config not found" with the file already created, and --show-file
    // would show the error text instead of the content.
    exists = fileManager.fileExists(atPath: path)

    if args.contains("--show-file") {
      if exists {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
          eprint(String(format: L10n.tr("cli.config.noread"), path))
          return 1
        }
        print(maskFileSecrets(in: content))
      } else {
        print(String(format: L10n.tr("cli.config.missing"), path))
      }
      return 0
    }

    print("path: \(path)")
    if !exists {
      print(String(format: L10n.tr("cli.config.missing"), path))
    }
    print("active_provider: \(ProviderStore.activeProvider?.id ?? L10n.tr("cli.config.noset"))")
    print("base_url: \(config.baseURL)")
    print("model: \(config.model)")
    print("timeout_seconds: \(config.timeoutSeconds)")
    print("sounds_enabled: \(config.soundsEnabled)")
    print("double_alt_max_interval: \(config.doubleAltMaxInterval)")
    print("log_level: \(config.logLevel)")
    print("language: \(config.language)")
    print("api_key: \(secretDisplay(config.apiKey))")
    print("proxy_key: \(secretDisplay(config.proxyKey))")
    return 0
  } catch {
    eprint(String(format: L10n.tr("cli.flag.configload"), "\(error)"))
    return 1
  }
}

// MARK: - Providers (несколько STT-провайдеров)

func providerList() -> Int32 {
  do {
    let (activeID, providers) = try AppConfig.loadProvidersOnly(from: nil)
    guard !providers.isEmpty else {
      print(L10n.tr("cli.provider.nosections"))
      return 0
    }
    for provider in providers {
      let marker = provider.id == activeID ? "*" : " "
      let display = provider.name.isEmpty ? provider.id : provider.name
      print("\(marker) \(display) [\(provider.id)]")
      print("    base_url: \(provider.baseURL)")
      print("    model: \(provider.model)")
      print("    api_key: \(secretDisplay(provider.apiKey))")
      if let keyFile = provider.apiKeyFile {
        print("    api_key_file: \(keyFile)")
      }
      print("    proxy_key: \(secretDisplay(provider.proxyKey))")
    }
    print(L10n.tr("cli.provider.activeMarker"))
    return 0
  } catch {
    eprint(String(format: L10n.tr("cli.flag.configload"), "\(error)"))
    return 1
  }
}

func providerUse(_ name: String, _ args: [String]) -> Int32 {
  do {
    try ProviderStore.setActive(providerID: name)
  } catch let ProviderStoreError.unknownProvider(providerID: id, available: available) {
    eprint(String(format: L10n.tr("cli.provider.notfound"), id, available.joined(separator: ", ")))
    return 2
  } catch {
    eprint(String(format: L10n.tr("cli.flag.configload"), "\(error)"))
    return 1
  }
  print(String(format: L10n.tr("cli.provider.active"), name))
  return restartAgentIfNeeded(args)
}

/// Agent restart (--no-restart skips it). Common for config-changing
  /// commands: provider use and routing set/unset. The canonical plist is
  /// overwritten (the path does not go stale after a manager update), then
  /// kickstart -k; if the service is not loaded — a full install
/// (bootout → bootstrap).
func restartAgentIfNeeded(_ args: [String]) -> Int32 {
  if args.contains("--no-restart") {
    print(L10n.tr("cli.provider.norestart"))
    return 0
  }
  let agentBinary = findAgentBinaryPath()
  guard !agentBinary.isEmpty else {
    eprint(L10n.tr("cli.agent.notfound"))
    return 1
  }
  let logPath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/NanoDictate/agent.log").path
  let installer = AgentInstaller(launchctl: Launchctl(run: runProcess))
  let result = installer.restart(agentBinary: agentBinary, logPath: logPath)

  if let writeError = result.writeError {
    eprint(String(format: L10n.tr("cli.plist.writeerror"), writeError))
    return 1
  }
  if result.binaryPathChanged {
    print(L10n.tr("cli.agent.tccRehint"))
  }
  if result.registered {
    print(L10n.tr("cli.provider.restart"))
    return 0
  }
  let msg = result.kickError.isEmpty ? result.bootstrapError : result.kickError
  eprint(String(format: L10n.tr("cli.provider.kickfail"), msg.isEmpty ? result.loadError : msg))
  return 0
}

func providerStatus() -> Int32 {
  let printResult = runProcess("/bin/launchctl", ["print", "\(guiDomain)/\(agentServiceName)"])
  let running = printResult.status == 0
  do {
    let providers = try ProviderStore.loadProviders()
    if let active = ProviderStore.activeProvider {
      print("active: \(active.name) [\(active.id)]")
      print("model: \(active.model)")
      print("base_url: \(active.baseURL)")
    } else if providers.isEmpty {
      print("active: \(L10n.tr("cli.no.providers"))")
    } else {
      print("active: \(L10n.tr("cli.no.active"))")
    }
  } catch {
    eprint(String(format: L10n.tr("cli.flag.configload"), "\(error)"))
    return 1
  }
  print(running ? "agent: running" : "agent: not running")
  return running ? 0 : 1
}

func providerShow(_ name: String) -> Int32 {
  do {
    let (activeID, providers) = try AppConfig.loadProvidersOnly(from: nil)
    guard let provider = providers.first(where: { $0.id == name }) else {
      let available = providers.map(\.id)
      eprint(
        String(format: L10n.tr("cli.provider.notfound"), name, available.joined(separator: ", ")))
      return 2
    }
    print("id: \(provider.id)")
    print("name: \(provider.name.isEmpty ? provider.id : provider.name)")
    print("active: \(provider.id == activeID)")
    print("base_url: \(provider.baseURL)")
    print("model: \(provider.model)")
    if provider.apiKey.isEmpty {
      print("api_key: \(L10n.tr("cli.config.noset"))")
      print(L10n.tr("cli.config.secretWarning"))
    } else {
      print("api_key: \(secretDisplay(provider.apiKey))")
    }
    if let keyFile = provider.apiKeyFile {
      let expanded = (keyFile as NSString).expandingTildeInPath
      print("api_key_file: \(keyFile)")
      if !FileManager.default.fileExists(atPath: expanded) {
        print(String(format: L10n.tr("cli.config.secretFileMissing"), expanded))
      }
    }
    if provider.proxyKey.isEmpty {
      print("proxy_key: \(L10n.tr("cli.config.noset"))")
    } else {
      print("proxy_key: \(secretDisplay(provider.proxyKey))")
    }
    return 0
  } catch {
    eprint(String(format: L10n.tr("cli.flag.configload"), "\(error)"))
    return 1
  }
}

func cmdProvider(_ args: [String]) -> Int32 {
  switch args.first?.lowercased() {
  case "list":
    return providerList()
  case "use", "set":
    let rest = Array(args.dropFirst())
    // --no-restart is not positional: recognized anywhere (incl. before the
    // name — otherwise it would go into validation as an invalid id).
    guard let name = rest.first(where: { $0 != "--no-restart" }) else {
      eprint(L10n.tr("usage.provider.use"))
      return 1
    }
    return providerUse(name, rest)
  case "status":
    return providerStatus()
  case "show":
    guard let name = args.dropFirst().first else {
      eprint(L10n.tr("usage.provider.show"))
      return 1
    }
    return providerShow(name)
  default:
    eprint(L10n.tr("usage.provider"))
    return 1
  }
}

// MARK: - STT routing by roles ([routing])

  /// `nanodictate routing [show]`: roles from the [routing] section and
/// their effective values (fallback to the active provider on an
/// empty/unknown role). Tolerant parsing like provider list — the display
/// works even with a stale active_provider.
func routingShow() -> Int32 {
  let path = AppConfig.defaultPath()
  guard FileManager.default.fileExists(atPath: path) else {
    print(String(format: L10n.tr("cli.config.missing"), path))
    return 0
  }
  let (activeID, providers) = (try? AppConfig.loadProvidersOnly(from: nil)) ?? ("", [])
  // routing is parsed only in the full parse (a coarse fallback to the
  // defaults with a broken active_provider — fixed by the provider use
  // command).
  let config = (try? AppConfig.load(from: nil)) ?? AppConfig.defaults
  let ids = providers.map(\.id)
  let seg = config.routing.segmentProvider
  let fin = config.routing.finalProvider
  let activeDisplay = activeID.isEmpty ? L10n.tr("cli.config.unset") : activeID
  func effective(_ role: String) -> String {
    !role.isEmpty && ids.contains(role)
      ? role
      : (activeID.isEmpty
        ? L10n.tr("cli.config.unset") : "\(activeID) \(L10n.tr("cli.config.active"))")
  }
  print("active_provider: \(activeDisplay)")
  print("segment_provider: \(seg.isEmpty ? L10n.tr("cli.config.unset") : seg)")
  print("final_provider: \(fin.isEmpty ? L10n.tr("cli.config.unset") : fin)")
  print("segment (effective): \(effective(seg))")
  print("final (effective): \(effective(fin))")
  return 0
}

/// Role key in the config ([routing]); nil — unknown role.
func routingKey(for role: String) -> String? {
  switch role {
  case "segment": return "segment_provider"
  case "final": return "final_provider"
  default: return nil
  }
}

/// `nanodictate routing set segment|final <id> [--no-restart]`: point edit
/// of a role key in [routing]. Id validation against [providers.X] sections
/// like provider use; atomic write + chmod 600; agent restart (unless
/// --no-restart). The role takes effect on agent restart.
func routingSet(role: String, providerID: String, args: [String]) -> Int32 {
  guard let key = routingKey(for: role) else {
    eprint(L10n.tr("cli.routing.usage"))
    return 1
  }
  do {
    let (_, providers) = try AppConfig.loadProvidersOnly(from: nil)
    guard providers.contains(where: { $0.id == providerID }) else {
      let available = providers.map(\.id)
      eprint(
        String(
          format: L10n.tr("cli.routing.noexist"), providerID, available.joined(separator: ", ")))
      eprint(L10n.tr("cli.routing.listHint"))
      return 2
    }
    try AppConfig.writeRoutingKeyValue(
      key: key, value: "\"\(providerID)\"", to: AppConfig.defaultPath())
  } catch {
    eprint(String(format: L10n.tr("cli.flag.configload"), "\(error)"))
    return 1
  }
  print(String(format: L10n.tr("cli.routing.role"), role, providerID))
  return restartAgentIfNeeded(args)
}

/// `nanodictate routing unset segment|final [--no-restart]`: clear a role
/// (an empty value is written — the resolver falls back to the active
/// provider).
func routingUnset(role: String, args: [String]) -> Int32 {
  guard let key = routingKey(for: role) else {
    eprint(L10n.tr("cli.routing.unset.usage"))
    return 1
  }
  do {
    try AppConfig.writeRoutingKeyValue(key: key, value: "\"\"", to: AppConfig.defaultPath())
  } catch {
    eprint(String(format: L10n.tr("cli.flag.configload"), "\(error)"))
    return 1
  }
  print(String(format: L10n.tr("cli.routing.reset"), role))
  return restartAgentIfNeeded(args)
}

func cmdRouting(_ args: [String]) -> Int32 {
  switch args.first?.lowercased() {
  case nil, "show", "status":
    return routingShow()
  case "set":
    let rest = Array(args.dropFirst())
    // --no-restart is not positional: recognized anywhere (incl. before
    // the role/name — otherwise it would go into validation as an invalid id).
    let positional = rest.filter { $0 != "--no-restart" }
    guard let role = positional.first, let providerID = positional.dropFirst().first else {
      eprint(L10n.tr("cli.routing.usage"))
      return 1
    }
    return routingSet(role: role, providerID: providerID, args: rest)
  case "unset":
    let rest = Array(args.dropFirst())
    let positional = rest.filter { $0 != "--no-restart" }
    guard let role = positional.first else {
      eprint(L10n.tr("cli.routing.unset.usage"))
      return 1
    }
    return routingUnset(role: role, args: rest)
  default:
    eprint(L10n.tr("cli.routing.main.usage"))
    return 1
  }
}

// swiftlint:disable:next cyclomatic_complexity function_body_length
func cmdTranscribe(_ args: [String]) -> Int32 {
  // Batch flags (--provider/--out/--max-segment/--overlap/--no-progress/
  // --resume) switch to batch mode; without them — one-shot transcription as before.
  var batch = BatchTranscribeOptions()
  var batchRequested = false
  var file: String?
  var i = 0
  while i < args.count {
    let argument = args[i]
    switch argument {
    case "--provider":
      guard i + 1 < args.count else {
        eprint(L10n.tr("cli.flag.provider"))
        return 1
      }
      batch.providerID = args[i + 1]
      i += 2
      batchRequested = true
    case "--out":
      guard i + 1 < args.count else {
        eprint(L10n.tr("cli.flag.out"))
        return 1
      }
      batch.outPath = args[i + 1]
      i += 2
      batchRequested = true
    case "--max-segment":
      guard i + 1 < args.count, let value = Double(args[i + 1]), value > 0 else {
        eprint(L10n.tr("cli.flag.maxsegment"))
        return 1
      }
      batch.maxSegment = value
      i += 2
      batchRequested = true
    case "--overlap":
      guard i + 1 < args.count, let value = Double(args[i + 1]), value >= 0 else {
        eprint(L10n.tr("cli.flag.overlap"))
        return 1
      }
      batch.overlap = value
      i += 2
      batchRequested = true
    case "--no-progress":
      batch.showProgress = false
      i += 1
      batchRequested = true
    case "--cut-at-pauses":
      batch.cutAtPauses = true
      i += 1
      batchRequested = true
    case "--no-cut-at-pauses":
      batch.cutAtPauses = false
      i += 1
      batchRequested = true
    case "--resume":
      batch.resume = true
      i += 1
      batchRequested = true
    case "--parallel":
      guard i + 1 < args.count, let value = Int(args[i + 1]), value >= 1 else {
        eprint(L10n.tr("cli.flag.parallel"))
        return 1
      }
      batch.maxConcurrent = value
      i += 2
      batchRequested = true
    case "--json":
      batch.json = true
      i += 1
    case "--help", "-h":
      eprint(usageTranscribeBatch)
      return 0
    default:
      if argument.hasPrefix("-") {
        eprint(String(format: L10n.tr("cli.flag.unknown"), argument))
        eprint(usageTranscribeBatch)
        return 1
      }
      guard file == nil else {
        eprint(String(format: L10n.tr("cli.flag.extra"), argument))
        return 1
      }
      file = argument
      i += 1
    }
  }
  guard let file else {
    eprint(L10n.tr("cli.transcribe.nofile"))
    eprint(usageTranscribeBatch)
    return 1
  }
  if !batchRequested {
    return cmdTranscribeLegacy(file, json: batch.json)
  }
  return cmdTranscribeBatch(file, options: batch)
}

struct BatchTranscribeOptions {
  var providerID = "gigaam"
  var outPath: String?
  var maxSegment: TimeInterval = 30
  var overlap: TimeInterval = 2.5
  var maxConcurrent = 1
  var showProgress = true
  // ON by default: split at speech pauses ≥ 0.3 s (per the "Long speech
  // practice" guide). --no-cut-at-pauses reverts to fixed-length chunks
  // (for compatibility with old-run checkpoints).
  var cutAtPauses = true
  var resume = false
  var json = false
}

// swiftlint:disable indentation_width
let usageTranscribeBatch = """
    \(L10n.tr("usage.transcribe"))
    \(L10n.tr("usage.batch"))
      \(L10n.tr("usage.batch.desc"))
  """
// swiftlint:enable indentation_width

func formatClock(_ seconds: TimeInterval) -> String {
  let totalSeconds = max(0, Int(seconds.rounded()))
  return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
}

/// Stable string stamp (djb2 over UTF-8 bytes) for a checkpoint key.
/// `String.hashValue` is not suitable: randomized across processes.
func stableCheckpointStamp(_ string: String) -> String {
  var hash: UInt64 = 5381
  for byte in string.utf8 {
    hash = (hash &* 33) &+ UInt64(byte)
  }
  return String(hash, radix: 16)
}

/// One batch-mode progress line on stderr, rewritten with \r
/// (no \n until done). One shared instance per run — atomic redraws
/// under NSLock. Format:
///   [12/84] ████████████░░░░░░░░░░ 33% · ~4 min left · avg 7.2s/chunk
/// finish() emits a newline (before the summary/errors); a repeated
/// finish() is a no-op. When disabled (--no-progress) it writes nothing.
final class BatchProgressBar {
  private let lock = NSLock()
  private let enabled: Bool
  private let width: Int
  private var finished = false

  init(enabled: Bool, width: Int = 24) {
    self.enabled = enabled
    self.width = width
  }

  /// Redraw the line. `completed` — count of finished chunks (N of [N/M]),
  /// `elapsed` — seconds since the run start.
  func update(completed: Int, total: Int, elapsed: TimeInterval) {
    lock.lock()
    defer { lock.unlock() }
    guard enabled, !finished else { return }
    let pct = total <= 0 ? 1.0 : min(1.0, max(0, Double(completed) / Double(total)))
    let filled = Int((pct * Double(width)).rounded())
    let bar = String(repeating: "█", count: filled) + String(repeating: "░", count: width - filled)
    let avg = completed > 0 ? elapsed / Double(completed) : 0
    let eta = avg * Double(max(0, total - completed))
    let percent = Int((pct * 100).rounded())
    let line = String(
      format: "\u{1B}[2K\r[%d/%d] %@ %3d%% · %@ · " + L10n.tr("progress.avgPerChunk"),
      completed,
      total,
      bar,
      percent,
      BatchProgressBar.etaText(eta),
      avg
    )
    FileHandle.standardError.write(Data(line.utf8))
  }

  /// Close the line with a newline (before the summary/error). Idempotent.
  func finish() {
    lock.lock()
    defer { lock.unlock() }
    guard enabled, !finished else { return }
    finished = true
    FileHandle.standardError.write(Data("\u{1B}[2K\r\n".utf8))
  }

  /// "~45 sec" / "~4 min" / "~1 h 12 min" (rounded up — we do not promise
  /// extra time).
  private static func etaText(_ seconds: TimeInterval) -> String {
    let totalSeconds = Int(seconds.rounded(.up))
    if totalSeconds < 60 {
      return String(format: L10n.tr("progress.eta.sec"), totalSeconds)
    }
    let minutes = totalSeconds / 60
    if minutes < 60 {
      return String(format: L10n.tr("progress.eta.min"), minutes)
    }
    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    if remainingMinutes == 0 {
      return String(format: L10n.tr("progress.eta.hour"), hours)
    }
    return String(format: L10n.tr("progress.eta.hm"), hours, remainingMinutes)
  }
}

// swiftlint:disable:next cyclomatic_complexity function_body_length
func cmdTranscribeBatch(_ file: String, options: BatchTranscribeOptions) -> Int32 {
  let fileManager = FileManager.default

  // 1. Config and provider (all from config.toml, nothing hardcoded).
  let config: AppConfig
  do { config = try AppConfig.load(from: nil) } catch {
    eprint(String(format: L10n.tr("cli.flag.configload"), "\(error)"))
    return 1
  }
  // swiftlint:disable:next trailing_closure
  var provider = config.providers.first(where: { $0.id == options.providerID })
  if provider == nil, options.providerID == "gigaam" {
    // Canon (config.example.toml) has no gigaam section — airubiz is
    // active there: fall back to the active provider, else the first
    // available, so batch mode works out-of-the-box without a flag edit.
    let active: AppConfig.Provider? = (try? ProviderStore.loadProviders())
      .flatMap { list in
        // swiftlint:disable:next trailing_closure
        list.first(where: { $0.isActive }).flatMap { active in
          // swiftlint:disable:next trailing_closure
          config.providers.first(where: { $0.id == active.id })
        }
      }
    let fallback = active ?? config.providers.first
    if let fallback {
      eprint(String(format: L10n.tr("cli.transcribe.warn"), fallback.id))
      provider = fallback
    }
  }
  guard let provider else {
    let available = config.providers.map(\.id).joined(separator: ", ")
    eprint(String(format: L10n.tr("cli.transcribe.noprovider"), options.providerID, available))
    return 1
  }
  guard !provider.baseURL.isEmpty else {
    eprint(String(format: L10n.tr("cli.transcribe.nourl"), provider.id))
    return 1
  }

  // 2. Convert to 16 kHz mono PCM16 WAV, STREAMING without loading into RAM.
  // Try to open the input directly (on-demand read windows from the file):
  // if not PCM16 WAV or not 16 kHz mono — afconvert to a temp file
  // (the temp lives until the run ends — run(fileURL:) reads windows from it).
  let inputURL = URL(fileURLWithPath: file)
  var wavURL = inputURL
  var tempWavURL: URL?
  var wavSampleCount = 0
  var wavSampleRate = 0
  do {
    let probe = try WAVFilePCMBatchContent(wavURL: wavURL)
    guard probe.sampleRate == 16000, probe.channels == 1 else {
      throw WAVFilePCMBatchContent.WAVFileError.invalidWAV
    }
    // The probe is needed ONLY for the summary (sampleCount/sampleRate):
    // take the values and release the object — its FileHandle closes in
    // deinit, and run(fileURL:) reopens the file with its own read windows.
    wavSampleCount = probe.sampleCount
    wavSampleRate = probe.sampleRate
  } catch {
    // Why the probe failed:
    // fileNotFound/ioError — the file is physically unavailable, afconvert
    // conversion will not help — show the original error and exit.
    if let probeError = error as? WAVFilePCMBatchContent.WAVFileError,
      case .fileNotFound = probeError
    {  // swiftlint:disable:this opening_brace
      eprint(String(format: L10n.tr("cli.transcribe.filenotfound"), file))
      return 1
    }
    if let probeError = error as? WAVFilePCMBatchContent.WAVFileError,
      case let .ioError(message) = probeError
    {  // swiftlint:disable:this opening_brace
      eprint(String(format: L10n.tr("cli.transcribe.readerror"), file, message))
      return 1
    }
    // invalidWAV (not PCM16 WAV / not 16 kHz mono) — regular case:
    // afconvert to a temp file (the temp lives until the run ends —
    // run(fileURL:) reads windows from it).
    let converted = fileManager.temporaryDirectory.appendingPathComponent(
      "nanodictate-batch-\(UUID().uuidString).wav")
    let conv = runProcess(
      "/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", file, converted.path])
    guard conv.status == 0 else {
      let msg = conv.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      eprint(
        String(format: L10n.tr("cli.transcribe.waverror"), file, msg.isEmpty ? conv.stdout : msg))
      return 1
    }
    tempWavURL = converted
    wavURL = converted
    guard let content = try? WAVFilePCMBatchContent(wavURL: converted) else {
      eprint(String(format: L10n.tr("cli.transcribe.converror"), converted.path))
      try? fileManager.removeItem(at: converted)
      return 1
    }
    wavSampleCount = content.sampleCount
    wavSampleRate = content.sampleRate
  }

  // Immutable copies for capture in the Task (var cannot be captured in an
  // @Sendable closure): after this block neither wavURL, tempWavURL,
  // nor the summary counters change.
  let batchWavURL = wavURL
  let tempWavForCleanup = tempWavURL
  let batchSampleCount = wavSampleCount
  let batchSampleRate = wavSampleRate

  // 3. Checkpoint: next to --out, else a stable path in the temp folder.
  // The temp checkpoint key includes the STAMP OF THE FULL FILE PATH
  // (different files with the same name do not collide) + the provider +
  // maxSegment + overlap (chunking depends on both).
  let checkpointPath: String
  if let out = options.outPath {
    checkpointPath = out + ".checkpoint.json"
  } else {
    // Chunking depends on the chunking parameters; pause alignment
    // (--cut-at-pauses, ON by default) sets different boundaries —
    // the "-pause" suffix in the checkpoint key. Old checkpoints without
    // the suffix (fixed chunking, before pause alignment landed) are
    // inherently incompatible and correctly ignored by resume.
    let pauseFactor = options.cutAtPauses ? "-pause" : ""
    let checkpointName =
      "nanodictate-batch-\(stableCheckpointStamp(inputURL.path))-\(provider.id)-"
      + "\(Int(options.maxSegment))-\(Int(options.overlap))\(pauseFactor).checkpoint.json"
    checkpointPath = fileManager.temporaryDirectory.appendingPathComponent(checkpointName).path
  }
  if options.resume, !fileManager.fileExists(atPath: checkpointPath) {
    eprint(String(format: L10n.tr("progress.noresume"), checkpointPath))
  }
  let sourcePath = inputURL.path
  if options.resume, fileManager.fileExists(atPath: checkpointPath) {
    if let checkpoint = try? BatchTranscriber.loadCheckpoint(from: checkpointPath) {
      if checkpoint.sourceFile != sourcePath {
        eprint(
          String(format: L10n.tr("progress.badcheckpoint"), checkpointPath, checkpoint.sourceFile))
      }
    }
  }

  // 4. Real chunk transport: request by provider fields + Retry-After.
  // The env key is scoped to the ACTIVE provider (the same active-id
  // convention as in NanoDictateAgent: empty active_provider → first in
  // order): an explicit --provider with its own key gets its key, without
  // a key — empty (the request fails normally), the env key does not leak
  // to foreign sections.
  let transport = URLSessionBatchTransport()
  let activeAdapterID: String? =
    config.activeProvider.isEmpty
    ? config.providers.first?.id
    : config.activeProvider
  let apiKey = RetryProvider.resolveAPIKey(for: provider, activeProviderID: activeAdapterID)
  let language = config.language
  let sendOne: BatchTranscriber.SendOne = { _, wav, chunkIndex, prompt in
    guard
      let prepared = BatchRequestBuilder.makeRequest(
        provider: provider,
        apiKey: apiKey,
        language: language,
        timeout: config.timeoutSeconds,
        wav: wav,
        chunkIndex: chunkIndex,
        batchParams: BatchSTTParams(prompt: prompt),
        proxyKey: provider.proxyKey,
        proxyKeyHeader: provider.proxyKeyHeader.isEmpty
          ? config.proxyKeyHeader : provider.proxyKeyHeader
      )
    else {
      throw BatchHTTPError.invalidResponse(
        String(format: L10n.tr("cli.batch.badBaseUrl"), provider.id))
    }
    let response: BatchHTTPResponse
    do {
      response = try await transport.send(request: prepared.request)
    } catch {
      throw BatchHTTPError.network(error.localizedDescription)
    }
    guard (200...299).contains(response.status) else {
      let snippet = String(decoding: response.body, as: UTF8.self)
      throw BatchHTTPError.http(
        response.status,
        message: String(snippet.prefix(300)),
        retryAfter: response.retryAfterSeconds
      )
    }
    do {
      return try ProviderRequestBuilder.extractText(
        from: response.body, path: prepared.transcriptPath
      )
      .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
      throw BatchHTTPError.invalidResponse(
        String(format: L10n.tr("cli.batch.parseError"), "\(error)"))
    }
  }

  // 4b. One shared progress bar per run (atomic redraws).
  let progressBar = BatchProgressBar(enabled: options.showProgress)

  Task {
    defer { progressBar.finish() }  // newline on any outcome
    do {
      let outcome = try await BatchTranscriber.run(
        fileURL: batchWavURL,
        maxSegment: options.maxSegment,
        overlap: options.overlap,
        providerID: provider.id,
        sourceFile: sourcePath,
        checkpointPath: checkpointPath,
        resume: options.resume,
        sendOne: sendOne,
        delay: { seconds in
          if seconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
          }
        },
        maxConcurrent: options.maxConcurrent,
        cutAtPauses: options.cutAtPauses,
        // swiftlint:disable:next trailing_closure
        onProgress: { completedChunks, totalChunks, _, _, elapsed, _ in
          progressBar.update(completed: completedChunks, total: totalChunks, elapsed: elapsed)
        }
      )

      // 5. Text: to --out (atomically) or to stdout. To a file — with a
      // trailing newline (empty text — empty file, no bare \n).
      if let out = options.outPath {
        do {
          let content = outcome.text.isEmpty ? outcome.text : outcome.text + "\n"
          try content.write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
        } catch {
          eprint(String(format: L10n.tr("cli.transcribe.writeError"), out, "\(error)"))
          if let tempWav = tempWavForCleanup {
            try? FileManager.default.removeItem(at: tempWav)
          }
          exit(1)
        }
      } else {
        print(outcome.text)
      }

      if let tempWav = tempWavForCleanup {
        try? FileManager.default.removeItem(at: tempWav)
      }  // read windows done

      // 6. Summary to stderr.
      let duration = Double(batchSampleCount) / Double(batchSampleRate)
      var summary = String(
        format: L10n.tr("progress.summary"),
        formatClock(duration),
        outcome.totalSegments,
        outcome.okCount,
        outcome.skippedCount,
        Int(outcome.elapsed)
      )
      if !outcome.skippedIndexes.isEmpty {
        summary += String(
          format: L10n.tr("progress.skipped"),
          outcome.skippedIndexes.map(String.init).joined(separator: ", "))
      }
      eprint(summary)
      eprint(String(format: L10n.tr("progress.checkpoint"), checkpointPath))

      // 7. --json: as in one-shot mode — transcription_raw.json next to the FILE
      // (in batch mode this is a copy of the checkpoint with chunk texts).
      if options.json {
        let rawURL = inputURL.deletingLastPathComponent().appendingPathComponent(
          "transcription_raw.json")
        do {
          try Data(contentsOf: URL(fileURLWithPath: checkpointPath)).write(
            to: rawURL, options: .atomic)
          eprint(String(format: L10n.tr("progress.jsonsaved"), rawURL.path))
        } catch {
          eprint(String(format: L10n.tr("progress.jsonfail"), rawURL.path, "\(error)"))
        }
      }
      exit(0)
    } catch {
      eprint(String(format: L10n.tr("cli.error.generic"), "\(error)"))
      exit(1)
    }
  }

  // Keep the main thread alive until the async batch finishes (it exits above).
  RunLoop.main.run()
  return 1  // unreachable
}

// swiftlint:disable:next function_body_length
func cmdTranscribeLegacy(_ file: String, json: Bool) -> Int32 {
  let fileManager = FileManager.default
  let inputURL = URL(fileURLWithPath: file)

  var wavURL = inputURL
  var tempWavURL: URL?
  if inputURL.pathExtension.lowercased() != "wav" {
    let converted = fileManager.temporaryDirectory.appendingPathComponent(
      "nanodictate-\(UUID().uuidString).wav")
    let conv = runProcess(
      "/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", file, converted.path])
    guard conv.status == 0 else {
      let msg = conv.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
      eprint(
        String(format: L10n.tr("cli.transcribe.waverror"), file, msg.isEmpty ? conv.stdout : msg))
      return 1
    }
    tempWavURL = converted
    wavURL = converted
  }

  let data: Data
  do {
    data = try Data(contentsOf: wavURL)
  } catch {
    eprint(String(format: L10n.tr("cli.transcribe.readerror"), wavURL.path, "\(error)"))
    if let tempWav = tempWavURL {
      try? fileManager.removeItem(at: tempWav)
    }
    return 1
  }
  // WAV data is loaded; the converted temp file is no longer needed.
  if let tempWav = tempWavURL {
    try? fileManager.removeItem(at: tempWav)
  }

  let config: AppConfig
  do {
    config = try AppConfig.load(from: nil)
  } catch {
    eprint(String(format: L10n.tr("cli.flag.configload"), "\(error)"))
    return 1
  }

  // Active provider = request adapter (as in NanoDictateAgent): on an empty
  // active_provider — the first provider in order, else its id.
  let activeAdapterID: String? =
    config.activeProvider.isEmpty
    ? config.providers.first?.id
    : config.activeProvider
  let transcriber = Transcriber(
    baseURL: config.baseURL,
    model: config.model,
    apiKey: config.apiKey,
    proxyKey: config.proxyKey,
    proxyKeyHeader: config.proxyKeyHeader,
    language: config.language,
    timeout: config.timeoutSeconds,
    logLevel: config.logLevel,
    cookieRelayProvider: config.transport == "cookie-relay"
      ? CookieRelayProvider.makeForCookieRelay(baseURL: config.baseURL)
      : nil,
    httpProxy: config.httpProxy,
    proxyUser: config.proxyUser,
    proxyPassword: config.proxyPassword,
    adapterID: activeAdapterID
  )
  // Data is always WAV (non-WAV is converted above); the server is strict
  // about the extension, so the multipart file field always sends
  // "audio.wav", not the original name.
  let filename = "audio.wav"
  let rawURL = inputURL.deletingLastPathComponent().appendingPathComponent("transcription_raw.json")

  Task {
    do {
      let result = try await transcriber.transcribe(wav: data, filename: filename)
      print(result.text)
      if json {
        do {
          try result.rawData.write(to: rawURL, options: .atomic)
          print(String(format: L10n.tr("progress.jsonsaved"), rawURL.path))
        } catch {
          eprint(String(format: L10n.tr("progress.jsonfail"), rawURL.path, "\(error)"))
        }
      }
      exit(0)
    } catch {
      eprint(String(format: L10n.tr("cli.error.generic"), "\(error)"))
      exit(1)
    }
  }

  // Keep the main thread alive until the async transcribe finishes (it exits above).
  RunLoop.main.run()
  return 1  // unreachable
}

func cmdLogs() -> Int32 {
  let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/NanoDictate/agent.log")
  guard let content = try? String(contentsOf: logURL, encoding: .utf8) else {
    print(L10n.tr("cli.logs.notfound"))
    return 1
  }
  let body = content.components(separatedBy: .newlines).suffix(50).joined(separator: "\n")
  if !body.isEmpty {
    print(body)
  }
  return 0
}

// MARK: - Last text and retry with another provider

/// `nanodictate last`: the last recognized text from the LAST_TEXT marker in
/// the agent log (written on every successful insert, retry included).
func cmdLast() -> Int32 {
  let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/NanoDictate/agent.log")
  guard let content = try? String(contentsOf: logURL, encoding: .utf8) else {
    print(L10n.tr("cli.last.notfound"))
    return 1
  }
  let marker = "LAST_TEXT: "
  let matches = content.components(separatedBy: .newlines)
    .compactMap { line -> String? in
      guard let range = line.range(of: marker) else { return nil }
      return String(line[range.upperBound...])
    }
  guard let last = matches.last, !last.isEmpty else {
    print(L10n.tr("cli.last.notext"))
    return 1
  }
  print(last)
  return 0
}

/// `nanodictate retry <provider>`: asks the agent to re-recognize the last
/// WAV (it lives in the agent's memory) with the given provider. Via
/// DistributedNotificationCenter — the insert is done by the AGENT itself
/// (it already has the Accessibility right and the familiar
/// insert/review path).
func cmdRetry(_ name: String) -> Int32 {
  let providers: [AppConfig.Provider]
  do {
    providers = try AppConfig.loadProvidersOnly(from: nil).providers
  } catch {
    eprint(String(format: L10n.tr("cli.flag.configload"), "\(error)"))
    return 1
  }
  guard let provider = providers.first(where: { $0.id == name }) else {
    let available = providers.map(\.id)
    eprint(
      String(format: L10n.tr("cli.provider.notfound"), name, available.joined(separator: ", ")))
    return 2
  }
  let target = "\(guiDomain)/\(agentServiceName)"
  let running = runProcess("/bin/launchctl", ["print", target]).status == 0
  guard running else {
    eprint(L10n.tr("cli.retry.notrunning"))
    return 1
  }
  DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("com.nanodictate.agent.retryRequest"),
    object: nil,
    userInfo: ["provider": name],
    deliverImmediately: true
  )
  let display = provider.name.isEmpty ? provider.id : provider.name
  print(String(format: L10n.tr("cli.retry.sent"), display, provider.id))
  return 0
}

/// Provider ids in one line (hint for retry usage).
func providerNamesText() -> String {
  let ids = (try? AppConfig.loadProvidersOnly(from: nil).providers.map(\.id)) ?? []
  return ids.isEmpty ? L10n.tr("cli.provider.nosections") : ids.joined(separator: ", ")
}

// MARK: - Usage

let usage = """
  \(L10n.tr("usage.title"))

  \(L10n.tr("usage.cmds"))
    start                            \(L10n.tr("usage.start"))
    stop                             \(L10n.tr("usage.stop"))
    status                           \(L10n.tr("usage.status"))
    config                           \(L10n.tr("usage.config"))
      config init [--force]          \(L10n.tr("usage.config.init"))
      config set-key \(L10n.tr("usage.placeholder.provider")) [\(L10n.tr("usage.placeholder.key"))] [--stdin]
        \(L10n.tr("usage.config.setkey"))
      config path                    \(L10n.tr("usage.config.path"))
      config --show-file             \(L10n.tr("usage.config.showfile"))
    provider list                    \(L10n.tr("usage.provider"))
      provider use \(L10n.tr("usage.placeholder.name")) [--no-restart]
      provider set \(L10n.tr("usage.placeholder.name")) [--no-restart] (\(L10n.tr("usage.placeholder.setAlias")))
        \(L10n.tr("usage.provider.use"))
      provider status                \(L10n.tr("usage.provider.status"))
      provider show \(L10n.tr("usage.placeholder.name"))              \(L10n.tr("usage.provider.show"))
    routing [show]                   \(L10n.tr("usage.routing"))
      routing set \(L10n.tr("usage.placeholder.role")) \(L10n.tr("usage.placeholder.name")) [--no-restart]
        \(L10n.tr("usage.routing.set"))
      routing unset \(L10n.tr("usage.placeholder.role")) [--no-restart]
        \(L10n.tr("usage.routing.unset"))
    transcribe \(L10n.tr("usage.placeholder.file")) [--json]         \(L10n.tr("usage.transcribe"))
    transcribe \(L10n.tr("usage.placeholder.file")) [--json]         \(L10n.tr("usage.batch"))
      [--provider <id>] [--out \(L10n.tr("usage.placeholder.path"))]
        [--max-segment <\(L10n.tr("usage.placeholder.seconds"))>] [--overlap <\(L10n.tr("usage.placeholder.seconds"))>]
      [--no-progress] [--resume]
        \(L10n.tr("usage.batch.desc"))
    retry \(L10n.tr("usage.placeholder.name"))                        \(L10n.tr("usage.retry"))
    last                             \(L10n.tr("usage.last"))
    logs                             \(L10n.tr("usage.logs"))
    help                             \(L10n.tr("usage.help"))
    --version, -v                    print version and exit
  """

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())

/// Localize early: read ui_language from config (if exists) before any output.
let uiLanguage = (try? AppConfig.load(from: nil))?.uiLanguage
L10n.language = uiLanguage == "ru" ? .ru : .en

guard let command = args.first?.lowercased() else {
  // No command in an interactive terminal — a light menu; in a pipe/script — usage.
  if MenuGate.shouldRunMenu(hasCommand: false, tty: isTTY()) {
    exit(runMenu())
  }
  print(usage)
  exit(0)
}

switch command {
case "start":
  exit(cmdStart())
case "stop":
  exit(cmdStop())
case "status":
  exit(cmdStatus())
case "config":
  exit(cmdConfig(Array(args.dropFirst())))
case "provider":
  exit(cmdProvider(Array(args.dropFirst())))
case "routing":
  exit(cmdRouting(Array(args.dropFirst())))
case "transcribe":
  exit(cmdTranscribe(Array(args.dropFirst())))
case "retry":
  guard let name = args.dropFirst().first else {
    eprint(L10n.tr("cli.retry.usage"))
    eprint(String(format: L10n.tr("cli.retry.available"), providerNamesText()))
    exit(1)
  }
  exit(cmdRetry(name))
case "last":
  exit(cmdLast())
case "logs":
  exit(cmdLogs())
case "--version", "-v":
  print("nanodictate \(NanoDictateVersion.string)")
  exit(0)
case "help", "-h", "--help":
  print(usage)
  exit(0)
default:
  eprint(String(format: L10n.tr("cli.cmd.unknown"), command))
  print(usage)
  exit(1)
}
