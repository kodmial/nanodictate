import Darwin
import Foundation
import DictationCore

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
let agentServiceName = "com.dictation.agent"

/// Абсолютный путь к бинарю агента (брат CLI-бинаря в .build/debug).
/// Env DICTATION_AGENT_BIN позволяет переопределить (например, установленный
/// в /usr/local/bin вариант). Промах тут не фатален — launchctl покажет ошибку.
func findAgentBinaryPath() -> String? {
    if let env = ProcessInfo.processInfo.environment["DICTATION_AGENT_BIN"], !env.isEmpty {
        return env
    }
    let exe = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    let sibling = exe.deletingLastPathComponent().appendingPathComponent("DictatorAgent")
    if FileManager.default.fileExists(atPath: sibling.path) { return sibling.path }
    return exe.path
}

/// Поиск шаблона LaunchAgent-plist (Resources/dictation-agent.plist.template):
/// 1) явный env DICTATION_PLIST_TEMPLATE; 2) директория Resources рядом с
/// бинарём; 3) исходники проекта (компиляция из дерева); 4) cwd/Resources.
func findPlistTemplate() -> URL? {
    let name = "dictation-agent.plist.template"
    if let env = ProcessInfo.processInfo.environment["DICTATION_PLIST_TEMPLATE"] {
        let url = URL(fileURLWithPath: env)
        if FileManager.default.fileExists(atPath: url.path) { return url }
    }
    let exeDir = (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
        .deletingLastPathComponent()
    let fromSourceDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()          // Sources/dictatorctl
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
    let logsDir = home.appendingPathComponent("Library/Logs/Dictation")

    do {
        try fm.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
    } catch {
        eprint("Не удалось создать директории: \(error)")
        return 1
    }

    guard let template = findPlistTemplate() else {
        eprint("Не найден шаблон dictation-agent.plist.template (Resources рядом с бинарём или в проекте; либо укажите DICTATION_PLIST_TEMPLATE)")
        return 1
    }
    guard let binaryPath = findAgentBinaryPath() else {
        eprint("Не удалось определить путь к DictatorAgent")
        return 1
    }
    guard let templateText = try? String(contentsOf: template, encoding: .utf8) else {
        eprint("Не удалось прочитать шаблон plist: \(template.path)")
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
        eprint("Не удалось записать plist: \(error)")
        return 1
    }

    // Идемпотентность: если агент уже загружен — выйти, не вызывая bootstrap/load повторно.
    let alreadyLoaded = runProcess("/bin/launchctl", ["print", "\(guiDomain)/\(agentServiceName)"])
    if alreadyLoaded.status == 0 {
        print("Dictation agent already running")
        return 0
    }

    let bootstrap = runProcess("/bin/launchctl", ["bootstrap", guiDomain, dest.path])
    if bootstrap.status == 0 {
        print("Dictation agent started")
        return 0
    }
    let load = runProcess("/bin/launchctl", ["load", dest.path])
    if load.status == 0 {
        print("Dictation agent started")
        return 0
    }
    let msg1 = bootstrap.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let msg2 = load.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    eprint(msg1.isEmpty ? "launchctl bootstrap: нет вывода" : "launchctl bootstrap не удался: \(msg1)")
    eprint(msg2.isEmpty ? "launchctl load fallback: нет вывода" : "launchctl load fallback не удался: \(msg2)")
    return 1
}

func cmdStop() -> Int32 {
    let target = "\(guiDomain)/\(agentServiceName)"
    let bootout = runProcess("/bin/launchctl", ["bootout", target])
    if bootout.status == 0 {
        print("Dictation agent stopped")
        return 0
    }
    let unload = runProcess("/bin/launchctl", ["unload", target])
    if unload.status == 0 {
        print("Dictation agent stopped")
        return 0
    }
    let msg1 = bootout.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    let msg2 = unload.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    eprint(msg1.isEmpty ? "launchctl bootout: нет вывода" : "launchctl bootout не удался: \(msg1)")
    eprint(msg2.isEmpty ? "launchctl unload fallback: нет вывода" : "launchctl unload fallback не удался: \(msg2)")
    return 1
}

func cmdStatus() -> Int32 {
    let printResult = runProcess("/bin/launchctl", ["print", "\(guiDomain)/\(agentServiceName)"])
    let running = printResult.status == 0
    print(running ? "running" : "not running")

    let pgrep = runProcess("/usr/bin/pgrep", ["-f", "DictatorAgent"])
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
            print("provider: (нет провайдеров — legacy-конфиг)")
        } else {
            print("provider: (не выбран — `dictatorctl provider use <имя>`)")
        }
    } catch {
        print("provider: (ошибка: \(error))")
    }

    if !FileManager.default.fileExists(atPath: AppConfig.defaultPath()) {
        print("hint: конфиг не найден — создайте шаблон командой `dictatorctl config init`")
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
    secret.isEmpty ? "(пусто)" : AppConfig.maskSecret(secret)
}

