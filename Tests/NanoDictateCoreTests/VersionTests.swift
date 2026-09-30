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
        // Exercise the production badge formatter, not a locally rebuilt string,
        // so dropping the `v` prefix in production fails this test.
        let display = OverlayVersion.displayString()
        XCTAssertEqual(display, "v\(NanoDictateVersion.string)")
        XCTAssertTrue(display.hasPrefix("v"))
        XCTAssertEqual(OverlayVersion.displayString(for: "1.2.3"), "v1.2.3")
    }

    @objc func testDisplayString_IsCompactSemver() {
        let display = OverlayVersion.displayString()
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
            source.contains("OverlayVersion.displayString()"),
            "overlay header must read OverlayVersion.displayString() (single source of truth)"
        )
        XCTAssertTrue(
            source.contains("NanoDictateVersion.string"),
            "version badge must derive from NanoDictateVersion.string (single source of truth)"
        )
        XCTAssertFalse(
            source.contains("Text(NanoDictateVersion.string)"),
            "overlay must keep the `v` prefix — Text(NanoDictateVersion.string) without the badge formatter would drop it"
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
           let version = source.range(of: "OverlayVersion.displayString()") {
            XCTAssertTrue(
                spacer.lowerBound < version.lowerBound,
                "version label must follow the Spacer so it pins to the far top-right"
            )
        } else {
            XCTFail("header HStack must contain both Spacer and OverlayVersion.displayString()")
        }
    }

    @objc func testPackagingManifestsCarryCurrentVersion() {
        // Regression for the 0.1.14 production packaging smoke failure:
        // Homebrew served 0.1.14 while the MacPorts channel still installed
        // 0.1.13 (verify-package: `nanodictate --version` did not carry the
        // expected version). The generated manifests lagged Version.swift on
        // main, so the documented `curl install-macports.sh` path installed a
        // stale tree. Every generated manifest must carry the current version
        // and no unfilled __VERSION__ placeholder may remain.
        let version = NanoDictateVersion.string
        let files = [
            "packaging/macports/Portfile",
            "packaging/homebrew/nanodictate.rb",
            "packaging/homebrew/Casks/nanodictate.rb",
            "nanodictate.rb",
        ]
        var contents: [String: String] = [:]
        for relative in files {
            guard let source = Self.repoFile(relative) else {
                XCTFail("Could not read \(relative) relative to the package root")
                return
            }
            contents[relative] = source
            XCTAssertFalse(
                source.contains("__VERSION__"),
                "\(relative) still contains an unfilled __VERSION__ placeholder"
            )
            XCTAssertTrue(
                source.contains(version),
                "\(relative) does not carry the current version \(version)"
            )
        }
        guard contents.count == files.count else { return }

        // MacPorts: the port version line, the release download URL and the
        // arch-specific distfile name must all target the current version.
        if let portfile = contents["packaging/macports/Portfile"] {
            XCTAssertTrue(
                portfile.contains("github.setup        kodmial nanodictate \(version) v"),
                "Portfile github.setup does not target \(version)"
            )
            XCTAssertTrue(
                portfile.contains("releases/download/v\(version)"),
                "Portfile master_sites does not target v\(version)"
            )
            XCTAssertTrue(
                portfile.contains("nanodictate-\(version)-macos-"),
                "Portfile distfiles do not target \(version)"
            )
        }
        // Homebrew formula + cask + root mirror: explicit version stanza and
        // arch-specific asset URLs must target the current version.
        for relative in [
            "packaging/homebrew/nanodictate.rb",
            "packaging/homebrew/Casks/nanodictate.rb",
            "nanodictate.rb",
        ] {
            guard let source = contents[relative] else { continue }
            XCTAssertTrue(
                source.contains("version \"\(version)\""),
                "\(relative) version stanza does not declare \(version)"
            )
            XCTAssertTrue(
                source.contains("releases/download/v\(version)/nanodictate-\(version)-macos-"),
                "\(relative) asset URLs do not target v\(version)"
            )
        }
        // The formula and the port install the same tarballs: their pinned
        // tarball checksums must agree, otherwise the channels ship different
        // bytes for the same version.
        if let formula = contents["packaging/homebrew/nanodictate.rb"],
           let portfile = contents["packaging/macports/Portfile"]
        {
            let formulaSHAs = Self.hexTokens(
                in: formula,
                pattern: "sha256\\s+\"([0-9a-f]{64})\""
            )
            let portSHAs = Self.hexTokens(
                in: portfile,
                pattern: "set distfile_sha256\\s+([0-9a-f]{64})"
            )
            XCTAssertEqual(formulaSHAs.count, 2, "formula must pin exactly 2 tarball checksums")
            XCTAssertEqual(portSHAs.count, 2, "Portfile must pin exactly 2 tarball checksums")
            XCTAssertEqual(
                Set(formulaSHAs), Set(portSHAs),
                "Homebrew formula and MacPorts Portfile pin different tarball checksums"
            )
        }
        // The MacPorts installer pins the canonical tree to an exact revision;
        // a missing or malformed pin would leave the documented install path
        // untethered from the synced tree.
        guard let installer = Self.repoFile("scripts/install-macports.sh") else {
            XCTFail("Could not read scripts/install-macports.sh relative to the package root")
            return
        }
        let pinFound: Bool = {
            guard let regex = try? NSRegularExpression(pattern: "PIN_REV=\"[0-9a-f]{40}\"") else {
                return false
            }
            let range = NSRange(installer.startIndex..., in: installer)
            return regex.firstMatch(in: installer, range: range) != nil
        }()
        XCTAssertTrue(pinFound, "scripts/install-macports.sh must pin PIN_REV to a 40-char git revision")
    }

    private static func repoFile(_ relative: String) -> String? {
        let fileDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let candidates = [
            fileDir.deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent(relative),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent(relative),
        ]
        guard let sourceURL = candidates.first(where: {
            FileManager.default.fileExists(atPath: $0.path)
        }) else {
            return nil
        }
        return try? String(contentsOf: sourceURL, encoding: .utf8)
    }

    private static func hexTokens(in source: String, pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(source.startIndex..., in: source)
        return regex.matches(in: source, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let tokenRange = Range(match.range(at: 1), in: source)
            else { return nil }
            return String(source[tokenRange])
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
