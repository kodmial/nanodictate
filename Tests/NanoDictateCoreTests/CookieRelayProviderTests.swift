import Foundation
@testable import NanoDictateCore

// MARK: - CookieRelayMockTransport
// One transport pretending to be a cookie-challenge proxy: any request without
// the __test cookie gets the JS-challenge HTML; with the cookie (and
// honorCookie) gets a normal JSON body. Mirrors the real proxy behavior.

final class CookieRelayMockTransport: HTTPTransport, @unchecked Sendable {

    let challengeBody: String
    var honorCookie: Bool
    /// STT-POST (multipart) count that gets a challenge instead of a reply.
    var rejectPostCount: Int

    private let lock = NSLock()
    private(set) var requests: [URLRequest] = []
    private(set) var statusCode = 200

    init(challengeBody: String, honorCookie: Bool = true, rejectPostCount: Int = 0) {
        self.challengeBody = challengeBody
        self.honorCookie = honorCookie
        self.rejectPostCount = rejectPostCount
    }

    func send(request: URLRequest) async throws -> (status: Int, body: Data, headers: [String: String]) {
        record(request)

        let contentType = request.value(forHTTPHeaderField: "Content-Type") ?? ""
        let isSTT = request.httpMethod == "POST" && contentType.hasPrefix("multipart/form-data")
        let hasCookie = request.value(forHTTPHeaderField: "Cookie") != nil

        if isSTT && consumeReject() {
            return (statusCode, Data(challengeBody.utf8), [:])
        }
        if hasCookie && honorCookie {
            return (statusCode, Data(#"{"text":"ok"}"#.utf8), [:])
        }
        return (statusCode, Data(challengeBody.utf8), [:])
    }

    private func record(_ request: URLRequest) {
        lock.lock(); defer { lock.unlock() }
        requests.append(request)
    }

    private func consumeReject() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if rejectPostCount > 0 {
            rejectPostCount -= 1
            return true
        }
        return false
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.count
    }

    var postCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.httpMethod == "POST" }.count
    }

    var lastRequest: URLRequest? {
        lock.lock(); defer { lock.unlock() }
        return requests.last
    }
}

// MARK: - GatedChallengeTransport
// Транспорт-челлендж, чей ПЕРВЫЙ send паркуется на гейте: refresh держится в
// полёте (незавершённым), пока тест не вызовет open(). Остальные send'ы
// отвечают как CookieRelayMockTransport (челлендж без куки, ok-тело с кукой).
// Запись запроса происходит ДО гейта, поэтому requestCount == 1 означает,
// что первый send уже вошёл и refresh вот-вот запаркуется.

/// Разовый гейт: `waitForOpen()` приостанавливает вызывающего (refresh в
/// полёте), пока тест не вызовет `open()`. Continuation-based — поток
/// cooperative pool не блокируется. Даёт детерминированную mid-wait отмену
/// без тайминговых гонок.
private final class OpenGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    var isOpen: Bool {
        lock.lock(); defer { lock.unlock() }
        return opened
    }

    /// Паркует вызывающего (первый send refresh'а) до open().
    func waitForOpen() async {
        lock.lock()
        let alreadyOpen = opened
        lock.unlock()
        if alreadyOpen { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            var resumeNow = false
            lock.lock()
            if opened {
                resumeNow = true
            } else {
                continuation = cont
            }
            lock.unlock()
            if resumeNow {
                cont.resume()
            }
        }
    }

    /// Отпускает запаркованный refresh.
    func open() {
        let toResume: CheckedContinuation<Void, Never>? = {
            lock.lock()
            defer { lock.unlock() }
            if opened { return nil }
            opened = true
            let c = continuation
            continuation = nil
            return c
        }()
        toResume?.resume()
    }
}

private final class GatedChallengeTransport: HTTPTransport, @unchecked Sendable {
    let challengeBody: String
    let gate = OpenGate()

    private let lock = NSLock()
    private var firstSendConsumed = false
    private(set) var requests: [URLRequest] = []