/// Спросить в TTY, перезаписывать ли существующий конфиг. В пайпе — false.
func configOverwriteConfirmed(_ path: String) -> Bool {
    guard isTTY(), stdinIsTTY() else { return false }
    eprint("Конфиг \(path) уже существует. Перезаписать? (y/N)")
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
        eprint("ОШИБКА: не удалось записать \(path): \(error)")
        return 1
    }
    print("Шаблон конфига создан: \(path) (chmod 600)")
    print("Заполните секреты: `dictatorctl config set-key <провайдер>` или отредактируйте файл.")
    return 0
}

/// `config set-key <провайдер> [ключ] [--stdin]` — api_key точечной правкой
/// секции `[providers.<id>]`. Ключ не передан: читается из stdin (при --stdin
/// или пайпе), иначе — ввод с клавиатуры. Предупреждает, если активна
/// env-переменная DICTATION_API_KEY (она приоритетнее файла).
func cmdConfigSetKey(path: String, args: [String]) -> Int32 {
    guard let providerID = args.first else {
        eprint("Использование: dictatorctl config set-key <провайдер-id> [ключ] [--stdin]")
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
        eprint("Введите значение api_key для '\(providerID)' (Enter — подтвердить):")
        guard let line = readLine() else {
            eprint("Отменено")
            return 1
        }
        value = line.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    guard !value.isEmpty else {
        eprint("Значение пусто — ключ не записан (передайте аргументом или через stdin)")
        return 1
    }
    guard !value.contains("\""), !value.contains("\\"), !value.contains("\n") else {
        eprint("ОШИБКА: значение содержит недопустимые символы (\", \\, перевод строки)")
        return 1
    }

    if let envKey = ProcessInfo.processInfo.environment["DICTATION_API_KEY"], !envKey.isEmpty {
        eprint("ВНИМАНИЕ: активна env-переменная DICTATION_API_KEY — приоритетнее api_key из файла;")
        eprint("пока она задана, записанный ключ использоваться не будет (см. `dictatorctl config show`).")
    }

    do {
        // writeProviderKeyValue ждёт значение в формате строки конфига (с кавычками),
        // как writeKeyValue для строк (ср. writeActiveProvider).
        try AppConfig.writeProviderKeyValue(providerID: providerID, key: "api_key", value: "\"\(value)\"", to: path)
    } catch {
        eprint("ОШИБКА: \(error)")
        return 1
    }
    print("api_key провайдера '\(providerID)' обновлён: \(path) (chmod 600)")
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
            eprint("Конфиг уже существует: \(path)")
            eprint("Для перезаписи используйте `dictatorctl config init --force`.")
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
                    eprint("Не удалось прочитать конфиг: \(path)")
                    return 1
                }
                print(maskFileSecrets(in: content))
            } else {
                print("Конфиг не найден: создайте шаблон командой `dictatorctl config init` (\(path))")
            }
            return 0
        }

        print("path: \(path)")
        if !exists {
            print("Конфиг не найден: создайте шаблон командой `dictatorctl config init` (\(path))")
        }
        print("active_provider: \(ProviderStore.activeProvider?.id ?? "(не выбран)")")
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
        eprint("ОШИБКА: \(error)")
        return 1
    }
}

