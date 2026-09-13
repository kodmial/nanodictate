import Foundation
@testable import DictationCore

final class ConfigTests: XCTestCase {

    // MARK: - Existing

    @objc func testParseBasic() throws {
        let content = """
        base_url = "https://x"
        model = "gigaam-v3"
        api_key = "sekret"
        timeout_seconds = 90
        """.trimmingCharacters(in: .newlines) + "\n"

        let config = try AppConfig.parse(content)

        XCTAssertEqual(config.baseURL, "https://x")
        XCTAssertEqual(config.model, "gigaam-v3")
        XCTAssertEqual(config.apiKey, "sekret")
        XCTAssertEqual(config.timeoutSeconds, 90)
    }

    @objc func testDefaultPath() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(AppConfig.defaultPath(), "\(home)/.config/dictation/config.toml")
    }

    // MARK: - Full TOML with all keys

    @objc func testParseFullTOML() throws {
        let content = """
        base_url = "https://custom.api/v1"
        model = "custom-model"
        api_key = "my-key"
        api_key_file = "/some/path"
        proxy_key = "test-proxy-123"
        timeout_seconds = 60
        double_alt_max_interval = 0.8
        sounds_enabled = false
        log_level = "debug"
        language = "ru"

        [api]
        """.trimmingCharacters(in: .newlines) + "\n"

        let config = try AppConfig.parse(content)

        XCTAssertEqual(config.baseURL, "https://custom.api/v1")
        XCTAssertEqual(config.model, "custom-model")
        XCTAssertEqual(config.apiKey, "my-key")
        XCTAssertEqual(config.apiKeyFile, "/some/path")
        XCTAssertEqual(config.proxyKey, "test-proxy-123")
        XCTAssertEqual(config.timeoutSeconds, 60)
        XCTAssertEqual(config.doubleAltMaxInterval, 0.8)
        XCTAssertFalse(config.soundsEnabled)
        XCTAssertEqual(config.logLevel, "debug")
        XCTAssertEqual(config.language, "ru")
    }

    // MARK: - proxy_key

    @objc func testParseProxyKey() throws {
        let content = """
        proxy_key = "test-proxy-123"
        """
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.proxyKey, "test-proxy-123")
    }

    // MARK: - Comments and empty lines

    @objc func testParseIgnoresCommentsAndEmptyLines() throws {
        let content = """
        # this is a comment
        base_url = "https://x"

        # another comment
        model = "m"

        """
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.baseURL, "https://x")
        XCTAssertEqual(config.model, "m")
        // everything else is default
        XCTAssertEqual(config.apiKey, "")
        XCTAssertEqual(config.proxyKey, "")
        XCTAssertEqual(config.timeoutSeconds, 120)
        XCTAssertTrue(config.soundsEnabled)
    }

    // MARK: - Missing file via load()

    @objc func testLoadMissingFileReturnsDefaults() throws {
        let config = try AppConfig.load(from: "/tmp/nonexistent_dictation_config_\(UUID()).toml")
        XCTAssertEqual(config, AppConfig.defaults)
    }

    // MARK: - api_key_file="" → nil

    @objc func testParseEmptyApiKeyFileReturnsNil() throws {
        let content = """
        api_key_file = ""
        """
        let config = try AppConfig.parse(content)
        XCTAssertNil(config.apiKeyFile)
    }

    // MARK: - api_key_file with temp file → key read + trim + quote stripping

    @objc func testLoadWithApiKeyFileReadsKey() throws {
        // key file contains: surrounding whitespace + quotes → trimmed to raw key
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_api_key_\(UUID().uuidString).txt")
        try "  \"my-secret-key\"  ".data(using: .utf8)!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let toml = "api_key = \"\"\napi_key_file = \"\(tmp.path)\"\n"
        let tomlFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_config_\(UUID().uuidString).toml")
        try toml.data(using: .utf8)!.write(to: tomlFile)
        defer { try? FileManager.default.removeItem(at: tomlFile) }

        let result = try AppConfig.load(from: tomlFile.path)
        XCTAssertEqual(result.apiKey, "my-secret-key")
    }

    @objc func testApiKeyFileUnquotedKey() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_api_key_\(UUID().uuidString).txt")
        try "bare-key-value".data(using: .utf8)!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let toml = "api_key = \"\"\napi_key_file = \"\(tmp.path)\"\n"
        let tomlFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_config_\(UUID().uuidString).toml")
        try toml.data(using: .utf8)!.write(to: tomlFile)
        defer { try? FileManager.default.removeItem(at: tomlFile) }

        let result = try AppConfig.load(from: tomlFile.path)
        XCTAssertEqual(result.apiKey, "bare-key-value")
    }

    @objc func testApiKeyFileBlankLinesSkipped() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_api_key_\(UUID().uuidString).txt")
        try "\n\n  \n  real-key\n".data(using: .utf8)!.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let toml = "api_key = \"\"\napi_key_file = \"\(tmp.path)\"\n"
        let tomlFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_config_\(UUID().uuidString).toml")
        try toml.data(using: .utf8)!.write(to: tomlFile)
        defer { try? FileManager.default.removeItem(at: tomlFile) }

        let result = try AppConfig.load(from: tomlFile.path)
        XCTAssertEqual(result.apiKey, "real-key")
    }

    // MARK: - Invalid timeout → throw

    @objc func testParseInvalidTimeoutThrows() {
        let content = "timeout_seconds = not_a_number\n"
        XCTAssertThrowsError(try AppConfig.parse(content)) { error in
            guard case AppConfig.AppConfigError.invalidLine = error else {
                XCTFail("Expected invalidLine error, got \(error)")
                return
            }
        }
    }

    @objc func testParseInvalidBoolThrows() {
        let content = "sounds_enabled = yes\n"
        XCTAssertThrowsError(try AppConfig.parse(content)) { error in
            guard case AppConfig.AppConfigError.invalidLine = error else {
                XCTFail("Expected invalidLine error, got \(error)")
                return
            }
        }
    }

    // MARK: - Unknown keys ignored

    @objc func testParseIgnoresUnknownKeys() throws {
        let content = """
        unknown_key = "foo"
        another_unknown = 42
        base_url = "https://x"
        """
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.baseURL, "https://x")
    }

    // MARK: - Chunked flag (пошаговая диктовка)

    @objc func testParseChunkedTrue() throws {
        let content = """
        base_url = "https://x"
        chunked = true
        language = "ru"
        """
        let config = try AppConfig.parse(content)
        XCTAssertTrue(config.chunked)
    }

    @objc func testParseChunkedFalse() throws {
        let content = """
        base_url = "https://x"
        chunked = false
        """
        let config = try AppConfig.parse(content)
        XCTAssertFalse(config.chunked)
    }

    @objc func testParseChunkedDefaultsToFalse() throws {
        let content = """
        base_url = "https://x"
        """
        let config = try AppConfig.parse(content)
        XCTAssertFalse(config.chunked)
    }

    @objc func testParseChunkedInvalidThrows() {
        let content = """
        chunked = "yes"
        """
        XCTAssertThrowsError(try AppConfig.parse(content)) { _ in }
    }

    // MARK: - Defaults are correct

    @objc func testDefaults() {
        let d = AppConfig.defaults
        XCTAssertTrue(d.baseURL.contains("gpt.mwsapis.ru"))
        XCTAssertEqual(d.model, "gigaam-v3")
        XCTAssertEqual(d.apiKey, "")
        XCTAssertNil(d.apiKeyFile)
        XCTAssertEqual(d.timeoutSeconds, 120)
        XCTAssertEqual(d.doubleAltMaxInterval, 0.4)
        XCTAssertTrue(d.soundsEnabled)
        XCTAssertEqual(d.logLevel, "info")
        XCTAssertEqual(d.language, "ru")
        XCTAssertFalse(d.chunked)
    }
}
