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

func findPlistPath() -> URL? {
    let name = "com.dima.altdictation.plist"
    // 1) Explicit override via environment.
    if let env = ProcessInfo.processInfo.environment["ALTDICTATION_PLIST"] {
        let url = URL(fileURLWithPath: env)
        if FileManager.default.fileExists(atPath: url.path) { return url }
    }
    // 2) Project Resources directory (compile-time source path and hard-coded path).
    let fromSourceDir = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()          // Sources/dictatorctl
        .deletingLastPathComponent()          // Sources
        .deletingLastPathComponent()          // project root
        .appendingPathComponent("Resources/\(name)")
    let candidates: [URL] = [
        fromSourceDir,
        URL(fileURLWithPath: "/Users/dima/projects/dictation/Resources/\(name)"),
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

    guard let source = findPlistPath() else {
        eprint("Не найден com.dima.altdictation.plist (ожидается в Resources проекта или укажите ALTDICTATION_PLIST)")
        return 1
    }

    let dest = launchAgentsDir.appendingPathComponent("com.dima.altdictation.plist")
    do {
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.copyItem(at: source, to: dest)
    } catch {
        eprint("Не удалось установить plist: \(error)")
        return 1
    }

    // Идемпотентность: если агент уже загружен — выйти, не вызывая bootstrap/load повторно.
    let alreadyLoaded = runProcess("/bin/launchctl", ["print", "\(guiDomain)/com.dima.altdictation"])
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
    let target = "\(guiDomain)/com.dima.altdictation"
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
    let printResult = runProcess("/bin/launchctl", ["print", "\(guiDomain)/com.dima.altdictation"])
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

    return running ? 0 : 1
}

func maskAPIKey(in content: String) -> String {
    var lines: [String] = []
    for line in content.components(separatedBy: .newlines) {
        let keyPart = line.split(separator: "=", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if keyPart == "api_key" || keyPart == "proxy_key" {
            lines.append("\(keyPart) = \"***\"")
        } else {
            lines.append(line)
        }
    }
    return lines.joined(separator: "\n")
}

func cmdConfig(_ args: [String]) -> Int32 {
    let path = AppConfig.defaultPath()
    let fm = FileManager.default
    let exists = fm.fileExists(atPath: path)

    if args.contains("--path") {
        print(path)
        return 0
    }

    var config: AppConfig
    do {
        config = try AppConfig.load(from: nil)
    } catch {
        eprint("ОШИБКА: \(error)")
        return 1
    }

    if args.contains("--show-file") {
        if exists {
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
                eprint("Не удалось прочитать конфиг: \(path)")
                return 1
            }
            print(maskAPIKey(in: content))
        } else {
            print("Конфиг не найден, используется defaults (\(path))")
        }
        return 0
    }

    print("path: \(path)")
    if !exists {
        print("Конфиг не найден, используется defaults (\(path))")
    }
    print("base_url: \(config.baseURL)")
    print("model: \(config.model)")
    print("timeout_seconds: \(config.timeoutSeconds)")
    print("sounds_enabled: \(config.soundsEnabled)")
    print("double_alt_max_interval: \(config.doubleAltMaxInterval)")
    print("log_level: \(config.logLevel)")
    print("language: \(config.language)")
    print("api_key: ***")
    print("proxy_key: ***")
    return 0
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
            print("    api_key: \(p.apiKey.isEmpty ? "(пусто)" : "***")")
            if let keyFile = p.apiKeyFile {
                print("    api_key_file: \(keyFile)")
            }
            print("    proxy_key: \(p.proxyKey.isEmpty ? "(пусто)" : "***")")
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
    if args.contains("--no-restart") {
        print("Агент не перезапущен (--no-restart)")
    } else {
        let target = "\(guiDomain)/com.dima.altdictation"
        let kick = runProcess("/bin/launchctl", ["kickstart", "-k", target])
        if kick.status == 0 {
            print("Агент перезапущен")
        } else {
            let msg = kick.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            eprint("Агент не перезапущен (запустите `dictatorctl start`): \(msg.isEmpty ? kick.stdout : msg)")
        }
    }
    return 0
}

func providerStatus() -> Int32 {
    let printResult = runProcess("/bin/launchctl", ["print", "\(guiDomain)/com.dima.altdictation"])
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
            print("api_key: ***")
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
            print("proxy_key: ***")
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
    case "use":
        guard let name = args.dropFirst().first else {
            eprint("Использование: dictatorctl provider use <имя> [--no-restart]")
            return 1
        }
        return providerUse(name, Array(args.dropFirst()))
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

    let transcriber = Transcriber(
        baseURL: config.baseURL,
        model: config.model,
        apiKey: config.apiKey,
        proxyKey: config.proxyKey,
        language: config.language,
        timeout: config.timeoutSeconds,
        logLevel: config.logLevel
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
    let target = "\(guiDomain)/com.dima.altdictation"
    let running = runProcess("/bin/launchctl", ["print", target]).status == 0
    guard running else {
        eprint("ОШИБКА: агент не запущен — последний WAV хранится в памяти агента. Запустите агент (`dictatorctl start`) и повторите.")
        return 1
    }
    DistributedNotificationCenter.default().postNotificationName(
        Notification.Name("com.dima.altdictation.retryRequest"),
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
  config                           Показать конфиг (api_key маскируется как ***)
    config --path                  Только путь к конфиг-файлу
    config --show-file             Содержимое конфиг-файла с маскировкой api_key
  provider list                    Список STT-провайдеров из config.toml (* — активный)
    provider use ИМЯ [--no-restart]
                                   Сделать ИМЯ активным провайдером: правка
                                   active_provider в config.toml, chmod 600 и
                                   перезапуск агента (--no-restart без перезапуска)
    provider status                Активный провайдер + статус агента
    provider show ИМЯ              Подробно о провайдере (секреты маскируются)
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