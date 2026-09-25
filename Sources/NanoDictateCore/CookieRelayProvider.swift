import CommonCrypto
import Foundation

// MARK: - CookieRelayProvider

//
// Unified STT provider transport (`transport` key), "cookie-relay" mode:
// proxy meets non-browser requests with JS challenge. Server returns HTML
// with script + constants a/b/c (hex 32 chars); browser computes cookie
// `__test = toHex(slowAES.decrypt(c, 2, a, b))` and redirects with it.
//
// Hard user requirements:
//   1. No node/JavaScript — slowAES.decrypt(c,2,a,b) reproduced byte-for-byte
//      on CommonCrypto (AES-128-CBC, WITHOUT padding removal), ~15 lines.
//   2. Cookie NOT in config — lives in memory: {value, createdAt}, TTL 120 s.
//   3. Refresh non-blocking: token younger 120 s — ensureFresh() returns it
//      instantly, zero network requests; stale/absent token refreshed in
//      BACKGROUND, caller gets current token at once. Blocking refresh in one
//      place only — STT request already got challenge (retry makes sense only
//      with fresh cookie).
//   4. One fixed browser UA (Chrome) — challenge and STT requests via proxy.

public final class CookieRelayProvider {
  /// Token TTL in memory (sec). Proxy issues cookie ≥ 120 s — below that
  /// fresh token never recalculated.
  public static let tokenTTL: TimeInterval = 120

  /// Sole agent UA: challenge + STT via cookie-relay proxy. Browser UA
  /// mandatory — curl/8.0 gets "Empty reply from server".
  public static let chromeUA =
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    + "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

  /// Cookie header name (without "=").
  private static let cookieName = "__test"

  /// Refresh timeout (challenge-GET, probe-GET), sec. Pages small, responses
  /// fast; refreshBlocking() may run INSIDE STT loop (challenge retry) —
  /// URLSession default 60 s would hang dictation past documented
  /// networkRequestTimeout (20 s).
  private static let refreshTimeout: TimeInterval = 8

  private struct Token {
    let value: String  // lowerHex cookie value, WITHOUT "__test="
    let createdAt: Date
  }

  private let lock = NSLock()
  private var token: Token?
  /// At most ONE background refresh in flight (dedup): parallel
  /// ensureFresh/refreshBlocking await the same Task. Task result —
  /// performRefresh() value: fresh token or nil.
  private var refreshInFlight: Task<String?, Never>?

  private let origin: String  // proxy scheme+host serving challenge
  private let userAgent: String
  private let transport: HTTPTransport?
  /// Injectable clock — tests age token without real delays.
  private let now: () -> Date

  public init(
    origin: String,
    userAgent: String = CookieRelayProvider.chromeUA,
    transport: HTTPTransport? = nil,
    now: @escaping () -> Date = { Date() }
  ) {
    self.origin = origin
    self.userAgent = userAgent
    self.transport = transport
    self.now = now
  }

  /// Factory for `transport == "cookie-relay"`: origin derived from STT
  /// endpoint baseURL (proxy). nil — URL unparsable, cookie layer impossible.
  public static func makeForCookieRelay(
    baseURL: String,
    transport: HTTPTransport? = nil
  ) -> CookieRelayProvider? {
    guard let origin = origin(from: baseURL) else { return nil }
    return CookieRelayProvider(origin: origin, transport: transport)
  }

  /// Scheme+host from STT endpoint URL — origin serving challenge.
  public static func origin(from baseURL: String) -> String? {
    guard
      let url = URL(string: baseURL),
      let scheme = url.scheme,
      let host = url.host
    else { return nil }
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    if let port = url.port {
      components.port = port
    }
    return components.string
  }

  // MARK: - API для Transcriber

  /// Full Cookie header value ("__test=<hex>") or nil. Sync, no network.
  public func currentCookie() -> String? {
    lock.lock()
    defer { lock.unlock() }
    return token.map { "\(Self.cookieName)=\($0.value)" }
  }

  /// Non-blocking token upkeep:
  /// - fresh (younger 120 s) and no refresh running → nothing launches,
  ///   current token returned instantly, zero network requests;
  /// - stale/absent OR refresh running → background recalc (deduped) starts,
  ///   CURRENT token returned immediately.
  public func ensureFresh() async -> String? {
    let header = currentCookie()
    let decision = refreshDecision()
    if decision.fresh, !decision.inFlight {
      return header
    }
    _ = startRefresh()
    return header
  }

  /// Blocking recalc "to result": awaits completion (own or in-flight) and
  /// returns NEW token, or nil on failure. Old token stays in memory
  /// (currentCookie() returns it), but retrying with it is pointless —
  /// challenge already showed server rejected it; challenge retry must use
  /// nil-semantics, so Transcriber aborts the attempt instead of wasting a
  /// POST on a dead cookie.
  public func refreshBlocking() async -> String? {
    let task = startRefresh()
    // Caller-cancellation aware (parallel failover cancels losing children):
    // return promptly instead of blocking the group on the shared refresh
    // (up to two 8 s GETs). The refresh task itself is NOT cancelled — it
    // is shared, other callers still await its result.
    if Task.isCancelled { return nil }
    guard let value = await waitAbandoningOnCancellation(task) else { return nil }
    return "\(Self.cookieName)=\(value)"
  }

