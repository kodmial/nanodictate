import Foundation
@testable import NanoDictateCore

// MARK: - ConfigMaskingTests
// Покрытие чистой функции AppConfig.maskFileSecrets — слайсер секретных
// значений в сыром тексте конфига (переехала из CLI main.swift).
// Фактическая логика маски: первые 4 + "***" + последние 4 символа
// (maskSecret), значения короче/равные 8 символам — просто "***".

final class ConfigMaskingTests: XCTestCase {

    // MARK: - Основные секретные ключи

    @objc func testMasksApiKeyValue() {
        let masked = AppConfig.maskFileSecrets(in: #"api_key = "abc123secret""#)
        XCTAssertEqual(masked, #"api_key = "abc1***cret""#)
    }

    @objc func testMasksAllThreeSecretKeys() {
        let masked = AppConfig.maskFileSecrets(
            in: """
            api_key = "abcdefgh12345678"
            proxy_key = "qwertyuiopasdfgh"
            proxy_password = "zxcvbnm1234567890"
            """
        )
        // По ключам — чтобы фейл показывал, какой ключ не замаскировался.
        let lines = masked.components(separatedBy: .newlines)
        XCTAssertEqual(lines[0], #"api_key = "abcd***5678""#)
        XCTAssertEqual(lines[1], #"proxy_key = "qwer***dfgh""#)
        XCTAssertEqual(lines[2], #"proxy_password = "zxcv***7890""#)
    }

    @objc func testMasksKeyWithPaddingSpacesAroundEquals() {
        let masked = AppConfig.maskFileSecrets(in: #"  api_key  =  "abcdefgh12345678"  "#)
        XCTAssertEqual(masked, #"  api_key  =  "abcd***5678"  "#)
    }

    // MARK: - Значения

    @objc func testEmptyValueStaysEmptyNotTripleQuotes() {
        let masked = AppConfig.maskFileSecrets(in: #"api_key = """#)
        XCTAssertEqual(masked, #"api_key = """#)
    }

    @objc func testShortValueBecomesJustStars() {
        // длина ≤ 8 → maskSecret возвращает "***" (ветка else maskSecret)
        let masked = AppConfig.maskFileSecrets(in: #"api_key = "abc12""#)
        XCTAssertEqual(masked, #"api_key = "***""#)
    }

    @objc func testValueWithSpacesAndSpecialChars() {
        // пробелы внутри кавычек обрезаются maskSecret, спецсимволы маскируются
        let input = #"proxy_password = "ab cd!@#$12""#
        let masked = AppConfig.maskFileSecrets(in: input)
        XCTAssertEqual(masked, #"proxy_password = "ab c***#$12""#)
    }

    @objc func testTrailingCommentAfterValuePreserved() {
        let masked = AppConfig.maskFileSecrets(in: #"api_key = "abc123secret" # my comment"#)
        XCTAssertEqual(masked, #"api_key = "abc1***cret" # my comment"#)
    }

    // MARK: - НЕ маскируется

    @objc func testUnquotedValueNotMasked() {
        let input = #"api_key = abc123secret"#
        XCTAssertEqual(AppConfig.maskFileSecrets(in: input), input)
    }

    @objc func testUnclosedQuoteNotMasked() {
        let input = #"api_key = "abc123secret"#
        XCTAssertEqual(AppConfig.maskFileSecrets(in: input), input)
    }

    @objc func testCommentLineUntouched() {
        let input = #"# api_key = "abc123secret""#
        XCTAssertEqual(AppConfig.maskFileSecrets(in: input), input)
    }

    @objc func testNonSecretKeyUntouched() {
        let input = #"model = "abc123secret""#
        XCTAssertEqual(AppConfig.maskFileSecrets(in: input), input)
    }

    @objc func testLineWithoutEqualsUntouched() {
        let input = "some api_key line"
        XCTAssertEqual(AppConfig.maskFileSecrets(in: input), input)
    }

    // MARK: - Многострочный контент

    @objc func testMultiLineContentMasksOnlySecretLines() {
        let input = """
        base_url = "https://proxy.example.com"
        api_key = "abcdefgh12345678"
        # комментарий api_key = "не маскируется"
        model = "gigaam-v3"
        proxy_password = ""
        """
        let masked = AppConfig.maskFileSecrets(in: input)
        XCTAssertEqual(
            masked,
            """
            base_url = "https://proxy.example.com"
            api_key = "abcd***5678"
            # комментарий api_key = "не маскируется"
            model = "gigaam-v3"
            proxy_password = ""
            """
        )
    }
}