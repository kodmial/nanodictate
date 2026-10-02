import Foundation
@testable import NanoDictateCore

// MARK: - STTContextualBiasTests
//
// Contextual biasing: normalization, limits, escaping/serialization and
// capability gating through #22 profiles. No network.

final class STTContextualBiasTests: XCTestCase {

    private let wav = Data([0x52, 0x49, 0x46, 0x46, 0x00, 0x00]) // "RIFF\0\0"

    private func bodyText(_ spec: STTRequestSpec) -> String? {
        guard case .multipart(let data, _) = spec.body else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Normalization and limits

    @objc func testSanitizeTermCollapsesWhitespaceAndTruncates() {
        XCTAssertEqual(
            STTContextualBiasing.sanitizeTerm("  Kubernetes\nEngine\tX "),
            "Kubernetes Engine X")
        XCTAssertNil(STTContextualBiasing.sanitizeTerm("   \n\t "))
        XCTAssertNil(STTContextualBiasing.sanitizeTerm(""))
        // CR/LF can never survive: multipart field injection impossible.
        let injected = STTContextualBiasing.sanitizeTerm("a\r\n--Boundary")
        XCTAssertFalse(injected?.contains("\r") ?? false)
        XCTAssertFalse(injected?.contains("\n") ?? false)
        let long = String(repeating: "x", count: 200)
        XCTAssertEqual(
            STTContextualBiasing.sanitizeTerm(long)?.count,
            STTContextualBiasLimits.maxTermLength)
    }

    @objc func testNormalizeVocabularyDedupesAndCaps() {
        let terms = ["Whisper", "whisper", "  WHISPER  ", "", "Kubernetes"]
        XCTAssertEqual(
            STTContextualBiasing.normalizeVocabulary(terms),
            ["Whisper", "Kubernetes"])
        let many = (0..<200).map { "term-\($0)" }
        let normalized = STTContextualBiasing.normalizeVocabulary(many)
        XCTAssertLessThanOrEqual(normalized.count, STTContextualBiasLimits.maxTerms)
        XCTAssertLessThanOrEqual(
            STTContextualBiasing.serializeVocabularyHint(normalized).count,
            STTContextualBiasLimits.maxVocabularyChars)
    }

    @objc func testNormalizeLanguageCodes() {
        XCTAssertEqual(STTContextualBiasing.normalizeLanguageCode("EN"), "en")
        XCTAssertEqual(STTContextualBiasing.normalizeLanguageCode("en_US"), "en-us")
        XCTAssertEqual(STTContextualBiasing.normalizeLanguageCode(" ru "), "ru")
        XCTAssertNil(STTContextualBiasing.normalizeLanguageCode(""))
        XCTAssertNil(STTContextualBiasing.normalizeLanguageCode("e"))
        XCTAssertNil(STTContextualBiasing.normalizeLanguageCode("en!"))
        XCTAssertEqual(
            STTContextualBiasing.normalizeExtraLanguages(["EN", "en", "ru", "", "xx!"]),
            ["en", "ru"])
    }

    @objc func testSerializeVocabularyHintDeterministic() {
        XCTAssertEqual(STTContextualBiasing.serializeVocabularyHint([]), "")
        XCTAssertEqual(
            STTContextualBiasing.serializeVocabularyHint(["a", "b"]),
            "Technical vocabulary: a, b")
        // Commas inside a term are preserved verbatim (human-readable hint).
        XCTAssertEqual(
            STTContextualBiasing.serializeVocabularyHint(["a,b", "c"]),
            "Technical vocabulary: a,b, c")
    }

    // MARK: - Prompt preservation

    @objc func testVocabularyFoldsIntoPromptAfterChain() {
        let caps = STTModelRegistry.resolve(adapterID: "openai", model: "whisper-1").capabilities
        let applied = STTContextualBiasing.apply(
            bias: STTContextualBias(vocabulary: ["Kubernetes"], extraLanguages: []),
            chainPrompt: "previous transcript",
            primaryLanguage: "ru",
            capabilities: caps,
            adapterID: "openai",
            model: "whisper-1")
        XCTAssertEqual(
            applied.effectivePrompt,
            "previous transcript\nTechnical vocabulary: Kubernetes")
        XCTAssertNil(applied.diagnostic)
        XCTAssertFalse(applied.vocabularyDropped)
    }

    @objc func testCombinedPromptOverflowPreservesChainAndTrimsHint() {
        let caps = STTModelRegistry.resolve(adapterID: "openai", model: "whisper-1").capabilities
        // Chain + hint exceeds the combined limit: chain must survive intact,
        // only complete hint words that fit are kept.
        let chain = String(repeating: "c", count: 980)
        let applied = STTContextualBiasing.apply(
            bias: STTContextualBias(
                vocabulary: ["alpha", "beta", "gamma", "delta"], extraLanguages: []),
            chainPrompt: chain,
            primaryLanguage: "",
            capabilities: caps)
        let prompt = applied.effectivePrompt ?? ""
        XCTAssertTrue(prompt.hasPrefix(chain + "\n") || prompt == chain)
        XCTAssertTrue(prompt.hasPrefix(chain))
        XCTAssertLessThanOrEqual(prompt.count, STTContextualBiasLimits.maxCombinedPromptLength)
        // No partial word: the hint suffix after the chain never ends mid-word
        // beyond what fits, and the chain prefix is byte-identical.
        XCTAssertEqual(String(prompt.prefix(chain.count)), chain)
    }

    @objc func testCombinedPromptOverflowOmitsHintWhenNothingFits() {
        let caps = STTModelRegistry.resolve(adapterID: "openai", model: "whisper-1").capabilities
        let chain = String(repeating: "c", count: 999)
        let applied = STTContextualBiasing.apply(
            bias: STTContextualBias(vocabulary: ["Kubernetes"], extraLanguages: []),
            chainPrompt: chain,
            primaryLanguage: "",
            capabilities: caps)
        XCTAssertEqual(applied.effectivePrompt, chain)
    }

    @objc func testEmptyBiasPreservesChainByteIdentical() {
        let caps = STTModelRegistry.resolve(adapterID: "openai", model: "whisper-1").capabilities
        let applied = STTContextualBiasing.apply(
            bias: .none,
            chainPrompt: "chain",
            primaryLanguage: "ru",
            capabilities: caps)
        XCTAssertEqual(applied.effectivePrompt, "chain")
        XCTAssertEqual(applied.effectiveLanguage, "ru")
        XCTAssertTrue(applied.effectiveLanguages.isEmpty)
        XCTAssertNil(applied.keywordsField)
        XCTAssertNil(applied.diagnostic)
    }

    // MARK: - Capability gating: languages

    @objc func testMultiHintMergesPrimaryAndExtras() {
        let caps = STTModelRegistry.resolve(adapterID: "openai", model: "gpt-transcribe").capabilities
        let applied = STTContextualBiasing.apply(
            bias: STTContextualBias(vocabulary: [], extraLanguages: ["RU", "en"]),
            chainPrompt: nil,
            primaryLanguage: "ru",
            capabilities: caps,
            adapterID: "openai",
            model: "gpt-transcribe")
        // Primary first, extras deduped.
        XCTAssertEqual(applied.effectiveLanguages, ["ru", "en"])
        XCTAssertEqual(applied.effectiveLanguage, "")
        XCTAssertNil(applied.diagnostic)
    }

    @objc func testSingleHintDropsExtrasWithDiagnostic() {
        let caps = STTModelRegistry.resolve(adapterID: "groq", model: "whisper-large-v3").capabilities
        let applied = STTContextualBiasing.apply(
            bias: STTContextualBias(vocabulary: [], extraLanguages: ["en", "ru"]),
            chainPrompt: nil,
            primaryLanguage: "ru",
            capabilities: caps,
            adapterID: "groq",
            model: "whisper-large-v3")
        XCTAssertEqual(applied.effectiveLanguage, "ru")
        XCTAssertTrue(applied.effectiveLanguages.isEmpty)
        XCTAssertEqual(applied.droppedExtraLanguages, ["en", "ru"])
        XCTAssertNotNil(applied.diagnostic)
        XCTAssertTrue(applied.diagnostic?.contains("single language hint") ?? false)
    }

    @objc func testNoneHintDropsAllLanguageHints() {
        let caps = STTModelRegistry.resolve(adapterID: "cloudflare", model: "").capabilities
        let applied = STTContextualBiasing.apply(
            bias: STTContextualBias(vocabulary: [], extraLanguages: ["en"]),
            chainPrompt: nil,
            primaryLanguage: "ru",
            capabilities: caps,
            adapterID: "cloudflare",
            model: "")
        XCTAssertEqual(applied.effectiveLanguage, "")
        XCTAssertTrue(applied.effectiveLanguages.isEmpty)
        XCTAssertNotNil(applied.diagnostic)
    }

    @objc func testNoneHintPrimaryOnlyLogsDiagnostic() {
        let caps = STTModelRegistry.resolve(adapterID: "cloudflare", model: "").capabilities
        let applied = STTContextualBiasing.apply(
            bias: STTContextualBias(vocabulary: [], extraLanguages: []),
            chainPrompt: nil,
            primaryLanguage: "ru",
            capabilities: caps,
            adapterID: "cloudflare",
            model: "")
        XCTAssertEqual(applied.effectiveLanguage, "")
        XCTAssertTrue(applied.effectiveLanguages.isEmpty)
        XCTAssertTrue(applied.droppedExtraLanguages.isEmpty)
        XCTAssertNotNil(applied.diagnostic)
    }

    // MARK: - Capability gating: vocabulary

    @objc func testCloudflareDropsVocabularyDeterministically() {
        let caps = STTModelRegistry.resolve(adapterID: "cloudflare", model: "").capabilities
        let applied = STTContextualBiasing.apply(
            bias: STTContextualBias(vocabulary: ["Kubernetes"], extraLanguages: []),
            chainPrompt: "chain",
            primaryLanguage: "",
            capabilities: caps,
            adapterID: "cloudflare",
            model: "")
        // Chain context is preserved; the caller omits `prompt` on no-prompt
        // profiles (STTAdapter gates on supportsPrompt).
        XCTAssertEqual(applied.effectivePrompt, "chain")
        XCTAssertTrue(applied.vocabularyDropped)
        XCTAssertNotNil(applied.diagnostic)
        XCTAssertTrue(applied.diagnostic?.contains("vocabulary") ?? false)
        // Terms themselves never appear in the diagnostic (privacy).
        XCTAssertFalse(applied.diagnostic?.contains("Kubernetes") ?? true)
    }

    @objc func testNoBuiltInProfileEmitsKeywordsField() {
        for (adapter, model) in [
            ("openai", "whisper-1"), ("openai", "gpt-transcribe"),
            ("groq", "whisper-large-v3"), ("cloudflare", ""),
            ("airubiz", "gigaam-v3-ctc-sherpa"), ("custom", "m"),
        ] {
            let caps = STTModelRegistry.resolve(adapterID: adapter, model: model).capabilities
            XCTAssertFalse(caps.supportsKeywordBiasing, "\(adapter)/\(model)")
            let applied = STTContextualBiasing.apply(
                bias: STTContextualBias(vocabulary: ["Kubernetes"], extraLanguages: []),
                chainPrompt: nil,
                primaryLanguage: "",
                capabilities: caps)
            XCTAssertNil(applied.keywordsField, "\(adapter)/\(model)")
        }
    }

    // MARK: - Request builder: gating + escaping

    @objc func testWhisperPlanFoldsVocabularyIntoPrompt() {
        let spec = ProviderRequestBuilder.plan(
            adapterID: "openai", baseURL: "", model: "whisper-1", apiKey: "k",
            language: "ru", wav: wav, prompt: "chain text",
            bias: STTContextualBias(vocabulary: ["Kubernetes", "Whisper"], extraLanguages: []))
        guard let text = bodyText(spec) else {
            XCTFail("openai whisper-1 must be multipart")
            return
        }
        XCTAssertTrue(text.contains("name=\"language\"\r\n\r\nru\r\n"))
        XCTAssertTrue(text.contains("chain text"))
        XCTAssertTrue(text.contains("Technical vocabulary: Kubernetes, Whisper"))
        XCTAssertFalse(text.contains("keywords[]"),
                       "no dedicated keywords field for current profiles")
    }

    @objc func testGptTranscribePlanUsesLanguagesArrayWithExtras() {
        let spec = ProviderRequestBuilder.plan(
            adapterID: "openai", baseURL: "", model: "gpt-transcribe", apiKey: "k",
            language: "ru", wav: wav,
            bias: STTContextualBias(vocabulary: ["NanoDictate"], extraLanguages: ["en"]))
        guard let text = bodyText(spec) else {
            XCTFail("gpt-transcribe must be multipart")
            return
        }
        XCTAssertTrue(text.contains("name=\"languages[]\"\r\n\r\nru\r\n"))
        XCTAssertTrue(text.contains("name=\"languages[]\"\r\n\r\nen\r\n"))
        XCTAssertFalse(text.contains("name=\"language\"\r\n"))
        XCTAssertTrue(text.contains("Technical vocabulary: NanoDictate"))
    }

    @objc func testGroqPlanIgnoresExtraLanguagesButKeepsVocabulary() {
        let spec = ProviderRequestBuilder.plan(
            adapterID: "groq", baseURL: "", model: "whisper-large-v3", apiKey: "k",
            language: "ru", wav: wav,
            bias: STTContextualBias(vocabulary: ["Kubernetes"], extraLanguages: ["en"]))
        guard let text = bodyText(spec) else {
            XCTFail("groq must be multipart")
            return
        }
        XCTAssertTrue(text.contains("name=\"language\"\r\n\r\nru\r\n"))
        XCTAssertFalse(text.contains("languages[]"))
        XCTAssertTrue(text.contains("Technical vocabulary: Kubernetes"))
    }

    @objc func testCloudflarePlanSendsNeitherVocabularyNorLanguages() {
        let url = "https://api.cloudflare.com/client/v4/accounts/a/ai/run/@cf/openai/whisper-large-v3-turbo"
        let spec = ProviderRequestBuilder.plan(
            adapterID: "cloudflare", baseURL: url, model: "", apiKey: "k",
            language: "ru", wav: wav, prompt: "chain",
            bias: STTContextualBias(vocabulary: ["Kubernetes"], extraLanguages: ["en"]))
        guard case .rawAudio(let data, _) = spec.body else {
            XCTFail("cloudflare must be raw audio")
            return
        }
        XCTAssertEqual(data, wav)
    }

    @objc func testVocabularyInjectionCannotBreakMultipart() {
        let spec = ProviderRequestBuilder.plan(
            adapterID: "openai", baseURL: "", model: "whisper-1", apiKey: "k",
            language: "", wav: wav,
            bias: STTContextualBias(
                vocabulary: ["evil\r\nContent-Disposition: form-data; name=\"model\"\r\n\r\nx"],
                extraLanguages: []))
        guard let text = bodyText(spec) else {
            XCTFail("must be multipart")
            return
        }
        XCTAssertFalse(text.contains("evil\r\nContent-Disposition"))
        XCTAssertTrue(text.contains("Technical vocabulary: evil"))
    }

    @objc func testMultipartBodyEmitsReservedKeywordsField() {
        // Reserved serialization path for future supportsKeywordBiasing models.
        let body = ProviderRequestBuilder.multipartBody(
            wav: wav, filename: "a.wav", model: "m", language: "", prompt: nil,
            boundary: "Boundary-TEST", keywords: ["Kubernetes", "Whisper"])
        let text = String(data: body, encoding: .utf8)!
        XCTAssertTrue(text.contains("name=\"keywords[]\"\r\n\r\nKubernetes\r\n"))
        XCTAssertTrue(text.contains("name=\"keywords[]\"\r\n\r\nWhisper\r\n"))
    }

    @objc func testEmptyBiasIsByteIdentical() {
        let plain = ProviderRequestBuilder.plan(
            adapterID: "openai", baseURL: "", model: "whisper-1", apiKey: "k",
            language: "ru", wav: wav, prompt: "chain")
        let biased = ProviderRequestBuilder.plan(
            adapterID: "openai", baseURL: "", model: "whisper-1", apiKey: "k",
            language: "ru", wav: wav, prompt: "chain", bias: .none)
        guard case .multipart(let plainData, _) = plain.body,
            case .multipart(let biasedData, _) = biased.body
        else {
            XCTFail("must be multipart")
            return
        }
        // Bodies differ only by the random boundary; field layout identical.
        let plainText = String(data: plainData, encoding: .utf8)!
        let biasedText = String(data: biasedData, encoding: .utf8)!
        XCTAssertEqual(
            plainText.components(separatedBy: "\r\n").filter { !$0.contains("Boundary-") },
            biasedText.components(separatedBy: "\r\n").filter { !$0.contains("Boundary-") })
    }

    // MARK: - Config

    @objc func testParseVocabularyAndExtraLanguages() throws {
        let content = """
        language = "ru"
        vocabulary = ["Kubernetes", "Whisper"]
        extra_languages = ["en", "ru"]
        """
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.vocabulary, ["Kubernetes", "Whisper"])
        XCTAssertEqual(config.extraLanguages, ["en", "ru"])
    }

