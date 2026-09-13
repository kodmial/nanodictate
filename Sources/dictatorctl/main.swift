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
        timeout: config.timeoutSeconds
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
  transcribe ФАЙЛ [--json]         Разовая расшифровка аудиофайла
                                   (не-WAV конвертируется через afconvert; с --json
                                   сырой ответ сохраняется в transcription_raw.json рядом с ФАЙЛ)
  logs                             Последние 50 строк лога агента
  help                             Показать эту справку
"""

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())

guard let command = args.first?.lowercased() else {
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
case "transcribe":
    exit(cmdTranscribe(Array(args.dropFirst())))
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