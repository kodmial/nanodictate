import Foundation

// MARK: - InsertMethod

/// Способ вставки распознанного текста (ключ конфига `insert_method`).
public enum InsertMethod: String, Equatable {
    /// Прямая эмуляция клавиатуры CGEvent (поведение по умолчанию).
    case cgevent = "cgevent"
    /// Через буфер обмена + Cmd+V (прежний буфер восстанавливается).
    case clipboard = "clipboard"
}

// MARK: - AppConfig

public struct AppConfig: Equatable {

    public var baseURL: String
    public var model: String
    public var apiKey: String
    public var apiKeyFile: String?
    public var proxyKey: String
    public var timeoutSeconds: Double
    public var doubleAltMaxInterval: Double
    public var soundsEnabled: Bool
    public var logLevel: String
    public var language: String

    // MARK: Быстрые UX-победы

    /// Окно undo последней вставки (сек): двойной Alt в пределах этого окна
    /// после успешной вставки стирает вставленный текст (ключ `undo_max_interval`).
    public var undoMaxInterval: Double
    /// Играть ли звук отката вставки (ключ `undo_sound_enabled`).
    public var undoSoundEnabled: Bool

    // MARK: Провайдеры STT

    /// Имя активной секции `[providers.X]` (пусто — не задан: legacy-конфиг).
    public var activeProvider: String

    /// Секции `[providers.X]` в порядке их появления в конфиге.
    public var providers: [Provider]

    /// Имена секций провайдеров (id) в порядке появления.
    public var providerNames: [String] { providers.map { $0.id } }

    // MARK: UX-опции (средние улучшения)

    /// Явный список провайдеров в порядке failover (топ-уровневый ключ
    /// `providers = ["groq", "gigaam"]`). Пусто — порядок секций `[providers.X]`.
    public var providersOrder: [String]

    /// Автоматический failover на следующий провайдер при сетевой/серверной
    /// ошибке основного (ключ `auto_failover`; дефолт false — прод-поведение).
    public var autoFailover: Bool

    /// Способ вставки распознанного текста (ключ `insert_method`; дефолт cgevent).
    public var insertMethod: InsertMethod

    /// Ревью перед вставкой: показать текст в stdout и ждать Enter/Esc
    /// (ключ `review_before_insert`; дефолт false — прод-поведение).
    public var reviewBeforeInsert: Bool

    // MARK: Failover-порядок

    /// Имена провайдеров в порядке failover: явный список `providers` из конфига,
    /// либо порядок появления секций `[providers.X]`.
    public var failoverOrderNames: [String] {
        providersOrder.isEmpty ? providerNames : providersOrder
    }

    /// Провайдеры для failover в порядке очереди, без уже вызванного (`failedID`).
    /// Дубли в списке схлопываются, неизвестные имена пропускаются.
    public func failoverProviders(excluding failedID: String?) -> [Provider] {
        var seen = Set<String>()
        var result: [Provider] = []
        for name in failoverOrderNames {
            guard let provider = providers.first(where: { $0.id == name }),
                  seen.insert(provider.id).inserted else { continue }
            if provider.id == failedID { continue }
            result.append(provider)
        }
        return result
    }

    // MARK: Defaults

    public static let defaults = AppConfig(
        baseURL: "https://gpt.mwsapis.ru/projects/project-ko-dmi-al/openai/v1/audio/transcriptions",
        model: "gigaam-v3",
        apiKey: "",
        apiKeyFile: nil,
        proxyKey: "",
        timeoutSeconds: 120,
        doubleAltMaxInterval: 0.4,
        soundsEnabled: true,
        logLevel: "info",
        language: "ru",
        undoMaxInterval: 2.0,
        undoSoundEnabled: true,
        activeProvider: "",
        providers: [],
        providersOrder: [],
        autoFailover: false,
        insertMethod: .cgevent,
        reviewBeforeInsert: false
    )