    @objc func testParseVocabularyDefaultsToEmpty() throws {
        let config = try AppConfig.parse("language = \"ru\"\n")
        XCTAssertEqual(config.vocabulary, [])
        XCTAssertEqual(config.extraLanguages, [])
    }

    @objc func testParseVocabularyPreservesCommasInsideQuotes() throws {
        let content = """
        vocabulary = ["foo, bar", "baz"]
        extra_languages = ["en", "ru"]
        """
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.vocabulary, ["foo, bar", "baz"])
        XCTAssertEqual(config.extraLanguages, ["en", "ru"])
    }

    // MARK: - Benchmark fixtures cover mixed RU/EN technical dictation

    @objc func testBuiltinFixturesIncludeCodeSwitchTechnical() {
        let fixtures = BenchmarkFixtures.builtins()
        let codeSwitch = fixtures.filter { $0.category == .technical }
        XCTAssertGreaterThanOrEqual(codeSwitch.count, 3)
        XCTAssertNotNil(fixtures.first { $0.id == "technical-codeswitch-short" })
        XCTAssertNotNil(fixtures.first { $0.id == "technical-codeswitch-long" })
        let short = fixtures.first { $0.id == "technical-codeswitch-short" }!
        XCTAssertTrue(short.transcript.contains("whisper"))
        XCTAssertEqual(short.durationBucket, .short)
        let long = fixtures.first { $0.id == "technical-codeswitch-long" }!
        XCTAssertEqual(long.durationBucket, .long)
        XCTAssertGreaterThanOrEqual(long.durationSeconds, 50)
    }

    @objc func testBenchmarkUploadIncludesBiasOverhead() {
        let samples = BenchmarkSynth.samples(seed: 1, durationSeconds: 1, kind: .technical)
        let wavData = WAVEncoder.encode(samples: samples, sampleRate: 16_000)
        let plain = BenchmarkSTTConfig(name: "plain", adapterID: "openai", model: "whisper-1")
        let biased = BenchmarkSTTConfig(
            name: "biased", adapterID: "openai", model: "whisper-1",
            bias: STTContextualBias(vocabulary: ["Kubernetes", "Whisper"], extraLanguages: []))
        XCTAssertGreaterThan(
            BenchmarkRunner.uploadBytes(config: biased, wav: wavData),
            BenchmarkRunner.uploadBytes(config: plain, wav: wavData))
    }
}
