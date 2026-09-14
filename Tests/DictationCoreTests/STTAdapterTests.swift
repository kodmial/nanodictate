import Foundation
@testable import DictationCore

// MARK: - STTAdapterTests
//
// Без сети: проверяется только ПОСТРОЕНИЕ запроса (url, заголовки, тело,
// contentType, transcriptPath, oauth-шаг) и парсинг текста ответа
// (extractText + multipartBody байт-в-байт).

final class STTAdapterTests: XCTestCase {

    private let wav = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00]) // "RIFF\0\0"

    // MARK: - Идентификаторы адаптеров

    @objc func testKnownProviderIDs() {
        let known = ProviderRequestBuilder.knownProviderIDs
        XCTAssertTrue(known.contains("openai"))
        XCTAssertTrue(known.contains("groq"))
        XCTAssertTrue(known.contains("local"))
        XCTAssertTrue(known.contains("deepgram"))
        XCTAssertTrue(known.contains("giga-chat"))
        XCTAssertTrue(known.contains("relay"))
        XCTAssertFalse(known.contains("custom"))
    }

    @objc func testAdapterFromMapping() {
        XCTAssertEqual(STTAdapterID.from("openai"), .openai)
        XCTAssertEqual(STTAdapterID.from("groq"), .groq)
        XCTAssertEqual(STTAdapterID.from("local"), .local)
        XCTAssertEqual(STTAdapterID.from("deepgram"), .deepgram)
        XCTAssertEqual(STTAdapterID.from("giga-chat"), .gigaChat)
        XCTAssertEqual(STTAdapterID.from("relay"), .relay)
        XCTAssertEqual(STTAdapterID.from("whatever"), .openAICompatible)
    }

    @objc func testDisplayName() {
        XCTAssertEqual(ProviderRequestBuilder.displayName(for: "openai"), "OpenAI")
        XCTAssertEqual(ProviderRequestBuilder.displayName(for: "groq"), "Groq")
        XCTAssertEqual(ProviderRequestBuilder.displayName(for: "deepgram"), "Deepgram")
        XCTAssertEqual(ProviderRequestBuilder.displayName(for: "giga-chat"), "GigaChat")
        XCTAssertEqual(ProviderRequestBuilder.displayName(for: "custom"), "custom")
    }

    @objc func testDefaultBaseURLAndModel() {
        XCTAssertEqual(STTAdapterID.openai.defaultBaseURL, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(STTAdapterID.groq.defaultBaseURL, "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(STTAdapterID.local.defaultBaseURL, "http://127.0.0.1:8080/v1/audio/transcriptions")
        XCTAssertEqual(STTAdapterID.deepgram.defaultBaseURL, "https://api.deepgram.com/v1/listen")
        XCTAssertEqual(STTAdapterID.gigaChat.defaultBaseURL, "https://gigachat.devices.sberbank.ru/api/v1/audio/transcriptions")
        XCTAssertEqual(STTAdapterID.relay.defaultBaseURL, "")
        XCTAssertEqual(STTAdapterID.openai.defaultModel, "whisper-1")
        XCTAssertEqual(STTAdapterID.groq.defaultModel, "whisper-large-v3")
        XCTAssertEqual(STTAdapterID.deepgram.defaultModel, "nova-3")
        XCTAssertEqual(STTAdapterID.local.defaultModel, "whisper-1")
    }

    @objc func testResolveBaseURLAndModel() {
        XCTAssertEqual(ProviderRequestBuilder.resolveBaseURL("", for: "groq"),
                       "https://api.groq.com/openai/v1/audio/transcriptions")
        XCTAssertEqual(ProviderRequestBuilder.resolveBaseURL("https://my.api/v1", for: "groq"), "https://my.api/v1")
        XCTAssertEqual(ProviderRequestBuilder.resolveModel("", for: "deepgram"), "nova-3")
        XCTAssertEqual(ProviderRequestBuilder.resolveModel("my-model", for: "deepgram"), "my-model")
    }

    // MARK: - OpenAI-совместимые адаптеры (openai/groq/local/relay)

    @objc func testOpenAIPlan() {
        let spec = ProviderRequestBuilder.plan(
            adapterID: "openai", baseURL: "", model: "", apiKey: "sk-openai",
            language: "ru", wav: wav, filename: "file.wav", prompt: "контекст")
        XCTAssertEqual(spec.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
        XCTAssertEqual(spec.headers.first(where: { $0.0 == "Authorization" })?.1, "Bearer sk-openai")
        XCTAssertTrue(spec.transcriptPath == nil)
        XCTAssertNil(spec.oauth)
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
    }

    @objc func testLocalPlanWithoutKey() {
        // local — без ключа: Authorization всё равно "Bearer " (формат не меняется).
        let spec = ProviderRequestBuilder.plan(
            adapterID: "local", baseURL: "", model: "", apiKey: "",
            language: "ru", wav: wav)
        XCTAssertEqual(spec.url?.absoluteString, "http://127.0.0.1:8080/v1/audio/transcriptions")
        XCTAssertEqual(spec.headers.first(where: { $0.0 == "Authorization" })?.1, "Bearer ")
    }

    @objc func testRelayRequiresExplicitBaseURL() {
        // relay не имеет дефолтного baseURL: пустой → url nil (нет запроса),
        // заданный — OpenAI-совместимый multipart с Bearer.
        let empty = ProviderRequestBuilder.plan(
            adapterID: "relay", baseURL: "", model: "", apiKey: "k",
            language: "ru", wav: wav)
        XCTAssertNil(empty.url)

        let set = ProviderRequestBuilder.plan(
            adapterID: "relay", baseURL: "https://relay.example.com/transcribe", model: "m", apiKey: "k",
            language: "ru", wav: wav)
        XCTAssertEqual(set.url?.absoluteString, "https://relay.example.com/transcribe")
        XCTAssertEqual(set.headers.first(where: { $0.0 == "Authorization" })?.1, "Bearer k")
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

    // MARK: - Deepgram

    @objc func testDeepgramPlan() {
        let spec = ProviderRequestBuilder.plan(
            adapterID: "deepgram", baseURL: "", model: "", apiKey: "dg-key",
            language: "ru", wav: wav)
        XCTAssertEqual(spec.url?.host, "api.deepgram.com")
        XCTAssertEqual(spec.url?.path, "/v1/listen")
        let query = spec.url?.query ?? ""
        XCTAssertTrue(query.contains("model=nova-3"))
        XCTAssertTrue(query.contains("language=ru"))
        XCTAssertTrue(query.contains("smart_format=true"))
        XCTAssertEqual(spec.transcriptPath ?? [], ["results", "channels", "0", "alternatives", "0", "transcript"])
        XCTAssertEqual(spec.headers.first(where: { $0.0 == "Authorization" })?.1, "Token dg-key")
        XCTAssertEqual(spec.headers.first(where: { $0.0 == "Content-Type" })?.1, "audio/wav")
        switch spec.body {
        case .rawAudio(let data, let contentType):
            XCTAssertEqual(data, wav)
            XCTAssertEqual(contentType, "audio/wav")
        case .multipart:
            XCTFail("deepgram — сырое аудио, не multipart")
        }
    }

    @objc func testDeepgramQueryBareModelStillGoesThrough() {
        // Даже без модели адаптер ставит дефолт nova-3.
        let spec = ProviderRequestBuilder.plan(
            adapterID: "deepgram", baseURL: "https://custom.dg/v1", model: "", apiKey: "k",
            language: "", wav: wav)
        XCTAssertEqual(spec.url?.query?.contains("model=nova-3"), true)
        XCTAssertFalse(spec.url?.query?.contains("language") ?? true)
    }

    // MARK: - GigaChat

    @objc func testGigaChatPlan() {
        let spec = ProviderRequestBuilder.plan(
            adapterID: "giga-chat", baseURL: "", model: "", apiKey: "client-id", apiSecret: "client-secret",
            language: "ru", wav: wav)
        XCTAssertEqual(spec.url?.absoluteString, "https://gigachat.devices.sberbank.ru/api/v1/audio/transcriptions")
        let rqUID = spec.headers.first(where: { $0.0 == "RqUID" })?.1
        XCTAssertNotNil(rqUID)
        XCTAssertTrue((rqUID?.count ?? 0) > 8)

        guard let oauth = spec.oauth else {
            XCTFail("giga-chat требует oauth-шаг")
            return
        }
        XCTAssertEqual(oauth.url.absoluteString, "https://ngw.devices.sberbank.ru:9443/api/v2/oauth")
        let basic = Data("client-id:client-secret".utf8).base64EncodedString()
        XCTAssertEqual(oauth.headers.first(where: { $0.0 == "Authorization" })?.1, "Basic \(basic)")
        XCTAssertEqual(oauth.headers.first(where: { $0.0 == "RqUID" })?.1, rqUID)
        XCTAssertEqual(oauth.body, "grant_type=client_credentials&scope=GIGACHAT_API_PERS")
        XCTAssertEqual(oauth.tokenJSONKey, "access_token")
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

    @objc func testExtractTextDeepgramPath() throws {
        let body = Data(#"{"results":{"channels":[{"alternatives":[{"transcript":"текст из deepgram"}]}]}}"#.utf8)
        let path = ["results", "channels", "0", "alternatives", "0", "transcript"]
        let text = try ProviderRequestBuilder.extractText(from: body, path: path)
        XCTAssertEqual(text, "текст из deepgram")
    }

    @objc func testExtractTextMissingDeepgramPath() {
        let body = Data(#"{"results":{}}"#.utf8)
        let path = ["results", "channels", "0", "alternatives", "0", "transcript"]
        XCTAssertThrowsError(try ProviderRequestBuilder.extractText(from: body, path: path)) { _ in }
    }

    @objc func testExtractTextEmptyBodyThrows() {
        XCTAssertThrowsError(try ProviderRequestBuilder.extractText(from: Data(), path: nil)) { _ in }
    }
}