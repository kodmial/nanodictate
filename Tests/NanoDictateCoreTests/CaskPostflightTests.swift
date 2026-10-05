import Foundation
@testable import NanoDictateCore

// MARK: - Homebrew Cask postflight smoke (issue #156, item 2)
//
// Regression: the cask postflight carried a literal `{{appdir}}` placeholder,
// so the quarantine-removal step targeted a nonexistent path and Gatekeeper
// kept refusing the first launch. This suite proves (mirroring
// scripts/check-cask-postflight.sh, which runs without macOS) that both the
// template — the source of truth consumed by scripts/release-prep.rb and the
// candidate smoke gate — and the generated cask resolve the REAL installed
// app path via the Cask DSL interpolation and remove ONLY
// com.apple.quarantine.

final class CaskPostflightTests: XCTestCase {

    private static func caskContents() -> (template: String, generated: String)? {
        let fileDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let repoRoot = fileDir
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates: [(String, String)] = [
            (
                repoRoot.appendingPathComponent("packaging/homebrew/Casks/nanodictate.rb.tpl").path,
                repoRoot.appendingPathComponent("packaging/homebrew/Casks/nanodictate.rb").path
            ),
            (
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("packaging/homebrew/Casks/nanodictate.rb.tpl").path,
                URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                    .appendingPathComponent("packaging/homebrew/Casks/nanodictate.rb").path
            ),
        ]
        for (tplPath, genPath) in candidates {
            if let tpl = try? String(contentsOfFile: tplPath, encoding: .utf8),
               let gen = try? String(contentsOfFile: genPath, encoding: .utf8) {
                return (tpl, gen)
            }
        }
        return nil
    }

    private static func postflightStanza(in content: String) -> String {
        guard let start = content.range(of: "postflight_steps do")?.lowerBound,
              let end = content[start...].range(of: "end")?.upperBound else {
            return ""
        }
        return String(content[start..<end])
    }

    @objc func testNoLiteralAppdirPlaceholder() {
        guard let casks = Self.caskContents() else {
            XCTFail("cannot read the Homebrew cask files")
            return
        }
        XCTAssertFalse(
            casks.template.contains("{{appdir}}"),
            "template must not contain a literal {{appdir}} placeholder")
        XCTAssertFalse(
            casks.generated.contains("{{appdir}}"),
            "generated cask must not contain a literal {{appdir}} placeholder")
    }

    @objc func testPostflightResolvesInstalledAppPath() {
        guard let casks = Self.caskContents() else {
            XCTFail("cannot read the Homebrew cask files")
            return
        }
        for (name, content) in [("template", casks.template), ("generated", casks.generated)] {
            let stanza = Self.postflightStanza(in: content)
            XCTAssertFalse(stanza.isEmpty, "\(name): postflight_steps stanza must exist")
            XCTAssertTrue(
                stanza.contains("#{appdir}/NanoDictate.app"),
                "\(name): postflight must resolve the installed app path via #{appdir}")
        }
    }

    @objc func testPostflightRemovesOnlyQuarantine() {
        guard let casks = Self.caskContents() else {
            XCTFail("cannot read the Homebrew cask files")
            return
        }
        for (name, content) in [("template", casks.template), ("generated", casks.generated)] {
            let stanza = Self.postflightStanza(in: content)
            XCTAssertTrue(
                stanza.contains("\"-dr\", \"com.apple.quarantine\""),
                "\(name): postflight must strip exactly com.apple.quarantine via xattr -dr")
            XCTAssertFalse(
                stanza.contains("\"-c\""),
                "\(name): postflight must not wipe all extended attributes")
            XCTAssertFalse(
                stanza.contains("spctl"),
                "\(name): postflight must not change Gatekeeper state")
            XCTAssertFalse(
                stanza.lowercased().contains("gatekeeper"),
                "\(name): postflight must not change Gatekeeper state")
        }
    }

    @objc func testTemplateAndGeneratedPostflightAgree() {
        guard let casks = Self.caskContents() else {
            XCTFail("cannot read the Homebrew cask files")
            return
        }
        func normalized(_ content: String) -> String {
            // Release placeholders filled by scripts/release-prep.rb plus the
            // released version/SHA values in the generated cask.
            var text = content
            for placeholder in ["__VERSION__", "__ZIP_SHA256_ARM64__", "__ZIP_SHA256_X86_64__"] {
                text = text.replacingOccurrences(of: placeholder, with: "")
            }
            // Strip concrete 0.1.24-style versions and 64-hex SHAs so only the
            // invariant stanza shape is compared.
            let versionPattern = try? NSRegularExpression(pattern: "[0-9]+\\.[0-9]+\\.[0-9]+")
            text = versionPattern?.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "") ?? text
            let shaPattern = try? NSRegularExpression(pattern: "[0-9a-f]{64}")
            text = shaPattern?.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "") ?? text
            return Self.postflightStanza(in: text)
        }
        XCTAssertEqual(
            normalized(casks.template), normalized(casks.generated),
            "postflight stanza drift between template and generated cask")
    }
}
