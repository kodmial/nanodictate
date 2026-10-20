import Foundation
@testable import NanoDictateCore

/// Cross-platform contract vectors shared with the Windows suite
/// (Tests/Fixtures/portable-parity.json). Configuration and request
/// assertions only cover fields both hosts advertise; intentional platform
/// differences live in docs/config-parity.md.
final class PortableParityTests: XCTestCase {

  private struct FixtureError: Error, CustomStringConvertible {
    let description: String
  }

  private struct Fixture {
    let configCases: [[String: Any]]
    let requestCases: [[String: Any]]
  }

  private static func fixtureURL() -> URL? {
    let source = URL(fileURLWithPath: #filePath)
    let root = source.deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let candidate = root.appendingPathComponent("Tests/Fixtures/portable-parity.json")
    return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
  }

  private static func loadFixture() throws -> Fixture {
    guard let url = fixtureURL(),
      let data = try? Data(contentsOf: url),
      let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
      throw FixtureError(description: "portable-parity.json not found or unreadable")
    }
    let version = (root["version"] as? NSNumber)?.intValue ?? 0
    guard version == 1 else {
      throw FixtureError(description: "unsupported fixture version \(version)")
    }
    guard let configCases = root["config_cases"] as? [[String: Any]],
      let requestCases = root["request_cases"] as? [[String: Any]]
    else {
      throw FixtureError(description: "fixture cases are missing")
    }
    return Fixture(configCases: configCases, requestCases: requestCases)
  }

  private static func string(_ object: [String: Any], _ key: String) -> String {
    object[key] as? String ?? ""
  }

  private static func dictionary(_ object: [String: Any], _ key: String) -> [String: Any] {
    object[key] as? [String: Any] ?? [:]
  }

  private static func stringDictionary(_ object: [String: Any], _ key: String) -> [String: String] {
    (object[key] as? [String: String]) ?? [:]
  }

  private static func array(_ object: [String: Any], _ key: String) -> [[String: Any]] {
    object[key] as? [[String: Any]] ?? []
  }

  private static func withEnvironment(
    _ values: [String: String], _ body: () throws -> Void
  ) rethrows {
    let keys = Set(values.keys).union(["NANODICTATE_API_KEY"])
    var previous: [String: String] = [:]
    for key in keys {
      if let value = ProcessInfo.processInfo.environment[key] {
        previous[key] = value
      }
    }
    defer {
      for key in keys {
        if let value = previous[key] {
          setenv(key, value, 1)
        } else {
          unsetenv(key)
        }
      }
    }
    for key in keys {
      unsetenv(key)
    }
    for (key, value) in values {
      setenv(key, value, 1)
    }
    try body()
  }

  @objc func testSharedConfigVectorsMatchSwiftProductionPath() throws {
    let fixture = try Self.loadFixture()
    XCTAssertFalse(fixture.configCases.isEmpty, "config fixture cases are required")
    let previousOverride = AppConfig.exampleContentOverride
    AppConfig.exampleContentOverride = ""
    defer { AppConfig.exampleContentOverride = previousOverride }
    for testCase in fixture.configCases {
      let name = Self.string(testCase, "name")
      try Self.withEnvironment(Self.stringDictionary(testCase, "env")) {
        try Self.assertConfigCase(testCase, name: name)
      }
    }
  }

