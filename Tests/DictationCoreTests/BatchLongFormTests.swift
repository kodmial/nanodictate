import Foundation
@testable import DictationCore

// MARK: - Тесты «Практики длинной речи» (пакетный путь): BatchLongForm
//
// Покрытие: BatchPromptChain.tail (контекстная склейка), BatchSTTParams
// (стабильные параметры транскрибации), BatchStableMultipartFields.numberString
// и гейтинг stable-полей по провайдерам.

final class BatchLongFormTests: XCTestCase {

    // MARK: BatchPromptChain.tail

    @objc func testTailEmptyAndWhitespaceReturnsEmpty() {
        XCTAssertEqual(BatchPromptChain.tail(""), "")
        XCTAssertEqual(BatchPromptChain.tail("   \n\t "), "")
    }

    @objc func testTailShorterThanLimitReturnsAsIs() {
        let text = "короткий текст"
        XCTAssertEqual(BatchPromptChain.tail(text), text)
        XCTAssertEqual(BatchPromptChain.tail(text, maxLength: 600), text)
    }

    @objc func testTailExactlyMaxLengthReturnsWhole() {
        let text = String(repeating: "а", count: 600)
        XCTAssertEqual(BatchPromptChain.tail(text), text)
    }

    @objc func testTailLongerTrimsToWindowAndStartsAtWordBoundary() {
        // 12 слов «слово» с пробелами = 6*12-1 = 71 символ. Лимит 40 —
        // окно начинается посередине слова: первое неполное «слово» дропается.
        let words = Array(repeating: "слово", count: 12)
        let text = words.joined(separator: " ")
        let tail = BatchPromptChain.tail(text, maxLength: 40)
        XCTAssertLessThanOrEqual(tail.count, 40)
        XCTAssertEqual(tail, text.split(separator: " ").suffix(6).joined(separator: " "),
                       "окно 40 символов изнутри слова — неполное слово отбрасывается до первого пробела")
    }

    @objc func testTailWindowStartingAtWordBoundaryKeepsWholeWord() {
        // 10 слов «абв» через пробел: 3*10 + 9 = 39 символов. Лимит 30 →
        // окно [-30..): попадает ровно на границу слов. Первое слово в окне
        // целое — не дропается.
        let words = Array(repeating: "абв", count: 10)
        let text = words.joined(separator: " ")
        let tail = BatchPromptChain.tail(text, maxLength: 31)
        let expected = words.suffix(8).joined(separator: " ")
        XCTAssertEqual(tail, expected,
                       "окно на границе слова сохраняет целое первое слово")
    }

    @objc func testTailSingleLongWordWithoutSpacesReturnsAsIs() {
        let text = String(repeating: "длинноеслово", count: 100) // без пробелов
        // Константная проверка: последние 10 символов «…длинноеслово» → «инноеслово».
        XCTAssertEqual(BatchPromptChain.tail(text, maxLength: 10), "инноеслово",
                       "одно длинное слово — хвост возвращается как есть (обрезать нечего до пробела)")
    }

    @objc func testTailTrimsSurroundingWhitespace() {
        let text = "  один два три  "
        XCTAssertEqual(BatchPromptChain.tail(text), "один два три")
    }

    // MARK: BatchSTTParams дефолты

    @objc func testBatchSTTParamsDefaults() {
        let p = BatchSTTParams()
        XCTAssertNil(p.prompt)
        XCTAssertEqual(p.temperature, 0, "temperature=0 — детерминированный декодер + перенос prompt")
        XCTAssertTrue(p.vadFilter, "vad_filter=true — серверный VAD отрезает тишину (где поддержан)")
        XCTAssertEqual(p.noSpeechThreshold, 0.6, "whisper-дефолт")
        XCTAssertEqual(p.compressionRatioThreshold, 2.4, "whisper-дефолт")
        XCTAssertEqual(p.logprobThreshold, -1.0, "whisper-дефолт")
    }

    // MARK: BatchStableMultipartFields.numberString

    @objc func testNumberStringLocaleIndependent() {
        XCTAssertEqual(BatchStableMultipartFields.numberString(0), "0")
        XCTAssertEqual(BatchStableMultipartFields.numberString(0.0), "0")
        XCTAssertEqual(BatchStableMultipartFields.numberString(-1.0), "-1")
        XCTAssertEqual(BatchStableMultipartFields.numberString(0.6), "0.6")
        XCTAssertEqual(BatchStableMultipartFields.numberString(2.4), "2.4")
        XCTAssertEqual(BatchStableMultipartFields.numberString(0.25), "0.25")
    }

    // MARK: Гейтинг stable-полей по провайдерам

    private func fields(for adapterID: String, params: BatchSTTParams? = BatchSTTParams()) -> BatchStableMultipartFields? {
        BatchStableMultipartFields.stableFields(for: adapterID, params: params)
    }

    @objc func testGatingOpenAITemperatureOnly() {
        let f = fields(for: "openai")
        XCTAssertEqual(f?.temperature, 0)
        XCTAssertNil(f?.vadFilter, "vad_filter нет в OpenAI Create transcription")
        XCTAssertNil(f?.noSpeechThreshold)
        XCTAssertNil(f?.compressionRatioThreshold)
        XCTAssertNil(f?.logprobThreshold)
    }

    @objc func testGatingGroqTemperatureAndVadFilter() {
        let f = fields(for: "groq")
        XCTAssertEqual(f?.temperature, 0)
        XCTAssertEqual(f?.vadFilter, true, "groq принимает vad_filter")
        XCTAssertNil(f?.noSpeechThreshold, "groq строгий к неизвестным полям")
    }

    @objc func testGatingOpenAICompatibleTemperatureOnly() {
        // local/relay/gigaam (selfhosted whisper/GigaAM) — все openAICompatible
        for adapter in ["gigaam", "local", "relay", "openai-compatible", "giga-chat"] {
            let f = fields(for: adapter)
            XCTAssertEqual(f?.temperature, 0, "\(adapter): temperature шлётся")
            XCTAssertNil(f?.vadFilter, "\(adapter): vad_filter не шлём")
            XCTAssertNil(f?.noSpeechThreshold)
            XCTAssertNil(f?.compressionRatioThreshold)
            XCTAssertNil(f?.logprobThreshold)
        }
    }

    @objc func testGatingCloudflareAndDeepgramNil() {
        XCTAssertNil(fields(for: "cloudflare"), "raw WAV body — multipart невозможен")
        XCTAssertNil(fields(for: "deepgram"), "только query-параметры")
    }

    @objc func testGatingNilParamsYieldsNil() {
        XCTAssertNil(BatchStableMultipartFields.stableFields(for: "groq", params: nil))
        XCTAssertNil(BatchStableMultipartFields.stableFields(for: "gigaam", params: nil))
    }
}