import Foundation
import CommonCrypto

// MARK: - ByetCookieProvider
//
// Унифицированный транспорт STT-провайдера (ключ `transport` в конфиге).
// Разбор Byet JS-челленджа, которым InfinityFree (а точнее Byet) встречает
// «небраузерные» запросы: сервер вместо контента присылает HTML со скриптом
// и константами a/b/c (hex по 32 символа); браузер вычисляет cookie
// `__test = toHex(slowAES.decrypt(c, 2, a, b))` и редиректит с ним.
//
// Требования пользователя, зашитые здесь:
//   1. Никакого node/JavaScript — slowAES.decrypt(c,2,a,b) воспроизводится
//      байт-в-байт на CommonCrypto (AES-128-CBC, БЕЗ снятия padding), ~15 строк.
//   2. Cookie НЕ в конфиге — живёт в памяти: {value, createdAt}, TTL 120 с.
//   3. Обновление неблокирующее: пока токен моложе 120 с — ensureFresh()
//      возвращает текущий токен мгновенно, без единого сетевого запроса;
//      протухший/отсутствующий токен обновляется ФОНОМ, вызывающий получает
//      текущий токен сразу. Блокирующий refresh нужен в одном месте — когда
//      STT-запрос уже получил челлендж (ретраить есть смысл только со свежей
//      кукой).
//   4. Один фиксированный браузерный UA (Chrome) — и за челленджем, и на
//      STT-запросы через прокси.

public final class ByetCookieProvider {

    /// TTL токена в памяти (сек). Cookie Byet выдаёт на ≥ 120 секунд —
    /// до этого срока свежий токен не пересчитывается вообще.
    public static let tokenTTL: TimeInterval = 120

    /// Единственный User-Agent, которым агент «ходит»: и за челленджем, и на
    /// STT-запросы через InfinityFree-прокси (браузерный UA обязателен —
    /// curl/8.0 получает «Empty reply from server»).
    public static let chromeUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    /// Имя cookie в заголовке (без "=").
    private static let cookieName = "__test"

    /// Таймаут refresh-запросов (челлендж-GET и probe-GET), сек. Страницы
    /// маленькие, ответ приходит быстро, а refreshBlocking() может выполняться
    /// ВНУТРИ STT-цикла (челлендж-ретрай) — дефолтные 60 с URLSession повисли
    /// бы на диктовке сверх документированного networkRequestTimeout (20 с).
    private static let refreshTimeout: TimeInterval = 8

    /// Значение токена в памяти.
    private struct Token {
        let value: String   // lowerHex значения cookie, БЕЗ "__test="
        let createdAt: Date
    }

    private let lock = NSLock()
    private var token: Token?
    /// Одновременно идёт НЕ более одного фонового пересчёта (дедупликация):
    /// параллельные ensureFresh/refreshBlocking дожидаются одного и того же Task.
    /// Результат Task — значение из performRefresh(): свежий токен или nil.
    private var refreshInFlight: Task<String?, Never>?

    private let origin: String   // схема+хост прокси, где живёт челлендж
    private let ua: String
    private let transport: HTTPTransport?
    /// Инъекцируемые часы — тесты «старят» токен без реальных задержек.
    private let now: () -> Date

    public init(
        origin: String,
        ua: String = ByetCookieProvider.chromeUA,
        transport: HTTPTransport? = nil,
        now: @escaping () -> Date = { Date() }
    ) {
        self.origin = origin
        self.ua = ua
        self.transport = transport
        self.now = now
    }

    /// Фабрика для `transport == "infinityfree"`: origin выводится из baseURL
    /// STT-эндпоинта (прокси). nil — URL непарсится, cookie-слой не поднять.
    public static func makeForInfinityFree(
        baseURL: String,
        transport: HTTPTransport? = nil
    ) -> ByetCookieProvider? {
        guard let origin = origin(from: baseURL) else { return nil }
        return ByetCookieProvider(origin: origin, transport: transport)
    }

    /// Схема+хост из URL STT-эндпоинта — origin, где Byet раздаёт челлендж.
    /// Например "https://kodmai.xo.je/go/…" → "https://kodmai.xo.je".
    public static func origin(from baseURL: String) -> String? {
        guard let url = URL(string: baseURL),
              let scheme = url.scheme,
              let host = url.host else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        if let port = url.port { components.port = port }
        return components.string
    }