  /// Awaits the shared refresh task, but abandons the wait (nil) the moment
  /// the CURRENT caller is cancelled. The shared refresh task is never
  /// cancelled here — other callers (parallel failover children in one
  /// withTaskGroup) still await its result.
  ///
  /// Why a continuation bridge instead of `await task.value`: in Swift 5.7 a
  /// task parked in `swift_task_future_wait` is resumed ONLY by the future's
  /// completion — the caller's cancellation does not wake it. A structural
  /// task-group race would stall too: the future-wait child is not woken by
  /// cancelAll() and the group scope exit waits for that child. So the wait
  /// goes through a checked continuation: the shared refresh resumes it with
  /// the value, the caller's cancellation handler resumes it with nil. The
  /// handler may fire before the continuation attaches (registrations race
  /// with the already-cancelled caller) — RefreshWaitBridge closes that
  /// ordering, and resuming a continuation needs no suspension, so a cancelled
  /// caller returns at once while the observer task falls out of scope.
  private func waitAbandoningOnCancellation(_ task: Task<String?, Never>) async -> String? {
    let bridge = RefreshWaitBridge()
    return await withTaskCancellationHandler(
      operation: {
        await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
          bridge.attach(continuation)
          // Unstructured observer: NOT a child of the caller's task group —
          // nothing waits for it at scope exit, and it is not cancelled with
          // the caller, so the shared refresh keeps serving other waiters.
          _ = Task { bridge.finish(await task.value) }
        }
      },
      onCancel: {
        bridge.abandon()
      }
    )
  }

  // MARK: - Статика: разбор челленджа и AES-128-CBC

  /// Cookie-challenge mark: page has aes.js, toNumbers, document.cookie —
  /// JS stub instead of content.
  public static func looksLikeChallenge(_ body: String) -> Bool {
    body.contains("aes.js") && body.contains("toNumbers") && body.contains("document.cookie")
  }

  public static func looksLikeChallenge(_ body: Data) -> Bool {
    guard let text = strictUTF8(body) else { return false }
    return looksLikeChallenge(text)
  }

  /// JS `toNumbers(d)` analog: hex string to byte array.
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

  /// JS `toHex(arr)` analog: byte array to lowerHex.
  public static func toHex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
  }

  /// Strict UTF-8 decoder: `String(decoding:as:)` replaces broken bytes;
  /// here nil-semantics kept explicitly — invalid sequence returns nil.
  private static func strictUTF8(_ data: Data) -> String? {
    let text = String(decoding: data, as: UTF8.self)
    guard text.utf8.elementsEqual(data) else { return nil }
    return text
  }

  /// Challenge constants extracted from page (32-char hex). Named struct
  /// over 3-element tuple (large_tuple rule).
  public struct ChallengeConstants {
    /// a: AES-128 key.
    public let keyHex: String
    /// b: initialization vector.
    public let ivHex: String
    /// c: ciphertext (single 16-byte block).
    public let cipherHex: String
  }

  /// Constants a/b/c from challenge body. Pages format differently (spaces
  /// around "=" and parens, line breaks, UPPERCASE-HEX) — each constant
  /// searched separately, order a,b,c irrelevant:
  ///   `\ba\s*=\s*toNumbers\s*\(\s*"([0-9A-Fa-f]{32})"\s*\)`
  /// All three found → set, else nil (page not our challenge).
  public static func extractConstants(from page: String) -> ChallengeConstants? {
    var found: [String: String] = [:]
    for name in ["a", "b", "c"] {
      let pattern = "\\b\(name)\\s*=\\s*toNumbers\\s*\\(\\s*\"([0-9A-Fa-f]{32})\"\\s*\\)"
      guard
        let regex = try? NSRegularExpression(pattern: pattern),
        let match = regex.firstMatch(in: page, range: NSRange(page.startIndex..., in: page)),
        match.numberOfRanges == 2,
        let hexRange = Range(match.range(at: 1), in: page)
      else { return nil }
      found[name] = String(page[hexRange])
    }
    guard
      let keyHex = found["a"],
      let ivHex = found["b"],
      let cipherHex = found["c"]
    else { return nil }
    return ChallengeConstants(keyHex: keyHex, ivHex: ivHex, cipherHex: cipherHex)
  }

  /// slowAES.decrypt(c, 2, a, b) byte-for-byte = standard AES-128-CBC:
  /// single 16-byte block from hex(c) decrypted with key hex(a), IV hex(b),
  /// WITHOUT padding removal (no kCCOptionPKCS7Padding). Result — lowerHex
  /// of decrypted block, the cookie value.
  public static func decrypt(a keyHex: String, b ivHex: String, c cipherHex: String) -> String? {
    let key = toNumbers(keyHex)
    let ivBytes = toNumbers(ivHex)
    let dataIn = toNumbers(cipherHex)
    guard key.count == 16, ivBytes.count == 16, dataIn.count == 16 else { return nil }
    var dataOut = [UInt8](repeating: 0, count: dataIn.count)
    let dataOutCount = dataOut.count
    var dataOutMoved = 0
    let status = dataIn.withUnsafeBytes { inPtr -> CCCryptorStatus in
      key.withUnsafeBytes { keyPtr in
        ivBytes.withUnsafeBytes { ivPtr in
          dataOut.withUnsafeMutableBytes { outPtr in
            CCCrypt(
              CCOperation(kCCDecrypt),
              CCAlgorithm(kCCAlgorithmAES),
              CCOptions(0),  // no kCCOptionPKCS7Padding
              keyPtr.baseAddress,
              kCCKeySizeAES128,
              ivPtr.baseAddress,
              inPtr.baseAddress,
              dataIn.count,
              outPtr.baseAddress,
              dataOutCount,
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

  /// Token freshness + refresh-in-flight under one lock (sync).
  private func refreshDecision() -> (fresh: Bool, inFlight: Bool) {
    lock.lock()
    defer { lock.unlock() }
    return (isFreshLocked(), refreshInFlight != nil)
  }

  private func isFreshLocked() -> Bool {
    guard let token else { return false }
    return now().timeIntervalSince(token.createdAt) < Self.tokenTTL
  }

  /// Starts recalc if absent; returns (possibly in-flight) Task. Task
  /// result — performRefresh() value: new token or nil.
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
    lock.lock()
    defer { lock.unlock() }
    refreshInFlight = nil
  }

  /// Full token compute+verify cycle:
  /// 1) GET origin (browser UA) — challenge page;
  /// 2) extract a/b/c, AES-128-CBC decrypt — cookie value;
  /// 3) probe: GET origin with new cookie — server replies NOT a challenge,
  ///    cookie accepted, stored.
  /// Any failure → nil, old token (if any) kept.
  private func performRefresh() async -> String? {
    guard
      let page = await fetchText(origin),
      let consts = Self.extractConstants(from: page.body),
      let value = Self.decrypt(a: consts.keyHex, b: consts.ivHex, c: consts.cipherHex)
    else {
      return nil
    }
    guard
      let probe = await fetchText(origin, cookie: value),
      (200..<300).contains(probe.status),
      !Self.looksLikeChallenge(probe.body)
    else {
      return nil
    }
    storeToken(value)
    return value
  }

  /// Stores cookie-accepted token in memory (sync — key safe).
  private func storeToken(_ value: String) {
    lock.lock()
    defer { lock.unlock() }
    token = Token(value: value, createdAt: now())
  }

  /// GET origin (optionally with cookie) — text body + HTTP status; nil on any
  /// error. Timeout refreshTimeout (8 s) hard: calls run from STT loop too.
  private func fetchText(_ urlString: String, cookie: String? = nil) async -> (status: Int, body: String)?
  {
    guard let url = URL(string: urlString) else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = Self.refreshTimeout
    request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    if let cookie {
      request.setValue("\(Self.cookieName)=\(cookie)", forHTTPHeaderField: "Cookie")
    }
    do {
      if let transport {
        let response = try await transport.send(request: request)
        guard let body = Self.strictUTF8(response.body) else { return nil }
        return (response.status, body)
      }
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let httpResponse = response as? HTTPURLResponse else { return nil }
      guard let body = Self.strictUTF8(data) else { return nil }
      return (httpResponse.statusCode, body)
    } catch {
      return nil
    }
  }
}

// MARK: - RefreshWaitBridge

/// Single-waiter channel between the shared refresh task and one
/// `refreshBlocking()` caller. Exactly-once continuation resume even when the
/// shared refresh completes at the same moment as the caller's cancellation:
/// attach/finish/abandon are closed under a lock (attach resumes nil itself
/// when an already-fired abandon set `decided`; finish/abandon capture the
/// attached continuation before clearing it). NSLock makes it safe to resume
/// from any thread — the runtime invokes cancellation handlers on the
/// cancelling thread.
private final class RefreshWaitBridge: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<String?, Never>?
  private var decided = false

  /// Caller's continuation attached; if an abandon already won the race,
  /// resumed with nil immediately.
  func attach(_ continuation: CheckedContinuation<String?, Never>) {
    lock.lock()
    if decided {
      lock.unlock()
      continuation.resume(returning: nil)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  /// Shared refresh completed — resume the waiter with its value (or nil on
  /// refresh failure).
  func finish(_ value: String?) {
    resume(returning: value)
  }

  /// Caller cancelled — abandon the wait.
  func abandon() {
    resume(returning: nil)
  }

  private func resume(returning value: String?) {
    lock.lock()
    if decided {
      lock.unlock()
      return
    }
    decided = true
    let continuation = self.continuation
    self.continuation = nil
    lock.unlock()
    continuation?.resume(returning: value)
  }
}
