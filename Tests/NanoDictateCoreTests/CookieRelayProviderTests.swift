import Foundation
@testable import NanoDictateCore

// MARK: - CookieRelayMockTransport
//
// One transport pretending to be a cookie-challenge proxy: any request without
// the __test cookie gets the JS-challenge HTML; with the cookie (and
// honorCookie) gets a normal JSON body. Mirrors the real proxy behavior.

final class CookieRelayMockTransport: HTTPTransport, @unchecked Sendable {

    let challengeBody: String
    var honorCookie: Bool
    /// Число STT-POST (multipart), которые получают челлендж вместо ответа.
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

    /// Синхронное потребление счётчика челленджей для STT-POST.
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

// MARK: - CookieRelayProviderTests

/// Реальный челлендж-фикстур (снят с https://proxy.example.com): константы a/b/c и
/// ожидаемый результат — эталон посчитан openssl (`-aes-128-cbc -nopad`).
///   a=f655ba9d09a112d4968c63579db590b4 (ключ AES-128)
///   b=98344c2eee86c3994890592585b49f80 (IV)
///   c=3e512bc3e42f39a757e79f4739c74138 (единственный 16-байтный блок)
///   d74696de7d49fcda5f03f4d247e07cf4 = slowAES.decrypt(c,2,a,b) = значение cookie.
final class CookieRelayProviderTests: XCTestCase {

    private let challengeHTML = """
    <html><body><script type="text/javascript" src="/aes.js" ></script><script>function toNumbers(d){var e=[];d.replace(/(..)/g,function(d){e.push(parseInt(d,16))});return e}function toHex(){for(var d=[],d=1==arguments.length&&arguments[0].constructor==Array?arguments[0]:arguments,e="",f=0;f<d.length;f++)e+=(16>d[f]?"0":"")+d[f].toString(16);return e.toLowerCase()}var a=toNumbers("f655ba9d09a112d4968c63579db590b4"),b=toNumbers("98344c2eee86c3994890592585b49f80"),c=toNumbers("3e512bc3e42f39a757e79f4739c74138");document.cookie="__test="+toHex(slowAES.decrypt(c,2,a,b))+"; max-age=21600; expires=Thu, 31-Dec-37 23:55:55 GMT; path=/"; location.href="https://proxy.example.com/?i=1";</script><noscript>This site requires Javascript to work, please enable Javascript in your browser or use a browser with Javascript support</noscript></body></html>
    """

    private let expectedCookie = "d74696de7d49fcda5f03f4d247e07cf4"

    /// Тестовые часы: injectable now() для «старения» токена без реальных пауз.
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

    /// Крутит event loop, пока mock не насчитает нужное число запросов.
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
        // Реальная страница может отличаться от эталона: пробелы вокруг «=» и
        // скобок, UPPER-HEX, другой порядок констант. Разбор обязан пережить всё.
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
        // Расшифровка uppercase-констант даёт ту же куку, что и lowercase.
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
            // Probe ушёл с готовым Cookie-заголовком.
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
            // Probe получил челлендж → новый токен НЕ принят → старый жив.
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
        // Старый токен есть в памяти, но повторный цикл не прошёл (probe снова
        // вернул челлендж — кука не принята). refreshBlocking обязан вернуть nil,
        // а НЕ старый токен: челлендж-ретрай не должен уходить с заведомо
        // мёртвой кукой и тратить POST. Старый токен при этом остаётся доступен
        // для неблокирующего пути ensureFresh (пока не протух по TTL).
        let transport = CookieRelayMockTransport(challengeBody: challengeHTML)
        let provider = makeProvider(transport: transport)

        runAsync("testRefreshFailsKeepsOldButNil") {
            _ = await provider.refreshBlocking()
            XCTAssertEqual(transport.requestCount, 2, "первый цикл успешен — токен в памяти")

            // Прокси «разонравилась» кука: любые запросы — снова челлендж.
            transport.honorCookie = false
            let refreshed = await provider.refreshBlocking()
            XCTAssertNil(refreshed, "неудачный пересчёт → nil, а не старый токен")
            XCTAssertEqual(provider.currentCookie(), "__test=" + self.expectedCookie,
                           "старый токен остаётся в памяти для ensureFresh")
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
}