  private static func assertConfigCase(_ testCase: [String: Any], name: String) throws {
    let expected = dictionary(testCase, "expected")
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("nanodictate-parity-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    for (relativePath, content) in stringDictionary(testCase, "files") {
      let fileURL = directory.appendingPathComponent(relativePath)
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data(content.utf8).write(to: fileURL)
    }
    let lines = (testCase["config"] as? [String]) ?? []
    let content = lines.joined(separator: "\n")
      .replacingOccurrences(of: "${KEY_DIR}", with: directory.path)
    let configURL = directory.appendingPathComponent("config.toml")
    try Data(content.utf8).write(to: configURL)

    let config = try AppConfig.load(from: configURL.path)
    XCTAssertEqual(config.activeProvider, string(expected, "active_provider"), name)
    XCTAssertEqual(config.language, string(expected, "language"), name)
    XCTAssertEqual(config.routing.segmentProvider, string(expected, "segment_provider"), name)
    XCTAssertEqual(config.routing.finalProvider, string(expected, "final_provider"), name)
    if let expectedOrder = expected["failover_order"] as? [String] {
      let effectiveOrder = config.failoverProviders(excluding: nil).map(\.id)
      XCTAssertEqual(effectiveOrder, expectedOrder, name)
    }

    let expectedProviders = array(expected, "providers")
    XCTAssertEqual(config.providers.count, expectedProviders.count, name)
    for (provider, wanted) in zip(config.providers, expectedProviders) {
      XCTAssertEqual(provider.id, string(wanted, "id"), name)
      XCTAssertEqual(provider.name, string(wanted, "name"), name)
      XCTAssertEqual(provider.baseURL, string(wanted, "base_url"), name)
      XCTAssertEqual(provider.model, string(wanted, "model"), name)
    }
    for (id, wantedKey) in stringDictionary(expected, "resolved_api_keys") {
      guard let provider = config.providers.first(where: { $0.id == id }) else {
        XCTFail("\(name): missing provider \(id)")
        continue
      }
      let resolved = RetryProvider.resolveAPIKey(
        for: provider, activeProviderID: config.activeProvider)
      XCTAssertEqual(resolved, wantedKey, "\(name): resolved key for \(id)")
    }
  }

  @objc func testSharedRequestVectorsMatchSwiftProductionPath() throws {
    let fixture = try Self.loadFixture()
    XCTAssertFalse(fixture.requestCases.isEmpty, "request fixture cases are required")
    for testCase in fixture.requestCases {
      let name = Self.string(testCase, "name")
      let providerFields = Self.dictionary(testCase, "provider")
      let expected = Self.dictionary(testCase, "expected")
      let apiKey = Self.string(providerFields, "api_key")
      let provider = AppConfig.Provider(
        id: Self.string(providerFields, "id"),
        name: Self.string(providerFields, "id"),
        baseURL: Self.string(providerFields, "base_url"),
        model: Self.string(providerFields, "model"),
        apiKey: apiKey,
        apiKeyFile: nil,
        proxyKey: ""
      )
      let prompt = testCase["prompt"] as? String
      let spec = ProviderRequestBuilder.plan(
        adapterID: provider.id,
        baseURL: provider.baseURL,
        model: provider.model,
        apiKey: apiKey,
        language: Self.string(testCase, "language"),
        wav: Data([1, 2, 3]),
        prompt: prompt,
        needsWordTimestamps: testCase["needs_word_timestamps"] as? Bool ?? false
      )

      XCTAssertEqual(spec.url?.absoluteString, Self.string(expected, "url"), name)
      let headers = spec.headers.filter { !(apiKey.isEmpty && $0.0 == "Authorization") }
      let authorization = headers.first(where: { $0.0 == "Authorization" })?.1
      XCTAssertEqual(authorization, expected["authorization"] as? String, name)

      let body = String(decoding: spec.bodyData, as: UTF8.self)
      for (field, value) in Self.stringDictionary(expected, "fields") {
        XCTAssertTrue(
          body.contains("name=\"\(field)\"\r\n\r\n\(value)\r\n"),
          "\(name): missing field \(field)")
      }
      for absent in (expected["absent"] as? [String]) ?? [] {
        XCTAssertFalse(
          body.contains("name=\"\(absent)\"\r\n"), "\(name): unexpected field \(absent)")
      }
      XCTAssertTrue(
        body.contains(
          "name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: "
            + Self.string(expected, "file_content_type") + "\r\n\r\n"),
        "\(name): file part content type")
    }
  }
}
