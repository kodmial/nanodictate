import Foundation
@testable import NanoDictateCore

/// Version constant tests; single source of truth for `nanodictate --version` (see Version.swift).
final class VersionTests: XCTestCase {

    @objc func testVersionStringIsSemver() {
        let parts = NanoDictateVersion.string.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "версия должна быть в формате major.minor.patch")
        XCTAssertTrue(parts.allSatisfy { !$0.isEmpty }, "все компоненты semver должны быть непустыми")
    }

    @objc func testVersionStringEqualsCurrentRelease() {
        // Канон версии — CHANGELOG.md: первый релизный заголовок `## [<semver>]`
        // сразу после блока `## [Unreleased]`. SwiftPM запускает тесты с
        // текущей рабочей директорией = корень пакета (в CI — корень клона),
        // где и лежит CHANGELOG.md.
        let changelogPath = FileManager.default.currentDirectoryPath + "/CHANGELOG.md"
        let changelog: String
        do {
            changelog = try String(contentsOfFile: changelogPath, encoding: .utf8)
        } catch {
            return XCTFail("не удалось прочитать \(changelogPath): \(error.localizedDescription)")
        }

        // Ищем первый заголовок релиза после строки `## [Unreleased]`.
        var foundUnreleased = false
        var currentRelease: String? = nil
        for line in changelog.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !foundUnreleased {
                // до маркера незарелизенных изменений — пропускаем всё
                if trimmed.hasPrefix("## [Unreleased]") {
                    foundUnreleased = true
                }
                continue
            }
            // после Unreleased смотрим только заголовки релизов `## [<semver>]`
            guard trimmed.hasPrefix("## ["),
                  let open = trimmed.firstIndex(of: "["),
                  let close = trimmed.firstIndex(of: "]") else { continue }
            let candidate = String(trimmed[trimmed.index(after: open)..<close])
            let parts = candidate.split(separator: ".")
            // берём первый же заголовок semver-формы major.minor.patch
            if parts.count == 3, parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isNumber } }) {
                currentRelease = candidate
                break
            }
        }

        guard let currentRelease = currentRelease else {
            return XCTFail("в \(changelogPath) не найден релизный заголовок `## [<semver>]` после `## [Unreleased]`")
        }
        XCTAssertEqual(NanoDictateVersion.string, currentRelease,
                       "NanoDictateVersion.string (\(NanoDictateVersion.string)) рассинхронизирована с CHANGELOG.md (\(currentRelease)) — обнови их вместе")
    }
}