// MARK: - Providers (несколько STT-провайдеров)

func providerList() -> Int32 {
    do {
        let (activeID, providers) = try AppConfig.loadProvidersOnly(from: nil)
        guard !providers.isEmpty else {
            print("Нет секций [providers.X] в конфиге (используется legacy-конфиг).")
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
        print("(* — активный провайдер)")
        return 0
    } catch {
        eprint("ОШИБКА: \(error)")
        return 1
    }
}

func providerUse(_ name: String, _ args: [String]) -> Int32 {
    do {
        try ProviderStore.setActive(providerID: name)
    } catch let ProviderStoreError.unknownProvider(providerID: id, available: available) {
        eprint("ОШИБКА: провайдер '\(id)' не найден. Доступные: \(available.joined(separator: ", "))")
        return 2
    } catch {
        eprint("ОШИБКА: \(error)")
        return 1
    }
    print("Активный провайдер: \(name)")
    return restartAgentIfNeeded(args)
}

/// Перезапуск агента через launchctl (--no-restart пропускает). Общий для
/// команд, меняющих конфиг: provider use и routing set/unset.
func restartAgentIfNeeded(_ args: [String]) -> Int32 {
    if args.contains("--no-restart") {
        print("Агент не перезапущен (--no-restart)")
        return 0
    }
    let target = "\(guiDomain)/\(agentServiceName)"
    let kick = runProcess("/bin/launchctl", ["kickstart", "-k", target])
    if kick.status == 0 {
        print("Агент перезапущен")
    } else {
        let msg = kick.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        eprint("Агент не перезапущен (запустите `dictatorctl start`): \(msg.isEmpty ? kick.stdout : msg)")
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
            print("active: (нет провайдеров — legacy-конфиг)")
        } else {
            print("active: (не выбран — `dictatorctl provider use <имя>`)")
        }
    } catch {
        eprint("ОШИБКА: \(error)")
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
            eprint("ОШИБКА: провайдер '\(name)' не найден. Доступные: \(available.joined(separator: ", "))")
            return 2
        }
        print("id: \(p.id)")
        print("name: \(p.name.isEmpty ? p.id : p.name)")
        print("active: \(p.id == activeID)")
        print("base_url: \(p.baseURL)")
        print("model: \(p.model)")
        if p.apiKey.isEmpty {
            print("api_key: (пусто)")
            print("! api_key: ВНИМАНИЕ — секрет не задан")
        } else {
            print("api_key: \(secretDisplay(p.apiKey))")
        }
        if let keyFile = p.apiKeyFile {
            let expanded = (keyFile as NSString).expandingTildeInPath
            print("api_key_file: \(keyFile)")
            if !FileManager.default.fileExists(atPath: expanded) {
                print("! api_key_file: ВНИМАНИЕ — файл не существует (\(expanded))")
            }
        }
        if p.proxyKey.isEmpty {
            print("proxy_key: (пусто)")
        } else {
            print("proxy_key: \(secretDisplay(p.proxyKey))")
        }
        if p.apiSecret.isEmpty {
            print("api_secret: (пусто)")
        } else {
            print("api_secret: \(secretDisplay(p.apiSecret))")
        }
        return 0
    } catch {
        eprint("ОШИБКА: \(error)")
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
            eprint("Использование: dictatorctl provider use <имя> [--no-restart]")
            return 1
        }
        return providerUse(name, rest)
    case "status":
        return providerStatus()
    case "show":
        guard let name = args.dropFirst().first else {
            eprint("Использование: dictatorctl provider show <имя>")
            return 1
        }
        return providerShow(name)
    default:
        eprint("Использование: dictatorctl provider list|use|status|show")
        return 1
    }
}

// MARK: - Маршрутизация STT по ролям ([routing])

