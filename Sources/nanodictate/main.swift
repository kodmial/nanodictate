import Darwin
import Foundation
import NanoDictateCore

// MARK: - Utils

func eprint(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
}

func runProcess(_ launchPath: String, _ args: [String]) -> (status: Int32, stdout: String, stderr: String) {
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
    let stdout = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return (process.terminationStatus, stdout, stderr)
}

/// User GUI domain for launchctl, e.g. "gui/501".
let guiDomain = "gui/\(getuid())"

/// Имя сервиса LaunchAgent (Label plist, target launchctl print/bootstrap/bootout).
let agentServiceName = "com.nanodictate.agent"

/// Абсолютный путь к бинарю агента (брат CLI-бинаря в .build/debug).
/// Env NANODICTATE_AGENT_BIN позволяет переопределить (например, установленный
/// в /usr/local/bin вариант). Промах тут не фатален — launchctl покажет ошибку.
func findAgentBinaryPath() -> String? {
    if let env = ProcessInfo.processInfo.environment["NANODICTATE_AGENT_BIN"], !env.isEmpty {
        return env
    }
    let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let sibling = exe.deletingLastPathComponent().appendingPathComponent("NanoDictateAgent")
    if FileManager.default.fileExists(atPath: sibling.path) { return sibling.path }
    return exe.path
}

/// Поиск шаблона LaunchAgent-plist (Resources/nanodictate-agent.plist.template):
/// 1) явный env NANODICTATE_PLIST_TEMPLATE; 2) директория Resources рядом с
/// бинарём; 3) исходники проекта (компиляция из дерева); 4) cwd/Resources.
func findPlistTemplate() -> URL? {
    let name = "nanodictate-agent.plist.template"
    if let env = ProcessInfo.processInfo.environment["NANODICTATE_PLIST_TEMPLATE"] {
        let url = URL(fileURLWithPath: env)
        if FileManager.default.fileExists(atPath: url.path) { return url }
    }
    let exeDir = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        .deletingLastPathComponent()
    let fromSourceDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()          // Sources/nanodictate
        .deletingLastPathComponent()          // Sources
        .deletingLastPathComponent()          // project root
        .appendingPathComponent("Resources/\(name)")
    let candidates: [URL] = [
        exeDir.appendingPathComponent("Resources/\(name)"),
        fromSourceDir,
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/\(name)"),
    ]
    for url in candidates where FileManager.default.fileExists(atPath: url.path) {
        return url
    }
    return nil
}

// MARK: - Subcommands