    // MARK: - API для Transcriber

    /// Полностью готовое значение заголовка Cookie («__test=<hex>») или nil.
    /// Синхронно, без сети.
    public func currentCookie() -> String? {
        lock.lock(); defer { lock.unlock() }
        return token.map { "\(Self.cookieName)=\($0.value)" }
    }

    /// Неблокирующее поддержание токена:
    /// - токен МОЛОЖЕ 120 с и обновление не идёт → ничего не запускает,
    ///   возвращает текущий токен мгновенно, сетевых запросов нет;
    /// - токен протух/отсутствует ИЛИ обновление уже идёт → запускает фоновый
    ///   пересчёт (дедуплицированный) и возвращает ТЕКУЩИЙ токен сразу.
    public func ensureFresh() async -> String? {
        let header = currentCookie()
        let decision = refreshDecision()
        if decision.fresh && !decision.inFlight { return header }
        _ = startRefresh()
        return header
    }

    /// Блокирующий пересчёт «до результата»: дожидается завершения (своего или
    /// уже идущего) пересчёта и возвращает результат пересчёта: НОВЫЙ токен,
    /// либо nil, если пересчёт не удался. Старый токен при неудаче остаётся
    /// в памяти (currentCookie() его вернёт), но ретраить ИМ бессмысленно —
    /// челлендж уже показал, что сервер его отверг; челлендж-ретрай обязан
    /// уходить с nil-семантикой → Transcriber прерывает попытку, а не тратит
    /// POST на заведомо мёртвую куку.
    public func refreshBlocking() async -> String? {
        let task = startRefresh()
        guard let value = await task.value else { return nil }
        return "\(Self.cookieName)=\(value)"
    }

    // MARK: - Статика: разбор челленджа и AES-128-CBC

    /// Признак Byet-челленджа: страница содержит aes.js, toNumbers и
    /// document.cookie — то есть вместо контента сервер прислал JS-заглушку.
    public static func looksLikeChallenge(_ body: String) -> Bool {
        body.contains("aes.js") && body.contains("toNumbers") && body.contains("document.cookie")
    }

    public static func looksLikeChallenge(_ body: Data) -> Bool {
        guard let text = String(data: body, encoding: .utf8) else { return false }
        return looksLikeChallenge(text)
    }