/// `dictatorctl routing [show]`: роли из секции [routing] и их effective-значения
/// (фолбэк на активного провайдера при пустой/неизвестной роли). Толерантный
/// разбор как у provider list — показ работает даже при stale active_provider.
func routingShow() -> Int32 {
    let path = AppConfig.defaultPath()
    guard FileManager.default.fileExists(atPath: path) else {
        print("Конфиг не найден: \(path)")
        print("Создайте шаблон: `dictatorctl config init`")
        return 0
    }
    let (activeID, providers) = (try? AppConfig.loadProvidersOnly(from: nil)) ?? ("", [])
    // routing парсится только в полном разборе (грубый откат на дефолты при
    // сломанном active_provider — чинится командой provider use).
    let config = (try? AppConfig.load(from: nil)) ?? AppConfig.defaults
    let ids = providers.map { $0.id }
    let seg = config.routing.segmentProvider
    let fin = config.routing.finalProvider
    let activeDisplay = activeID.isEmpty ? "(не задан)" : activeID
    func effective(_ role: String) -> String {
        !role.isEmpty && ids.contains(role)
            ? role
            : (activeID.isEmpty ? "(не задан)" : "\(activeID) (активный)")
    }
    print("active_provider: \(activeDisplay)")
    print("segment_provider: \(seg.isEmpty ? "(не задан)" : seg)")
    print("final_provider: \(fin.isEmpty ? "(не задан)" : fin)")
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

/// `dictatorctl routing set segment|final <id> [--no-restart]`: точечная правка
/// ключа роли в [routing]. Валидация id по секциям [providers.X] как в
/// provider use; атомарная запись + chmod 600; перезапуск агента (кроме
/// --no-restart). Роль действует с перезапуска агента.
func routingSet(role: String, providerID: String, args: [String]) -> Int32 {
    guard let key = routingKey(for: role) else {
        eprint("Использование: dictatorctl routing set segment|final <провайдер-id> [--no-restart]")
        return 1
    }
    do {
        let (_, providers) = try AppConfig.loadProvidersOnly(from: nil)
        guard providers.contains(where: { $0.id == providerID }) else {
            let available = providers.map { $0.id }
            eprint("ОШИБКА: провайдер '\(providerID)' не найден. Доступные: \(available.joined(separator: ", "))")
            eprint("Список: `dictatorctl provider list`")
            return 2
        }
        try AppConfig.writeRoutingKeyValue(key: key, value: "\"\(providerID)\"", to: AppConfig.defaultPath())
    } catch {
        eprint("ОШИБКА: \(error)")
        return 1
    }
    print("Роль \(role): \(providerID)")
    return restartAgentIfNeeded(args)
}

/// `dictatorctl routing unset segment|final [--no-restart]`: очистка роли
/// (пишется пустое значение — резолвер фолбэчит на активного провайдера).
func routingUnset(role: String, args: [String]) -> Int32 {
    guard let key = routingKey(for: role) else {
        eprint("Использование: dictatorctl routing unset segment|final [--no-restart]")
        return 1
    }
    do {
        try AppConfig.writeRoutingKeyValue(key: key, value: "\"\"", to: AppConfig.defaultPath())
    } catch {
        eprint("ОШИБКА: \(error)")
        return 1
    }
    print("Роль \(role) сброшена — фолбэк на активного провайдера")
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
            eprint("Использование: dictatorctl routing set segment|final <провайдер-id> [--no-restart]")
            return 1
        }
        return routingSet(role: role, providerID: providerID, args: rest)
    case "unset":
        let rest = Array(args.dropFirst())
        let positional = rest.filter { $0 != "--no-restart" }
        guard let role = positional.first else {
            eprint("Использование: dictatorctl routing unset segment|final [--no-restart]")
            return 1
        }
        return routingUnset(role: role, args: rest)
    default:
        eprint("Использование: dictatorctl routing [show]|set|unset")
        return 1
    }
}

