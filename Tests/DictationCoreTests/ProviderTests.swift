import Foundation
@testable import DictationCore

final class ProviderTests: XCTestCase {

    private func tmpFile(_ name: String, _ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)_\(UUID().uuidString).toml")
        try content.data(using: .utf8)!.write(to: url)
        return url
    }

    private func filePermissions(_ url: URL) throws -> UInt16 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.uint16Value ?? 0
    }

    // MARK: - Парсинг секций

    @objc func testParseTwoProviders() throws {
        let content = """
        [providers.groq]
        name = "Groq (yandex-proxy)"
        base_url = "https://groq.test/v1"
        model = "whisper-large-v3"
        api_key = "gsk_123"
        proxy_key = "px-1"
        [providers.gigaam]
        name = "GigaAM (mwsapis)"
        base_url = "https://gigaam.test/v1"
        model = "gigaam-v3"
        api_key_file = "~/.config/dictation/keys/gigaam.key"
        """
        let config = try AppConfig.parse(content)

        XCTAssertEqual(config.providers.count, 2)
        XCTAssertEqual(config.providerNames, ["groq", "gigaam"])
        XCTAssertEqual(config.activeProvider, "")
        // Без active_provider и без legacy-ключей → активен первый по порядку.
        XCTAssertEqual(config.baseURL, "https://groq.test/v1")
        XCTAssertEqual(config.model, "whisper-large-v3")
        // Effective apiKeyFile берётся из активного провайдера (groq) — у него файла нет.
        XCTAssertNil(config.apiKeyFile)

        let groq = config.providers[0]
        XCTAssertEqual(groq.id, "groq")
        XCTAssertEqual(groq.name, "Groq (yandex-proxy)")
        XCTAssertEqual(groq.baseURL, "https://groq.test/v1")
        XCTAssertEqual(groq.model, "whisper-large-v3")
        XCTAssertEqual(groq.apiKey, "gsk_123")
        XCTAssertEqual(groq.proxyKey, "px-1")
        XCTAssertNil(groq.apiKeyFile)

        let gigaam = config.providers[1]
        XCTAssertEqual(gigaam.id, "gigaam")
        XCTAssertEqual(gigaam.name, "GigaAM (mwsapis)")
        XCTAssertEqual(gigaam.apiKeyFile, "~/.config/dictation/keys/gigaam.key")
        XCTAssertEqual(gigaam.apiKey, "")
    }

    @objc func testActiveProviderFillsEffectiveFields() throws {
        let content = """
        active_provider = "gigaam"
        [providers.groq]
        base_url = "https://groq.test/v1"
        model = "whisper-large-v3"
        api_key = "gsk_123"
        [providers.gigaam]
        base_url = "https://gigaam.test/v1"
        model = "gigaam-v3"
        api_key_file = "~/.keys/gigaam.key"
        proxy_key = "px-2"
        """
        let config = try AppConfig.parse(content)

        XCTAssertEqual(config.activeProvider, "gigaam")
        XCTAssertEqual(config.baseURL, "https://gigaam.test/v1")
        XCTAssertEqual(config.model, "gigaam-v3")
        XCTAssertEqual(config.apiKeyFile, "~/.keys/gigaam.key")
        XCTAssertEqual(config.proxyKey, "px-2")
        XCTAssertEqual(config.apiKey, "")
    }

    // MARK: - Правила резолва

    /// legacy-only без секций → ровно прежнее поведение.
    @objc func testLegacyOnlyKeepsPreviousBehavior() throws {
        let content = """
        base_url = "https://mwsapis.test/v1"
        model = "gigaam-v3"
        api_key = "legacy-key"
        proxy_key = "legacy-proxy"
        timeout_seconds = 45
        """
        let config = try AppConfig.parse(content)

        XCTAssertEqual(config.baseURL, "https://mwsapis.test/v1")
        XCTAssertEqual(config.model, "gigaam-v3")
        XCTAssertEqual(config.apiKey, "legacy-key")
        XCTAssertEqual(config.proxyKey, "legacy-proxy")
        XCTAssertEqual(config.timeoutSeconds, 45)
        XCTAssertTrue(config.providers.isEmpty)
        XCTAssertEqual(config.activeProvider, "")
    }

    /// legacy-ключи + секции без active_provider → ОШИБКА «неоднозначно».
    @objc func testLegacyPlusProvidersWithoutActiveThrows() {
        let content = """
        base_url = "https://legacy.test/v1"
        [providers.groq]
        base_url = "https://groq.test/v1"
        api_key = "k"
        """
        XCTAssertThrowsError(try AppConfig.parse(content)) { error in
            guard case AppConfig.AppConfigError.ambiguousLegacyAndProviders = error else {
                XCTFail("Expected ambiguousLegacyAndProviders, got \(error)")
                return
            }
        }
    }

    /// active_provider не существует → ошибка со списком доступных.
    @objc func testActiveProviderNotFoundThrowsWithList() {
        let content = """
        active_provider = "nope"
        [providers.groq]
        base_url = "https://groq.test/v1"
        [providers.gigaam]
        base_url = "https://gigaam.test/v1"
        """
        XCTAssertThrowsError(try AppConfig.parse(content)) { error in
            guard case AppConfig.AppConfigError.activeProviderNotFound(let active, let available) = error else {
                XCTFail("Expected activeProviderNotFound, got \(error)")
                return
            }
            XCTAssertEqual(active, "nope")
            XCTAssertEqual(available, ["groq", "gigaam"])
        }
    }

    /// Дубликат имени секции → ошибка.
    @objc func testDuplicateProviderThrows() {
        let content = """
        [providers.groq]
        base_url = "https://a.test/v1"
        [providers.groq]
        base_url = "https://b.test/v1"
        """
        XCTAssertThrowsError(try AppConfig.parse(content)) { error in
            guard case AppConfig.AppConfigError.duplicateProvider(let id) = error else {
                XCTFail("Expected duplicateProvider, got \(error)")
                return
            }
            XCTAssertEqual(id, "groq")
        }
    }

    // MARK: - Регресс-гард: ключи секций не утекают в top-level

    @objc func testSectionKeysDoNotLeakToTopLevel() throws {
        let content = """
        base_url = "https://global.test/v1"
        api_key = "global-key"
        [api]
        base_url = "https://evil.test/v1"
        api_key = "evil-key"
        model = "evil-model"
        timeout_seconds = 1
        """
        let config = try AppConfig.parse(content)

        XCTAssertEqual(config.baseURL, "https://global.test/v1")
        XCTAssertEqual(config.apiKey, "global-key")
        // model не тронут ключом из [api]; timeout тоже.
        XCTAssertEqual(config.model, AppConfig.defaults.model)
        XCTAssertEqual(config.timeoutSeconds, AppConfig.defaults.timeoutSeconds)
        XCTAssertTrue(config.providers.isEmpty)
    }

    // MARK: - writeActiveProvider (точечная правка, файл сохраняется байт-в-байт)

    @objc func testWriteActiveProviderReplacesLinePreservingFile() throws {
        let original = """
        # комментарий
        base_url = "https://x"
        active_provider = "groq"

        [providers.groq]
        api_key = "sekret"

        """
        let url = try tmpFile("write_replace", original)
        defer { try? FileManager.default.removeItem(at: url) }

        try AppConfig.writeActiveProvider(name: "gigaam", to: url.path)

        let expected = """
        # комментарий
        base_url = "https://x"
        active_provider = "gigaam"

        [providers.groq]
        api_key = "sekret"

        """
        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(content, expected)
        let perms = try filePermissions(url)
        XCTAssertEqual(perms, 0o600)
    }

    @objc func testWriteActiveProviderAppendsWhenMissing() throws {
        let original = "base_url = \"https://x\"\n"
        let url = try tmpFile("write_append", original)
        defer { try? FileManager.default.removeItem(at: url) }

        try AppConfig.writeActiveProvider(name: "groq", to: url.path)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(content, "base_url = \"https://x\"\nactive_provider = \"groq\"\n")
        let perms = try filePermissions(url)
        XCTAssertEqual(perms, 0o600)
    }

    @objc func testWriteActiveProviderCreatesMissingFile() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("write_create_\(UUID().uuidString).toml")
        defer { try? FileManager.default.removeItem(at: url) }

        try AppConfig.writeActiveProvider(name: "ya", to: url.path)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(content, "active_provider = \"ya\"\n")
        let perms = try filePermissions(url)
        XCTAssertEqual(perms, 0o600)
    }

    // MARK: - Раскрытие ~ в api_key_file

    @objc func testLoadExpandsTildeInApiKeyFile() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let keyPath = "\(home)/.dictation_test_key_\(UUID().uuidString).key"
        try "tilde-key".data(using: .utf8)!.write(to: URL(fileURLWithPath: keyPath))
        defer { try? FileManager.default.removeItem(atPath: keyPath) }

        // Превращаем абсолютный путь в "~/..." — единственный способ проверить
        // раскрытие тильды, не кладя файл в реальный .config/dictation.
        let tildePath = (keyPath as NSString).replacingOccurrences(of: home, with: "~")
        XCTAssertTrue(tildePath.hasPrefix("~/"))

        let toml = "api_key_file = \"\(tildePath)\"\n"
        let url = try tmpFile("tilde", toml)
        defer { try? FileManager.default.removeItem(at: url) }

        let config = try AppConfig.load(from: url.path)
        XCTAssertEqual(config.apiKey, "tilde-key")
    }

    // MARK: - ProviderStore (контракт для меню)

    @objc func testProviderStoreLoadSetsActive() throws {
        let url = try tmpFile("store_load", """
        active_provider = "groq"
        [providers.groq]
        base_url = "https://groq.test/v1"
        model = "whisper-large-v3"
        [providers.ya]
        base_url = "https://ya.test/v1"
        model = "gigaam-v3"
        """)
        ProviderStore.configPathOverride = url.path
        defer { ProviderStore.configPathOverride = nil }

        let providers = try ProviderStore.loadProviders()

        XCTAssertEqual(providers.count, 2)
        XCTAssertEqual(providers[0].id, "groq")
        XCTAssertTrue(providers[0].isActive)
        XCTAssertEqual(providers[0].baseURL, "https://groq.test/v1")
        XCTAssertFalse(providers[1].isActive)
        XCTAssertEqual(ProviderStore.activeProvider?.id, "groq")
        XCTAssertEqual(ProviderStore.activeProvider?.name, "groq") // нет name → fallback на id
    }

    @objc func testProviderStoreSetActiveWritesConfig() throws {
        let url = try tmpFile("store_use", """
        active_provider = "groq"
        [providers.groq]
        api_key = "a"
        [providers.ya]
        api_key = "b"
        """)
        ProviderStore.configPathOverride = url.path
        defer { ProviderStore.configPathOverride = nil }

        try ProviderStore.setActive(providerID: "ya")

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.contains("active_provider = \"ya\""))
        // Остальной файл не пострадал.
        XCTAssertTrue(content.contains("[providers.groq]"))
        XCTAssertEqual(ProviderStore.activeProvider?.id, "ya")
        let providers = try ProviderStore.loadProviders()
        XCTAssertTrue(providers.first { $0.id == "ya" }!.isActive)
        XCTAssertFalse(providers.first { $0.id == "groq" }!.isActive)
    }

    @objc func testProviderStoreSetActiveUnknownThrows() throws {
        let url = try tmpFile("store_unknown", """
        [providers.groq]
        api_key = "a"
        """)
        ProviderStore.configPathOverride = url.path
        defer { ProviderStore.configPathOverride = nil }

        XCTAssertThrowsError(try ProviderStore.setActive(providerID: "nope")) { error in
            guard case ProviderStoreError.unknownProvider(let id, let available) = error else {
                XCTFail("Expected unknownProvider, got \(error)")
                return
            }
            XCTAssertEqual(id, "nope")
            XCTAssertEqual(available, ["groq"])
        }
    }

    /// Загрузка провайдеров не бросает из-за stale active_provider —
    /// меню должно позволять починить выбор.
    @objc func testProviderStoreLoadWorksWithStaleActive() throws {
        let url = try tmpFile("store_stale", """
        active_provider = "stale"
        [providers.groq]
        base_url = "https://groq.test/v1"
        """)
        ProviderStore.configPathOverride = url.path
        defer { ProviderStore.configPathOverride = nil }

        let providers = try ProviderStore.loadProviders()
        XCTAssertEqual(providers.count, 1)
        XCTAssertNil(ProviderStore.activeProvider) // stale не совпал ни с одним
    }
}