    // MARK: Public API

    public static func defaultPath() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.config/dictation/config.toml"
    }

    /// Load config from a TOML-like file.
    /// - If `path` is nil, uses `defaultPath()`.
    /// - If the file does not exist, returns default config (no error).
    /// - If the file exists but cannot be parsed, throws `AppConfigError`.
    public static func load(from path: String?) throws -> AppConfig {
        let resolvedPath = path ?? defaultPath()
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return defaults
        }
        let content = try String(contentsOfFile: resolvedPath, encoding: .utf8)
        var config = try parse(content)
        // Resolve apiKey from apiKeyFile if apiKey is empty
        if config.apiKey.isEmpty, let keyFile = config.apiKeyFile {
            config.apiKey = Self.readAPIKey(from: keyFile)
        }
        return config
    }

    // MARK: Провайдер

    /// Секция `[providers.X]` в конфиге. `id` — имя секции.
    public struct Provider: Equatable {
        /// Имя секции: `groq` из `[providers.groq]`.
        public var id: String
        /// Отображаемое имя (ключ `name` в секции; пусто — не задан).
        public var name: String
        public var baseURL: String
        public var model: String
        public var apiKey: String
        public var apiKeyFile: String?
        public var proxyKey: String

        public static func withDefaults(id: String) -> Provider {
            Provider(
                id: id,
                name: "",
                baseURL: AppConfig.defaults.baseURL,
                model: AppConfig.defaults.model,
                apiKey: "",
                apiKeyFile: nil,
                proxyKey: ""
            )
        }
    }

    // MARK: Errors

    public enum AppConfigError: Error, CustomStringConvertible {
        case invalidLine(Int, String)
        case invalidValue(String, String, Int)
        case cannotReadKeyFile(String, Error?)
        /// Две секции с одним именем: `[providers.groq]` дважды.
        case duplicateProvider(String)
        /// `active_provider` указывает на отсутствующую секцию.
        case activeProviderNotFound(active: String, available: [String])
        /// Одновременно legacy-ключи и секции, но без `active_provider`.
        case ambiguousLegacyAndProviders
        case cannotWriteConfig(String, Error?)

        public var description: String {
            switch self {
            case .invalidLine(let line, let text):
                return "Invalid config at line \(line): \(text)"
            case .invalidValue(let key, let value, let line):
                return "Invalid value for key '\(key)' at line \(line): '\(value)'"
            case .cannotReadKeyFile(let path, let underlying):
                let msg = underlying?.localizedDescription ?? "unknown error"
                return "Cannot read API key file '\(path)': \(msg)"
            case .duplicateProvider(let id):
                return "Duplicate provider section: [providers.\(id)]"
            case .activeProviderNotFound(let active, let available):
                let list = available.isEmpty ? "(нет провайдеров)" : available.joined(separator: ", ")
                return "active_provider = \"\(active)\" not found. Available providers: \(list)"
            case .ambiguousLegacyAndProviders:
                return "Ambiguous config: both legacy keys (base_url/model/api_key...) and [providers.X] sections are present, but active_provider is not set. Set active_provider."
            case .cannotWriteConfig(let path, let underlying):
                let msg = underlying?.localizedDescription ?? "unknown error"
                return "Cannot write config '\(path)': \(msg)"
            }
        }
    }

    // MARK: - TOML-like parser

    public static func parse(_ content: String) throws -> AppConfig {
        try parseContent(content, resolveProvider: true)
    }

    /// Разбор ТОЛЬКО провайдеров без резолва `active_provider`: не бросает ошибок
    /// выбора (stale active_provider, неоднозначность). Нужен меню и CLI, где
    /// сломанный выбор надо чинить, а не падать на загрузке.
    public static func parseProvidersOnly(_ content: String) throws -> (activeProvider: String, providers: [Provider]) {
        let config = try parseContent(content, resolveProvider: false)
        return (config.activeProvider, config.providers)
    }

    /// Как `load(from:)`, но возвращает только провайдеров (без резолва) —
    /// для меню/CLI, которые должны работать даже при сломанном active_provider.
    public static func loadProvidersOnly(from path: String?) throws -> (activeProvider: String, providers: [Provider]) {
        let resolvedPath = path ?? defaultPath()
        guard FileManager.default.fileExists(atPath: resolvedPath) else {
            return ("", [])
        }
        let content = try String(contentsOfFile: resolvedPath, encoding: .utf8)
        return try parseProvidersOnly(content)
    }

    private static func parseContent(_ content: String, resolveProvider: Bool) throws -> AppConfig {
        var baseURL: String = defaults.baseURL
        var model: String = defaults.model
        var apiKey: String = defaults.apiKey
        var apiKeyFile: String? = defaults.apiKeyFile
        var proxyKey: String = defaults.proxyKey
        var timeoutSeconds: Double = defaults.timeoutSeconds
        var doubleAltMaxInterval: Double = defaults.doubleAltMaxInterval
        var soundsEnabled: Bool = defaults.soundsEnabled
        var logLevel: String = defaults.logLevel
        var language: String = defaults.language
        var undoMaxInterval: Double = defaults.undoMaxInterval
        var undoSoundEnabled: Bool = defaults.undoSoundEnabled

        var activeProvider: String = ""
        var providers: [Provider] = []

        // Новые UX-опции (средние улучшения): дефолт = прод-поведение.
        var providersOrder: [String] = defaults.providersOrder
        var autoFailover: Bool = defaults.autoFailover
        var insertMethod: InsertMethod = defaults.insertMethod
        var reviewBeforeInsert: Bool = defaults.reviewBeforeInsert

        // true, если на верхнем уровне встречен хотя бы один legacy-ключ STT
        // (base_url/model/api_key/api_key_file/proxy_key) — для детекта неоднозначности.
        var legacySTTKeysSeen = false
        // Имя текущей секции [providers.X] (nil — верхний уровень).
        var currentProviderID: String?
        // true внутри непровайдерской секции ([api] и т.п.) — все ключи пропускаем,
        // чтобы они не утекали в top-level.
        var insideForeignSection = false

        let lines = content.components(separatedBy: .newlines)
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Skip empty lines and comments
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            // Section header: [providers.X] или любая другая секция.
            if line.hasPrefix("[") {
                // Отрезаем возможный хвостовой комментарий: "[providers.groq] # comment".
                var headerLine = line
                if let hashIndex = line.firstIndex(of: "#") {
                    headerLine = String(line[..<hashIndex]).trimmingCharacters(in: .whitespaces)
                }
                guard headerLine.hasSuffix("]") else {
                    throw AppConfigError.invalidLine(index + 1, rawLine)
                }
                var header = String(headerLine.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if header.hasPrefix("\""), header.hasSuffix("\"") {
                    header = String(header.dropFirst().dropLast())
                }
                let providersPrefix = "providers."
                if header.hasPrefix(providersPrefix) {
                    let providerID = String(header.dropFirst(providersPrefix.count)).trimmingCharacters(in: .whitespaces)
                    guard !providerID.isEmpty else {
                        throw AppConfigError.invalidLine(index + 1, rawLine)
                    }
                    guard !providers.contains(where: { $0.id == providerID }) else {
                        throw AppConfigError.duplicateProvider(providerID)
                    }
                    providers.append(Provider.withDefaults(id: providerID))
                    currentProviderID = providerID
                    insideForeignSection = false
                } else {
                    // Чужая секция: ключи внутри неё игнорируем (регресс-гард).
                    currentProviderID = nil
                    insideForeignSection = true
                }
                continue
            }

            // Ключи внутри непровайдерских секций в top-level не читаем.
            if insideForeignSection { continue }

            guard let eqIndex = line.firstIndex(of: "=") else {
                throw AppConfigError.invalidLine(index + 1, rawLine)
            }
            let key = line[line.startIndex..<eqIndex]
                .trimmingCharacters(in: .whitespaces)
            let valuePart = line[line.index(after: eqIndex)...]
                .trimmingCharacters(in: .whitespaces)

            // Ключ внутри секции [providers.X].
            if let providerID = currentProviderID,
               let providerIndex = providers.firstIndex(where: { $0.id == providerID }) {
                switch key {
                case "name":
                    providers[providerIndex].name = try parseString(valuePart, line: index + 1, rawLine: rawLine)
                case "base_url":
                    providers[providerIndex].baseURL = try parseString(valuePart, line: index + 1, rawLine: rawLine)
                case "model":
                    providers[providerIndex].model = try parseString(valuePart, line: index + 1, rawLine: rawLine)
                case "api_key":
                    providers[providerIndex].apiKey = try parseString(valuePart, line: index + 1, rawLine: rawLine)
                case "api_key_file":
                    providers[providerIndex].apiKeyFile = try parseStringOptional(valuePart, line: index + 1, rawLine: rawLine)
                case "proxy_key":
                    providers[providerIndex].proxyKey = try parseString(valuePart, line: index + 1, rawLine: rawLine)
                default:
                    // Неизвестный ключ внутри секции — игнорируем
                    break
                }
                continue
            }

            switch key {
            case "base_url":
                baseURL = try parseString(valuePart, line: index + 1, rawLine: rawLine)
                legacySTTKeysSeen = true
            case "model":
                model = try parseString(valuePart, line: index + 1, rawLine: rawLine)
                legacySTTKeysSeen = true
            case "api_key":
                apiKey = try parseString(valuePart, line: index + 1, rawLine: rawLine)
                legacySTTKeysSeen = true
            case "api_key_file":
                apiKeyFile = try parseStringOptional(valuePart, line: index + 1, rawLine: rawLine)
                legacySTTKeysSeen = true
            case "proxy_key":
                proxyKey = try parseString(valuePart, line: index + 1, rawLine: rawLine)
                legacySTTKeysSeen = true
            case "active_provider":
                activeProvider = try parseString(valuePart, line: index + 1, rawLine: rawLine)
            case "timeout_seconds":
                timeoutSeconds = try parseDouble(valuePart, line: index + 1, rawLine: rawLine)
            case "double_alt_max_interval":
                doubleAltMaxInterval = try parseDouble(valuePart, line: index + 1, rawLine: rawLine)
            case "sounds_enabled":
                soundsEnabled = try parseBool(valuePart, line: index + 1, rawLine: rawLine)
            case "log_level":
                logLevel = try parseString(valuePart, line: index + 1, rawLine: rawLine)
            case "language":
                language = try parseString(valuePart, line: index + 1, rawLine: rawLine)
            case "undo_max_interval":
                undoMaxInterval = try parseDouble(valuePart, line: index + 1, rawLine: rawLine)
            case "undo_sound_enabled":
                undoSoundEnabled = try parseBool(valuePart, line: index + 1, rawLine: rawLine)
            case "providers":
                providersOrder = try parseStringArray(valuePart, line: index + 1, rawLine: rawLine)
            case "auto_failover":
                autoFailover = try parseBool(valuePart, line: index + 1, rawLine: rawLine)
            case "insert_method":
                let method = try parseString(valuePart, line: index + 1, rawLine: rawLine)
                switch method {
                case InsertMethod.cgevent.rawValue:
                    insertMethod = .cgevent
                case InsertMethod.clipboard.rawValue:
                    insertMethod = .clipboard
                default:
                    throw AppConfigError.invalidValue(key, valuePart, index + 1)
                }
            case "review_before_insert":
                reviewBeforeInsert = try parseBool(valuePart, line: index + 1, rawLine: rawLine)
            default:
                // Unknown key — ignore
                break
            }
        }

        var config = AppConfig(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            apiKeyFile: apiKeyFile,
            proxyKey: proxyKey,
            timeoutSeconds: timeoutSeconds,
            doubleAltMaxInterval: doubleAltMaxInterval,
            soundsEnabled: soundsEnabled,
            logLevel: logLevel,
            language: language,
            undoMaxInterval: undoMaxInterval,
            undoSoundEnabled: undoSoundEnabled,
            activeProvider: activeProvider,
            providers: providers,
            providersOrder: providersOrder,
            autoFailover: autoFailover,
            insertMethod: insertMethod,
            reviewBeforeInsert: reviewBeforeInsert
        )

        if resolveProvider {
            try resolveActiveProvider(in: &config, legacySTTKeysSeen: legacySTTKeysSeen)
        }
        return config
    }

    /// Правила выбора активного провайдера:
    /// - active_provider задан и существует → его поля заполняют effective-поля;
    /// - active_provider задан, но секции нет → ошибка со списком доступных;
    /// - только секции, без active_provider → первый по порядку;
    /// - legacy-ключи + секции без active_provider → ошибка «неоднозначно»;
    /// - только legacy → прежнее поведение (ничего не трогаем).
    private static func resolveActiveProvider(in config: inout AppConfig, legacySTTKeysSeen: Bool) throws {
        if !config.activeProvider.isEmpty {
            guard let selected = config.providers.first(where: { $0.id == config.activeProvider }) else {
                throw AppConfigError.activeProviderNotFound(
                    active: config.activeProvider,
                    available: config.providers.map { $0.id }
                )
            }
            apply(selected, to: &config)
        } else if !config.providers.isEmpty {
            if legacySTTKeysSeen {
                throw AppConfigError.ambiguousLegacyAndProviders
            }
            apply(config.providers[0], to: &config)
        }
        // else: чистый legacy-конфиг — ровно прежнее поведение.
    }

    private static func apply(_ provider: Provider, to config: inout AppConfig) {
        config.baseURL = provider.baseURL
        config.model = provider.model
        config.apiKey = provider.apiKey
        config.apiKeyFile = provider.apiKeyFile
        config.proxyKey = provider.proxyKey
    }

    // MARK: Value parsers

    private static func parseString(_ raw: String, line: Int, rawLine: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2,
              trimmed.hasPrefix("\""),
              trimmed.hasSuffix("\"") else {
            throw AppConfigError.invalidLine(line, rawLine)
        }
        let inner = trimmed.index(trimmed.startIndex, offsetBy: 1)
        let end = trimmed.index(trimmed.endIndex, offsetBy: -1)
        return String(trimmed[inner..<end])
    }

    private static func parseStringOptional(_ raw: String, line: Int, rawLine: String) throws -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed == "" || trimmed == "\"\"" {
            return nil
        }
        return try parseString(trimmed, line: line, rawLine: rawLine)
    }

    private static func parseDouble(_ raw: String, line: Int, rawLine: String) throws -> Double {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard let value = Double(trimmed) else {
            throw AppConfigError.invalidLine(line, rawLine)
        }
        return value
    }

    private static func parseBool(_ raw: String, line: Int, rawLine: String) throws -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed == "true" { return true }
        if trimmed == "false" { return false }
        throw AppConfigError.invalidLine(line, rawLine)
    }

    /// Разбор массива строк: `providers = ["groq", "gigaam"]`.
    /// Допускает пробелы между элементами и после запятых.
    private static func parseStringArray(_ raw: String, line: Int, rawLine: String) throws -> [String] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
            throw AppConfigError.invalidLine(line, rawLine)
        }
        let inner = trimmed.dropFirst().dropLast()
        let result = inner
            .components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        var values: [String] = []
        for item in result {
            values.append(try parseString(item, line: line, rawLine: rawLine))
        }
        return values
    }

    // MARK: Key file reader

    private static func readAPIKey(from path: String) -> String {
        // Раскрываем "~": api_key_file = "~/.config/dictation/keys/..."
        let expandedPath = (path as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: expandedPath) else {
            return ""
        }
        guard let content = String(data: data, encoding: .utf8) else {
            return ""
        }
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                // Strip surrounding quotes if present
                if trimmed.count >= 2,
                   trimmed.hasPrefix("\""),
                   trimmed.hasSuffix("\"") {
                    let inner = trimmed.index(trimmed.startIndex, offsetBy: 1)
                    let end = trimmed.index(trimmed.endIndex, offsetBy: -1)
                    return String(trimmed[inner..<end])
                }
                return trimmed
            }
        }
        return ""
    }

    // MARK: Запись ключей конфига (точечная правка, byte-preserving)

    /// Точечная правка строки `key = value` в конфиг-файле.
    /// Не сериализует весь файл — иначе потеряются комментарии. Строка ищется
    /// на верхнем уровне (вне секций), значение в кавычках заменяется точечно
    /// (хвостовой комментарий сохраняется), без кавычек — заменяется всё после
    /// `=`. Если ключа нет — добавляется в конец. После атомарной записи
    /// возвращает права 0600 (atomic-запись сбрасывает их на umask).
    ///
    /// `value` — готовая литеральная форма значения: `"gigaam"` для строк,
    /// `true`/`false` для bool, `2` для чисел.
    public static func writeKeyValue(key: String, value: String, to path: String) throws {
        let fm = FileManager.default
        var content = ""
        if fm.fileExists(atPath: path), let existing = try? String(contentsOfFile: path, encoding: .utf8) {
            content = existing
        }

        var replaced = false
        let lines = content.components(separatedBy: "\n").map { line -> String in
            guard !replaced else { return line }
            let stripped = line.drop(while: { $0 == " " || $0 == "\t" })
            guard let eqIndex = stripped.firstIndex(of: "=") else { return line }
            let lineKey = stripped[stripped.startIndex..<eqIndex].trimmingCharacters(in: .whitespaces)
            guard lineKey == key else { return line }
            let valueStart = stripped.index(after: eqIndex)
            let newLine: String
            if let open = line[valueStart...].firstIndex(of: "\""),
               let close = line[line.index(after: open)...].firstIndex(of: "\"") {
                // Точечная замена значения в кавычках; хвост строки (комментарий) сохраняем.
                let prefix = String(line[..<open])
                let suffix = String(line[line.index(after: close)...])
                newLine = prefix + value + suffix
            } else {
                // Значение без кавычек (bool/число): заменяем всё после "=".
                let leading = String(line[..<valueStart])
                newLine = leading.trimmingCharacters(in: .whitespaces) + " " + value
            }
            replaced = true
            return newLine
        }

        var result = lines.joined(separator: "\n")
        if !replaced {
            // Строка не найдена — добавляем в конец.
            if !result.isEmpty && !result.hasSuffix("\n") {
                result += "\n"
            }
            result += "\(key) = \(value)\n"
        }

        do {
            try result.data(using: .utf8)!.write(to: URL(fileURLWithPath: path), options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        } catch {
            throw AppConfigError.cannotWriteConfig(path, error)
        }
    }

    /// Точечная правка строки `active_provider = "…"` в конфиг-файле (путь по умолчанию).
    public static func writeActiveProvider(name: String) throws {
        try writeActiveProvider(name: name, to: defaultPath())
    }

    public static func writeActiveProvider(name: String, to path: String) throws {
        try writeKeyValue(key: "active_provider", value: "\"\(name)\"", to: path)
    }

    /// Точечная правка `review_before_insert = true|false`.
    public static func writeReviewBeforeInsert(value: Bool, to path: String? = nil) throws {
        try writeKeyValue(key: "review_before_insert", value: value ? "true" : "false", to: path ?? defaultPath())
    }
}