    init(challengeBody: String) {
        self.challengeBody = challengeBody
    }

    func send(request: URLRequest) async throws -> (status: Int, body: Data, headers: [String: String]) {
        lock.lock()
        requests.append(request)
        let isFirst = !firstSendConsumed
        firstSendConsumed = true
        lock.unlock()

        if isFirst {
            await gate.waitForOpen()
        }

        if request.value(forHTTPHeaderField: "Cookie") != nil {
            return (200, Data(#"{"text":"ok"}"#.utf8), [:])
        }
        return (200, Data(challengeBody.utf8), [:])
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests.count
    }
}

// MARK: - CookieRelayProviderTests

/// Real challenge fixture (captured from https://proxy.example.com); reference
/// value computed with openssl (-aes-128-cbc -nopad).
///   a=f655ba9d09a112d4968c63579db590b4 (AES-128 key)
///   b=98344c2eee86c3994890592585b49f80 (IV)
///   c=3e512bc3e42f39a757e79f4739c74138 (single 16-byte block)
///   d74696de7d49fcda5f03f4d247e07cf4 = slowAES.decrypt(c,2,a,b) = cookie value.
final class CookieRelayProviderTests: XCTestCase {

    private let challengeHTML = """
    <html><body><script type="text/javascript" src="/aes.js" ></script><script>function toNumbers(d){var e=[];d.replace(/(..)/g,function(d){e.push(parseInt(d,16))});return e}function toHex(){for(var d=[],d=1==arguments.length&&arguments[0].constructor==Array?arguments[0]:arguments,e="",f=0;f<d.length;f++)e+=(16>d[f]?"0":"")+d[f].toString(16);return e.toLowerCase()}var a=toNumbers("f655ba9d09a112d4968c63579db590b4"),b=toNumbers("98344c2eee86c3994890592585b49f80"),c=toNumbers("3e512bc3e42f39a757e79f4739c74138");document.cookie="__test="+toHex(slowAES.decrypt(c,2,a,b))+"; max-age=21600; expires=Thu, 31-Dec-37 23:55:55 GMT; path=/"; location.href="https://proxy.example.com/?i=1";</script><noscript>This site requires Javascript to work, please enable Javascript in your browser or use a browser with Javascript support</noscript></body></html>
    """

    private let expectedCookie = "d74696de7d49fcda5f03f4d247e07cf4"

    /// Injectable now() ages the token without real pauses.
    private final class TestClock {
        var value = Date()
    }

    /// Runs an async closure to completion inside a synchronous test method.
    private func runAsync(_ testName: String, _ body: @escaping () async throws -> Void) {
        let expectation = expectation(description: testName)
        Task {
            do {
                try await body()
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 10)
    }

    private func waitForRequests(_ transport: CookieRelayMockTransport, count: Int, timeout: TimeInterval = 3) async {
        let deadline = CFAbsoluteTimeGetCurrent() + timeout
        while transport.requestCount < count && CFAbsoluteTimeGetCurrent() < deadline {
            await Task.yield()
        }
    }

    private func makeProvider(transport: CookieRelayMockTransport, clock: TestClock? = nil) -> CookieRelayProvider {
        CookieRelayProvider(
            origin: "https://proxy.example.com",
            transport: transport,
            now: { clock?.value ?? Date() }
        )
    }

    // MARK: - Разбор и дешифровка челленджа

    @objc func testExtractConstantsFromChallenge() {
        let consts = CookieRelayProvider.extractConstants(from: challengeHTML)
        XCTAssertNotNil(consts)
        XCTAssertEqual(consts?.keyHex, "f655ba9d09a112d4968c63579db590b4")
        XCTAssertEqual(consts?.ivHex, "98344c2eee86c3994890592585b49f80")
        XCTAssertEqual(consts?.cipherHex, "3e512bc3e42f39a757e79f4739c74138")
    }

    @objc func testDecryptMatchesReferenceValue() {
        let value = CookieRelayProvider.decrypt(
            a: "f655ba9d09a112d4968c63579db590b4",
            b: "98344c2eee86c3994890592585b49f80",
            c: "3e512bc3e42f39a757e79f4739c74138"
        )
        XCTAssertEqual(value, expectedCookie, "slowAES.decrypt(c,2,a,b) == AES-128-CBC без padding")
    }

    @objc func testDecryptInvalidSizesReturnNil() {
        XCTAssertNil(CookieRelayProvider.decrypt(a: "aa", b: "bb", c: "cc"))
        XCTAssertNil(CookieRelayProvider.decrypt(a: "", b: "", c: ""))
    }

    @objc func testLooksLikeChallenge() {
        XCTAssertTrue(CookieRelayProvider.looksLikeChallenge(challengeHTML))
        XCTAssertTrue(CookieRelayProvider.looksLikeChallenge(Data(challengeHTML.utf8)))
        XCTAssertFalse(CookieRelayProvider.looksLikeChallenge(#"{"text":"ok"}"#))
        XCTAssertFalse(CookieRelayProvider.looksLikeChallenge(""))
    }

    @objc func testExtractConstantsToleratesSpacesAndUppercaseAndOrder() {
        // Real page may vary: spaces, UPPER-HEX, constant order — parser must survive.
        let page = """
        <script>var c=toNumbers("3E512BC3E42F39A757E79F4739C74138") ;
        b = toNumbers( "98344c2eee86c3994890592585b49f80" ) ,  a=toNumbers("F655BA9D09A112D4968C63579DB590B4");
        </script>
        """
        let consts = CookieRelayProvider.extractConstants(from: page)
        XCTAssertNotNil(consts, "пробелы/UPPER-HEX/порядок не должны ломать разбор")
        XCTAssertEqual(consts?.keyHex.lowercased(), "f655ba9d09a112d4968c63579db590b4")
        XCTAssertEqual(consts?.ivHex, "98344c2eee86c3994890592585b49f80")
        XCTAssertEqual(consts?.cipherHex.lowercased(), "3e512bc3e42f39a757e79f4739c74138")
        // Uppercase constants decrypt to the same cookie.
        if let consts = consts {
            let value = CookieRelayProvider.decrypt(a: consts.keyHex, b: consts.ivHex, c: consts.cipherHex)
            XCTAssertEqual(value, expectedCookie)
        }
    }

    @objc func testOriginFromBaseURL() {
        XCTAssertEqual(
            CookieRelayProvider.origin(from: "https://proxy.example.com/go/https://api.openai.com/v1"),
            "https://proxy.example.com"
        )
        XCTAssertEqual(CookieRelayProvider.origin(from: "https://proxy.example.com:8443/go/x"), "https://proxy.example.com:8443")
        XCTAssertNil(CookieRelayProvider.origin(from: "not a url"))
    }

    // MARK: - Полный цикл refresh

    @objc func testRefreshProducesCookie() {
        let transport = CookieRelayMockTransport(challengeBody: challengeHTML)
        let provider = makeProvider(transport: transport)

        runAsync("testRefresh") {
            let cookie = await provider.refreshBlocking()
            XCTAssertEqual(cookie, "__test=" + self.expectedCookie)
            XCTAssertEqual(transport.requestCount, 2,
                           "полный цикл = GET челленджа + probe GET с новой кукой")
            let probe = transport.requests.dropFirst().first
            XCTAssertEqual(probe?.value(forHTTPHeaderField: "Cookie"), "__test=" + self.expectedCookie)
        }
    }

    @objc func testFreshTokenEnsureFreshZeroNetwork() {
        let transport = CookieRelayMockTransport(challengeBody: challengeHTML)
        let provider = makeProvider(transport: transport)

        runAsync("testFreshZeroNetwork") {
            _ = await provider.refreshBlocking()
            let cookie = await provider.ensureFresh()
            XCTAssertEqual(cookie, "__test=" + self.expectedCookie)
            XCTAssertEqual(transport.requestCount, 2,
                           "токен моложе 120 с — ensureFresh() мгновенен, сетевых запросов нет")
        }
    }

    @objc func testStaleTokenRecomputesInBackground() {
        let clock = TestClock()
        let transport = CookieRelayMockTransport(challengeBody: challengeHTML)
        let provider = makeProvider(transport: transport, clock: clock)

        runAsync("testStaleBackground") {
            _ = await provider.refreshBlocking()
            XCTAssertEqual(transport.requestCount, 2)

            clock.value = clock.value.addingTimeInterval(CookieRelayProvider.tokenTTL + 1)
            let cookie = await provider.ensureFresh()
            XCTAssertEqual(cookie, "__test=" + self.expectedCookie,
                           "возвращает ТЕКУЩИЙ токен сразу, не дожидаясь пересчёта")
            await self.waitForRequests(transport, count: 4)
            XCTAssertEqual(transport.requestCount, 4, "протухший токен пересчитан ФОНОМ")
            XCTAssertEqual(provider.currentCookie(), "__test=" + self.expectedCookie)
        }
    }

    @objc func testConcurrentEnsureFreshSingleRefresh() {
        let clock = TestClock()
        let transport = CookieRelayMockTransport(challengeBody: challengeHTML)
        let provider = makeProvider(transport: transport, clock: clock)

        runAsync("testConcurrent") {
            _ = await provider.refreshBlocking()
            clock.value = clock.value.addingTimeInterval(CookieRelayProvider.tokenTTL + 1)

            async let first = provider.ensureFresh()
            async let second = provider.ensureFresh()
            _ = await first
            _ = await second
            await self.waitForRequests(transport, count: 4)
            XCTAssertEqual(transport.requestCount, 4,
                           "параллельные ensureFresh на протухший токен → ОДИН пересчёт (2 запроса), не два")
        }
    }

    @objc func testFailedProbePreservesOldToken() {
        let clock = TestClock()
        let transport = CookieRelayMockTransport(challengeBody: challengeHTML, honorCookie: true)
        let provider = makeProvider(transport: transport, clock: clock)

        runAsync("testProbeFails") {
            _ = await provider.refreshBlocking()
            XCTAssertEqual(transport.requestCount, 2)

            transport.honorCookie = false
            clock.value = clock.value.addingTimeInterval(CookieRelayProvider.tokenTTL + 1)

            let cookie = await provider.ensureFresh()
            XCTAssertEqual(cookie, "__test=" + self.expectedCookie, "старый токен отдаётся мгновенно")
            await self.waitForRequests(transport, count: 4)
            XCTAssertEqual(transport.requestCount, 4, "фоновый пересчёт честно сходил за токеном")
            // Probe got challenge → new token rejected → old stays alive.
            XCTAssertEqual(provider.currentCookie(), "__test=" + self.expectedCookie)
        }
    }

    @objc func testRefreshFailsOnNetworkErrorReturnsNil() {
        final class FailingTransport: HTTPTransport, @unchecked Sendable {
            func send(request: URLRequest) async throws -> (status: Int, body: Data, headers: [String: String]) {
                throw URLError(.cannotConnectToHost)
            }
        }
        let provider = CookieRelayProvider(origin: "https://proxy.example.com", transport: FailingTransport())
        runAsync("testNetworkFail") {
            let cookie = await provider.refreshBlocking()
            XCTAssertNil(cookie, "сбой сети → nil, токена нет")
            XCTAssertNil(provider.currentCookie())
        }
    }

    @objc func testRefreshFailureReturnsNilDespiteOldToken() {
        // Probe still challenged: refreshBlocking must return nil, not the stale
        // cookie — challenge retry must not keep POSTing a dead cookie. Old cookie
        // stays available for ensureFresh until TTL.
        let transport = CookieRelayMockTransport(challengeBody: challengeHTML)
        let provider = makeProvider(transport: transport)

        runAsync("testRefreshFailsKeepsOldButNil") {
            _ = await provider.refreshBlocking()
            XCTAssertEqual(transport.requestCount, 2, "первый цикл успешен — токен в памяти")

            // Proxy now rejects the cookie: every request gets a challenge.
            transport.honorCookie = false
            let refreshed = await provider.refreshBlocking()
            XCTAssertNil(refreshed, "неудачный пересчёт → nil, а не старый токен")
            XCTAssertEqual(provider.currentCookie(), "__test=" + self.expectedCookie,
                           "старый токен остаётся в памяти для ensureFresh")
        }
    }

    // MARK: - Верифицирующий probe: не-2xx статус и challenge-тело

    @objc func testProbeNon2xxStatusRejectsToken() {
        final class Non2xxProbeTransport: HTTPTransport, @unchecked Sendable {
            let challengeBody: String
            init(challengeBody: String) { self.challengeBody = challengeBody }
            func send(request: URLRequest) async throws -> (status: Int, body: Data, headers: [String: String]) {
                // Запрос с Cookie — это probe; челлендж-GET куки не несёт.
                if request.value(forHTTPHeaderField: "Cookie") != nil {
                    return (503, Data(#"{"error":"upstream down"}"#.utf8), [:])
                }
                return (200, Data(challengeBody.utf8), [:])
            }
        }
        let provider = CookieRelayProvider(
            origin: "https://proxy.example.com",
            transport: Non2xxProbeTransport(challengeBody: challengeHTML)
        )

        runAsync("testProbeNon2xx") {
            let cookie = await provider.refreshBlocking()
            XCTAssertNil(cookie, "probe GET вернул 503 (не-2xx) — токен не сохраняется")
            XCTAssertNil(provider.currentCookie(), "не сохраняется и в памяти")
        }
    }

    @objc func testProbeChallengeBodyRejectsToken() {
        // honorCookie=false: верифицирующий probe получает 200 с challenge-телом
        // — cookie вычислилась, но сервер её не принял.
        let transport = CookieRelayMockTransport(challengeBody: challengeHTML, honorCookie: false)
        let provider = makeProvider(transport: transport)

        runAsync("testProbeChallengeBody") {
            let cookie = await provider.refreshBlocking()
            XCTAssertNil(cookie, "probe вернул 200 с challenge-телом — токен не сохраняется")
            XCTAssertEqual(transport.requestCount, 2, "челлендж GET + probe GET с кукой")
            XCTAssertNil(provider.currentCookie())
        }
    }

    @objc func testMakeForCookieRelayFromBaseURL() {
        let transport = CookieRelayMockTransport(challengeBody: challengeHTML)
        let provider = CookieRelayProvider.makeForCookieRelay(
            baseURL: "https://proxy.example.com/go/https://api.openai.com/v1/audio/transcriptions",
            transport: transport
        )
        XCTAssertNotNil(provider, "parsable base_url → cookie-слой поднят")
        XCTAssertNil(CookieRelayProvider.makeForCookieRelay(baseURL: "not a url"))

        guard let provider = provider else { return }
        runAsync("testMakeFor") {
            _ = await provider.refreshBlocking()
            XCTAssertEqual(transport.requestCount, 2)
        }
    }

    // MARK: - Отменённый caller refreshBlocking

    @objc func testRefreshBlockingCancelledCallerReturnsNilButKeepsSharedRefresh() {
        let transport = CookieRelayMockTransport(challengeBody: challengeHTML)
        let provider = makeProvider(transport: transport)

        runAsync("testCancelledCaller") {
            // Отменённый caller: refreshBlocking() возвращает nil мгновенно
            // (не блокирует группу на shared-пересчёте), НО refresh, который
            // он стартовал, НЕ отменяется — другие caller'ы дожидаются его
            // результата.
            let cancelledCaller = Task { () -> String? in
                // Детерминированно: ждём, пока cancel() применится к задаче,
                // затем вызываем refreshBlocking уже в отменённом контексте.
                for _ in 0..<10_000 {
                    if Task.isCancelled { break }
                    await Task.yield()
                }
                return await provider.refreshBlocking()
            }
            cancelledCaller.cancel()
            let first = await cancelledCaller.value
            XCTAssertNil(first, "отменённый caller → nil, а не ожидание сети")

            // Shared refresh жив: обычный caller получает результат ТОГО ЖЕ
            // пересчёта (суммарно 2 запроса — дубль не запускался, task не был
            // отменён).
            let second = await provider.refreshBlocking()
            XCTAssertEqual(second, "__test=" + self.expectedCookie)
            XCTAssertEqual(transport.requestCount, 2,
                           "один общий пересчёт выжил после отмены первого caller'а")
            XCTAssertEqual(provider.currentCookie(), "__test=" + self.expectedCookie)
        }
    }

    @objc func testRefreshBlockingCancelledMidWaitReturnsNilButSharedRefreshCompletes() {
        let transport = GatedChallengeTransport(challengeBody: challengeHTML)
        let provider = CookieRelayProvider(
            origin: "https://proxy.example.com",
            transport: transport,
            now: { Date() }
        )

        runAsync("testCancelledMidWait") {
            // Safety net: даже при падении ассерта отпустить refresh — никакой
            // запаркованный таск не должен пережить тест (паттерн ReviewGate).
            defer { transport.gate.open() }

            // Caller входит в refreshBlocking БЕЗ отмены (пре-чек
            // `if Task.isCancelled` не срабатывает) и застревает ВНУТРИ
            // waitAbandoningOnCancellation: refresh в полёте (первый send
            // запаркован на гейте), continuation уже прикреплён.
            let caller = Task { () -> String? in
                await provider.refreshBlocking()
            }

            // Детерминированно: ждём первый запрос (refresh реально вошёл в
            // сеть и вот-вот запаркуется), даём caller'у прикрепить
            // continuation и уснуть — затем отменяем mid-wait.
            let entered = CFAbsoluteTimeGetCurrent() + 3
            while transport.requestCount < 1 && CFAbsoluteTimeGetCurrent() < entered {
                await Task.yield()
            }
            try await Task.sleep(nanoseconds: 100_000_000)

            caller.cancel()
            let first = await caller.value
            XCTAssertNil(first, "mid-wait отменённый caller → nil, а не ожидание сети")
            XCTAssertFalse(transport.gate.isOpen,
                           "nil получен от ABANDON'а (гейт ещё закрыт), а не от завершения refresh'а")

            // Shared refresh жив: отпускаем гейт — таск, который стартовал
            // отменённый caller, НЕ был отменён и доводит цикл до конца.
            transport.gate.open()
            let done = CFAbsoluteTimeGetCurrent() + 3
            while transport.requestCount < 2 && CFAbsoluteTimeGetCurrent() < done {
                await Task.yield()
            }
            XCTAssertEqual(transport.requestCount, 2,
                           "общий пересчёт доведён до конца (челлендж GET + probe GET)")
            // requestCount инкрементится в верху send ДО storeToken — токен
            // появляется на микросекунды позже окончания последнего send.
            // Полизация фактического состояния (тот же паттерн, что выше).
            while provider.currentCookie() == nil && CFAbsoluteTimeGetCurrent() < done {
                await Task.yield()
            }
            XCTAssertEqual(provider.currentCookie(), "__test=" + self.expectedCookie,
                           "shared refresh не отменён — токен в итоге сохранён")

            // Обычный caller теперь получает готовый токен без сетевого
            // пересчёта: токен свежий (TTL не вышел) → ensureFresh() мгновенен.
            let second = await provider.ensureFresh()
            XCTAssertEqual(second, "__test=" + self.expectedCookie)
            XCTAssertEqual(transport.requestCount, 2, "повторного пересчёта не было")
        }
    }
}