func cmdTranscribe(_ args: [String]) -> Int32 {
    guard let file = args.first else {
        eprint("Использование: dictatorctl transcribe ФАЙЛ [--json]")
        return 1
    }
    let jsonFlag = args.contains("--json")

    let fm = FileManager.default
    let inputURL = URL(fileURLWithPath: file)

    var wavURL = inputURL
    var tempWavURL: URL?
    if inputURL.pathExtension.lowercased() != "wav" {
        let converted = fm.temporaryDirectory.appendingPathComponent("dictatorctl-\(UUID().uuidString).wav")
        let conv = runProcess("/usr/bin/afconvert",
                              ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", file, converted.path])
        guard conv.status == 0 else {
            let msg = conv.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            eprint("ОШИБКА: не удалось конвертировать \(file) в WAV: \(msg.isEmpty ? conv.stdout : msg)")
            return 1
        }
        tempWavURL = converted
        wavURL = converted
    }

    let data: Data
    do {
        data = try Data(contentsOf: wavURL)
    } catch {
        eprint("ОШИБКА: не удалось прочитать \(wavURL.path): \(error)")
        if let t = tempWavURL { try? fm.removeItem(at: t) }
        return 1
    }
    // WAV data is loaded; the converted temp file is no longer needed.
    if let t = tempWavURL { try? fm.removeItem(at: t) }

    let config: AppConfig
    do {
        config = try AppConfig.load(from: nil)
    } catch {
        eprint("ОШИБКА: \(error)")
        return 1
    }

    // Активный провайдер = адаптер запроса (как в DictatorAgent): при пустом
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
        byetCookieProvider: config.transport == "relay" || config.transport == "infinityfree"
            ? ByetCookieProvider.makeForInfinityFree(baseURL: config.baseURL)
            : nil,
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
            if jsonFlag {
                do {
                    try result.rawData.write(to: rawURL, options: .atomic)
                    print("Сохранено: \(rawURL.path)")
                } catch {
                    eprint("Не удалось сохранить \(rawURL.path): \(error)")
                }
            }
            exit(0)
        } catch {
            eprint("ОШИБКА: \(error)")
            exit(1)
        }
    }

    // Keep the main thread alive until the async transcribe finishes (it exits above).
    RunLoop.main.run()
    return 1 // unreachable
}

func cmdLogs() -> Int32 {
    let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Dictation/agent.log")
    guard let content = try? String(contentsOf: logURL, encoding: .utf8) else {
        print("Лог не найден")
        return 1
    }
    let body = content.components(separatedBy: .newlines).suffix(50).joined(separator: "\n")
    if !body.isEmpty { print(body) }
    return 0
}

// MARK: - Последний текст и retry другим провайдером

/// `dictatorctl last`: последний распознанный текст из маркера LAST_TEXT в логе
/// агента (пишется при каждой успешной вставке, включая retry).
func cmdLast() -> Int32 {
    let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Dictation/agent.log")
    guard let content = try? String(contentsOf: logURL, encoding: .utf8) else {
        print("Лог агента не найден")
        return 1
    }
    let marker = "LAST_TEXT: "
    let matches = content.components(separatedBy: .newlines)
        .compactMap { line -> String? in
            guard let range = line.range(of: marker) else { return nil }
            return String(line[range.upperBound...])
        }
    guard let last = matches.last, !last.isEmpty else {
        print("Пока нет распознанного текста (маркер LAST_TEXT не найден в логе)")
        return 1
    }
    print(last)
    return 0
}

