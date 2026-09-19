import Foundation
@testable import NanoDictateCore

/// Тесты константы версии (NanoDictateVersion): semver-форма и значение релиза.
/// Единственный источник правды для `nanodictate --version` — см. Version.swift.
final class VersionTests: XCTestCase {

    @objc func testVersionStringIsSemver() {
        let parts = NanoDictateVersion.string.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "версия должна быть в формате major.minor.patch")
        XCTAssertTrue(parts.allSatisfy { !$0.isEmpty }, "все компоненты semver должны быть непустыми")
    }

    @objc func testVersionStringEqualsCurrentRelease() {
        XCTAssertEqual(NanoDictateVersion.string, "0.1.0")
    }
}