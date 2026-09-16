import Foundation
import AppKit
@testable import DictationCore

/// Тесты метки оверлея «через что идёт распознавание» (RecognitionLabel).
///
/// КРИТИЧЕСКОЕ требование: метка обязана браться из ТОГО ЖЕ разрешённого
/// (resolved) провайдера, из которого агент строит реальный запросный путь
/// (Transcriber + транспорт), а НЕ перечитываться из config.toml в момент
/// показа оверлея и не хардкодиться. Единый источник истины — resolved-конфиг
/// сессии: в агенте это `resolvedConfig` (тот же объект, из которого в init
/// собран Transcriber), здесь — config, полученный `AppConfig.parse` с тем же
/// резолвом `active_provider`.
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
        // active_provider = "gigaam": effective-конфиг берёт поля секции gigaam
        // (как агент при построении Transcriber) — метка обязана называть её.
        let config = try AppConfig.parse(Self.twoProvidersTOML)

        XCTAssertEqual(config.activeProvider, "gigaam")
        XCTAssertEqual(config.model, "gigaam-v3", "модель активной секции легла в effective-конфиг")
        XCTAssertEqual(RecognitionLabel.activeProviderID(in: config), "gigaam")
        XCTAssertEqual(RecognitionLabel.forSession(config), "gigaam · gigaam-v3")
    }

    @objc func testLabelChangesWhenActiveProviderChanges() throws {
        // Смена активного провайдера в тестовом конфиге обязана менять метку:
        // ярлык следует за resolved-провайдером, а не зашит константой.
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
        // Жёсткая связка на уровне значений: метка строится из тех же
        // resolved-полей (config.activeProvider / config.model / config.transport),
        // что агент кладёт в Transcriber. Сверка с ручной сборкой из них же —
        // расхождение невозможно, пока источник один.
        let config = try AppConfig.parse(Self.twoProvidersTOML)

        let manual = RecognitionLabel.build(
            provider: config.activeProvider, // разрешённый id активной секции
            model: config.model,
            route: RecognitionLabel.route(transport: config.transport)
        )
        XCTAssertEqual(RecognitionLabel.forSession(config), manual)
        // Модель/транспорт метки — ровно те, что в effective-конфиге (source of truth).
        XCTAssertTrue(RecognitionLabel.forSession(config).contains(config.model))
    }

    @objc func testLabelUsesFirstProvider_WhenNoActiveProvider() throws {
        // Секции без active_provider (документированный сценарий) — активен
        // первый по порядку. Тот же резолв, что в resolveActiveProvider.
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
        // Явный active_provider → он; пусто + секции → первый; legacy без секций → nil.
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
        // name = "MWS" у секции gigaam: метка показывает displayName, а не
        // «лживый» id («GigaAM») — имя берётся из ТОЙ ЖЕ секции, чьи поля
        // агент скопировал в effective-конфиг. Итог: «MWS · gigaam-v3».
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

        // Раздельные части шапки — тем же displayName.
        let parts = RecognitionLabel.sessionParts(config)
        XCTAssertEqual(parts.provider, "MWS")
        XCTAssertEqual(parts.model, "gigaam-v3")
        XCTAssertEqual("\(parts.provider) · \(parts.model)", RecognitionLabel.forSession(config))
    }

    @objc func testLabel_FallsBackToProviderID_WhenNameEmpty() throws {
        // name пустой — фоллбэк на id: метка не пропадает и не врёт.
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
        // Пробельный name == пустой: на метку не влияет.
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
        // name не задан вовсе (двухпровайдерный кейс) — id остаётся меткой:
        // существующие ярлыки не меняются без явного name в конфиге.
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
        // Пустая модель при relay-транспорте: маршрут остаётся («через что реально
        // идёт запрос»), модель не показывается.
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
        // Чистый legacy-конфиг (секций нет) — провайдер не разрешился вовсе: «—».
        let legacy = try AppConfig.parse("""
        base_url = "https://legacy.test/v1"
        model = "gigaam-v3"
        """)
        XCTAssertTrue(legacy.providers.isEmpty)
        XCTAssertEqual(RecognitionLabel.forSession(legacy), "—")

        // И дефолтный конфиг (нет файла) — тоже «—», а не секреты/модель.
        let defaults = AppConfig.defaults
        XCTAssertEqual(RecognitionLabel.forSession(defaults), "—")
    }

    @objc func testLabelFallback_EmptyTransportIsDirect() throws {
        // transport пустой/отсутствует → прямой маршрут, без стрелки.
        let config = try AppConfig.parse(Self.twoProvidersTOML)
        XCTAssertEqual(config.transport, "", "у gigaam транспорт не задан — наследует пустой корневой")
        XCTAssertEqual(RecognitionLabel.route(transport: config.transport), .direct)
        XCTAssertEqual(RecognitionLabel.forSession(config), "gigaam · gigaam-v3")

        XCTAssertEqual(RecognitionLabel.route(transport: nil), .direct)
        XCTAssertEqual(RecognitionLabel.route(transport: "  "), .direct, "пробельный transport — тоже direct")
    }

    @objc func testLabelUsesResolvedTransport_InheritedFromRoot() throws {
        // Транспорт секции не задан, но корневой задан — effective transport
        // наследует корневой (та же логика Config.apply, из которой агент
        // решает про CookieRelayProvider). Метка показывает реальный маршрут.
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

    // MARK: - Примитивы построителя

    // displayProviderName/serverName удалены: мёртвый код в проде (не
    // участвуют в forSession/build — ярлык строится из id-провайдера,
    // а не отображаемого имени/host).

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

        // Смена значения (новая сессия) — состояние обновляется, панель не трогается.
        controller.setSTTLabel("cookie-relay→groq · whisper-large-v3")
        XCTAssertEqual(controller.testState?.sttLabel, "cookie-relay→groq · whisper-large-v3")
        controller.hide()
    }

    @objc func testSetSTTLabel_EmptyHidesLabelInState() {
        // Пустая строка — ярлык скрыт (вью показывает Text только при непустом).
        let controller = OverlayController()
        controller.setSTTLabel("")
        XCTAssertEqual(controller.testState?.sttLabel, "")
        controller.hide()
    }

    @objc func testResetPhaseAndHide_ClearSTTLabel() {
        // Метка живёт только в течение цикла: resetPhase() (терминальные точки
        // цикла, включая undo-путь «Отмена вставки») и hide() обязаны сбрасывать
        // sttLabel, чтобы на панели статуса не оставалась метка ПРОШЛОЙ сессии.
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
        // Значения те же, что in forSession, но раздельно.
        let config = try AppConfig.parse(Self.twoProvidersTOML)
        let parts = RecognitionLabel.sessionParts(config)
        XCTAssertEqual(parts.provider, "gigaam")
        XCTAssertEqual(parts.model, "gigaam-v3")
        // Склейка частей с разделителем == строка forSession (не разойдутся).
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
        // Рендер шапки идёт из строки сессии (setSTTLabel) — разбор обратно
        // на {provider, model} без потерь.
        let label = RecognitionLabel.build(provider: "groq", model: "whisper-large-v3", route: .relay("cookie-relay"))
        XCTAssertEqual(label, "cookie-relay→groq · whisper-large-v3")
        let parts = RecognitionLabel.parts(fromLabel: label)
        XCTAssertEqual(parts.provider, "cookie-relay→groq")
        XCTAssertEqual(parts.model, "whisper-large-v3")
    }

    @objc func testParts_FromLabelWithoutSeparator() {
        // Legacy «—» и одиночный провайдер без модели: вся строка — провайдер.
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
        // Полный круг: sessionParts → build-склейка → parts(fromLabel:) == исходные.
        for content in [Self.twoProvidersTOML,
                        Self.twoProvidersTOML.replacingOccurrences(of: "gigaam", with: "groq")] {
            guard let config = try? AppConfig.parse(content) else { continue }
            let label = RecognitionLabel.forSession(config)
            let reparsed = RecognitionLabel.parts(fromLabel: label)
            XCTAssertEqual(reparsed, RecognitionLabel.sessionParts(config))
        }
    }
}