func cmdStart() -> Int32 {
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let launchAgentsDir = home.appendingPathComponent("Library/LaunchAgents")
    let logsDir = home.appendingPathComponent("Library/Logs/NanoDictate")

    do {
        try fm.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
    } catch {
        eprint(String(format: L10n.tr("cli.dir.error"), "\(error)"))
        return 1
    }

    guard let template = findPlistTemplate() else {
        eprint(L10n.tr("cli.plist.notfound"))
        return 1
    }
    guard let binaryPath = findAgentBinaryPath() else {
        eprint(L10n.tr("cli.agent.notfound"))
        return 1
    }
    guard let templateText = try? String(contentsOf: template, encoding: .utf8) else {
        eprint(String(format: L10n.tr("cli.plist.readerror"), template.path))
        return 1
    }
    // Шаблон генерируется в plist с РЕАЛЬНЫМ путём бинаря агента и лог-файлом
    // в домашней директории пользователя (launchd ~ не раскрывает сам).
    let logPath = logsDir.appendingPathComponent("agent.log").path
    let plistText = templateText
        .replacingOccurrences(of: "{{BINARY_PATH}}", with: binaryPath)
        .replacingOccurrences(of: "{{LOG_PATH}}", with: logPath)

    let dest = launchAgentsDir.appendingPathComponent("\(agentServiceName).plist")
    do {
        try plistText.data(using: .utf8)!.write(to: dest, options: .atomic)
    } catch {
        eprint(String(format: L10n.tr("cli.plist.writeerror"), "\(error)"))
        return 1
    }

    // Идемпотентность: если агент уже загружен — выйти, не вызывая bootstrap/load повторно.
    let alreadyLoaded = runProcess("/bin/launchctl", ["print", "\(guiDomain)/\(agentServiceName)"])
    if alreadyLoaded.status == 0 {
        print("NanoDictate agent already running")
        return 0
    }

    let bootstrap = runProcess("/bin/launchctl", ["bootstrap", guiDomain, dest.path])
    if bootstrap.status == 0 {
        print("NanoDictate agent started")
        return 0
    }
    let load = runProcess("/bin/launchctl", ["load", dest.path])
    if load.status == 0 {
        print("NanoDictate agent started")
        return 0
    }
    let msg1 = bootstrap.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let msg2 = load.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    eprint(msg1.isEmpty ? L10n.tr("cli.bootstrap.nodata") : String(format: L10n.tr("cli.bootstrap.fail"), msg1))
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
    eprint(msg1.isEmpty ? L10n.tr("cli.bootout.nodata") : String(format: L10n.tr("cli.bootout.fail"), msg1))
    eprint(msg2.isEmpty ? L10n.tr("cli.unload.nodata") : String(format: L10n.tr("cli.unload.fail"), msg2))
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

/// Маскировка секретов в сыром тексте конфиг-файла: api_key / proxy_key /
/// api_secret — значения в кавычках заменяются на maskSecret (первые 4 + "***" +
/// последние 4). Пустые значения остаются пустыми.
func maskFileSecrets(in content: String) -> String {
    var lines: [String] = []
    for line in content.components(separatedBy: .newlines) {
        let key = line.split(separator: "=", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if key == "api_key" || key == "proxy_key" || key == "api_secret",
           let eqIndex = line.firstIndex(of: "="),
           let open = line[line.index(after: eqIndex)...].firstIndex(of: "\""),
           let close = line[line.index(after: open)...].firstIndex(of: "\"") {
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

/// "(пусто)" для пустых секретов, иначе — первые 4 + "***" + последние 4 символа.
func secretDisplay(_ secret: String) -> String {
    secret.isEmpty ? L10n.tr("cli.placeholder.empty") : AppConfig.maskSecret(secret)
}

/// Спросить в TTY, перезаписывать ли существующий конфиг. В пайпе — false.
func configOverwriteConfirmed(_ path: String) -> Bool {
    guard isTTY(), stdinIsTTY() else { return false }
    eprint(String(format: L10n.tr("cli.config.overwrite"), path))
    let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
    return answer == "y" || answer == "yes"
}

/// Записать шаблон конфига (создаёт директорию при необходимости) с правами 0600.
func writeConfigTemplate(path: String) -> Int32 {
    let fm = FileManager.default
    let dir = (path as NSString).deletingLastPathComponent
    do {
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try AppConfig.initTemplate().data(using: .utf8)!
            .write(to: URL(fileURLWithPath: path), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
    } catch {
        eprint(String(format: L10n.tr("cli.config.writeerror"), path, "\(error)"))
        return 1
    }
    print(String(format: L10n.tr("cli.config.template"), path))
    print(L10n.tr("cli.config.fillserts"))
    return 0
}

/// `config set-key <провайдер> [ключ] [--stdin]` — api_key точечной правкой
/// секции `[providers.<id>]`. Ключ не передан: читается из stdin (при --stdin
/// или пайпе), иначе — ввод с клавиатуры. Предупреждает, если активна
/// env-переменная NANODICTATE_API_KEY (она приоритетнее файла).
func cmdConfigSetKey(path: String, args: [String]) -> Int32 {
    guard let providerID = args.first else {
        eprint(L10n.tr("cli.setkey.usage"))
        return 1
    }
    let rest = Array(args.dropFirst())
    let useStdin = rest.contains("--stdin")
    let keyArg = rest.first(where: { !$0.hasPrefix("--") })

    let value: String
    if let keyArg = keyArg {
        value = keyArg
    } else if useStdin || !stdinIsTTY() {
        let data = FileHandle.standardInput.readDataToEndOfFile()
        value = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
        // writeProviderKeyValue ждёт значение в формате строки конфига (с кавычками),
        // как writeKeyValue для строк (ср. writeActiveProvider).
        try AppConfig.writeProviderKeyValue(providerID: providerID, key: "api_key", value: "\"\(value)\"", to: path)
    } catch {
        eprint(String(format: L10n.tr("cli.config.writeerror"), providerID, "\(error)"))
        return 1
    }
    print(String(format: L10n.tr("cli.setkey.updated"), providerID, path))
    return 0
}

/// Терминальный ли stdin (для ввода ключа с клавиатуры vs пайп).
func stdinIsTTY() -> Bool {
    isatty(STDIN_FILENO) == 1
}

func cmdConfig(_ args: [String]) -> Int32 {
    let path = AppConfig.defaultPath()
    let fm = FileManager.default
    let exists = fm.fileExists(atPath: path)

    // `config path` — алиас `config --path`.
    if args.first?.lowercased() == "path" || args.contains("--path") {
        print(path)
        return 0
    }

    // `config init [--force]` — создать шаблон (без подтверждения не перезаписывает).
    if args.first?.lowercased() == "init" {
        guard !exists || args.contains("--force") || configOverwriteConfirmed(path) else {
            eprint(String(format: L10n.tr("cli.config.exists"), path))
            eprint(L10n.tr("cli.config.forcehint"))
            return 1
        }
        return writeConfigTemplate(path: path)
    }

    // `config set-key <провайдер> [ключ]` — точечная правка api_key в секции.
    if args.first?.lowercased() == "set-key" {
        return cmdConfigSetKey(path: path, args: Array(args.dropFirst()))
    }

    do {
        let config = try AppConfig.load(from: nil)

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
        if !config.apiSecret.isEmpty {
            print("api_secret: \(secretDisplay(config.apiSecret))")
        }
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
        for p in providers {
            let marker = p.id == activeID ? "*" : " "
            let display = p.name.isEmpty ? p.id : p.name
            print("\(marker) \(display) [\(p.id)]")
            print("    base_url: \(p.baseURL)")
            print("    model: \(p.model)")
            print("    api_key: \(secretDisplay(p.apiKey))")
            if let keyFile = p.apiKeyFile {
                print("    api_key_file: \(keyFile)")
            }
            print("    proxy_key: \(secretDisplay(p.proxyKey))")
            if !p.apiSecret.isEmpty {
                print("    api_secret: \(secretDisplay(p.apiSecret))")
            }
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

/// Перезапуск агента через launchctl (--no-restart пропускает). Общий для
/// команд, меняющих конфиг: provider use и routing set/unset.
func restartAgentIfNeeded(_ args: [String]) -> Int32 {
    if args.contains("--no-restart") {
        print(L10n.tr("cli.provider.norestart"))
        return 0
    }
    let target = "\(guiDomain)/\(agentServiceName)"
    let kick = runProcess("/bin/launchctl", ["kickstart", "-k", target])
    if kick.status == 0 {
        print(L10n.tr("cli.provider.restart"))
    } else {
        let msg = kick.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        eprint(String(format: L10n.tr("cli.provider.kickfail"), msg.isEmpty ? kick.stdout : msg))
    }
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
        guard let p = providers.first(where: { $0.id == name }) else {
            let available = providers.map { $0.id }
            eprint(String(format: L10n.tr("cli.provider.notfound"), name, available.joined(separator: ", ")))
            return 2
        }
        print("id: \(p.id)")
        print("name: \(p.name.isEmpty ? p.id : p.name)")
        print("active: \(p.id == activeID)")
        print("base_url: \(p.baseURL)")
        print("model: \(p.model)")
        if p.apiKey.isEmpty {
            print("api_key: \(L10n.tr("cli.config.noset"))")
            print(L10n.tr("cli.config.secretWarning"))
        } else {
            print("api_key: \(secretDisplay(p.apiKey))")
        }
        if let keyFile = p.apiKeyFile {
            let expanded = (keyFile as NSString).expandingTildeInPath
            print("api_key_file: \(keyFile)")
            if !FileManager.default.fileExists(atPath: expanded) {
                print(String(format: L10n.tr("cli.config.secretFileMissing"), expanded))
            }
        }
        if p.proxyKey.isEmpty {
            print("proxy_key: \(L10n.tr("cli.config.noset"))")
        } else {
            print("proxy_key: \(secretDisplay(p.proxyKey))")
        }
        if p.apiSecret.isEmpty {
            print("api_secret: \(L10n.tr("cli.config.noset"))")
        } else {
            print("api_secret: \(secretDisplay(p.apiSecret))")
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
        // --no-restart не позиционный: распознаётся в любом месте (в т.ч.
        // до имени — иначе уходит в валидацию как невалидный id).
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

// MARK: - Маршрутизация STT по ролям ([routing])

/// `nanodictate routing [show]`: роли из секции [routing] и их effective-значения
/// (фолбэк на активного провайдера при пустой/неизвестной роли). Толерантный
/// разбор как у provider list — показ работает даже при stale active_provider.
func routingShow() -> Int32 {
    let path = AppConfig.defaultPath()
    guard FileManager.default.fileExists(atPath: path) else {
        print(String(format: L10n.tr("cli.config.missing"), path))
        return 0
    }
    let (activeID, providers) = (try? AppConfig.loadProvidersOnly(from: nil)) ?? ("", [])
    // routing парсится только в полном разборе (грубый откат на дефолты при
    // сломанном active_provider — чинится командой provider use).
    let config = (try? AppConfig.load(from: nil)) ?? AppConfig.defaults
    let ids = providers.map { $0.id }
    let seg = config.routing.segmentProvider
    let fin = config.routing.finalProvider
    let activeDisplay = activeID.isEmpty ? L10n.tr("cli.config.unset") : activeID
    func effective(_ role: String) -> String {
        !role.isEmpty && ids.contains(role)
            ? role
            : (activeID.isEmpty ? L10n.tr("cli.config.unset") : "\(activeID) \(L10n.tr("cli.config.active"))")
    }
    print("active_provider: \(activeDisplay)")
    print("segment_provider: \(seg.isEmpty ? L10n.tr("cli.config.unset") : seg)")
    print("final_provider: \(fin.isEmpty ? L10n.tr("cli.config.unset") : fin)")
    print("segment (effective): \(effective(seg))")
    print("final (effective): \(effective(fin))")
    return 0
}

/// Ключ роли в конфиге ([routing]); nil — неизвестная роль.
func routingKey(for role: String) -> String? {
    switch role {
    case "segment": return "segment_provider"
    case "final": return "final_provider"
    default: return nil
    }
}

/// `nanodictate routing set segment|final <id> [--no-restart]`: точечная правка
/// ключа роли в [routing]. Валидация id по секциям [providers.X] как в
/// provider use; атомарная запись + chmod 600; перезапуск агента (кроме
/// --no-restart). Роль действует с перезапуска агента.
func routingSet(role: String, providerID: String, args: [String]) -> Int32 {
    guard let key = routingKey(for: role) else {
        eprint(L10n.tr("cli.routing.usage"))
        return 1
    }
    do {
        let (_, providers) = try AppConfig.loadProvidersOnly(from: nil)
        guard providers.contains(where: { $0.id == providerID }) else {
            let available = providers.map { $0.id }
            eprint(String(format: L10n.tr("cli.routing.noexist"), providerID, available.joined(separator: ", ")))
            eprint(L10n.tr("cli.routing.listHint"))
            return 2
        }
        try AppConfig.writeRoutingKeyValue(key: key, value: "\"\(providerID)\"", to: AppConfig.defaultPath())
    } catch {
        eprint(String(format: L10n.tr("cli.flag.configload"), "\(error)"))
        return 1
    }
    print(String(format: L10n.tr("cli.routing.role"), role, providerID))
    return restartAgentIfNeeded(args)
}

/// `nanodictate routing unset segment|final [--no-restart]`: очистка роли
/// (пишется пустое значение — резолвер фолбэчит на активного провайдера).
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
        // --no-restart не позиционный: распознаётся в любом месте (в т.ч.
        // до роли/имени — иначе уходит в валидацию как невалидный id).
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

func cmdTranscribe(_ args: [String]) -> Int32 {
    // Пакетные флаги (--provider/--out/--max-segment/--overlap/--no-progress/
    // --resume) включают пакетный режим; без них — разовая расшифровка как раньше.
    var batch = BatchTranscribeOptions()
    var batchRequested = false
    var file: String?
    var i = 0
    while i < args.count {
        let a = args[i]
        switch a {
        case "--provider":
            guard i + 1 < args.count else { eprint(L10n.tr("cli.flag.provider")); return 1 }
            batch.providerID = args[i + 1]; i += 2; batchRequested = true
        case "--out":
            guard i + 1 < args.count else { eprint(L10n.tr("cli.flag.out")); return 1 }
            batch.outPath = args[i + 1]; i += 2; batchRequested = true
        case "--max-segment":
            guard i + 1 < args.count, let v = Double(args[i + 1]), v > 0 else {
                eprint(L10n.tr("cli.flag.maxsegment")); return 1
            }
            batch.maxSegment = v; i += 2; batchRequested = true
        case "--overlap":
            guard i + 1 < args.count, let v = Double(args[i + 1]), v >= 0 else {
                eprint(L10n.tr("cli.flag.overlap")); return 1
            }
            batch.overlap = v; i += 2; batchRequested = true
        case "--no-progress":
            batch.showProgress = false; i += 1; batchRequested = true
        case "--cut-at-pauses":
            batch.cutAtPauses = true; i += 1; batchRequested = true
        case "--no-cut-at-pauses":
            batch.cutAtPauses = false; i += 1; batchRequested = true
        case "--resume":
            batch.resume = true; i += 1; batchRequested = true
        case "--parallel":
            guard i + 1 < args.count, let v = Int(args[i + 1]), v >= 1 else {
                eprint(L10n.tr("cli.flag.parallel")); return 1
            }
            batch.maxConcurrent = v; i += 2; batchRequested = true
        case "--json":
            batch.json = true; i += 1
        case "--help", "-h":
            eprint(usageTranscribeBatch)
            return 0
        default:
            if a.hasPrefix("-") {
                eprint(String(format: L10n.tr("cli.flag.unknown"), a))
                eprint(usageTranscribeBatch)
                return 1
            }
            guard file == nil else { eprint(String(format: L10n.tr("cli.flag.extra"), a)); return 1 }
            file = a; i += 1
        }
    }
    guard let file = file else {
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
    // По умолчанию ВКЛЮЧЕНО: резать по паузам речи ≥ 0.3 с (рекомендация
    // «Практики длинной речи»). --no-cut-at-pauses — обратно к фиксированной
    // длине (для совместимости с чекпоинтами старых прогонов).
    var cutAtPauses = true
    var resume = false
    var json = false
}

let usageTranscribeBatch = """
  \(L10n.tr("usage.transcribe"))
  \(L10n.tr("usage.batch"))
    \(L10n.tr("usage.batch.desc"))
"""

func formatClock(_ seconds: TimeInterval) -> String {
    let s = max(0, Int(seconds.rounded()))
    return String(format: "%02d:%02d", s / 60, s % 60)
}

/// Стабильный отпечаток строки (djb2 по UTF-8 байтам) для ключа чекпоинта.
/// `String.hashValue` не годится: рандомизирован между процессами.
func stableCheckpointStamp(_ s: String) -> String {
    var hash: UInt64 = 5381
    for byte in s.utf8 {
        hash = (hash &* 33) &+ UInt64(byte)
    }
    return String(hash, radix: 16)
}

/// Одна строка прогресса пакетного режима в stderr, перезаписываемая \r
/// (без \n до завершения). Один общий экземпляр на прогон — атомарные
/// перерисовки под NSLock. Формат:
///   [12/84] ████████████░░░░░░░░░░ 33% · ~4 мин осталось · средн. 7.2с/чанк
/// finish() ставит перевод строки (перед итогами/ошибками); повторный
/// finish() — no-op. Выключен (--no-progress) — не пишет ничего.
final class BatchProgressBar {
    private let lock = NSLock()
    private let enabled: Bool
    private let width: Int
    private var finished = false

    init(enabled: Bool, width: Int = 24) {
        self.enabled = enabled
        self.width = width
    }

    /// Перерисовать строку. `completed` — число готовых чанков (N из [N/M]),
    /// `elapsed` — секунд с начала прогона.
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
        let line = String(format: "\u{1B}[2K\r[%d/%d] %@ %3d%% · %@ · " + L10n.tr("progress.avgPerChunk"),
                          completed, total, bar, percent, BatchProgressBar.etaText(eta), avg)
        FileHandle.standardError.write(Data(line.utf8))
    }

    /// Закрыть строку переводом строки (до итога/ошибки). Идемпотентна.
    func finish() {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, !finished else { return }
        finished = true
        FileHandle.standardError.write(Data("\u{1B}[2K\r\n".utf8))
    }

    /// «~45 сек» / «~4 мин» / «~1 ч 12 мин» (округление вверх — не обещаем
    /// лишнего времени).
    private static func etaText(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded(.up))
        if s < 60 { return String(format: L10n.tr("progress.eta.sec"), s) }
        let m = s / 60
        if m < 60 { return String(format: L10n.tr("progress.eta.min"), m) }
        let h = m / 60
        let mm = m % 60
        if mm == 0 { return String(format: L10n.tr("progress.eta.hour"), h) }
        return String(format: L10n.tr("progress.eta.hm"), h, mm)
    }
}

func cmdTranscribeBatch(_ file: String, options: BatchTranscribeOptions) -> Int32 {
    let fm = FileManager.default

    // 1. Конфиг и провайдер (всё из config.toml, ничего не зашито).
    let config: AppConfig
    do { config = try AppConfig.load(from: nil) }
    catch {
        eprint(String(format: L10n.tr("cli.flag.configload"), "\(error)"))
        return 1
    }
    var provider = config.providers.first(where: { $0.id == options.providerID })
    if provider == nil && options.providerID == "gigaam" {
        // Стоковый конфиг (config init) секции gigaam не содержит: фолбэк на
        // активного провайдера, иначе — первого доступного, чтобы batch-режим
        // работал out-of-box без правки флага.
        let active: AppConfig.Provider? = (try? ProviderStore.loadProviders())
            .flatMap { list in list.first(where: { $0.isActive }).flatMap { active in
                config.providers.first(where: { $0.id == active.id })
            } }
        let fallback = active ?? config.providers.first
        if let fallback = fallback {
            eprint(String(format: L10n.tr("cli.transcribe.warn"), fallback.id))
            provider = fallback
        }
    }
    guard let provider = provider else {
        eprint(String(format: L10n.tr("cli.transcribe.noprovider"), options.providerID, config.providers.map { $0.id }.joined(separator: ", ")))
        return 1
    }
    guard !provider.baseURL.isEmpty else {
        eprint(String(format: L10n.tr("cli.transcribe.nourl"), provider.id))
        return 1
    }

    // 2. Приведение к 16 кГц моно PCM16 WAV, СТРИМИНГ без загрузки в RAM.
    // Пробуем открыть вход напрямую (read-окна по требованию из файла):
    // если это не PCM16 WAV или не 16 кГц моно — afconvert во временный файл
    // (временный живёт до конца прогона — run(fileURL:) читает из него окна).
    let inputURL = URL(fileURLWithPath: file)
    var wavURL = inputURL
    var tempWavURL: URL?
    var wavSampleCount = 0
    var wavSampleRate = 0
    do {
        let probe = try WAVFilePCMBatchContent(wavURL: wavURL)
        guard probe.sampleRate == 16000 && probe.channels == 1 else {
            throw WAVFilePCMBatchContent.WAVFileError.invalidWAV
        }
        // Пробник нужен ТОЛЬКО для сводки (sampleCount/sampleRate): берём
        // значения и отпускаем объект — его FileHandle закрывается в deinit,
        // а run(fileURL:) открывает файл заново собственными read-окнами.
        wavSampleCount = probe.sampleCount
        wavSampleRate = probe.sampleRate
    } catch {
        // Причина отказа пробника:
        // fileNotFound/ioError — файл физически недоступен, конвертация
        // afconvert не поможет — показываем исходную ошибку и выходим.
        if let probeError = error as? WAVFilePCMBatchContent.WAVFileError,
           case .fileNotFound = probeError {
            eprint(String(format: L10n.tr("cli.transcribe.filenotfound"), file))
            return 1
        }
        if let probeError = error as? WAVFilePCMBatchContent.WAVFileError,
           case .ioError(let message) = probeError {
            eprint(String(format: L10n.tr("cli.transcribe.readerror"), file, message))
            return 1
        }
        // invalidWAV (не PCM16 WAV / не 16 кГц моно) — штатный случай:
        // afconvert во временный файл (временный живёт до конца прогона —
        // run(fileURL:) читает из него окна).
        let converted = fm.temporaryDirectory.appendingPathComponent("nanodictate-batch-\(UUID().uuidString).wav")
        let conv = runProcess("/usr/bin/afconvert",
                              ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", file, converted.path])
        guard conv.status == 0 else {
            let msg = conv.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            eprint(String(format: L10n.tr("cli.transcribe.waverror"), file, msg.isEmpty ? conv.stdout : msg))
            return 1
        }
        tempWavURL = converted
        wavURL = converted
        guard let content = try? WAVFilePCMBatchContent(wavURL: converted) else {
            eprint(String(format: L10n.tr("cli.transcribe.converror"), converted.path))
            try? fm.removeItem(at: converted)
            return 1
        }
        wavSampleCount = content.sampleCount
        wavSampleRate = content.sampleRate
    }

    // Неизменяемые копии для захвата в Task (var нельзя захватывать в
    // @Sendable-замыкание): после этого блока ни wavURL, ни tempWavURL,
    // ни счётчики сводки уже не меняются.
    let batchWavURL = wavURL
    let tempWavForCleanup = tempWavURL
    let batchSampleCount = wavSampleCount
    let batchSampleRate = wavSampleRate

    // 3. Чекпоинт: рядом с --out, иначе стабильный путь во временной папке.
    // Ключ временного чекпоинта учитывает ОТПЕЧАТОК ПОЛНОГО ПУТИ файла
    // (разные файлы с одинаковым именем не сталкиваются) + провайдера +
    // maxSegment + overlap (нарезка чанков зависит от обоих).
    let checkpointPath: String
    if let out = options.outPath {
        checkpointPath = out + ".checkpoint.json"
    } else {
        // Нарезка зависит от нарезочных параметров; выравнивание на паузы
        // (--cut-at-pauses, по умолчанию ВКЛЮЧЕНО) задаёт другие границы —
        // суффикс "-pause" в ключе чекпоинта. Старые чекпоинты без суффикса
        // (фиксированная нарезка, до внедрения паузного выравнивания)
        // заведомо несовместимы и корректно игнорируются resume.
        let pauseFactor = options.cutAtPauses ? "-pause" : ""
        checkpointPath = fm.temporaryDirectory
            .appendingPathComponent("nanodictate-batch-\(stableCheckpointStamp(inputURL.path))-\(provider.id)-\(Int(options.maxSegment))-\(Int(options.overlap))\(pauseFactor).checkpoint.json")
            .path
    }
    if options.resume && !fm.fileExists(atPath: checkpointPath) {
        eprint(String(format: L10n.tr("progress.noresume"), checkpointPath))
    }
    let sourcePath = inputURL.path
    if options.resume, fm.fileExists(atPath: checkpointPath),
       let cp = try? BatchTranscriber.loadCheckpoint(from: checkpointPath),
       cp.sourceFile != sourcePath {
        eprint(String(format: L10n.tr("progress.badcheckpoint"), checkpointPath, cp.sourceFile))
    }

    // 4. Реальный транспорт чанка: запрос по полям провайдера + Retry-After.
    let transport = URLSessionBatchTransport()
    let apiKey = RetryProvider.resolveAPIKey(for: provider) // env > api_key > api_key_file
    let language = config.language
    let sendOne: BatchTranscriber.SendOne = { attempt, wav, chunkIndex, prompt in
        guard let prepared = BatchRequestBuilder.makeRequest(
            provider: provider,
            apiKey: apiKey,
            language: language,
            timeout: config.timeoutSeconds,
            wav: wav,
            chunkIndex: chunkIndex,
            batchParams: BatchSTTParams(prompt: prompt),
            proxyKey: provider.proxyKey,
            proxyKeyHeader: provider.proxyKeyHeader.isEmpty ? config.proxyKeyHeader : provider.proxyKeyHeader
        ) else {
            throw BatchHTTPError.invalidResponse(String(format: L10n.tr("cli.batch.badBaseUrl"), provider.id))
        }
        let response: BatchHTTPResponse
        do { response = try await transport.send(request: prepared.request) }
        catch { throw BatchHTTPError.network(error.localizedDescription) }
        guard (200...299).contains(response.status) else {
            let snippet = String(data: response.body, encoding: .utf8) ?? ""
            throw BatchHTTPError.http(response.status,
                                      message: String(snippet.prefix(300)),
                                      retryAfter: response.retryAfterSeconds)
        }
        do {
            return try ProviderRequestBuilder.extractText(from: response.body, path: prepared.transcriptPath)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw BatchHTTPError.invalidResponse(String(format: L10n.tr("cli.batch.parseError"), "\(error)"))
        }
    }

    // 4b. Один общий прогресс-бар на прогон (атомарные перерисовки).
    let progressBar = BatchProgressBar(enabled: options.showProgress)

    Task {
        defer { progressBar.finish() }   // перевести строку при любом исходе
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
                onProgress: { i, n, _, _, elapsed, _ in
                    progressBar.update(completed: i, total: n, elapsed: elapsed)
                }
            )

            // 5. Текст: в --out (атомарно) или в stdout. В файл — с завершающим
            // переводом строки (пустой текст — пустой файл, без голого \n).
            if let out = options.outPath {
                do {
                    let content = outcome.text.isEmpty ? outcome.text : outcome.text + "\n"
                    try content.write(to: URL(fileURLWithPath: out), atomically: true, encoding: .utf8)
                } catch {
                    eprint(String(format: L10n.tr("cli.transcribe.writeError"), out, "\(error)"))
                    if let t = tempWavForCleanup { try? FileManager.default.removeItem(at: t) }
                    exit(1)
                }
            } else {
                print(outcome.text)
            }

            if let t = tempWavForCleanup { try? FileManager.default.removeItem(at: t) } // read-окна отработали

            // 6. Итог в stderr.
            let duration = Double(batchSampleCount) / Double(batchSampleRate)
            var summary = String(format: L10n.tr("progress.summary"),
                                formatClock(duration), outcome.totalSegments, outcome.okCount, outcome.skippedCount, Int(outcome.elapsed))
            if !outcome.skippedIndexes.isEmpty {
                summary += String(format: L10n.tr("progress.skipped"), outcome.skippedIndexes.map(String.init).joined(separator: ", "))
            }
            eprint(summary)
            eprint(String(format: L10n.tr("progress.checkpoint"), checkpointPath))

            // 7. --json: как в разовом режиме — transcription_raw.json рядом с ФАЙЛ
            // (в пакетном режиме это копия чекпоинта с текстами чанков).
            if options.json {
                let rawURL = inputURL.deletingLastPathComponent().appendingPathComponent("transcription_raw.json")
                do {
                    try Data(contentsOf: URL(fileURLWithPath: checkpointPath)).write(to: rawURL, options: .atomic)
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
    return 1 // unreachable
}

func cmdTranscribeLegacy(_ file: String, json: Bool) -> Int32 {
    let fm = FileManager.default
    let inputURL = URL(fileURLWithPath: file)

    var wavURL = inputURL
    var tempWavURL: URL?
    if inputURL.pathExtension.lowercased() != "wav" {
        let converted = fm.temporaryDirectory.appendingPathComponent("nanodictate-\(UUID().uuidString).wav")
        let conv = runProcess("/usr/bin/afconvert",
                              ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", file, converted.path])
        guard conv.status == 0 else {
            let msg = conv.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            eprint(String(format: L10n.tr("cli.transcribe.waverror"), file, msg.isEmpty ? conv.stdout : msg))
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
        if let t = tempWavURL { try? fm.removeItem(at: t) }
        return 1
    }
    // WAV data is loaded; the converted temp file is no longer needed.
    if let t = tempWavURL { try? fm.removeItem(at: t) }

    let config: AppConfig
    do {
        config = try AppConfig.load(from: nil)
    } catch {
        eprint(String(format: L10n.tr("cli.flag.configload"), "\(error)"))
        return 1
    }

    // Активный провайдер = адаптер запроса (как в NanoDictateAgent): при пустом
    // active_provider — первый провайдер по порядку, иначе его id.
    let activeAdapterID: String? = config.activeProvider.isEmpty
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
        apiSecret: config.apiSecret,
        adapterID: activeAdapterID
    )
    // Данные всегда WAV (не-WAV конвертируется выше); сервер строг к расширению,
    // поэтому в multipart-поле файла всегда слать "audio.wav", а не исходное имя.
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
    return 1 // unreachable
}

func cmdLogs() -> Int32 {
    let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/NanoDictate/agent.log")
    guard let content = try? String(contentsOf: logURL, encoding: .utf8) else {
        print(L10n.tr("cli.logs.notfound"))
        return 1
    }
    let body = content.components(separatedBy: .newlines).suffix(50).joined(separator: "\n")
    if !body.isEmpty { print(body) }
    return 0
}

// MARK: - Последний текст и retry другим провайдером

/// `nanodictate last`: последний распознанный текст из маркера LAST_TEXT в логе
/// агента (пишется при каждой успешной вставке, включая retry).
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

/// `nanodictate retry <provider>`: просит агента повторить распознавание
/// последнего WAV (он у агента в памяти) указанным провайдером. Через
/// DistributedNotificationCenter — вставку выполняет САМ агент (у него уже
/// есть право «Доступность» и знакомый путь вставки/ревью).
func cmdRetry(_ name: String) -> Int32 {
    let providers: [AppConfig.Provider]
    do {
        providers = try AppConfig.loadProvidersOnly(from: nil).providers
    } catch {
        eprint(String(format: L10n.tr("cli.flag.configload"), "\(error)"))
        return 1
    }
    guard let provider = providers.first(where: { $0.id == name }) else {
        let available = providers.map { $0.id }
        eprint(String(format: L10n.tr("cli.provider.notfound"), name, available.joined(separator: ", ")))
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

/// Список id провайдеров одной строкой (подсказка для usage retry).
func providerNamesText() -> String {
    let ids = (try? AppConfig.loadProvidersOnly(from: nil).providers.map { $0.id }) ?? []
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
    [--provider <id>] [--out \(L10n.tr("usage.placeholder.path"))] [--max-segment <\(L10n.tr("usage.placeholder.seconds"))>] [--overlap <\(L10n.tr("usage.placeholder.seconds"))>]
    [--no-progress] [--resume]
                                   \(L10n.tr("usage.batch.desc"))
  retry \(L10n.tr("usage.placeholder.name"))                        \(L10n.tr("usage.retry"))
  last                             \(L10n.tr("usage.last"))
  logs                             \(L10n.tr("usage.logs"))
  help                             \(L10n.tr("usage.help"))
"""

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())

// Localize early: read ui_language from config (if exists) before any output.
let uiLanguage = (try? AppConfig.load(from: nil))?.uiLanguage
L10n.language = uiLanguage == "ru" ? .ru : .en

guard let command = args.first?.lowercased() else {
    // Без команды в интерактивном терминале — лёгкое меню; в пайпе/скрипте — usage.
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
case "help", "-h", "--help":
    print(usage)
    exit(0)
default:
    eprint(String(format: L10n.tr("cli.cmd.unknown"), command))
    print(usage)
    exit(1)
}