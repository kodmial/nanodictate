import Foundation
@testable import NanoDictateCore

// MARK: - STTAdapterTests
//
// No network: request building (url/headers/body/contentType/transcriptPath)
// and response text parsing (extractText, byte-exact multipartBody).

final class STTAdapterTests: XCTestCase {

    private let wav = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00]) // "RIFF\0\0"

    // MARK: - Идентификаторы адаптеров

    @objc func testKnownProviderIDs() {
        let known = ProviderRequestBuilder.knownProviderIDs
        XCTAssertTrue(known.contains("openai"))
        XCTAssertTrue(known.contains("groq"))
        XCTAssertTrue(known.contains("cloudflare"))
        XCTAssertFalse(known.contains("custom"))
        // Removed adapters must stay gone — fallback would hide a regression.
        XCTAssertFalse(known.contains("deepgram"))
        XCTAssertFalse(known.contains("giga-chat"))
        XCTAssertFalse(known.contains("relay"))
        XCTAssertEqual(known, ["openai", "groq", "cloudflare"])
    }

    @objc func testAdapterFromMapping() {
        XCTAssertEqual(STTAdapterID.from("openai"), .openai)
        XCTAssertEqual(STTAdapterID.from("groq"), .groq)
        XCTAssertEqual(STTAdapterID.from("cloudflare"), .cloudflare)
        XCTAssertEqual(STTAdapterID.from("whatever"), .openAICompatible)
        // Unknown id — selfhosted providers fall back to openAICompatible.
        XCTAssertEqual(STTAdapterID.from("gigaam"), .openAICompatible)
        XCTAssertEqual(STTAdapterID.from("selfhosted"), .openAICompatible)
    }

    @objc func testDisplayName() {
        XCTAssertEqual(ProviderRequestBuilder.displayName(for: "openai"), "OpenAI")
        XCTAssertEqual(ProviderRequestBuilder.displayName(for: "groq"), "Groq")
        XCTAssertEqual(ProviderRequestBuilder.displayName(for: "cloudflare"), "Cloudflare")
        XCTAssertEqual(ProviderRequestBuilder.displayName(for: "custom"), "custom")
    }

    @objc func testDefaultBaseURLAndModel() {
        XCTAssertEqual(STTAdapterID.openai.defaultBaseURL, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(STTAdapterID.groq.defaultBaseURL, "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(STTAdapterID.cloudflare.defaultBaseURL, "")
        XCTAssertEqual(STTAdapterID.openAICompatible.defaultBaseURL, "",
                       "ручные провайдеры без дефолтного endpoint — base_url обязателен")
        XCTAssertEqual(STTAdapterID.openai.defaultModel, "whisper-1")
        XCTAssertEqual(STTAdapterID.groq.defaultModel, "whisper-large-v3")
        XCTAssertEqual(STTAdapterID.cloudflare.defaultModel, "")
        XCTAssertEqual(STTAdapterID.openAICompatible.defaultModel, "")
    }

    @objc func testResolveBaseURLAndModel() {
        XCTAssertEqual(ProviderRequestBuilder.resolveBaseURL("", for: "groq"),
                       "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(ProviderRequestBuilder.resolveBaseURL("https://my.api/v1", for: "groq"), "https://my.api/v1")
        XCTAssertEqual(ProviderRequestBuilder.resolveModel("", for: "openai"), "whisper-1")
        XCTAssertEqual(ProviderRequestBuilder.resolveModel("my-model", for: "groq"), "my-model")
        // Cloudflare has no default — model lives in the URL.
        XCTAssertEqual(ProviderRequestBuilder.resolveModel("", for: "cloudflare"), "")
        // openAICompatible: empty base_url never falls back to a local endpoint.
        XCTAssertEqual(ProviderRequestBuilder.resolveBaseURL("", for: "gigaam"), "")
        XCTAssertEqual(ProviderRequestBuilder.resolveBaseURL("", for: "selfhosted"), "")
    }

    // MARK: - OpenAI-совместимые адаптеры (openai/groq)

    @objc func testOpenAIPlan() {
        let spec = ProviderRequestBuilder.plan(
            adapterID: "openai", baseURL: "", model: "", apiKey: "sk-openai",
            language: "ru", wav: wav, filename: "file.wav", prompt: "контекст")
        XCTAssertEqual(spec.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(spec.headers.first(where: { $0.0 == "Authorization" })?.1, "Bearer sk-openai")
        XCTAssertTrue(spec.transcriptPath == nil)
        switch spec.body {
        case .multipart(let data, let contentType):
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary=Boundary-"))
            let text = String(data: data, encoding: .utf8)!
            XCTAssertTrue(text.contains("name=\"file\"; filename=\"file.wav\""))
            XCTAssertTrue(text.contains("name=\"model\""))
            XCTAssertTrue(text.contains("whisper-1"))
            XCTAssertTrue(text.contains("name=\"language\""))
            XCTAssertTrue(text.contains("name=\"prompt\""))
        case .rawAudio:
            XCTFail("openai должен быть multipart")
        }
    }

    @objc func testGroqPlan() {
        let spec = ProviderRequestBuilder.plan(
            adapterID: "groq", baseURL: "", model: "", apiKey: "sk-groq",
            language: "", wav: wav)
        XCTAssertEqual(spec.url?.absoluteString, "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(spec.headers.first(where: { $0.0 == "Authorization" })?.1, "Bearer sk-groq")
        guard case .multipart(let data, _) = spec.body else {
            XCTFail("groq — multipart")
            return
        }
        let text = String(data: data, encoding: .utf8)!
        // HTTP 400 fix: Groq wants verbose_json, without timestamp_granularities[].
        XCTAssertTrue(text.contains("name=\"response_format\"\r\n\r\nverbose_json\r\n"),
                      "verbose_json запрашивается (Groq поддерживает)")
        XCTAssertFalse(text.contains("timestamp_granularities"),
                       "Groq отвергает timestamp_granularities[] (HTTP 400) — не шлём")
        XCTAssertFalse(text.contains("name=\"language\""),
                       "пустой language — поле language в запрос НЕ уходит (авто-детект Whisper)")
    }

    // MARK: - Не задан language → языковой параметр в запрос не попадает

    @objc func testUnsetLanguageOmitsLanguageParam() {
        // Live agent path: config without language → Whisper auto-detects.
        let spec = ProviderRequestBuilder.plan(
            adapterID: "groq", baseURL: "", model: "", apiKey: "sk-groq",
            language: "", wav: wav)
        guard case .multipart(let data, _) = spec.body else {
            XCTFail("groq — multipart")
            return
        }
        let text = String(data: data, encoding: .utf8)!
        XCTAssertFalse(text.contains("name=\"language\""),
                       "не задан language — language=... не должен уходить в запрос")
    }

    @objc func testExplicitLanguageIsForwarded() {
        let spec = ProviderRequestBuilder.plan(
            adapterID: "groq", baseURL: "", model: "", apiKey: "sk-groq",
            language: "ru", wav: wav)
        guard case .multipart(let data, _) = spec.body else {
            XCTFail("groq — multipart")
            return
        }
        let text = String(data: data, encoding: .utf8)!
        XCTAssertTrue(text.contains("name=\"language\"\r\n\r\nru\r\n"),
                       "явный language форвардится в multipart как раньше")
    }

    // MARK: - Selfhosted (gigaam / selfhosted → openAICompatible)

    @objc func testGigaAMPlanEndToEnd() {
        // Live GigaAM: unknown id → openAICompatible multipart with word
        // timestamps, language forwarded, no extra auth steps.
        let url = "https://example.com/projects/proj/openai/v1/audio/transcriptions"
        let spec = ProviderRequestBuilder.plan(
            adapterID: "gigaam", baseURL: url, model: "gigaam-v3", apiKey: "gigaam-key",
            language: "ru", wav: wav, filename: "file.wav")
        XCTAssertEqual(spec.url?.absoluteString, url, "base_url используется как есть")
        XCTAssertEqual(spec.headers.first(where: { $0.0 == "Authorization" })?.1, "Bearer gigaam-key")
        switch spec.body {
        case .multipart(let data, let contentType):
            XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary=Boundary-"))
            let text = String(data: data, encoding: .utf8)!
            XCTAssertTrue(text.contains("name=\"file\"; filename=\"file.wav\""))
            XCTAssertTrue(text.contains("name=\"model\"\r\n\r\ngigaam-v3\r\n"))
            XCTAssertTrue(text.contains("name=\"language\"\r\n\r\nru\r\n"),
                          "language форвардится как у любого openai-совместимого")
            XCTAssertTrue(text.contains("response_format"),
                          "supportsVerboseJSON=true у openAICompatible — просим verbose_json")
            XCTAssertTrue(text.contains("timestamp_granularities"),
                          "supportsWordTimestamps=true у openAICompatible — просим word-таймстампы")
        case .rawAudio:
            XCTFail("gigaam — multipart, не raw")
        }
    }

    @objc func testSelfhostedPlanWithoutKey() {
        // No api_key → "Bearer " (empty token); no base_url default → url nil.
        let spec = ProviderRequestBuilder.plan(
            adapterID: "selfhosted", baseURL: "https://stt.example.net/v1", model: "gigaam-v3",
            apiKey: "", language: "ru", wav: wav)
        XCTAssertEqual(spec.url?.absoluteString, "https://stt.example.net/v1")
        XCTAssertEqual(spec.headers.first(where: { $0.0 == "Authorization" })?.1, "Bearer ")

        let empty = ProviderRequestBuilder.plan(
            adapterID: "selfhosted", baseURL: "", model: "m", apiKey: "",
            language: "ru", wav: wav)
        XCTAssertNil(empty.url, "у openAICompatible нет дефолтного base_url — пустой → nil")
    }

    @objc func testUnknownAdapterFallsBackToOpenAICompatible() {
        let spec = ProviderRequestBuilder.plan(
            adapterID: "custom-my", baseURL: "https://custom.example/v1", model: "m", apiKey: "k",
            language: "ru", wav: wav)
        XCTAssertEqual(spec.url?.absoluteString, "https://custom.example/v1")
        XCTAssertEqual(spec.headers.first(where: { $0.0 == "Authorization" })?.1, "Bearer k")
        switch spec.body {
        case .multipart: break
        case .rawAudio: XCTFail("unknown id — openai-совместимый multipart")
        }
    }

    // MARK: - Cloudflare

    @objc func testCloudflarePlan() {
        let url = "https://api.cloudflare.com/client/v4/accounts/acct/ai/run/@cf/openai/whisper-large-v3-turbo"
        let spec = ProviderRequestBuilder.plan(
            adapterID: "cloudflare", baseURL: url, model: "", apiKey: "cf-key",
            language: "ru", wav: wav)
        XCTAssertEqual(spec.url?.absoluteString, url)
        XCTAssertEqual(spec.transcriptPath ?? [], ["result", "text"],
                       "Cloudflare Workers AI отвечает {\"result\":{\"text\":…}}")
        XCTAssertEqual(spec.headers.first(where: { $0.0 == "Authorization" })?.1, "Bearer cf-key")
        XCTAssertEqual(spec.headers.first(where: { $0.0 == "Content-Type" })?.1, "audio/wav")
        switch spec.body {
        case .rawAudio(let data, let contentType):
            XCTAssertEqual(data, wav, "тело — сырые WAV-байты как есть")
            XCTAssertEqual(contentType, "audio/wav")
        case .multipart:
            XCTFail("cloudflare — сырые байты + audio/wav, не multipart (multipart → 400 code 8001)")
        }
    }

    @objc func testCloudflareRequiresExplicitBaseURL() {
        // No default base URL — provider must set its own endpoint.
        let spec = ProviderRequestBuilder.plan(
            adapterID: "cloudflare", baseURL: "", model: "", apiKey: "k",
            language: "ru", wav: wav)
        XCTAssertNil(spec.url)
    }

    // MARK: - Multipart байт-в-байт

    @objc func testMultipartBodyByteExact() {
        let boundary = "Boundary-TEST"
        let body = ProviderRequestBuilder.multipartBody(
            wav: wav, filename: "audio.wav", model: "whisper-1", language: "ru",
            prompt: nil, boundary: boundary)
        let expected = """
        --Boundary-TEST\r
        Content-Disposition: form-data; name="file"; filename="audio.wav"\r
        Content-Type: audio/wav\r
        \r
        RIFF\u{0}\u{0}\r
        --Boundary-TEST\r
        Content-Disposition: form-data; name="model"\r
        \r
        whisper-1\r
        --Boundary-TEST\r
        Content-Disposition: form-data; name="language"\r
        \r
        ru\r
        --Boundary-TEST--\r\n
        """
        XCTAssertEqual(body, Data(expected.utf8))
    }

    @objc func testMultipartOmitsLanguageAndPromptWhenEmpty() {
        let boundary = "Boundary-TEST"
        let body = ProviderRequestBuilder.multipartBody(
            wav: wav, filename: "audio.wav", model: "m", language: "",
            prompt: nil, boundary: boundary)
        let text = String(data: body, encoding: .utf8)!
        XCTAssertFalse(text.contains("language"))
        XCTAssertFalse(text.contains("prompt"))
        XCTAssertTrue(text.hasSuffix("--Boundary-TEST--\r\n"))
    }

    @objc func testMultipartBodyAppendsStableFieldsBeforeClosing() {
        // Stable fields after prompt in fixed order; numbers locale-independent.
        let boundary = "Boundary-TEST"
        let stable = BatchStableMultipartFields(
            temperature: 0,
            vadFilter: true,
            noSpeechThreshold: 0.6,
            compressionRatioThreshold: 2.4,
            logprobThreshold: -1.0
        )
        let body = ProviderRequestBuilder.multipartBody(
            wav: wav, filename: "a.wav", model: "m", language: "ru",
            prompt: "контекст", boundary: boundary, stable: stable)
        let text = String(data: body, encoding: .utf8)!

        let promptPos = text.range(of: "name=\"prompt\"")!.lowerBound
        let tempPos = text.range(of: "name=\"temperature\"\r\n\r\n0")!.lowerBound
        let vadPos = text.range(of: "name=\"vad_filter\"\r\n\r\ntrue")!.lowerBound
        let noSpeechPos = text.range(of: "name=\"no_speech_threshold\"\r\n\r\n0.6")!.lowerBound
        let ratioPos = text.range(of: "name=\"compression_ratio_threshold\"\r\n\r\n2.4")!.lowerBound
        let logprobPos = text.range(of: "name=\"logprob_threshold\"\r\n\r\n-1")!.lowerBound
        let closingPos = text.range(of: "--Boundary-TEST--\r\n")!.lowerBound

        XCTAssertTrue(tempPos > promptPos, "temperature после prompt")
        XCTAssertTrue(vadPos > tempPos, "vad_filter после temperature")
        XCTAssertTrue(noSpeechPos > vadPos, "no_speech_threshold после vad_filter")
        XCTAssertTrue(ratioPos > noSpeechPos, "compression_ratio_threshold после no_speech_threshold")
        XCTAssertTrue(logprobPos > ratioPos, "logprob_threshold после compression_ratio_threshold")
        XCTAssertTrue(closingPos > logprobPos, "закрывающий boundary ПОСЛЕ всех stable-полей")
    }

    // MARK: - extractText

    @objc func testExtractTextFlat() throws {
        let body = Data(#"{"text":"привет мир"}"#.utf8)
        let text = try ProviderRequestBuilder.extractText(from: body, path: nil)
        XCTAssertEqual(text, "привет мир")
    }

    @objc func testExtractTextFlatMissingField() {
        let body = Data(#"{"other":1}"#.utf8)
        XCTAssertThrowsError(try ProviderRequestBuilder.extractText(from: body, path: nil)) { error in
            guard case TranscribeError.invalidResponse(let message) = error else {
                XCTFail("ожидался invalidResponse, получено \(error)")
                return
            }
            XCTAssertEqual(message, "Missing 'text' field")
        }
    }

    @objc func testExtractTextNotJSON() {
        XCTAssertThrowsError(try ProviderRequestBuilder.extractText(from: Data("not json".utf8), path: nil)) { error in
            guard case TranscribeError.invalidResponse(let message) = error else {
                XCTFail("ожидался invalidResponse, получено \(error)")
                return
            }
            XCTAssertEqual(message, "Response is not a JSON object")
        }
    }

    @objc func testExtractTextCloudflarePath() throws {
        // Cloudflare wraps text under result.text — walk transcriptPath.
        let body = Data(#"{"result":{"text":"текст из cloudflare"}}"#.utf8)
        let path = ["result", "text"]
        let text = try ProviderRequestBuilder.extractText(from: body, path: path)
        XCTAssertEqual(text, "текст из cloudflare")
    }

    @objc func testExtractTextMissingCloudflarePath() {
        let body = Data(#"{"result":{}}"#.utf8)
        let path = ["result", "text"]
        XCTAssertThrowsError(try ProviderRequestBuilder.extractText(from: body, path: path)) { _ in }
    }

    @objc func testExtractTextEmptyBodyThrows() {
        XCTAssertThrowsError(try ProviderRequestBuilder.extractText(from: Data(), path: nil)) { _ in }
    }

    // MARK: - Word-таймстампы (verbose_json / cloudflare words)

    @objc func testOpenAIPlanRequestsVerboseJSON() {
        let spec = ProviderRequestBuilder.plan(
            adapterID: "openai", baseURL: "", model: "", apiKey: "sk-openai",
            language: "ru", wav: wav, filename: "file.wav", prompt: "контекст")
        guard case .multipart(let data, _) = spec.body else {
            XCTFail("openai должен быть multipart")
            return
        }
        let text = String(data: data, encoding: .utf8)!
        XCTAssertTrue(text.contains("name=\"response_format\"\r\n\r\nverbose_json\r\n"),
                      "verbose_json даёт word-таймстампы")
        XCTAssertTrue(text.contains("name=\"timestamp_granularities[]\"\r\n\r\nword\r\n"))
        // Fields sit between prompt and the closing boundary.
        let formatPos = text.range(of: "response_format")!.lowerBound
        let granPos = text.range(of: "timestamp_granularities[]")!.lowerBound
        XCTAssertTrue(formatPos < granPos)
        let closingPos = text.range(of: "--Boundary-", options: .backwards)!.lowerBound
        XCTAssertTrue(granPos < closingPos, "закрывающий boundary после полей таймстампов")
    }

    @objc func testMultipartBodyEmitsTimestampFields() {
        let boundary = "Boundary-TEST"
        let body = ProviderRequestBuilder.multipartBody(
            wav: wav, filename: "a.wav", model: "m", language: "", prompt: nil, boundary: boundary,
            responseFormat: "verbose_json", timestampGranularities: ["word"])
        let text = String(data: body, encoding: .utf8)!
        XCTAssertTrue(text.contains("name=\"response_format\"\r\n\r\nverbose_json\r\n"))
        XCTAssertTrue(text.contains("name=\"timestamp_granularities[]\"\r\n\r\nword\r\n"))
        XCTAssertTrue(text.hasSuffix("--Boundary-TEST--\r\n"))
    }

    /// OpenAI response: top-level words[] with word/start/end.
    @objc func testExtractWordsOpenAIFlat() {
        let body = Data(#"{"text":"один два","words":[{"word":"один","start":0.1,"end":0.5},{"word":"два","start":0.5,"end":1.0}]}"#.utf8)
        let words = ProviderRequestBuilder.extractWords(from: body, path: nil)
        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words[0].word, "один")
        XCTAssertEqual(words[0].start, 0.1, accuracy: 0.0001)
        XCTAssertEqual(words[0].end, 0.5, accuracy: 0.0001)
        XCTAssertEqual(words[1].word, "два")
        XCTAssertEqual(words[1].end, 1.0, accuracy: 0.0001)
    }

    /// Cloudflare: words under parent path; word falls back to punctuated_word.
    @objc func testExtractWordsCloudflarePath() {
        let body = Data(#"{"result":{"words":[{"word":"один","start":0.0,"end":0.4},{"punctuated_word":"два.","start":0.5,"end":0.9}]}}"#.utf8)
        let path = ["result", "text"]
        let words = ProviderRequestBuilder.extractWords(from: body, path: path)
        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words[0].word, "один")
        XCTAssertEqual(words[1].word, "два.", "fallback на punctuated_word")
    }

    /// Broken entries skipped; bad JSON and absent words → empty list.
    @objc func testExtractWordsSkippedAndBroken() {
        // "б" lacks end — entry dropped.
        let partial = Data(#"{"words":[{"word":"а","start":0.1,"end":0.2},{"word":"б","start":0.3}]}"#.utf8)
        XCTAssertEqual(ProviderRequestBuilder.extractWords(from: partial, path: nil).map { $0.word }, ["а"])

        XCTAssertTrue(ProviderRequestBuilder.extractWords(from: Data("nope".utf8), path: nil).isEmpty,
                      "битый JSON → пустой список")
        XCTAssertTrue(ProviderRequestBuilder.extractWords(from: Data(), path: nil).isEmpty,
                      "пустое тело → пустой список")
        let noWords = Data(#"{"text":"просто текст"}"#.utf8)
        XCTAssertTrue(ProviderRequestBuilder.extractWords(from: noWords, path: nil).isEmpty)
        // Cloudflare: no words in result.
        let cf = Data(#"{"result":{"text":"т"}}"#.utf8)
        let path = ["result", "text"]
        XCTAssertTrue(ProviderRequestBuilder.extractWords(from: cf, path: path).isEmpty)
    }
}