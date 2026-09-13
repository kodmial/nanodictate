import Foundation

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
        language: "ru"
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

    // MARK: Errors

    public enum AppConfigError: Error, CustomStringConvertible {
        case invalidLine(Int, String)
        case cannotReadKeyFile(String, Error?)

        public var description: String {
            switch self {
            case .invalidLine(let line, let text):
                return "Invalid config at line \(line): \(text)"
            case .cannotReadKeyFile(let path, let underlying):
                let msg = underlying?.localizedDescription ?? "unknown error"
                return "Cannot read API key file '\(path)': \(msg)"
            }
        }
    }

    // MARK: - TOML-like parser

    public static func parse(_ content: String) throws -> AppConfig {
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

        let lines = content.components(separatedBy: .newlines)
        for (index, rawLine) in lines.enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // Skip empty lines and comments
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("[") {
                continue
            }
            guard let eqIndex = line.firstIndex(of: "=") else {
                throw AppConfigError.invalidLine(index + 1, rawLine)
            }
            let key = line[line.startIndex..<eqIndex]
                .trimmingCharacters(in: .whitespaces)
            let valuePart = line[line.index(after: eqIndex)...]
                .trimmingCharacters(in: .whitespaces)

            switch key {
            case "base_url":
                baseURL = try parseString(valuePart, line: index + 1, rawLine: rawLine)
            case "model":
                model = try parseString(valuePart, line: index + 1, rawLine: rawLine)
            case "api_key":
                apiKey = try parseString(valuePart, line: index + 1, rawLine: rawLine)
            case "api_key_file":
                apiKeyFile = try parseStringOptional(valuePart, line: index + 1, rawLine: rawLine)
            case "proxy_key":
                proxyKey = try parseString(valuePart, line: index + 1, rawLine: rawLine)
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
            default:
                // Unknown key — ignore
                break
            }
        }

        return AppConfig(
            baseURL: baseURL,
            model: model,
            apiKey: apiKey,
            apiKeyFile: apiKeyFile,
            proxyKey: proxyKey,
            timeoutSeconds: timeoutSeconds,
            doubleAltMaxInterval: doubleAltMaxInterval,
            soundsEnabled: soundsEnabled,
            logLevel: logLevel,
            language: language
        )
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

    // MARK: Key file reader

    private static func readAPIKey(from path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path) else {
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
}
