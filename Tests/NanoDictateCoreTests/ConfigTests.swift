import Foundation
@testable import NanoDictateCore

final class ConfigTests: XCTestCase {

    // Load-тесты полагаются на ОТСУТСТВИЕ канона на диске: на машине с
    // установленной homebrew/macports-формулой реальный поиск по
    // bundledExampleURLs() нашёл бы config.example.toml и изменил поведение.
    // Сентинел "" = «канона нет» (см. AppConfig.exampleContent()); канон-тесты
    // переопределяют его реальным содержимым в теле теста.
    override func setUp() {
        super.setUp()
        AppConfig.exampleContentOverride = ""
    }

    override func tearDown() {
        AppConfig.exampleContentOverride = nil
        super.tearDown()
    }

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
        XCTAssertEqual(AppConfig.defaultPath(), "\(home)/.config/nanodictate/config.toml")
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

    // MARK: - proxy_key_header

    @objc func testParseProxyKeyHeader() throws {
        let content = """
        proxy_key_header = "X-Api-Key"
        """
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.proxyKeyHeader, "X-Api-Key")
    }

    @objc func testDefaultProxyKeyHeaderIsXProxyKey() throws {
        let content = """
        proxy_key = "test-proxy-123"
        """
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.proxyKeyHeader, "X-Proxy-Key",
                       "по умолчанию передаётся старый заголовок (обратная совместимость)")
    }

    // MARK: - proxy_key_header в секции провайдера (приоритет над корневым)

    @objc func testParseProxyKeyHeaderInProviderSection() throws {
        let content = """
        active_provider = "groq"
        proxy_key_header = "X-Proxy-Key"

        [providers.groq]
        base_url = "https://proxy.example.com/go/https://api.groq.com/openai/v1/audio/transcriptions"
        model = "whisper-large-v3"
        api_key = "gsk-test"
        proxy_key = "secret-1"
        proxy_key_header = "X-Api-Key"
        """
        let config = try AppConfig.parse(content)
        guard let provider = config.providers.first else {
            XCTFail("Нет секции провайдера в конфиге")
            return
        }
        XCTAssertEqual(provider.proxyKeyHeader, "X-Api-Key")
        XCTAssertEqual(config.proxyKeyHeader, "X-Api-Key",
                       "заголовок секции попадает в effective-конфиг")
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
        // Сентинел "" = «канона нет» (см. setUp): отсутствующий конфиг не
        // создаётся и load() отдаёт дефолты.
        AppConfig.exampleContentOverride = ""
        defer { AppConfig.exampleContentOverride = nil }
        let path = "/tmp/nonexistent_nanodictate_config_\(UUID()).toml"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let config = try AppConfig.load(from: path)
        XCTAssertEqual(config, AppConfig.defaults)
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: path),
            "без канона файл не создаётся"
        )
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
        // Личных endpoint/model нет: пусто, известные адаптеры подставляют свои.
        XCTAssertEqual(d.baseURL, "")
        XCTAssertEqual(d.model, "")
        XCTAssertEqual(d.apiKey, "")
        XCTAssertNil(d.apiKeyFile)
        XCTAssertEqual(d.timeoutSeconds, 120)
        XCTAssertEqual(d.doubleAltMaxInterval, 0.4)
        XCTAssertTrue(d.soundsEnabled)
        XCTAssertEqual(d.logLevel, "info")
        XCTAssertEqual(d.language, "")
        XCTAssertFalse(d.chunked)
    }

    // MARK: - ui_language НЕ является STT-языком (изоляция полей)

    @objc func testUiLanguageDoesNotBecomeSTTLanguage() throws {
        // Конфиг с ui_language, но БЕЗ language: STT-язык остаётся пустым
        // (авто-детект), ui_language живёт отдельно (ТОЛЬКО для меню/TUI).
        let content = """
        ui_language = "en"
        base_url = "https://x"
        """
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.uiLanguage, "en")
        XCTAssertEqual(config.language, "", "ui_language не должен протекать в STT language")
    }

    @objc func testExplicitLanguageStillParsed() throws {
        // Явный language = "ru" в конфиге форвардится в STT-запрос как раньше.
        let content = """
        language = "ru"
        ui_language = "en"
        """
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.language, "ru")
        XCTAssertEqual(config.uiLanguage, "en")
    }

    // MARK: - api_secret в секции провайдера игнорируется

    @objc func testParseProviderIgnoresUnknownApiSecretKey() throws {
        // api_secret снесён: ключ в секции ничего не ломает (default: break),
        // остальные поля парсятся как обычно. Тест живёт и при текущем коде,
        // и после удаления обработки api_secret.
        let content = """
        [providers.groq]
        name = "Groq"
        api_key = "gk-123"
        api_secret = "client-secret"
        """
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.providers.count, 1)
        XCTAssertEqual(config.providers.first?.id, "groq")
        XCTAssertEqual(config.providers.first?.apiKey, "gk-123", "api_key остаётся")
    }

    // MARK: - NANODICTATE_API_KEY env — приоритет над ключами из файла

    @objc func testLoadEnvAPIKeyOverrides() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanodictate-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("config.toml").path
        let content = """
        active_provider = "openai"

        [providers.openai]
        base_url = "https://api.openai.com/v1/audio/transcriptions"
        model = "whisper-1"
        api_key = "file-key"
        """
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        setenv("NANODICTATE_API_KEY", "env-key", 1)
        defer { unsetenv("NANODICTATE_API_KEY") }
        let config = try AppConfig.load(from: path)
        XCTAssertEqual(config.apiKey, "env-key", "env-ключ приоритетнее api_key из файла")
        XCTAssertEqual(config.providers.first?.apiKey, "env-key")
    }

    @objc func testLoadWithoutEnvKeepsFileKey() throws {
        unsetenv("NANODICTATE_API_KEY")
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanodictate-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("config.toml").path
        let content = """
        [providers.openai]
        api_key = "file-key"
        model = "whisper-1"

        active_provider = "openai"
        """
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        let config = try AppConfig.load(from: path)
        XCTAssertEqual(config.apiKey, "file-key")
    }

    @objc func testLoadEnvAPIKeyScopesToActiveProviderOnly() throws {
        // env-ключ пишется ТОЛЬКО в секцию активного провайдера (и effective);
        // неактивные секции сохраняют собственные api_key / api_key_file.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("nanodictate-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("config.toml").path
        let content = """
        active_provider = "openai"

        [providers.openai]
        api_key = "openai-file-key"

        [providers.groq]
        api_key = "groq-file-key"

        [providers.cloudflare]
        api_key_file = "~/.config/nanodictate/keys/cloudflare.key"
        """
        try content.write(toFile: path, atomically: true, encoding: .utf8)
        setenv("NANODICTATE_API_KEY", "env-key", 1)
        defer { unsetenv("NANODICTATE_API_KEY") }
        let config = try AppConfig.load(from: path)
        XCTAssertEqual(config.apiKey, "env-key", "env-ключ применяется к effective-полю")
        XCTAssertEqual(config.providers.first(where: { $0.id == "openai" })?.apiKey, "env-key",
                       "активной секции env-ключ перезаписывает file-ключ")
        XCTAssertEqual(config.providers.first(where: { $0.id == "groq" })?.apiKey, "groq-file-key",
                       "неактивная секция хранит СВОЙ api_key — env её не перезатирает")
        XCTAssertEqual(config.providers.first(where: { $0.id == "cloudflare" })?.apiKey, "",
                       "неактивная секция с api_key_file не получает env-ключ в api_key")
        XCTAssertEqual(config.providers.first(where: { $0.id == "cloudflare" })?.apiKeyFile,
                       "~/.config/nanodictate/keys/cloudflare.key",
                       "неактивная секция сохраняет СВОЙ api_key_file нетронутым")
    }

    // MARK: - Новые UX-ключи: providers / auto_failover / insert_method / review_before_insert

    @objc func testParseProvidersOrderArray() throws {
        let content = """
        providers = ["groq", "gigaam"]
        auto_failover = true
        insert_method = "clipboard"
        review_before_insert = true

        [providers.groq]
        name = "Groq"
        model = "whisper-large-v3"

        [providers.gigaam]
        name = "GigaAM"
        model = "gigaam-v3"
        """
        let config = try AppConfig.parse(content)

        XCTAssertEqual(config.providersOrder, ["groq", "gigaam"])
        XCTAssertTrue(config.autoFailover)
        XCTAssertEqual(config.insertMethod, .clipboard)
        XCTAssertTrue(config.reviewBeforeInsert)
    }

    @objc func testParseDefaultsForNewKeys() throws {
        let content = "base_url = \"https://x\"\n"
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.providersOrder, [])
        XCTAssertFalse(config.autoFailover)
        XCTAssertEqual(config.insertMethod, .cgevent)
        XCTAssertFalse(config.reviewBeforeInsert)
    }

    @objc func testParseEmptyProvidersArray() throws {
        let content = "providers = []\n"
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.providersOrder, [])
    }

    @objc func testParseBadInsertMethodThrows() {
        let content = "insert_method = \"paste\"\n"
        XCTAssertThrowsError(try AppConfig.parse(content)) { error in
            guard case AppConfig.AppConfigError.invalidValue = error else {
                XCTFail("Expected invalidValue error, got \(error)")
                return
            }
        }
    }

    @objc func testParseBadBoolForReviewThrows() {
        let content = "review_before_insert = maybe\n"
        XCTAssertThrowsError(try AppConfig.parse(content)) { error in
            guard case AppConfig.AppConfigError.invalidLine = error else {
                XCTFail("Expected invalidLine error, got \(error)")
                return
            }
        }
    }

    // MARK: - failoverOrderNames / failoverProviders

    @objc func testFailoverOrderNamesDefaultsToProviderSections() throws {
        let content = """
        [providers.b]
        name = "B"

        [providers.a]
        name = "A"
        """
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.failoverOrderNames, ["b", "a"])
    }

    @objc func testFailoverOrderNamesUsesExplicitProviders() throws {
        let content = """
        providers = ["groq"]

        [providers.groq]
        name = "Groq"

        [providers.gigaam]
        name = "GigaAM"
        """
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.failoverOrderNames, ["groq"], "Явный список providers перекрывает порядок секций")
    }

    @objc func testFailoverProvidersFiltersFailedAndUnknown() throws {
        let content = """
        providers = ["groq", "gigaam", "missing"]

        [providers.groq]
        name = "Groq"

        [providers.gigaam]
        name = "GigaAM"
        """
        let config = try AppConfig.parse(content)
        let all = config.failoverProviders(excluding: nil)
        XCTAssertEqual(all.map { $0.id }, ["groq", "gigaam"], "Неизвестные имена пропускаются")

        let withoutFailed = config.failoverProviders(excluding: "groq")
        XCTAssertEqual(withoutFailed.map { $0.id }, ["gigaam"], "Упавший провайдер исключается")
    }

    // MARK: - writeReviewBeforeInsert roundtrip

    @objc func testWriteReviewBeforeInsertRoundtrip() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_review_\(UUID().uuidString).toml")
        try "base_url = \"https://x\"\n".data(using: .utf8)!.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        try AppConfig.writeReviewBeforeInsert(value: true, to: path.path)

        let content = try String(contentsOf: path, encoding: .utf8)
        XCTAssertTrue(content.contains("review_before_insert = true"))

        let config = try AppConfig.load(from: path.path)
        XCTAssertTrue(config.reviewBeforeInsert)
    }

    // MARK: - transport (какой STT-транспорт включён)

    @objc func testParseTransportRoot() throws {
        // Легаси-алиас "infinityfree" канонизируется в "cookie-relay" при парсинге.
        let content = """
        base_url = "https://x"
        transport = "infinityfree"
        """
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.transport, "cookie-relay")
    }

    @objc func testCanonicalTransportAliases() {
        // Прямое тестирование канонизации: и "relay", и "infinityfree" — это
        // легаси-имена cookie-relay; всё остальное проходит как есть.
        XCTAssertEqual(AppConfig.canonicalTransport("relay"), "cookie-relay")
        XCTAssertEqual(AppConfig.canonicalTransport("infinityfree"), "cookie-relay")
        XCTAssertEqual(AppConfig.canonicalTransport("cookie-relay"), "cookie-relay")
        XCTAssertEqual(AppConfig.canonicalTransport("http"), "http")
        XCTAssertEqual(AppConfig.canonicalTransport("gateway"), "gateway")
        XCTAssertEqual(AppConfig.canonicalTransport("  relay  "), "cookie-relay", "пробелы обрезаются")
        XCTAssertEqual(AppConfig.canonicalTransport(""), "")
    }

    @objc func testTransportDefaultEmpty() throws {
        // Без transport в конфиге — поведение ровно как раньше (без cookie-логики).
        let content = """
        base_url = "https://x"
        model = "m"
        """
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.transport, "")
    }

    @objc func testParseTransportInProviderSectionApplies() throws {
        let content = """
        active_provider = "groq"

        [providers.groq]
        base_url = "https://g"
        model = "m"
        api_key = "k"
        transport = "infinityfree"
        """
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.providers.first?.transport, "cookie-relay",
                       "легаси-алиас канонизирован в секции")
        XCTAssertEqual(config.transport, "cookie-relay",
                       "transport активной секции попадает в effective-конфиг")
    }

    @objc func testProviderTransportOverridesRoot() throws {
        let content = """
        transport = "openrouter"
        active_provider = "groq"

        [providers.groq]
        base_url = "https://g"
        model = "m"
        api_key = "k"
        transport = "infinityfree"
        """
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.transport, "cookie-relay",
                       "transport секции имеет приоритет над корневым")
    }

    @objc func testRootTransportPreservedWhenProviderOmits() throws {
        let content = """
        transport = "infinityfree"
        active_provider = "groq"

        [providers.groq]
        base_url = "https://g"
        model = "m"
        api_key = "k"
        """
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.providers.first?.transport, "")
        XCTAssertEqual(config.transport, "cookie-relay",
                       "без transport в секции корневой transport остаётся в силе (канонизирован)")
    }

    @objc func testParseHTTPProxyTransport() throws {
        // transport = "http" + http_proxy/proxy_user/proxy_password парсятся и
        // попадают в effective-конфиг из активной секции.
        let content = """
        active_provider = "groq"

        [providers.groq]
        base_url = "https://api.groq.com/openai/v1/audio/transcriptions"
        model = "whisper-large-v3"
        api_key = "k"
        transport = "http"
        http_proxy = "proxy.example.com:8080"
        proxy_user = "alice"
        proxy_password = "secret"
        """
        let config = try AppConfig.parse(content)
        guard let provider = config.providers.first else {
            XCTFail("Нет секции providers")
            return
        }
        XCTAssertEqual(provider.transport, "http")
        XCTAssertEqual(config.transport, "http")
        XCTAssertEqual(provider.httpProxy, "proxy.example.com:8080")
        XCTAssertEqual(config.httpProxy, "proxy.example.com:8080",
                       "http_proxy секции попадает в effective-конфиг")
        XCTAssertEqual(config.proxyUser, "alice")
        XCTAssertEqual(config.proxyPassword, "secret")
    }

    @objc func testParseGatewayTransport() throws {
        // transport = "gateway" + proxy_key/proxy_key_header — релейный маршрут
        // через заголовок: секция парсится, креды остаются в провайдере.
        let content = """
        active_provider = "groq"

        [providers.groq]
        base_url = "https://api.groq.com/openai/v1/audio/transcriptions"
        model = "whisper-large-v3"
        api_key = "k"
        transport = "gateway"
        proxy_key = "gk-secret"
        proxy_key_header = "X-Proxy-Key"
        """
        let config = try AppConfig.parse(content)
        guard let provider = config.providers.first else {
            XCTFail("Нет секции providers")
            return
        }
        XCTAssertEqual(provider.transport, "gateway")
        XCTAssertEqual(config.transport, "gateway")
        XCTAssertEqual(provider.proxyKey, "gk-secret")
        XCTAssertEqual(provider.proxyKeyHeader, "X-Proxy-Key",
                       "proxy_key_header попадает в effective-конфиг")
    }

    // MARK: - Секция Cloudflare (JSON-base64 транспорт)

    @objc func testParseCloudflareProviderSection() throws {
        let content = """
        active_provider = "cloudflare"

        [providers.cloudflare]
        name = "Cloudflare Workers AI"
        base_url = "https://api.cloudflare.com/client/v4/accounts/ACCT/ai/run/@cf/openai/whisper-large-v3-turbo"
        model = "@cf/openai/whisper-large-v3-turbo"
        api_key = "cfut-token"
        transport = "cloudflare"
        """
        let config = try AppConfig.parse(content)
        guard let provider = config.providers.first else {
            XCTFail("Нет секции [providers.cloudflare] в конфиге")
            return
        }
        XCTAssertEqual(provider.id, "cloudflare")
        XCTAssertEqual(provider.name, "Cloudflare Workers AI")
        XCTAssertEqual(provider.baseURL,
                       "https://api.cloudflare.com/client/v4/accounts/ACCT/ai/run/@cf/openai/whisper-large-v3-turbo")
        XCTAssertEqual(provider.model, "@cf/openai/whisper-large-v3-turbo")
        XCTAssertEqual(provider.apiKey, "cfut-token")
        XCTAssertEqual(provider.transport, "cloudflare")
        XCTAssertEqual(config.transport, "cloudflare",
                       "transport секции попадает в effective-конфиг (как cookie-relay)")
        XCTAssertEqual(config.activeProvider, "cloudflare")
    }

    @objc func testTransportKeyDoesNotTriggerLegacyAmbiguity() throws {
        // Ключ transport НЕ legacy-STT: его наличие вместе с секциями не должно
        // давать ошибки «неоднозначно» при отсутствии active_provider.
        let content = """
        transport = "infinityfree"

        [providers.groq]
        base_url = "https://g"
        model = "m"
        api_key = "k"
        """
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.activeProvider, "")
        XCTAssertEqual(config.transport, "cookie-relay",
                       "легаси-алиас канонизирован и на корневом уровне")
        XCTAssertEqual(config.baseURL, "https://g", "первый провайдер применён как active")
    }

    // MARK: - maskSecret (первые 4 + "***" + последние 4)

    @objc func testMaskSecretLongKey() {
        XCTAssertEqual(AppConfig.maskSecret("abcd1234wxyz"), "abcd***wxyz")
        XCTAssertEqual(AppConfig.maskSecret("0123456789abcdef"), "0123***cdef")
    }

    @objc func testMaskSecretShortOrEmpty() {
        XCTAssertEqual(AppConfig.maskSecret("short"), "***")
        XCTAssertEqual(AppConfig.maskSecret(""), "***")
        XCTAssertEqual(AppConfig.maskSecret("   "), "***")
    }

    @objc func testMaskSecretTrimsWhitespace() {
        XCTAssertEqual(AppConfig.maskSecret("  abcdefghijkl  "), "abcd***ijkl")
    }

    // MARK: - Example-канон (config.example.toml)

    /// Читает канон из корня пакета (swift test запускается из корня пакета).
    private func exampleCanonContent() throws -> String {
        try String(
            contentsOfFile: FileManager.default.currentDirectoryPath + "/config.example.toml",
            encoding: .utf8
        )
    }

    @objc func testExampleCanonParses() throws {
        let content = try exampleCanonContent()
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.activeProvider, "airubiz")
        XCTAssertTrue(
            config.providerNames.contains("airubiz"),
            "канон содержит секцию airubiz: \(config.providerNames)"
        )
        let airubiz = config.providers.first { $0.id == "airubiz" }
        XCTAssertEqual(airubiz?.baseURL, "https://api.airubiz.site/v1/audio/transcriptions")
        XCTAssertEqual(airubiz?.model, "gigaam-v3-ctc-sherpa")
        XCTAssertEqual(airubiz?.apiKey, "")
        XCTAssertEqual(airubiz?.transport, "", "у airubiz транспорт не задан — direct")
        let cloudflare = config.providers.first { $0.id == "cloudflare" }
        XCTAssertEqual(cloudflare?.transport, "",
                       "у cloudflare transport не задан — секция = STT-адаптер, а не HTTPTransport")
        XCTAssertNil(config.providers.first { $0.id == "cookie-relay" },
                     "канон больше не содержит секцию cookie-relay")
        for provider in config.providers {
            XCTAssertEqual(provider.apiKey, "", "канон не содержит секретов")
        }
    }

    @objc func testExampleCanonRoundTripViaFile() throws {
        let content = try exampleCanonContent()
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_example_roundtrip_\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: file) }
        try content.data(using: .utf8)!.write(to: file)
        let config = try AppConfig.load(from: file.path)
        XCTAssertEqual(config.activeProvider, "airubiz")
        XCTAssertEqual(config.providerNames,
                       ["openai", "groq", "cloudflare", "airubiz"],
                       "секции канона в порядке появления")
    }

    @objc func testAutoCopyOnFirstRun() throws {
        let example = try exampleCanonContent()
        AppConfig.exampleContentOverride = example
        defer { AppConfig.exampleContentOverride = nil }
        let tempPath = "/tmp/nanodictate_autocopy_\(UUID().uuidString).toml"
        defer { try? FileManager.default.removeItem(atPath: tempPath) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempPath))

        let config = try AppConfig.load(from: tempPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempPath), "автокопия создаёт файл")
        let written = try String(contentsOfFile: tempPath, encoding: .utf8)
        XCTAssertEqual(written, example, "файл — точная копия канона")
        XCTAssertEqual(config.activeProvider, "airubiz")
    }

    @objc func testMergeExampleUnderUserConfig() throws {
        let example = try exampleCanonContent()
        AppConfig.exampleContentOverride = example
        defer { AppConfig.exampleContentOverride = nil }
        let userFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_merge_canon_\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: userFile) }
        // Юзер-конфиг БЕЗ секции airubiz, со своим активным groq.
        let userConfig = """
        active_provider = "groq"

        [providers.groq]
        name = "Groq"
        base_url = "https://api.groq.com/openai/v1/audio/transcriptions"
        model = "whisper-large-v3"
        api_key = ""
        """
        try userConfig.data(using: .utf8)!.write(to: userFile)

        let config = try AppConfig.load(from: userFile.path)
        XCTAssertEqual(config.activeProvider, "groq", "юзер-конфиг перекрывает active_provider канона")
        XCTAssertTrue(
            config.providers.contains { $0.id == "airubiz" },
            "секция airubiz из канона сохранена при мерже"
        )
        let airubiz = config.providers.first { $0.id == "airubiz" }
        XCTAssertEqual(airubiz?.baseURL, "https://api.airubiz.site/v1/audio/transcriptions")
        XCTAssertEqual(airubiz?.model, "gigaam-v3-ctc-sherpa")
    }

    @objc func testSectionsWithoutActiveProviderDoNotInheritCanonProviders() throws {
        // Секции [providers.*] ЕСТЬ, active_provider НЕТ: канон даёт только
        // скалярные дефолты, его active_provider "airubiz" и секции НЕ протекают.
        // Иначе resolveActiveProvider назначил бы активным airubiz (не первую
        // секцию юзера), а undeclared-секции канона попали бы в failover.
        let savedEnvKey = ProcessInfo.processInfo.environment["NANODICTATE_API_KEY"]
        unsetenv("NANODICTATE_API_KEY")
        defer {
          if let savedEnvKey = savedEnvKey {
            setenv("NANODICTATE_API_KEY", savedEnvKey, 1)
          }
        }
        let example = try exampleCanonContent()
        AppConfig.exampleContentOverride = example
        defer { AppConfig.exampleContentOverride = nil }
        let userFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_sections_no_active_\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: userFile) }
        let userConfig = """
        [providers.custom]
        name = "Custom"
        base_url = "https://custom.example/v1/transcriptions"
        model = "custom-model"
        api_key = ""
        """
        try userConfig.data(using: .utf8)!.write(to: userFile)

        let config = try AppConfig.load(from: userFile.path)
        XCTAssertEqual(config.activeProvider, "",
                       "без active_provider активным становится первый провайдер, не airubiz из канона")
        XCTAssertEqual(config.providers.map(\.id), ["custom"],
                       "секции канона (openai/groq/cloudflare/airubiz) не наследуются")
        XCTAssertEqual(config.baseURL, "https://custom.example/v1/transcriptions")
        XCTAssertEqual(config.model, "custom-model")
        XCTAssertFalse(
            config.failoverProviders(excluding: nil).contains { $0.id == "airubiz" },
            "undeclared-секции канона не попадают в failover"
        )
        XCTAssertEqual(config.failoverProviders(excluding: nil).map(\.id), ["custom"])
    }

    @objc func testLegacyFlatConfigPreservesLegacyKeys() throws {
        // Плоский legacy-конфиг (top-level base_url/model/api_key, без секций
        // [providers.*] и без active_provider) + доступный канон: мерж НЕ
        // применяется — база дефолты, иначе секции канона (6 шт.) и его
        // active_provider "airubiz" затёрли бы legacy-поля юзера (включая
        // api_key/api_key_file, которые resolveActiveProvider ставит в nil).
        // Если в окружении задан NANODICTATE_API_KEY — снять (env имеет приоритет
        // над файлом и перекрыл бы legacy api_key); паттерн — как в
        // testLoadWithoutEnvKeepsFileKey, прежнее значение возвращается в defer.
        let savedEnvKey = ProcessInfo.processInfo.environment["NANODICTATE_API_KEY"]
        unsetenv("NANODICTATE_API_KEY")
        defer {
          if let savedEnvKey = savedEnvKey {
            setenv("NANODICTATE_API_KEY", savedEnvKey, 1)
          }
        }
        let example = try exampleCanonContent()
        AppConfig.exampleContentOverride = example
        defer { AppConfig.exampleContentOverride = nil }
        let legacyFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_legacy_flat_\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: legacyFile) }
        let legacy = """
        base_url = "https://legacy.example/v1/transcribe"
        model = "legacy-model"
        api_key = "legacy-secret"
        api_key_file = "/nonexistent/keys.txt"
        timeout_seconds = 42
        """
        try legacy.data(using: .utf8)!.write(to: legacyFile)

        let config = try AppConfig.load(from: legacyFile.path)
        XCTAssertEqual(
            config.baseURL, "https://legacy.example/v1/transcribe",
            "legacy base_url не затирается каноном"
        )
        XCTAssertEqual(config.model, "legacy-model")
        XCTAssertEqual(
            config.apiKey, "legacy-secret",
            "legacy api_key не затирается секцией airubiz канона"
        )
        XCTAssertEqual(config.timeoutSeconds, 42)
        XCTAssertTrue(
            config.providers.isEmpty,
            "legacy-конфиг не наследует секции канона"
        )
        XCTAssertEqual(
            config.activeProvider, "",
            "legacy-конфиг без active_provider — ровно прежнее поведение"
        )
    }

    /// Структурный тест порядка кандидатов канона (fix v0.0.13: перенос
    /// config.example.toml из Contents/MacOS в Contents/Resources .app-бандла).
    /// Контракт списка: executableDir → share/nanodictate по prefixDir →
    /// ресурсы .app-бандла (Bundle.main.resourcePath) → фиксированные пути
    /// пакетных менеджеров. Проверяется сам список (структура), а не файловая
    /// система — тест детерминирован на любой машине и ловит изменение
    /// порядка или пропажу кандидата. Файловое «первый существующий» — это
    /// поведение exampleContent(), покрытое override-тестами выше; конкретику
    /// резолва Contents/Resources в .app до-verify-ает CI (--deep verify).
    @objc func testBundledExampleURLsContractOrder() {
        let urls = AppConfig.bundledExampleURLs()
        let paths = urls.map { $0.path }
        let executableDir = (CommandLine.arguments[0] as NSString).deletingLastPathComponent
        let prefixDir = (executableDir as NSString).deletingLastPathComponent
        let resourceCandidatePresent = Bundle.main.resourcePath != nil
        XCTAssertEqual(
            urls.count, resourceCandidatePresent ? 6 : 5,
            "5 старых кандидатов + ресурсный .app-кандидат (если resourcePath существует)"
        )
        XCTAssertEqual(
            paths[0],
            URL(fileURLWithPath: executableDir)
                .appendingPathComponent("config.example.toml").path,
            "первый кандидат — рядом с бинарём (тарбол release.yml)"
        )
        XCTAssertEqual(
            paths[1],
            URL(fileURLWithPath: prefixDir)
                .appendingPathComponent("share/nanodictate/config.example.toml").path,
            "второй кандидат — share/nanodictate под prefixDir (Homebrew/MacPorts)"
        )
        if let resourcePath = Bundle.main.resourcePath {
            XCTAssertEqual(
                paths[2],
                URL(fileURLWithPath: resourcePath)
                    .appendingPathComponent("config.example.toml").path,
                "ресурсный кандидат — сразу после prefixDir, до фиксированных путей"
            )
        }
        // Индекс после ресурсного кандидата (или после prefixDir, когда
        // resourcePath у раннера отсутствует) — начало фиксированного списка.
        let fixedStart = resourceCandidatePresent ? 3 : 2
        XCTAssertEqual(
            paths[fixedStart], "/opt/homebrew/share/nanodictate/config.example.toml",
            "за ресурсным кандидатом следуют фиксированные пути пакетных менеджеров"
        )
        XCTAssertEqual(paths[fixedStart + 1], "/usr/local/share/nanodictate/config.example.toml")
        XCTAssertEqual(paths[fixedStart + 2], "/opt/local/share/nanodictate/config.example.toml")
    }

    // MARK: - writeKeyValue (top-level, вне секций)

    @objc func testWriteKeyValueReplacesTopLevelOnly() throws {
        // Одноимённый ключ внутри секции не должен затрагиваться (CodeRabbit).
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_write_kv_top_\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: file) }
        try """
        api_key = "top-old"
        [providers.groq]
        api_key = "section-old"
        """.data(using: .utf8)!.write(to: file)

        try AppConfig.writeKeyValue(key: "api_key", value: "\"top-new\"", to: file.path)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("api_key = \"top-new\""))
        XCTAssertFalse(text.contains("top-old"))
        XCTAssertTrue(text.contains("api_key = \"section-old\""),
                      "ключ внутри [providers.groq] не тронут")
    }

    @objc func testWriteKeyValueIgnoresSectionKeysAndInsertsBeforeFirstSection() throws {
        // Ключа на верхнем уровне нет — искать в секции нельзя: вставляем
        // строку перед первым заголовком секции, секционный ключ не трогаем.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_write_kv_section_\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: file) }
        try """
        [providers.groq]
        api_key = "section-old"
        """.data(using: .utf8)!.write(to: file)

        try AppConfig.writeKeyValue(key: "api_key", value: "\"top-new\"", to: file.path)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("api_key = \"top-new\""))
        XCTAssertTrue(text.contains("api_key = \"section-old\""),
                      "секционный ключ остался на месте")
        let inserted = text.range(of: "api_key = \"top-new\"")!
        let header = text.range(of: "[providers.groq]")!
        XCTAssertTrue(inserted.lowerBound < header.lowerBound,
                      "top-level строка вставлена ПЕРЕД первой секцией")
        let config = try AppConfig.parse(text)
        XCTAssertEqual(config.providers.first { $0.id == "groq" }?.apiKey, "section-old")
    }

    @objc func testWriteKeyValueIgnoresSectionWithTrailingSpaceInHeader() throws {
        // Заголовок с хвостовыми пробелами `[providers.groq]  ` парсер читает
        // как секцию — writeKeyValue должен так же, иначе заменит ключ внутри
        // секции (воскрешение бага, починенного для обычных заголовков).
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_write_kv_trailing_sp_\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: file) }
        let content = "[providers.groq]  \napi_key = \"section-old\"\n"
        try content.data(using: .utf8)!.write(to: file)

        try AppConfig.writeKeyValue(key: "api_key", value: "\"top-new\"", to: file.path)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("api_key = \"top-new\""))
        XCTAssertTrue(text.contains("api_key = \"section-old\""),
                      "секционный ключ не тронут при хвостовых пробелах в заголовке")
        let inserted = text.range(of: "api_key = \"top-new\"")!
        let header = text.range(of: "[providers.groq]")!
        XCTAssertTrue(inserted.lowerBound < header.lowerBound,
                      "top-level строка вставлена ПЕРЕД первой секцией")
        let config = try AppConfig.parse(text)
        XCTAssertEqual(config.providers.first { $0.id == "groq" }?.apiKey, "section-old")
    }

    @objc func testWriteKeyValueInsertsBeforeFirstSectionWhenNotFound() throws {
        // Есть top-level строки и секции: отсутствующий ключ — перед секцией.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_write_kv_insert_\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: file) }
        try """
        language = "ru"

        [providers.groq]
        name = "Groq"
        """.data(using: .utf8)!.write(to: file)

        try AppConfig.writeKeyValue(key: "active_provider", value: "\"groq\"", to: file.path)
        let text = try String(contentsOf: file, encoding: .utf8)
        let inserted = text.range(of: "active_provider = \"groq\"")!
        let header = text.range(of: "[providers.groq]")!
        XCTAssertTrue(inserted.lowerBound < header.lowerBound)
        XCTAssertTrue(text.contains("language = \"ru\""),
                      "существующие top-level строки не тронуты")
        let config = try AppConfig.parse(text)
        XCTAssertEqual(config.activeProvider, "groq",
                       "парсер читает вставленную строку как top-level")
    }

    @objc func testWriteKeyValueAppendsToEndWhenNoSections() throws {
        // Без секций поведение прежнее: строка добавляется в конец файла.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_write_kv_append_\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: file) }
        try "language = \"ru\"\n".data(using: .utf8)!.write(to: file)

        try AppConfig.writeKeyValue(key: "active_provider", value: "\"groq\"", to: file.path)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(
            text, "language = \"ru\"\nactive_provider = \"groq\"\n",
            "без секций — прежнее поведение: дописывается с переводом строки")
        let parsed = try AppConfig.parse(text)
        XCTAssertEqual(parsed.activeProvider, "groq")
    }

    // MARK: - writeProviderKeyValue (config set-key)

    @objc func testWriteProviderKeyValueReplacesInExistingSection() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_set_key_\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: file) }
        let content = """
        language = "ru"
        active_provider = "groq"

        [providers.groq]
        name = "Groq"
        base_url = ""
        api_key = "old-key" # коммент сохраняется
        """
        try content.data(using: .utf8)!.write(to: file)

        // Значение передаётся в формате строки конфига (с кавычками), как
        // writeKeyValue для строк (ср. writeActiveProvider).
        try AppConfig.writeProviderKeyValue(providerID: "groq", key: "api_key", value: "\"new-value\"", to: file.path)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("api_key = \"new-value\" # коммент сохраняется"))
        XCTAssertFalse(text.contains("old-key"))
        // Остальные строки не тронуты.
        XCTAssertTrue(text.contains("language = \"ru\""))
        XCTAssertTrue(text.contains("[providers.groq]"))
    }

    @objc func testWriteProviderKeyValueCreatesMissingSection() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_set_key_new_\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: file) }
        try "language = \"ru\"\n".data(using: .utf8)!.write(to: file)

        try AppConfig.writeProviderKeyValue(providerID: "cloudflare", key: "api_key", value: "\"cf-123\"", to: file.path)
        let config = try AppConfig.parse(String(contentsOf: file, encoding: .utf8))
        XCTAssertEqual(config.providers.first { $0.id == "cloudflare" }?.apiKey, "cf-123")
    }

    @objc func testWriteProviderKeyValueAddsKeyToNewFile() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_set_key_fresh_\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: file) }

        try AppConfig.writeProviderKeyValue(providerID: "openai", key: "api_key", value: "\"sk-x\"", to: file.path)
        let config = try AppConfig.parse(String(contentsOf: file, encoding: .utf8))
        XCTAssertEqual(config.providers.first { $0.id == "openai" }?.apiKey, "sk-x")
    }

    @objc func testWriteProviderKeyValueSets0600Permissions() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_set_key_perm_\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: file) }

        try AppConfig.writeProviderKeyValue(providerID: "openai", key: "api_key", value: "\"sk-x\"", to: file.path)
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms & 0o777, 0o600, "файл с секретом обязан быть 0600")
    }

    @objc func testWriteProviderKeyValueAppendsInsideExistingSectionAfterKeys() throws {
        // Ключа ещё нет — добавляется в конец секции, а не после неё.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_set_key_append_\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: file) }
        try """
        [providers.cloudflare]
        base_url = ""
        model = ""

        [providers.groq]
        base_url = ""
        """.data(using: .utf8)!.write(to: file)

        try AppConfig.writeProviderKeyValue(providerID: "cloudflare", key: "api_key", value: "\"k\"", to: file.path)
        let config = try AppConfig.parse(String(contentsOf: file, encoding: .utf8))
        XCTAssertEqual(config.providers.first { $0.id == "cloudflare" }?.apiKey, "k")
        XCTAssertEqual(config.providers.first { $0.id == "groq" }?.apiKey, "",
                       "ключ попал в секцию cloudflare, не в groq")
    }

    @objc func testWriteProviderKeyValueRecognizesSectionWithTrailingComment() {
        // Заголовок секции с хвостовым комментарием: ключ правятся в секции,
        // дубликат `[providers.groq]` НЕ создаётся (парсер не упадёт).
        // Метод без `throws`: мини-XCTest вызывает тесты через perform, и
        // реально брошенная ошибка роняет процесс.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_set_key_comment_\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: file) }
        do {
            try """
            # провайдеры
            [providers.groq] # основной

            api_key = "old"
            """.data(using: .utf8)!.write(to: file)

            try AppConfig.writeProviderKeyValue(providerID: "groq", key: "api_key", value: "\"new\"", to: file.path)
            let content = try String(contentsOf: file, encoding: .utf8)
            XCTAssertEqual(content.components(separatedBy: "[providers.groq]").count - 1, 1,
                           "секция не продублирована")
            let config = try AppConfig.parse(content)
            XCTAssertEqual(config.providers.first { $0.id == "groq" }?.apiKey, "new")
            XCTAssertTrue(content.contains("# основной"), "заголовочный комментарий сохранён")
        } catch {
            XCTFail("Неожиданная ошибка: \(error)")
        }
    }

    // MARK: - Маршрутизация STT по ролям ([routing])

    @objc func testParseRoutingSection() throws {
        let content = """
        active_provider = "groq"

        [providers.groq]
        name = "Groq"

        [providers.cloudflare]
        name = "Cloudflare"

        [routing]
        segment_provider = "cloudflare"
        final_provider = "groq"
        unknown_routing_key = "ignored"
        [providers.selfhosted]
        name = "Selfhosted"
        """
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.routing.segmentProvider, "cloudflare")
        XCTAssertEqual(config.routing.finalProvider, "groq")
        XCTAssertEqual(config.segmentProviderID(), "cloudflare")
        XCTAssertEqual(config.finalProviderID(), "groq")
        // Неизвестный ключ внутри [routing] игнорируется, секция кончилась —
        // следующая [providers.X] читается как обычно.
        XCTAssertEqual(config.providers.map { $0.id }, ["groq", "cloudflare", "selfhosted"])
    }

    @objc func testRoutingKeysOutsideSectionDoNotLeak() throws {
        let content = """
        active_provider = "groq"
        segment_provider = "cloudflare"

        [providers.groq]
        name = "Groq"
        """
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.routing.segmentProvider, "",
                       "роль читается только внутри секции [routing]")
        XCTAssertEqual(config.segmentProviderID(), "groq")
    }

    @objc func testRoutingResolversFallBackToActiveWhenUnset() throws {
        let content = """
        active_provider = "groq"

        [providers.groq]
        name = "Groq"

        [providers.cloudflare]
        name = "Cloudflare"
        """
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.routing.segmentProvider, "")
        XCTAssertEqual(config.routing.finalProvider, "")
        XCTAssertEqual(config.segmentProviderID(), "groq", "роль не задана — активный")
        XCTAssertEqual(config.finalProviderID(), "groq", "роль не задана — активный")
    }

    @objc func testRoutingResolversUseRoleOrFallbackOnUnknownID() throws {
        let content = """
        active_provider = "groq"

        [providers.groq]
        name = "Groq"

        [providers.cloudflare]
        name = "Cloudflare"

        [routing]
        segment_provider = "cloudflare"
        final_provider = "nonexistent"
        """
        // Неизвестный id роли НЕ роняет парсинг (толерантный резолвер).
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.segmentProviderID(), "cloudflare")
        XCTAssertEqual(config.finalProviderID(), "groq", "неизвестный id роли — фолбэк на активного")
    }

    @objc func testRoutingResolversLegacyConfigReturnEmpty() throws {
        // Legacy-конфиг (секций нет): active_provider пуст — роли тоже пусты,
        // агент работает как раньше (новые резолверы не бросают).
        let content = "base_url = \"https://x\"\nmodel = \"m\"\napi_key = \"k\"\n"
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.activeProvider, "")
        XCTAssertEqual(config.segmentProviderID(), "")
        XCTAssertEqual(config.finalProviderID(), "")
    }

    @objc func testWriteRoutingKeyValueCreatesSectionAndLoads() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_routing_new_\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: file) }
        try """
        active_provider = "groq"

        [providers.groq]
        name = "Groq"

        [providers.cloudflare]
        name = "Cloudflare"
        """.data(using: .utf8)!.write(to: file)

        try AppConfig.writeRoutingKeyValue(key: "segment_provider", value: "\"cloudflare\"", to: file.path)
        let config = try AppConfig.load(from: file.path)
        XCTAssertEqual(config.routing.segmentProvider, "cloudflare")
        XCTAssertEqual(config.segmentProviderID(), "cloudflare")
        // Файл с ролью — как и все точечные правки конфига — 0600.
        let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(perms & 0o777, 0o600, "правка конфига обязана быть 0600")
    }

    @objc func testWriteRoutingKeyValueReplacesInExistingSection() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_routing_replace_\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: file) }
        try """
        active_provider = "groq"

        [providers.groq]
        name = "Groq"

        [providers.cloudflare]
        name = "Cloudflare"

        [routing]
        segment_provider = "relay" # коммент сохраняется
        """.data(using: .utf8)!.write(to: file)

        try AppConfig.writeRoutingKeyValue(key: "segment_provider", value: "\"cloudflare\"", to: file.path)
        let text = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(text.contains("segment_provider = \"cloudflare\" # коммент сохраняется"))
        XCTAssertFalse(text.contains("relay"))
        // Остальные строки не тронуты.
        XCTAssertTrue(text.contains("active_provider = \"groq\""))
        XCTAssertTrue(text.contains("[routing]"))
    }

    @objc func testWriteRoutingKeyValueAppendsInsideExistingSection() throws {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_routing_append_\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: file) }
        try """
        active_provider = "groq"

        [providers.groq]
        name = "Groq"

        [providers.cloudflare]
        name = "Cloudflare"

        [routing]
        segment_provider = "cloudflare"
        """.data(using: .utf8)!.write(to: file)

        // Ключа final_provider ещё нет — дописывается в конец секции [routing].
        try AppConfig.writeRoutingKeyValue(key: "final_provider", value: "\"groq\"", to: file.path)
        let content = try String(contentsOf: file, encoding: .utf8)
        XCTAssertEqual(content.components(separatedBy: "[routing]").count - 1, 1, "секция не продублирована")
        let config = try AppConfig.load(from: file.path)
        XCTAssertEqual(config.routing.segmentProvider, "cloudflare")
        XCTAssertEqual(config.routing.finalProvider, "groq")
    }

    @objc func testWriteRoutingKeyValueUnsetFallsBackToActive() throws {
        // Очистка роли = пустое значение: файл остаётся парсируемым, резолвер
        // фолбэчит на активного провайдера.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_routing_unset_\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: file) }
        try """
        active_provider = "groq"

        [providers.groq]
        name = "Groq"

        [routing]
        segment_provider = "cloudflare"
        """.data(using: .utf8)!.write(to: file)

        try AppConfig.writeRoutingKeyValue(key: "segment_provider", value: "\"\"", to: file.path)
        let config = try AppConfig.load(from: file.path)
        XCTAssertEqual(config.routing.segmentProvider, "")
        XCTAssertEqual(config.segmentProviderID(), "groq", "очищенная роль — фолбэк на активного")
    }
}
