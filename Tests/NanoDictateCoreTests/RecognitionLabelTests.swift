import Foundation
import AppKit
@testable import NanoDictateCore

/// Tests of overlay "what recognition goes through" label (RecognitionLabel).
///
/// CRITICAL: label MUST come from the SAME resolved provider the agent uses
/// to build the real request path (Transcriber + transport) — NOT re-read
/// from config.toml at overlay time, NOT hardcoded. Single source of truth:
/// session resolved config (`resolvedConfig` in agent; here config from
/// `AppConfig.parse` with the same `active_provider` resolution).
final class RecognitionLabelTests: XCTestCase {

    override func setUp() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
    }

    private static let twoProvidersTOML = """
    active_provider = "gigaam"

    [providers.groq]
    base_url = "https://groq.test/v1"
    model = "whisper-large-v3"
    api_key = "gsk_123"
    transport = "infinityfree"

    [providers.gigaam]
    base_url = "https://gigaam.test/v1"
    model = "gigaam-v3"
    api_key = "v1.xxx"
    """

    // MARK: - (а) Жёсткая связка: метка == провайдер/модель того же resolved-провайдера

    @objc func testLabelMatchesResolvedActiveProvider() throws {
        // active_provider = "gigaam": effective config takes gigaam section fields
        // (like agent building Transcriber) — label must name it.
        let config = try AppConfig.parse(Self.twoProvidersTOML)

        XCTAssertEqual(config.activeProvider, "gigaam")
        XCTAssertEqual(config.model, "gigaam-v3", "модель активной секции легла в effective-конфиг")
        XCTAssertEqual(RecognitionLabel.activeProviderID(in: config), "gigaam")
        XCTAssertEqual(RecognitionLabel.forSession(config), "gigaam · gigaam-v3")
    }

    @objc func testLabelChangesWhenActiveProviderChanges() throws {
        // Changing active provider must change the label:
        // label follows resolved provider, not a hardcoded constant.
        let content = Self.twoProvidersTOML.replacingOccurrences(
            of: "active_provider = \"gigaam\"",
            with: "active_provider = \"groq\""
        )
        let config = try AppConfig.parse(content)

        XCTAssertEqual(config.activeProvider, "groq")
        XCTAssertEqual(config.model, "whisper-large-v3")
        XCTAssertEqual(RecognitionLabel.forSession(config), "cookie-relay→groq · whisper-large-v3",
                       "смена провайдера меняет и имя, и модель, и транспорт в метке")
    }

    @objc func testLabelDerivedFromSameResolvedFieldsAsTranscriber() throws {
        // Value-level binding: label built from same resolved fields
        // (activeProvider / model / transport) agent puts in Transcriber.
        // Cross-check vs manual build — drift impossible while source is single.
        let config = try AppConfig.parse(Self.twoProvidersTOML)

        let manual = RecognitionLabel.build(
            provider: config.activeProvider, // resolved id of active section
            model: config.model,
            route: RecognitionLabel.route(transport: config.transport)
        )
        XCTAssertEqual(RecognitionLabel.forSession(config), manual)
        // Label model/transport — exactly those in effective config (source of truth).
        XCTAssertTrue(RecognitionLabel.forSession(config).contains(config.model))
    }

    @objc func testLabelUsesFirstProvider_WhenNoActiveProvider() throws {
        // Sections without active_provider (documented scenario): first in order
        // active. Same resolution as in resolveActiveProvider.
        let content = """
        [providers.groq]
        base_url = "https://groq.test/v1"
        model = "whisper-large-v3"
        api_key = "gsk_123"

        [providers.gigaam]
        base_url = "https://gigaam.test/v1"
        model = "gigaam-v3"
        api_key = "v1.xxx"
        """
        let config = try AppConfig.parse(content)

        XCTAssertEqual(config.activeProvider, "")
        XCTAssertEqual(RecognitionLabel.activeProviderID(in: config), "groq")
        XCTAssertEqual(config.model, "whisper-large-v3")
        XCTAssertEqual(RecognitionLabel.forSession(config), "groq · whisper-large-v3")
    }

    @objc func testActiveProviderID_FollowsResolutionRules() throws {
        // Explicit active_provider → it; empty + sections → first; legacy without sections → nil.
        let withActive = try AppConfig.parse(Self.twoProvidersTOML)
        XCTAssertEqual(RecognitionLabel.activeProviderID(in: withActive), "gigaam")

        let sectionsOnly = try AppConfig.parse("""
        [providers.b]
        base_url = "https://b.test/v1"
        model = "m"
        """)
        XCTAssertEqual(RecognitionLabel.activeProviderID(in: sectionsOnly), "b")

        let legacy = try AppConfig.parse("""
        base_url = "https://legacy.test/v1"
        model = "gigaam-v3"
        """)
        XCTAssertNil(RecognitionLabel.activeProviderID(in: legacy), "legacy без секций — провайдер не разрешился")
    }

    // MARK: - Отображаемое имя провайдера (name из конфига, фоллбэк на id)

    @objc func testLabel_UsesProviderDisplayNameFromConfig() throws {
        // name = "MWS" on gigaam section: label shows displayName, not "lying" id
        // ("GigaAM") — name taken from the SAME section whose fields agent
        // copied into effective config. Result: "MWS · gigaam-v3".
        let config = try AppConfig.parse("""
        active_provider = "gigaam"

        [providers.gigaam]
        name = "MWS"
        base_url = "https://gigaam.test/v1"
        model = "gigaam-v3"
        api_key = "v1.xxx"
        """)
        XCTAssertEqual(config.providers.first?.name, "MWS", "парсер читает name из секции провайдера")
        XCTAssertEqual(RecognitionLabel.forSession(config), "MWS · gigaam-v3")
        XCTAssertEqual(RecognitionLabel.displayName(for: "gigaam", in: config), "MWS")

        // Split header parts — same displayName.
        let parts = RecognitionLabel.sessionParts(config)
        XCTAssertEqual(parts.provider, "MWS")
        XCTAssertEqual(parts.model, "gigaam-v3")
        XCTAssertEqual("\(parts.provider) · \(parts.model)", RecognitionLabel.forSession(config))
    }

    @objc func testLabel_FallsBackToProviderID_WhenNameEmpty() throws {
        // Empty name → fallback to id: label not lost, not lying.
        let config = try AppConfig.parse("""
        active_provider = "gigaam"

        [providers.gigaam]
        name = ""
        base_url = "https://gigaam.test/v1"
        model = "gigaam-v3"
        api_key = "v1.xxx"
        """)
        XCTAssertEqual(RecognitionLabel.forSession(config), "gigaam · gigaam-v3",
                       "пустой name — фоллбэк на id провайдера")
        XCTAssertEqual(RecognitionLabel.displayName(for: "gigaam", in: config), "gigaam")
    }

    @objc func testLabel_FallsBackToProviderID_WhenNameWhitespaceOnly() throws {
        // Whitespace-only name == empty: no effect on label.
        let config = try AppConfig.parse("""
        active_provider = "gigaam"

        [providers.gigaam]
        name = "   "
        base_url = "https://gigaam.test/v1"
        model = "gigaam-v3"
        api_key = "v1.xxx"
        """)
        XCTAssertEqual(RecognitionLabel.forSession(config), "gigaam · gigaam-v3")
    }

    @objc func testLabel_FallsBackToProviderID_WhenNameAbsent() {
        // No name at all (two-provider case): id stays the label —
        // existing labels unchanged without explicit name in config.
        let config = try? AppConfig.parse(Self.twoProvidersTOML)
        XCTAssertEqual(config.map(RecognitionLabel.forSession) ?? "", "gigaam · gigaam-v3")
        XCTAssertEqual(RecognitionLabel.displayName(for: "gigaam", in: config ?? AppConfig.defaults), "gigaam")
    }

    // MARK: - (б) Фоллбэки: модель пустая / провайдер не разрешился / transport пустой

    @objc func testLabelFallback_EmptyModelShowsOnlyProvider() throws {
        let content = """
        active_provider = "gigaam"

        [providers.gigaam]
        base_url = "https://gigaam.test/v1"
        model = ""
        """
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.model, "")
        XCTAssertEqual(RecognitionLabel.forSession(config), "gigaam", "пустая модель — только имя провайдера")
    }

    @objc func testLabelFallback_EmptyModelWithRelayKeepsRoute() throws {
        // Empty model with relay transport: route stays ("through what the request
        // really goes"), model not shown.
        let config = try AppConfig.parse("""
        active_provider = "groq"

        [providers.groq]
        base_url = "https://groq.test/v1"
        model = ""
        transport = "infinityfree"
        """)
        XCTAssertEqual(RecognitionLabel.forSession(config), "cookie-relay→groq")
    }

    @objc func testLabelFallback_NoProviderResolvedShowsDash() throws {
        // Pure legacy config (no sections): provider unresolved — "—".
        let legacy = try AppConfig.parse("""
        base_url = "https://legacy.test/v1"
        model = "gigaam-v3"
        """)
        XCTAssertTrue(legacy.providers.isEmpty)
        XCTAssertEqual(RecognitionLabel.forSession(legacy), "—")

        // Default config (no file) — also "—", not secrets/model.
        let defaults = AppConfig.defaults
        XCTAssertEqual(RecognitionLabel.forSession(defaults), "—")
    }

    @objc func testLabelFallback_EmptyTransportIsDirect() throws {
        // Empty/missing transport → direct route, no arrow.
        let config = try AppConfig.parse(Self.twoProvidersTOML)
        XCTAssertEqual(config.transport, "", "у gigaam транспорт не задан — наследует пустой корневой")
        XCTAssertEqual(RecognitionLabel.route(transport: config.transport), .direct)
        XCTAssertEqual(RecognitionLabel.forSession(config), "gigaam · gigaam-v3")

        XCTAssertEqual(RecognitionLabel.route(transport: nil), .direct)
        XCTAssertEqual(RecognitionLabel.route(transport: "  "), .direct, "пробельный transport — тоже direct")
    }

    @objc func testLabelUsesResolvedTransport_InheritedFromRoot() throws {
        // Section transport unset, root set: effective transport inherits root
        // (Config.apply logic agent uses for CookieRelayProvider).
        // Label shows the real route.
        let content = """
        transport = "infinityfree"
        active_provider = "gigaam"

        [providers.gigaam]
        base_url = "https://gigaam.test/v1"
        model = "gigaam-v3"
        """
        let config = try AppConfig.parse(content)
        XCTAssertEqual(config.transport, "cookie-relay", "без transport в секции корневой остаётся в силе (канонизирован)")
        XCTAssertEqual(RecognitionLabel.forSession(config), "cookie-relay→gigaam · gigaam-v3")
    }

    // MARK: - route(): только cookie-relay ведёт через реле

    @objc func testRoute_NonCookieTransportIsDirect() {
        XCTAssertEqual(RecognitionLabel.route(transport: "http://example.test"), .direct,
                       "http-транспорт — прямой запрос, не реле")
        XCTAssertEqual(RecognitionLabel.route(transport: "gateway"), .direct)
        XCTAssertEqual(RecognitionLabel.route(transport: "direct"), .direct)
    }

    @objc func testRoute_CookieRelayTrimsToRelay() {
        XCTAssertEqual(RecognitionLabel.route(transport: "cookie-relay"), .relay("cookie-relay"))
        XCTAssertEqual(RecognitionLabel.route(transport: "  cookie-relay  "), .relay("cookie-relay"),
                       "cookie-relay с пробелами тримится до канонического значения")
    }

    // MARK: - Примитивы построителя

    // displayProviderName/serverName removed: dead prod code (not in
    // forSession/build — label built from provider id, not display name/host).

    @objc func testBuild_DirectAndEmptyModel() {
        XCTAssertEqual(RecognitionLabel.build(provider: "gigaam", model: "gigaam-v3"), "gigaam · gigaam-v3")
        XCTAssertEqual(RecognitionLabel.build(provider: "gigaam", model: ""), "gigaam")
        XCTAssertEqual(RecognitionLabel.build(provider: "groq", model: "  whisper-large-v3  "), "groq · whisper-large-v3",
                       "модель обрезается по краям")
    }

    @objc func testBuild_RelayRoute() {
        XCTAssertEqual(
            RecognitionLabel.build(provider: "groq", model: "whisper-large-v3", route: .relay("cookie-relay")),
            "cookie-relay→groq · whisper-large-v3"
        )
        XCTAssertEqual(
            RecognitionLabel.build(provider: "groq", model: "whisper-large-v3", route: .relay("")),
            "groq · whisper-large-v3",
            "пустое имя реле — как прямой запрос"
        )
        XCTAssertEqual(
            RecognitionLabel.providerPart(provider: "groq", route: .relay("cookie-relay")),
            "cookie-relay→groq"
        )
        XCTAssertEqual(
            RecognitionLabel.providerPart(provider: "groq", route: .direct),
            "groq"
        )
    }

    // MARK: - Плумбинг: setSTTLabel доходит до состояния оверлея

    @objc func testSetSTTLabel_PassesThroughToOverlayState() {
        let controller = OverlayController()
        controller.setSTTLabel("gigaam · gigaam-v3")
        XCTAssertEqual(controller.testState?.sttLabel, "gigaam · gigaam-v3")

        // Changed value (new session): state updates, panel untouched.
        controller.setSTTLabel("cookie-relay→groq · whisper-large-v3")
        XCTAssertEqual(controller.testState?.sttLabel, "cookie-relay→groq · whisper-large-v3")
        controller.hide()
    }

    @objc func testSetSTTLabel_EmptyHidesLabelInState() {
        // Empty string — label hidden (view shows Text only when non-empty).
        let controller = OverlayController()
        controller.setSTTLabel("")
        XCTAssertEqual(controller.testState?.sttLabel, "")
        controller.hide()
    }

    @objc func testResetPhaseAndHide_ClearSTTLabel() {
        // Label lives only within a cycle: resetPhase() (terminal cycle points,
        // incl. undo path "cancel insert") and hide() must clear sttLabel —
        // no LAST-session label left on the status panel.
        let controller = OverlayController()
        controller.setSTTLabel("gigaam · gigaam-v3")
        controller.resetPhase()
        XCTAssertEqual(controller.testState?.sttLabel, "", "resetPhase сбрасывает метку прошлой сессии")

        controller.setSTTLabel("groq · whisper-large-v3")
        controller.hide()
        XCTAssertEqual(controller.testState?.sttLabel, "", "hide сбрасывает метку через resetPhase")
    }

    // MARK: - parts() — раздельные части шапки {provider, model}

    @objc func testSessionParts_DirectRoute() throws {
        // Same values as forSession, but split apart.
        let config = try AppConfig.parse(Self.twoProvidersTOML)
        let parts = RecognitionLabel.sessionParts(config)
        XCTAssertEqual(parts.provider, "gigaam")
        XCTAssertEqual(parts.model, "gigaam-v3")
        // Parts joined with separator == forSession string (cannot drift apart).
        XCTAssertEqual("\(parts.provider) · \(parts.model)", RecognitionLabel.forSession(config))
    }

    @objc func testSessionParts_RelayPrefixGoesToProvider() throws {
        let content = Self.twoProvidersTOML.replacingOccurrences(
            of: "active_provider = \"gigaam\"",
            with: "active_provider = \"groq\""
        )
        let config = try AppConfig.parse(content)
        let parts = RecognitionLabel.sessionParts(config)
        XCTAssertEqual(parts.provider, "cookie-relay→groq", "маршрут-префикс остаётся в части провайдера")
        XCTAssertEqual(parts.model, "whisper-large-v3")
    }

    @objc func testSessionParts_LegacyProviderIsDash() throws {
        let legacy = try AppConfig.parse("""
        base_url = "https://legacy.test/v1"
        model = "gigaam-v3"
        """)
        let parts = RecognitionLabel.sessionParts(legacy)
        XCTAssertEqual(parts.provider, "—", "legacy без секций — провайдер «—», как в forSession")
        XCTAssertEqual(parts.model, "", "модели без провайдера нет места в шапке")
    }

    @objc func testSessionParts_EmptyModelShowsOnlyProvider() throws {
        let config = try AppConfig.parse("""
        active_provider = "gigaam"

        [providers.gigaam]
        base_url = "https://gigaam.test/v1"
        model = ""
        """)
        let parts = RecognitionLabel.sessionParts(config)
        XCTAssertEqual(parts.provider, "gigaam")
        XCTAssertEqual(parts.model, "")
    }

    @objc func testParts_BuilderSplitsProviderAndModel() {
        let p1 = RecognitionLabel.parts(provider: "gigaam", model: "gigaam-v3")
        XCTAssertEqual(p1.provider, "gigaam")
        XCTAssertEqual(p1.model, "gigaam-v3")

        let p2 = RecognitionLabel.parts(provider: "groq", model: "  whisper-large-v3  ", route: .relay("cookie-relay"))
        XCTAssertEqual(p2.provider, "cookie-relay→groq")
        XCTAssertEqual(p2.model, "whisper-large-v3", "модель обрезается по краям")
    }

    @objc func testParts_FromSessionLabel() {
        // Header renders from session string (setSTTLabel) — parsed back
        // to {provider, model} without loss.
        let label = RecognitionLabel.build(provider: "groq", model: "whisper-large-v3", route: .relay("cookie-relay"))
        XCTAssertEqual(label, "cookie-relay→groq · whisper-large-v3")
        let parts = RecognitionLabel.parts(fromLabel: label)
        XCTAssertEqual(parts.provider, "cookie-relay→groq")
        XCTAssertEqual(parts.model, "whisper-large-v3")
    }

    @objc func testParts_FromLabelWithoutSeparator() {
        // Legacy "—" and lone provider without model: whole string is provider.
        XCTAssertEqual(RecognitionLabel.parts(fromLabel: "—"),
                       RecognitionLabel.RecognitionLabelParts(provider: "—", model: ""))
        XCTAssertEqual(RecognitionLabel.parts(fromLabel: "gigaam"),
                       RecognitionLabel.RecognitionLabelParts(provider: "gigaam", model: ""))
    }

    @objc func testParts_FromLabelTrimsWhitespace() {
        XCTAssertEqual(
            RecognitionLabel.parts(fromLabel: "  gigaam · gigaam-v3  "),
            RecognitionLabel.RecognitionLabelParts(provider: "gigaam", model: "gigaam-v3")
        )
    }

    @objc func testParts_RoundTripWithForSession() throws {
        // Full round: sessionParts → build join → parts(fromLabel:) == original.
        for content in [Self.twoProvidersTOML,
                        Self.twoProvidersTOML.replacingOccurrences(of: "gigaam", with: "groq")] {
            guard let config = try? AppConfig.parse(content) else { continue }
            let label = RecognitionLabel.forSession(config)
            let reparsed = RecognitionLabel.parts(fromLabel: label)
            XCTAssertEqual(reparsed, RecognitionLabel.sessionParts(config))
        }
    }
}