/// `dictatorctl retry <provider>`: просит агента повторить распознавание
/// последнего WAV (он у агента в памяти) указанным провайдером. Через
/// DistributedNotificationCenter — вставку выполняет САМ агент (у него уже
/// есть право «Доступность» и знакомый путь вставки/ревью).
func cmdRetry(_ name: String) -> Int32 {
    let providers: [AppConfig.Provider]
    do {
        providers = try AppConfig.loadProvidersOnly(from: nil).providers
    } catch {
        eprint("ОШИБКА: \(error)")
        return 1
    }
    guard let provider = providers.first(where: { $0.id == name }) else {
        let available = providers.map { $0.id }
        eprint("ОШИБКА: провайдер '\(name)' не найден. Доступные: \(available.joined(separator: ", "))")
        return 2
    }
    let target = "\(guiDomain)/\(agentServiceName)"
    let running = runProcess("/bin/launchctl", ["print", target]).status == 0
    guard running else {
        eprint("ОШИБКА: агент не запущен — последний WAV хранится в памяти агента. Запустите агент (`dictatorctl start`) и повторите.")
        return 1
    }
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.dictation.agent.retryRequest"),
        object: nil,
        userInfo: ["provider": name],
        deliverImmediately: true
    )
    let display = provider.name.isEmpty ? provider.id : provider.name
    print("Retry отправлен агенту: повторное распознавание последней записи провайдером '\(display) [\(provider.id)]'")
    return 0
}

/// Список id провайдеров одной строкой (подсказка для usage retry).
func providerNamesText() -> String {
    let ids = (try? AppConfig.loadProvidersOnly(from: nil).providers.map { $0.id }) ?? []
    return ids.isEmpty ? "(нет секций [providers.X] в конфиге)" : ids.joined(separator: ", ")
}

// MARK: - Usage

let usage = """
Использование: dictatorctl <команда> [аргументы]

Команды:
  start                            Установить и запустить LaunchAgent
  stop                             Остановить LaunchAgent
  status                           Статус агента (launchctl + pgrep — pid процесса)
  config                           Показать конфиг (секреты маскируются: abcd***wxyz)
    config init [--force]          Создать шаблон config.toml (chmod 600; существующий
                                   файл без --force перезаписывается только после
                                   подтверждения в терминале)
    config set-key ПРОВАЙДЕР [КЛЮЧ] [--stdin]
                                   Записать api_key в секцию [providers.ПРОВАЙДЕР]
                                   (chmod 600; КЛЮЧ не указан — ввод с клавиатуры или
                                   stdin при --stdin/пайпе; предупреждение, если задан
                                   DICTATION_API_KEY)
    config path                    Путь к конфиг-файлу (алиас config --path)
    config --show-file             Содержимое конфиг-файла с маскировкой секретов
  provider list                    Список STT-провайдеров из config.toml (* — активный)
    provider use ИМЯ [--no-restart]
    provider set ИМЯ [--no-restart] (алиас use)
                                   Сделать ИМЯ активным провайдером: правка
                                   active_provider в config.toml, chmod 600 и
                                   перезапуск агента (--no-restart без перезапуска)
    provider status                Активный провайдер + статус агента
    provider show ИМЯ              Подробно о провайдере (секреты маскируются)
  routing [show]                   Маршрутизация STT по ролям ([routing]):
                                   segment/final + их effective (фолбэк на active)
    routing set РОЛЬ ИМЯ [--no-restart]
                                   РОЛЬ = segment (сегменты пошаговой диктовки)
                                   или final (проход по всей записи); ИМЯ среди
                                   [providers.X]; правка config.toml (chmod 600),
                                   перезапуск агента (--no-restart без перезапуска)
    routing unset РОЛЬ [--no-restart]
                                   Очистить роль — фолбэк на активного провайдера
  transcribe ФАЙЛ [--json]         Разовая расшифровка аудиофайла
                                   (не-WAV конвертируется через afconvert; с --json
                                   сырой ответ сохраняется в transcription_raw.json рядом с ФАЙЛ)
  retry ИМЯ                        Повторить распознавание последней записи другим
                                   провайдером (агент хранит последний WAV в памяти;
                                   вставку выполняет сам агент)
  last                             Показать последний распознанный текст (маркер LAST_TEXT)
  logs                             Последние 50 строк лога агента
  help                             Показать эту справку
"""

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())

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
        eprint("Использование: dictatorctl retry ИМЯ")
        eprint("Доступные провайдеры: \(providerNamesText())")
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
    eprint("Неизвестная команда: \(command)")
    print(usage)
    exit(1)
}