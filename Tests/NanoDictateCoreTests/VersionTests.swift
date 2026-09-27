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

    @objc func testDisplayString_HasVPrefixAndMatchesVersion() {
        let display = "v\(NanoDictateVersion.string)"
        XCTAssertEqual(display, "v\(NanoDictateVersion.string)")
        XCTAssertTrue(display.hasPrefix("v"))
    }

    @objc func testDisplayString_IsCompactSemver() {
        let display = "v\(NanoDictateVersion.string)"
        XCTAssertTrue(display.hasPrefix("v"), "header version must use compact `vX.Y.Z` format")
        let bare = String(display.dropFirst())
        let parts = bare.split(separator: ".")
        XCTAssertEqual(parts.count, 3, "display version must stay major.minor.patch")
        XCTAssertTrue(parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isNumber } })
    }

    @objc func testOverlayHeader_UsesVersionSourceWithoutHardcodedDuplicate() {
        guard let source = Self.overlayControllerSource() else {
            XCTFail("Could not read Sources/NanoDictateCore/OverlayController.swift")
            return
        }
        XCTAssertTrue(
            source.contains("NanoDictateVersion.string"),
            "overlay header must read NanoDictateVersion.string (single source of truth)"
        )
        // No separately hard-coded version literal in the header/view that can drift.
        let pattern = "\"v[0-9]+\\.[0-9]+\\.[0-9]+\""
        let foundHardcoded: Bool = {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
            let range = NSRange(source.startIndex..., in: source)
            return regex.firstMatch(in: source, range: range) != nil
        }()
        XCTAssertFalse(
            foundHardcoded,
            "overlay must not hard-code a version like \"v0.1.1\" — use NanoDictateVersion"
        )
        // Version sits after the Spacer in the same header HStack (far top-right).
        if let spacer = source.range(of: "Spacer(minLength: 0)"),
           let version = source.range(of: "NanoDictateVersion.string") {
            XCTAssertTrue(
                spacer.lowerBound < version.lowerBound,
                "version label must follow the Spacer so it pins to the far top-right"
            )
        } else {
            XCTFail("header HStack must contain both Spacer and NanoDictateVersion.string")
        }
    }

    private static func overlayControllerSource() -> String? {
        let fileDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let candidates = [
            fileDir.deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/NanoDictateCore/OverlayController.swift"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("Sources/NanoDictateCore/OverlayController.swift"),
        ]
        guard let sourceURL = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            return nil
        }
        return try? String(contentsOf: sourceURL, encoding: .utf8)
    }
}