    /// Аналог JS `toNumbers(d)`: hex-строка → массив байт.
    public static func toNumbers(_ hex: String) -> [UInt8] {
        var result: [UInt8] = []
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex) ?? hex.endIndex
            if let byte = UInt8(hex[index..<next], radix: 16) {
                result.append(byte)
            }
            index = next
        }
        return result
    }

    /// Аналог JS `toHex(arr)`: массив байт → lowerHex.
    public static func toHex(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// Константы a/b/c из тела челленджа. Разные страницы форматируются по-разному
    /// (пробелы вокруг «=» и скобок, переносы строк, UPPERCASE-HEX), поэтому
    /// каждая константа ищется отдельно — порядок a,b,c не важен:
    ///   `\ba\s*=\s*toNumbers\s*\(\s*"([0-9A-Fa-f]{32})"\s*\)`
    /// Все три найдены → набор, иначе nil (такая страница — не наш челлендж).
    public static func extractConstants(from page: String) -> (a: String, b: String, c: String)? {
        var found: [String: String] = [:]
        for name in ["a", "b", "c"] {
            let pattern = "\\b\(name)\\s*=\\s*toNumbers\\s*\\(\\s*\"([0-9A-Fa-f]{32})\"\\s*\\)"
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: page, range: NSRange(page.startIndex..., in: page)),
                  match.numberOfRanges == 2,
                  let hexRange = Range(match.range(at: 1), in: page) else { return nil }
            found[name] = String(page[hexRange])
        }
        guard let a = found["a"], let b = found["b"], let c = found["c"] else { return nil }
        return (a, b, c)
    }

    /// slowAES.decrypt(c, 2, a, b) байт-в-байт = стандартный AES-128-CBC:
    /// единственный 16-байтный блок из hex(c) расшифровать ключом hex(a),
    /// IV hex(b), БЕЗ снятия padding (kCCOptionPKCS7Padding не передаём).
    /// Результат — lowerHex расшифрованного блока → значение cookie.
    public static func decrypt(a: String, b: String, c: String) -> String? {
        let key = toNumbers(a)
        let iv = toNumbers(b)
        let dataIn = toNumbers(c)
        guard key.count == 16, iv.count == 16, dataIn.count == 16 else { return nil }
        var dataOut = [UInt8](repeating: 0, count: dataIn.count)
        let dataOutCount = dataOut.count
        var dataOutMoved = 0
        let status = dataIn.withUnsafeBytes { inPtr -> CCCryptorStatus in
            key.withUnsafeBytes { keyPtr in
                iv.withUnsafeBytes { ivPtr in
                    dataOut.withUnsafeMutableBytes { outPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0), // БЕЗ kCCOptionPKCS7Padding
                            keyPtr.baseAddress, kCCKeySizeAES128,
                            ivPtr.baseAddress,
                            inPtr.baseAddress, dataIn.count,
                            outPtr.baseAddress, dataOutCount,
                            &dataOutMoved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        return toHex(dataOut)
    }

    // MARK: - Внутреннее

    /// Свежесть токена и факт идущего пересчёта — под одним замком (синхронно).
    private func refreshDecision() -> (fresh: Bool, inFlight: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (isFreshLocked(), refreshInFlight != nil)
    }

    private func isFreshLocked() -> Bool {
        guard let token = token else { return false }
        return now().timeIntervalSince(token.createdAt) < Self.tokenTTL
    }

    /// Запускает пересчёт, если его ещё нет; возвращает (в т.ч. уже идущий) Task.
    /// Результат Task — значение из performRefresh(): новый токен или nil.
    private func startRefresh() -> Task<String?, Never> {
        lock.lock()
        if let existing = refreshInFlight {
            lock.unlock()
            return existing
        }
        let task = Task { [weak self] () -> String? in
            defer { self?.clearInFlight() }
            guard let self else { return nil }
            return await self.performRefresh()
        }
        refreshInFlight = task
        lock.unlock()
        return task
    }

    private func clearInFlight() {
        lock.lock(); defer { lock.unlock() }
        refreshInFlight = nil
    }

    /// Полный цикл вычисления и проверки токена:
    /// 1) GET origin (UA браузера) → страница-челлендж;
    /// 2) извлечь a/b/c, расшифровать AES-128-CBC → значение cookie;
    /// 3) probe: GET origin с новой кукой → сервер отвечает НЕ челленджем —
    ///    кука принята, кладём в память.
    /// Любой сбой → nil, старый токен (если был) сохраняется.
    private func performRefresh() async -> String? {
        guard let page = await fetchText(origin),
              let consts = Self.extractConstants(from: page),
              let value = Self.decrypt(a: consts.a, b: consts.b, c: consts.c) else {
            return nil
        }
        guard let probe = await fetchText(origin, cookie: value),
              !Self.looksLikeChallenge(probe) else {
            return nil
        }
        storeToken(value)
        return value
    }

    /// Кладёт принятый кукой токен в память (синхронно — ключ в безопасности).
    private func storeToken(_ value: String) {
        lock.lock(); defer { lock.unlock() }
        token = Token(value: value, createdAt: now())
    }

    /// GET origin (и опционально с cookie) → тело текстом; nil при любой ошибке.
    /// Таймаут refreshTimeout (8 с) — жёстко: вызовы идут и из STT-цикла.
    private func fetchText(_ urlString: String, cookie: String? = nil) async -> String? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = Self.refreshTimeout
        request.setValue(ua, forHTTPHeaderField: "User-Agent")
        if let cookie = cookie {
            request.setValue("\(Self.cookieName)=\(cookie)", forHTTPHeaderField: "Cookie")
        }
        let result: (status: Int, body: Data)
        do {
            if let transport = transport {
                result = try await transport.send(request: request)
            } else {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { return nil }
                result = (http.statusCode, data)
            }
        } catch {
            return nil
        }
        return String(data: result.body, encoding: .utf8)
    }
}