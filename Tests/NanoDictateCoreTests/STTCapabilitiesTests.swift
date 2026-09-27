import Foundation
@testable import NanoDictateCore

// MARK: - STTCapabilitiesTests
//
// Model-aware capability/profile layer: resolution by concrete
// provider+model, request construction per profile, audio requirements,
// and the conservative custom-endpoint fallback.

final class STTCapabilitiesTests: XCTestCase {

    private let wav = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00]) // "RIFF\0\0"

    private func bodyText(_ spec: STTRequestSpec) -> String? {
        guard case .multipart(let data, _) = spec.body else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Resolution: same family, different models

    @objc func testOpenAIWhisperVsModernModelCapabilitiesDiffer() {
        let whisper = STTModelRegistry.resolve(adapterID: "openai", model: "whisper-1")
        let modern = STTModelRegistry.resolve(adapterID: "openai", model: "gpt-4o-transcribe")
        XCTAssertTrue(whisper.capabilities.supportsVerboseJSON)
        XCTAssertTrue(whisper.capabilities.supportsWordTimestamps)
        XCTAssertTrue(whisper.capabilities.supportsTemperature)
        XCTAssertFalse(modern.capabilities.supportsVerboseJSON)
        XCTAssertFalse(modern.capabilities.supportsWordTimestamps)
        XCTAssertFalse(modern.capabilities.supportsTemperature)
        XCTAssertTrue(modern.capabilities.supportsPrompt)
    }

    @objc func testOpenAIMiniTranscribeMatchesModernProfile() {
        let mini = STTModelRegistry.resolve(adapterID: "openai", model: "gpt-4o-mini-transcribe")
        XCTAssertFalse(mini.capabilities.supportsVerboseJSON)
        XCTAssertFalse(mini.capabilities.supportsWordTimestamps)
        XCTAssertFalse(mini.capabilities.supportsTemperature)
    }

    @objc func testOpenAIResolutionCaseInsensitive() {
        let upper = STTModelRegistry.resolve(adapterID: "openai", model: "Whisper-1")
        XCTAssertTrue(upper.capabilities.supportsVerboseJSON)
    }

    @objc func testGroqKnownModelKeepsVerboseWithoutGranularities() {
        let groq = STTModelRegistry.resolve(adapterID: "groq", model: "whisper-large-v3")
        XCTAssertTrue(groq.capabilities.supportsVerboseJSON)
        XCTAssertFalse(groq.capabilities.supportsWordTimestamps)
        XCTAssertTrue(groq.capabilities.supportsVadFilter)
        XCTAssertTrue(groq.capabilities.supportsServerVAD)
    }

    @objc func testGroqTurboModelMatchesKnownProfile() {
        let turbo = STTModelRegistry.resolve(adapterID: "groq", model: "whisper-large-v3-turbo")
        XCTAssertTrue(turbo.capabilities.supportsVerboseJSON)
        XCTAssertTrue(turbo.capabilities.supportsVadFilter)
    }

    // MARK: - Request construction per model (same provider family)

    @objc func testOpenAIWhisperPlanRequestsVerboseAndWordTimestamps() {
        let spec = ProviderRequestBuilder.plan(
            adapterID: "openai", baseURL: "", model: "whisper-1", apiKey: "k",
            language: "ru", wav: wav)
        guard let text = bodyText(spec) else {
            XCTFail("openai whisper-1 must be multipart")
            return
        }
        XCTAssertTrue(text.contains("name=\"response_format\"\r\n\r\nverbose_json\r\n"))
        XCTAssertTrue(text.contains("name=\"timestamp_granularities[]\"\r\n\r\nword\r\n"))
    }

    @objc func testOpenAIModernPlanOmitsUnsupportedParams() {
        let spec = ProviderRequestBuilder.plan(
            adapterID: "openai", baseURL: "", model: "gpt-4o-transcribe", apiKey: "k",
            language: "ru", wav: wav, prompt: "context",
            batchParams: BatchSTTParams(prompt: "chained", temperature: 0))
        guard let text = bodyText(spec) else {
            XCTFail("openai modern model must be multipart")
            return
        }
        XCTAssertFalse(text.contains("response_format"),
                       "modern OpenAI model must not receive verbose_json")
        XCTAssertFalse(text.contains("timestamp_granularities"),
                       "modern OpenAI model must not receive word granularities")
        XCTAssertFalse(text.contains("name=\"temperature\""),
                       "modern OpenAI model must not receive temperature")
        XCTAssertTrue(text.contains("name=\"prompt\""),
                      "prompt is still supported by the modern profile")
        XCTAssertTrue(text.contains("name=\"language\""))
    }

    @objc func testGroqPlanVerboseWithoutGranularities() {
        let spec = ProviderRequestBuilder.plan(
            adapterID: "groq", baseURL: "", model: "whisper-large-v3", apiKey: "k",
            language: "", wav: wav)
        guard let text = bodyText(spec) else {
            XCTFail("groq must be multipart")
            return
        }
        XCTAssertTrue(text.contains("verbose_json"))
        XCTAssertFalse(text.contains("timestamp_granularities"))
    }

    // MARK: - Every built-in backend

    @objc func testCloudflareProfileIsRawAudio() {
        let url = "https://api.cloudflare.com/client/v4/accounts/a/ai/run/@cf/openai/whisper-large-v3-turbo"
        let profile = STTModelRegistry.resolve(adapterID: "cloudflare", model: "")
        XCTAssertEqual(profile.capabilities.transport, .batchRawAudio)
        XCTAssertEqual(profile.transcriptPath ?? [], ["result", "text"])
        XCTAssertEqual(profile.capabilities.languageHint, .none)
        XCTAssertFalse(profile.capabilities.supportsPrompt)
        let spec = ProviderRequestBuilder.plan(
            adapterID: "cloudflare", baseURL: url, model: "", apiKey: "k",
            language: "ru", wav: wav, prompt: "ignored")
        XCTAssertEqual(spec.transcriptPath ?? [], ["result", "text"])
        guard case .rawAudio(let data, let contentType) = spec.body else {
            XCTFail("cloudflare must be raw audio")
            return
        }
        XCTAssertEqual(data, wav)
        XCTAssertEqual(contentType, "audio/wav")
    }

    @objc func testAirubizProfileIsConservativeMultipart() {
        // Historic section ids (airubiz/gigaam) map to the conservative
        // OpenAI-compatible fallback: no verbose, no timestamps.
        let spec = ProviderRequestBuilder.plan(
            adapterID: "airubiz", baseURL: "https://api.airubiz.site/v1/audio/transcriptions",
            model: "gigaam-v3-ctc-sherpa", apiKey: "", language: "ru", wav: wav)
        guard let text = bodyText(spec) else {
            XCTFail("airubiz must be multipart")
            return
        }
        XCTAssertTrue(text.contains("name=\"model\"\r\n\r\ngigaam-v3-ctc-sherpa\r\n"))
        XCTAssertTrue(text.contains("name=\"language\""))
        XCTAssertFalse(text.contains("response_format"))
        XCTAssertFalse(text.contains("timestamp_granularities"))
    }

    @objc func testCustomEndpointConservativeFallback() {
        let caps = STTModelRegistry.resolve(adapterID: "my-custom", model: "anything").capabilities
        XCTAssertEqual(caps.transport, .batchMultipart)
        XCTAssertFalse(caps.supportsVerboseJSON)
        XCTAssertFalse(caps.supportsWordTimestamps)
        XCTAssertTrue(caps.supportsPrompt)
        XCTAssertTrue(caps.supportsTemperature)
        XCTAssertFalse(caps.supportsVadFilter)
        XCTAssertEqual(caps.languageHint, .single)
        XCTAssertFalse(caps.supportsKeywordBiasing)
        let spec = ProviderRequestBuilder.plan(
            adapterID: "my-custom", baseURL: "https://stt.example/v1", model: "m",
            apiKey: "k", language: "ru", wav: wav)
        guard let text = bodyText(spec) else {
            XCTFail("custom endpoint must be multipart")
            return
        }
        XCTAssertFalse(text.contains("response_format"))
        XCTAssertFalse(text.contains("timestamp_granularities"))
    }

    // MARK: - Stable fields are model-aware

    @objc func testStableFieldsWhisperVsModern() {
        let whisper = BatchStableMultipartFields.stableFields(
            for: "openai", model: "whisper-1", params: BatchSTTParams())
        XCTAssertEqual(whisper?.temperature, 0)
        let modern = BatchStableMultipartFields.stableFields(
            for: "openai", model: "gpt-4o-transcribe", params: BatchSTTParams())
        XCTAssertNil(modern?.temperature, "modern profile sends no temperature")
    }

    @objc func testStableFieldsGroqKeepsVadFilter() {
        let groq = BatchStableMultipartFields.stableFields(
            for: "groq", model: "whisper-large-v3", params: BatchSTTParams())
        XCTAssertEqual(groq?.temperature, 0)
        XCTAssertEqual(groq?.vadFilter, true)
    }

    @objc func testStableFieldsCloudflareNil() {
        XCTAssertNil(BatchStableMultipartFields.stableFields(
            for: "cloudflare", model: "", params: BatchSTTParams()))
    }

    // MARK: - Audio profiles

    @objc func testAudioProfilesAreMono16kWav() {
        for (adapter, model) in [
            ("openai", "whisper-1"),
            ("openai", "gpt-4o-transcribe"),
            ("groq", "whisper-large-v3"),
            ("cloudflare", ""),
            ("airubiz", "gigaam-v3-ctc-sherpa"),
            ("custom", "m"),
        ] {
            let audio = ProviderRequestBuilder.audioProfile(adapterID: adapter, model: model)
            XCTAssertEqual(audio.sampleRate, 16000, "\(adapter)/\(model)")
            XCTAssertEqual(audio.channels, 1, "\(adapter)/\(model)")
            XCTAssertEqual(audio.uploadFormat, .wav, "\(adapter)/\(model)")
        }
    }

    @objc func testWAVEncoderMatchesAudioProfile() {
        let audio = ProviderRequestBuilder.audioProfile(adapterID: "groq", model: "whisper-large-v3")
        let viaProfile = WAVEncoder.encode(samples: [1, 2, 3], audioProfile: audio)
        let direct = WAVEncoder.encode(samples: [1, 2, 3], sampleRate: 16000, channels: 1)
        XCTAssertEqual(viaProfile, direct)
    }

    // MARK: - Streaming reserved, batch everywhere today

    @objc func testNoBuiltInProfileUsesStreaming() {
        for (adapter, model) in [
            ("openai", "whisper-1"), ("openai", "gpt-4o-transcribe"),
            ("groq", "whisper-large-v3"), ("cloudflare", ""),
            ("airubiz", "gigaam-v3-ctc-sherpa"), ("custom", "m"),
        ] {
            let transport = STTModelRegistry.resolve(adapterID: adapter, model: model)
                .capabilities.transport
            XCTAssertTrue(
                transport == .batchMultipart || transport == .batchRawAudio,
                "\(adapter)/\(model) must be batch today")
        }
    }
}
