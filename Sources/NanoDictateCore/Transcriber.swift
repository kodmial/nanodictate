import Foundation
import Network

// MARK: - TimedWord

/// Word with timestamps from STT response (verbose_json).
/// Relative time within the recognized audio, seconds.
public struct TimedWord: Equatable {
  public let word: String
  public let start: Double
  public let end: Double

  public init(word: String, start: Double, end: Double) {
    self.word = word
    self.start = start
    self.end = end
  }
}

// MARK: - TranscriptionResult

public struct TranscriptionResult {
  public let text: String
  public let rawData: Data  // raw API response (JSON as-is)
  /// Word timestamps from response; empty — provider returned none
  /// (not an error: segment stitching degrades to word diff).
  public let words: [TimedWord]

  public init(text: String, rawData: Data, words: [TimedWord] = []) {
    self.text = text
    self.rawData = rawData
    self.words = words
  }
}

// MARK: - TranscribeError

public enum TranscribeError: Error, Equatable {
  case network(String)
  case http(Int, String)  // HTTP code + body text (truncated to ~500 characters)
  case invalidResponse(String)  // not JSON or missing "text" field
}

// MARK: - Network availability (preflight)

/// Quick network check before an STT request via Network framework.
///
/// NWPathMonitor made for ONE async snapshot of the current state and
/// cancelled right away — no permanent listener needed. Checks GENERAL
/// connectivity, not a local interface: STT goes to an external API
/// (provider via Render forwarder or GigaAM). "Router up, internet down"
/// invisible here — hard network request timeout catches it
/// (`Transcriber.networkRequestTimeout`).
public enum NetworkReachability {
  /// Simplified path status for pure logic (from NWPath.status).
  public enum PathStatus {
    case satisfied
    case requiresConnection
    case unsatisfied
  }

  /// Pure "is internet reachable" decision — tested without a real network.
  /// - `unsatisfied` — no route at all → no internet.
  /// - `requiresConnection` — route exists, on demand (VPN/PPP) → try the
  ///   request, hard timeout backs us up.
  /// - `satisfied` — route exists; internet reachable only when the route
  ///   has a non-loopback interface (else it's a local loop only, external
  ///   API unreachable).
  public static func isReachable(status: PathStatus, possibleExternalRoute: Bool) -> Bool {
    switch status {
    case .unsatisfied:
      return false
    case .requiresConnection:
      return true
    case .satisfied:
      return possibleExternalRoute
    }
  }

  /// Async check of the current network state: one NWPathMonitor, first
  /// path update, immediate cancel.
  public static func isInternetReachable() async -> Bool {
    guard let snapshot = await currentPathSnapshot() else {
      // Monitor silent — don't block dictation: optimistically assume
      // network up, hard timeout backs us up.
      return true
    }
    return isReachable(
      status: snapshot.status, possibleExternalRoute: snapshot.possibleExternalRoute)
  }

  // MARK: - NWPath

  private struct PathSnapshot {
    let status: PathStatus
    let possibleExternalRoute: Bool
  }

  /// Waits for the first (current) path from NWPathMonitor; max 2 seconds —
  /// then returns nil so dictation never hangs on the preflight itself.
  private static func currentPathSnapshot() async -> PathSnapshot? {
    let monitor = NWPathMonitor()
    return await withCheckedContinuation { continuation in
      let lock = NSLock()
      var finished = false
      let resume: (PathSnapshot?) -> Void = { value in
        lock.lock()
        guard !finished else {
          lock.unlock()
          return
        }
        finished = true
        lock.unlock()
        // Clear handler BEFORE cancel: else the monitor holds the closure
        // (and the continuation/lock) and never frees. Both paths
        // (first path and 2-second fallback) arrive here only, and
        // finished guarantees exactly one call — nil+cancel once.
        monitor.pathUpdateHandler = nil
        monitor.cancel()
        continuation.resume(returning: value)
      }
      monitor.pathUpdateHandler = { path in
        resume(snapshot(path: path))
      }
      monitor.start(queue: DispatchQueue(label: "nanodictate.network-monitor", qos: .utility))
      // Fallback: first path must arrive fast; if NWPathMonitor stays
      // silent — don't hold dictation, return nil (optimistic, timeout
      // backs us up).
      DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.0) {
        resume(nil)
      }
    }
  }

  private static func snapshot(path: NWPath) -> PathSnapshot {
    let status: PathStatus
    switch path.status {
    case .satisfied:
      status = .satisfied
    case .requiresConnection:
      status = .requiresConnection
    default:
      status = .unsatisfied
    }
    let interfaces = path.availableInterfaces
    // Empty interface list — "unknown": optimistically assume the external
    // route possible (let the request try, timeout decides).
    let possibleExternalRoute = interfaces.isEmpty || interfaces.contains { $0.type != .loopback }
    return PathSnapshot(status: status, possibleExternalRoute: possibleExternalRoute)
  }
}

// MARK: - HTTPTransport

public protocol HTTPTransport: AnyObject {
  /// Send a request; return the response (status + body + headers).
  /// The default implementation is URLSession.
  // swiftlint:disable:next large_tuple
  func send(request: URLRequest) async throws -> (
    status: Int, body: Data, headers: [String: String]
  )
}

// MARK: - Internal request/response types

/// HTTP response of an STT request (status + body + headers) — internal
/// transcriber type; the public contract (HTTPTransport.send) stays a tuple.
private struct STTHTTPResponse {
  let status: Int
  let body: Data
  let headers: [String: String]
}

/// Context of an adapter STT request: bundles the send params previously
/// passed one by one (sendWithRetry/debugDump).
private struct SendContext {
  var request: URLRequest
  let transcriptPath: [String]?
  let wav: Data
  let filename: String
  /// Effective multipart file-part filename from the plan (after capability
  /// gating and extension coercion). Debug dump uses this, not `filename`.
  let filePartFilename: String
  /// Effective multipart file-part MIME type from the plan (e.g.
  /// `audio/wav` / `audio/flac`). Never the enclosing multipart content
  /// type and never the requested format before gating.
  let filePartContentType: String
  /// Byte count of the actual uploaded audio payload (after FLAC encoding
  /// when selected). May differ from `wav.count` (original WAV bytes).
  let filePartByteCount: Int
  let prompt: String?
  let skipPreflight: Bool
}

// MARK: - Transcriber

public final class Transcriber {
  // MARK: - Constants

  /// Hard network timeout of the STT HTTP request (s), ~15–20 s. Separate
  /// from config `timeout_seconds` (Transcriber.timeout): config may only
  /// LIMIT it with a smaller value, never raise — else dictation hangs up
  /// to 120 s again. Terminal (no retry), so the overlay "processing" phase
  /// lives no longer than the timeout + a small margin.
  public static let networkRequestTimeout: TimeInterval = 20

  /// Total STT attempts (initial + up to 3 retries with backoff). Network
  /// errors almost always fail fast (connection refused/reset), so 4 quick
  /// attempts + backoff ≈ 5 s — within the overlay watchdog budget;
  /// timeout (20 s) is terminal and spawns no retries.
  public static let maxAttempts = 4

  /// Canonical "no internet" message — overlay `OverlayErrorText` mapping
  /// and tests rely on it. Computed property: resolved on each access so
  /// the language toggle in the menu applies live.
  public static var noInternetMessage: String {
    L10n.tr("error.noInternet")
  }

  /// Canonical "STT timeout" message — overlay `OverlayErrorText` mapping
  /// and tests rely on it. Computed property: resolved on each access so
  /// the language toggle in the menu applies live.
  public static var sttTimeoutMessage: String {
    L10n.tr("error.sttTimeout")
  }

  private let baseURL: String
  private let model: String
  private let apiKey: String
  private let proxyKey: String
  /// Header name for the proxy key (default `X-Proxy-Key`); changeable from
  /// config (`proxy_key_header`) so the proxy layer never conflicts.
  private let proxyKeyHeader: String
  private let language: String
  /// Timeout from config (`timeout_seconds`); the actual request timeout —
  /// `min(timeout, networkRequestTimeout)`.
  private let timeout: TimeInterval
  private let logLevel: String
  private let transport: HTTPTransport?
  /// Network preflight before send: true — network up. Default: real check
  /// via NetworkReachability; tests inject a mock.
  private let networkChecker: () async -> Bool
  /// Cookie relay layer (transport == "cookie-relay"): computed in-memory
  /// `__test` cookie + unified Chrome UA. nil — no cookie logic, behavior
  /// as before.
  private let cookieRelayProvider: CookieRelayProvider?
  /// HTTP proxy (forwarding): URL-rewrite to `<httpProxy>/<originURL>` —
  /// honored only for an `https://`-prefixed proxy (plain-HTTP would leak
  /// audio and credentials), otherwise ignored with a warning. Empty — no
  /// HTTP proxy, behavior as before.
  private let httpProxy: String
  private let proxyUser: String
  private let proxyPassword: String
  /// Request adapter id ("openai", "groq", ..., from the `[providers.<id>]`
  /// section). Empty — legacy single-section config: falls back to the
  /// OpenAI-compatible adapter when a baseURL is set, else an error; unknown —
  /// OpenAI-compatible request with own baseURL/model.
  private let adapterID: String?
  /// Factory for the realtime WebSocket transport (one session per dictation).
  /// nil — production `URLSessionWebSocketTransport`; tests inject a mock.
  private let realtimeTransportFactory: (() -> any RealtimeTransport)?
  /// Contextual biasing (reusable vocabulary + extra language hints from
  /// config `vocabulary` / `extra_languages`). Gated per model profile in
  /// ProviderRequestBuilder.plan; empty = previous behavior.
  private let contextualBias: STTContextualBias

  /// Retry candidate (see `shouldRetry`): HTTP 429/5xx and transport
  /// (non-timeout) network errors. Everything else terminal.
  static func isRetryable(_ error: TranscribeError) -> Bool {
    switch error {
    case .http(let code, _):
      return code == 429 || (500...599).contains(code)
    case .network:
      return true
    case .invalidResponse:
      return false
    }
  }

  /// Attempt #`retryIndex` (1st, 2nd, ...) sleeps before the retry:
  /// exponential base interval `0.5 * 2^n` s + jitter `jitter` s (random
  /// 0…0.25 by default — spreads coincident clients).
  static func backoffDelay(
    beforeRetry retryIndex: Int, jitter: Double = Double.random(in: 0...0.25)
  ) -> TimeInterval {
    0.5 * pow(2.0, Double(retryIndex)) + jitter
  }

  /// `Retry-After` from response headers (seconds), when set and parseable.
  /// Header searched case-insensitively; RFC 7231 allows both seconds and
  /// HTTP-date (delay = date − now, non-negativity floor).
  /// Bad value → nil (default backoff then).
  static func retryAfterSeconds(from headers: [String: String]) -> TimeInterval? {
    guard
      let raw = headers.first(where: {
        $0.key.caseInsensitiveCompare("retry-after") == .orderedSame
      })?.value
    else {
      return nil
    }
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    if let seconds = Double(trimmed), seconds.isFinite, seconds >= 0 {
      return seconds
    }
    // Retry-After as HTTP-date (RFC 7231 §7.1.1.1).
    guard let date = httpDate(from: trimmed) else { return nil }
    return max(0, date.timeIntervalSince(Date()))
  }

  /// HTTP-date parsing (RFC 7231 §7.1.1.1): IMF-fixdate
  /// ("EEE, dd MMM yyyy HH:mm:ss GMT"), obsolete RFC 850
  /// ("EEEE, dd-MMM-yy HH:mm:ss GMT") and asctime ("EEE MMM d HH:mm:ss yyyy").
  /// Unrecognized — nil.
  static func httpDate(from raw: String) -> Date? {
    let value = raw.trimmingCharacters(in: .whitespaces)
    let formats = [
      // swiftlint:disable:next trailing_comma
      "EEE, dd MMM yyyy HH:mm:ss zzz", "EEEE, dd-MMM-yy HH:mm:ss zzz", "EEE MMM d HH:mm:ss yyyy",
    ]
    for format in formats {
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.timeZone = TimeZone(secondsFromGMT: 0)
      formatter.dateFormat = format
      if let date = formatter.date(from: value) {
        return date
      }
    }
    return nil
  }

  private let retrySleep: (TimeInterval) async -> Void

  public init(
    baseURL: String,
    model: String,
    apiKey: String,
    proxyKey: String = "",
    proxyKeyHeader: String = "X-Proxy-Key",
    language: String = "",
    timeout: TimeInterval = 120,
    logLevel: String = "info",
    transport: HTTPTransport? = nil,
    networkChecker: (() async -> Bool)? = nil,
    cookieRelayProvider: CookieRelayProvider? = nil,
    httpProxy: String = "",
    proxyUser: String = "",
    proxyPassword: String = "",
    adapterID: String? = nil,
    contextualBias: STTContextualBias = .none,
    retrySleep: ((TimeInterval) async -> Void)? = nil,
    realtimeTransportFactory: (() -> any RealtimeTransport)? = nil
  ) {
    // Empty config baseURL/model resolve to adapter defaults
    // (ProviderRequestBuilder.resolve*); re-resolve of non-empty — no-op.
    self.baseURL = ProviderRequestBuilder.resolveBaseURL(baseURL, for: adapterID ?? "")
    self.model = ProviderRequestBuilder.resolveModel(model, for: adapterID ?? "")
    self.apiKey = apiKey
    self.proxyKey = proxyKey
    self.proxyKeyHeader = proxyKeyHeader
    self.language = language
    self.timeout = timeout
    self.logLevel = logLevel
    self.transport = transport
    self.networkChecker = networkChecker ?? { await NetworkReachability.isInternetReachable() }
    self.cookieRelayProvider = cookieRelayProvider
    self.httpProxy = httpProxy
    self.proxyUser = proxyUser
    self.proxyPassword = proxyPassword
    self.adapterID = adapterID
    self.contextualBias = contextualBias
    self.realtimeTransportFactory = realtimeTransportFactory
    // Injected sleep between retries: tests run backoff without real
    // pauses. Default — real Task.sleep (seconds > 0).
    self.retrySleep =
      retrySleep ?? { seconds in
        guard seconds > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      }
  }

  /// Transcribe WAV audio via a multipart/form-data POST to the transcription endpoint.
  /// On retryable failures (network, HTTP 429/5xx) retries with exponential
  /// backoff and jitter, up to `maxAttempts` total. Timeouts, cancellation
  /// and invalid responses are terminal.
  /// - Parameter wav: WAV (RIFF PCM16) bytes. The upload container is chosen
  ///   by `audioFormat` through the model profile capabilities, and the bytes
  ///   are encoded to match: `.flac` FLAC-encodes the decoded PCM (lossless),
  ///   falling back to WAV when the profile does not accept FLAC or encoding
  ///   fails. Never pass pre-encoded FLAC bytes here; the selected format is
  ///   always applied to these WAV bytes before each provider request.
  /// - Parameter prompt: optional context for Whisper-compatible APIs
  ///   (`prompt` form-data field): text of already-recognized segments in
  ///   stepwise dictation. Default nil — old single-request path unchanged.
  /// - Parameter needsWordTimestamps: request `verbose_json` + word
  ///   granularities where the model profile supports them (chunked/live
  ///   segment overlap stitching). Default false: normal push-to-talk sends
  ///   one complete utterance per request without timestamps.
  /// - Parameter audioFormat: requested upload container. Gated by the model
  ///   profile (`supportedUploadFormats`): unsupported requests fall back to
  ///   the profile preferred format. Default `.wav`: byte-identical behavior.
  public func transcribe(
    wav: Data, filename: String = "audio.wav", prompt: String? = nil,
    needsWordTimestamps: Bool = false,
    audioFormat: STTUploadFormat = .wav
  )
    async throws -> TranscriptionResult
  {  // swiftlint:disable:this opening_brace
    if logLevel.lowercased() == "debug" {
      // URL/model/size — no api_key/proxy_key or headers.
      let details = String(
        format: "STT send: url=%@ model=%@ language=%@ wavBytes=%d",
        baseURL,
        model,
        language.isEmpty ? "-" : language,
        wav.count
      )
      Logger.log(details, level: "debug")
    }

    // Adapter path: ProviderRequestBuilder builds the request spec
    // (known provider — own format, unknown — OpenAI-compatible).
    // Legacy single-section config has no provider section (adapterID
    // nil/empty): fall back to the OpenAI-compatible adapter when a base URL
    // is set, so such configs keep transcribing.
    guard let adapterID, !adapterID.isEmpty else {
      if !baseURL.isEmpty {
        Logger.log(
          "STT: no adapterID — using openAICompatible with configured baseURL", level: "info")
        return try await transcribeViaAdapter(
          adapterID: STTAdapterID.openAICompatible.rawValue,
          wav: wav, filename: filename, prompt: prompt,
          needsWordTimestamps: needsWordTimestamps, audioFormat: audioFormat)
      }
      Logger.log("STT error: empty adapterID — transcribe требует провайдер", level: "error")
      throw TranscribeError.network("No STT provider configured")
    }
    // Stateful realtime profiles (today: `gpt-live-transcribe` family) never
    // go through the batch multipart path: one WebSocket session per
    // dictation streams raw PCM16 and returns the final transcript.
    // The batch plan for these profiles stays an invalid spec (nil URL);
    // realtime failures surface here and never fall back to batch uploads.
    if ProviderRequestBuilder.isRealtime(adapterID: adapterID, model: model) {
      return try await transcribeViaRealtime(wav: wav, prompt: prompt)
    }
    return try await transcribeViaAdapter(
      adapterID: adapterID, wav: wav, filename: filename, prompt: prompt,
      needsWordTimestamps: needsWordTimestamps, audioFormat: audioFormat)
  }

  // MARK: - Adapter path

  private func transcribeViaAdapter(
    adapterID: String, wav: Data, filename: String, prompt: String?,
    needsWordTimestamps: Bool = false,
    audioFormat: STTUploadFormat = .wav
  )
    async throws -> TranscriptionResult
  {  // swiftlint:disable:this opening_brace
    // Preflight BEFORE the request: no network — don't waste a request on
    // a surely dead STT.
    if await !networkChecker() {
      Logger.log("STT not sent: no internet (preflight)", level: "error")
      throw TranscribeError.network(Self.noInternetMessage)
    }

    // Encode the selected container before planning: the request metadata
    // must never describe bytes it does not carry (no WAV bytes labelled
    // as FLAC). Stored WAV is retained for recording/debug; each provider
    // request encodes from the recovered PCM for its own selected format,
    // so retries and failovers re-encode per target instead of relabelling.
    let prepared = Self.prepareUpload(
      wav: wav, filename: filename, audioFormat: audioFormat,
      adapterID: adapterID, model: model)
    let spec = ProviderRequestBuilder.plan(
      adapterID: adapterID,
      baseURL: baseURL,
      model: model,
      apiKey: apiKey,
      language: language,
      wav: prepared.data,
      filename: prepared.filename,
      prompt: prompt,
      needsWordTimestamps: needsWordTimestamps,
      audioFormat: prepared.effectiveFormat,
      bias: contextualBias
    )
    guard let url = spec.url else {
      Logger.log("STT error: invalid base URL", level: "error")
      throw TranscribeError.network("Invalid base URL")
    }

    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.httpBody = spec.bodyData
    request.setValue(spec.contentType, forHTTPHeaderField: "Content-Type")
    for (name, value) in spec.headers {
      // An empty key must not produce "Bearer " with no token (same rule as BatchRequestBuilder).
      if name == "Authorization", apiKey.isEmpty {
        continue
      }
      request.setValue(value, forHTTPHeaderField: name)
    }
    if !proxyKey.isEmpty {
      request.setValue(proxyKey, forHTTPHeaderField: proxyKeyHeader)
    }
    await applyCookieRelayHeaders(to: &request)
    request.timeoutInterval = min(timeout, Self.networkRequestTimeout)

    let context = SendContext(
      request: request,
      transcriptPath: spec.transcriptPath,
      wav: wav,
      filename: filename,
      filePartFilename: spec.filePartFilename,
      filePartContentType: spec.filePartContentType,
      filePartByteCount: prepared.data.count,
      prompt: prompt,
      skipPreflight: true
    )
    return try await sendWithRetry(context: context)
  }

  /// Encode WAV bytes to the capability-gated upload container.
  ///
  /// - `wav` is always WAV (RIFF PCM16) bytes; the returned `data` carries
  ///   the `effectiveFormat` container (FLAC bytes when FLAC is requested,
  ///   supported and encodable, else the original WAV bytes).
  /// - The capability gate mirrors `ProviderRequestBuilder.plan`: a format
  ///   outside `supportedUploadFormats` falls back to the profile preferred
  ///   format, so the plan gate stays a no-op and metadata always matches
  ///   bytes.
  /// - FLAC is lossless: WAV is decoded to PCM (`WAVDecoder`) and re-encoded
  ///   (`FLACEncoder`); any decode/encode failure falls back to WAV so the
  ///   request path stays total and never mislabels bytes.
  /// - Already-FLAC input (legacy callers passing encoder output directly) is
  ///   passed through when FLAC is the effective format, so existing
  ///   benchmark usage keeps working while new callers pass WAV.
  static func prepareUpload(
    wav: Data, filename: String, audioFormat: STTUploadFormat,
    adapterID: String, model: String
  ) -> (data: Data, filename: String, effectiveFormat: STTUploadFormat) {
    let profile = ProviderRequestBuilder.profile(adapterID: adapterID, model: model)
    let gated: STTUploadFormat =
      profile.audio.supportedUploadFormats.contains(audioFormat)
      ? audioFormat : profile.audio.uploadFormat
    guard gated == .flac else {
      return (
        data: wav,
        filename: AudioTransportEncoder.coercedFilename(filename, for: gated),
        effectiveFormat: gated
      )
    }
    guard FLACEncoder.canEncode(profile: profile.audio) else {
      return (
        data: wav,
        filename: AudioTransportEncoder.coercedFilename(filename, for: .wav),
        effectiveFormat: .wav
      )
    }
    if isFLACMagic(wav) {
      return (
        data: wav,
        filename: AudioTransportEncoder.coercedFilename(filename, for: .flac),
        effectiveFormat: .flac
      )
    }
    guard let pcm = WAVDecoder.decodePCM16(wav), pcm.channels == 1,
      let flac = FLACEncoder.encode(
        samples: pcm.samples, sampleRate: pcm.sampleRate, channels: pcm.channels)
    else {
      return (
        data: wav,
        filename: AudioTransportEncoder.coercedFilename(filename, for: .wav),
        effectiveFormat: .wav
      )
    }
    return (
      data: flac,
      filename: AudioTransportEncoder.coercedFilename(filename, for: .flac),
      effectiveFormat: .flac
    )
  }

  private static func isFLACMagic(_ data: Data) -> Bool {
    data.count >= 4 && data[0] == 0x66 && data[1] == 0x4C && data[2] == 0x61
      && data[3] == 0x43
  }

  // MARK: - Send

  /// Single send point for all paths (adapter, cloudflare).
  ///
  /// HTTP proxy (`http_proxy` in config) — honored ONLY when it has an
  /// https:// scheme: the request URL is rewritten "URL-as-path" — the
  /// original URL fully becomes the PATH of the proxying URL:
  ///   https://<httpProxy>/<full-original-URL>
  /// E.g. for http_proxy "https://127.0.0.1:8080" and request
  /// https://api.openai.com/v1/audio/transcriptions:
  ///   https://127.0.0.1:8080/https://api.openai.com/v1/audio/transcriptions
  /// Scheme-less or http:// proxies are ignored (a plain-HTTP proxy would
  /// leak the audio and the STT credentials in clear text — CWE-319) and
  /// the request goes direct, with a warning. When proxy_user/proxy_password
  /// are set, adds the header
  /// `Proxy-Authorization: Basic base64("user:pass")`.
  private func send(request: URLRequest) async throws -> STTHTTPResponse {
    var request = request
    if !httpProxy.isEmpty, !httpProxy.hasPrefix("https://") {
      Logger.log(
        "http proxy ignored: only an https:// proxy is used (request goes direct)", level: "warn")
    } else if !httpProxy.isEmpty, let original = request.url?.absoluteString {
      var proxyBase = httpProxy
      while proxyBase.hasSuffix("/") {
        proxyBase.removeLast()
      }
      guard let proxiedURL = URL(string: "\(proxyBase)/\(original)") else {
        throw URLError(.badURL)
      }
      request.url = proxiedURL
      if !proxyUser.isEmpty {
        let credentials = "\(proxyUser):\(proxyPassword)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        request.setValue("Basic \(encoded)", forHTTPHeaderField: "Proxy-Authorization")
      }
    }
    if let transport {
      let proxied = try await transport.send(request: request)
      return STTHTTPResponse(status: proxied.status, body: proxied.body, headers: proxied.headers)
    }
    let (data, response) = try await URLSession.shared.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw URLError(.badServerResponse)
    }
    // Response headers — for Retry-After (HTTP 429). HTTPURLResponse keeps
    // them with any key casing; our lookup is case-insensitive.
    var headers: [String: String] = [:]
    for (name, value) in httpResponse.allHeaderFields {
      if let stringValue = value as? String {
        headers[String(describing: name)] = stringValue
      }
    }
    return STTHTTPResponse(status: httpResponse.statusCode, body: data, headers: headers)
  }

  // MARK: - Response parsing

  /// Parse an HTTP response into a transcription result.
  /// - `transcriptPath == nil` — OpenAI-compatible flat `{"text": "…"}`;
  /// - else text extracted via the adapter JSON path (cloudflare).
  /// Word timestamps (if the provider returned them) go to `result.words`;
  /// broken/empty array — not an error (empty).
  /// Errors and their strings — exactly as in the adapter path (see tests).
  private static func parseResponse(_ response: STTHTTPResponse, transcriptPath: [String]? = nil)
    throws -> TranscriptionResult
  {  // swiftlint:disable:this opening_brace
    let status = response.status
    let body = response.body
    guard (200...299).contains(status) else {
      let text = String(decoding: body, as: UTF8.self)
      guard !text.isEmpty else {
        throw TranscribeError.http(status, "")
      }
      throw TranscribeError.http(status, String(text.prefix(500)))
    }
    let text = try ProviderRequestBuilder.extractText(from: body, path: transcriptPath)
    let words = ProviderRequestBuilder.extractWords(from: body, path: transcriptPath)
    return TranscriptionResult(text: text, rawData: body, words: words)
  }
}

extension Transcriber {
  // MARK: - Realtime path

  /// Transcribe WAV audio through one stateful realtime session.
  /// Decodes the WAV to Int16 samples (mono-mixed when needed), then runs
  /// connect → append → commit → waitForFinal → close. Fail-closed: any
  /// realtime failure throws and never degrades into batch uploads.
  /// Realtime bypasses custom routing: the session always dials the fixed
  /// `wss://api.openai.com/v1/realtime` endpoint with the provider `apiKey`
  /// as Bearer credential. Configured `baseURL`, `httpProxy`, `proxyKey`,
  /// and cookie-relay settings do not apply; a conflicting configuration
  /// logs a warning so credentials and audio are not silently sent outside
  /// the intended gateway.
  private func transcribeViaRealtime(wav: Data, prompt: String?) async throws -> TranscriptionResult {
    if await !networkChecker() {
      Logger.log("STT not sent: no internet (preflight)", level: "error")
      throw TranscribeError.network(Self.noInternetMessage)
    }
    Self.warnIfRealtimeBypassesRouting(
      baseURL: baseURL,
      adapterID: adapterID,
      httpProxy: httpProxy,
      proxyKey: proxyKey,
      hasCookieRelay: cookieRelayProvider != nil)
    guard let info = WAVDecoder.decodePCM16(wav) else {
      throw TranscribeError.invalidResponse("Invalid WAV for realtime transcription")
    }
    let mono = Self.monoSamples(from: info)
    guard !mono.isEmpty else {
      throw TranscribeError.invalidResponse("Invalid WAV for realtime transcription")
    }
    let transport: any RealtimeTransport
    if let factory = realtimeTransportFactory {
      transport = factory()
    } else {
      guard let url = RealtimeEndpoint.transcriptionURL() else {
        throw TranscribeError.network("Invalid base URL")
      }
      transport = URLSessionWebSocketTransport(url: url, apiKey: apiKey)
    }
    let config = RealtimeSessionConfig(
      model: model,
      language: language,
      prompt: prompt,
      keywords: STTContextualBiasing.normalizeVocabulary(contextualBias.vocabulary),
      extraLanguages: STTContextualBiasing.normalizeExtraLanguages(contextualBias.extraLanguages),
      sourceSampleRate: info.sampleRate)
    let session = RealtimeTranscriptionSession(transport: transport, config: config)
    // Esc/watchdog cancellation must close the WebSocket immediately instead
    // of waiting for a stalled send to return: the handler cancels the
    // session (which closes the transport and unblocks suspended sends)
    // before the awaited operation observes cancellation.
    do {
      return try await withTaskCancellationHandler {
        try await session.connect()
        try await session.appendAudio(mono, sourceSampleRate: info.sampleRate)
        try await session.commit()
        let text = try await session.waitForFinal()
        await session.close()
        return TranscriptionResult(text: text, rawData: Data(text.utf8))
      } onCancel: {
        Task { await session.cancel() }
      }
    } catch is CancellationError {
      await session.cancel()
      throw TranscribeError.network("Request cancelled")
    } catch let error as RealtimeTranscriptionError {
      await session.close()
      if case .cancelled = error {
        throw TranscribeError.network("Request cancelled")
      }
      throw TranscribeError.network(Self.describeRealtime(error))
    } catch {
      await session.close()
      if error is TranscribeError {
        throw error
      }
      throw TranscribeError.network(error.localizedDescription)
    }
  }

  /// Mono mix of decoded WAV samples (channel-interleaved when multichannel).
  static func monoSamples(from info: WAVInfo) -> [Int16] {
    if info.channels <= 1 {
      return info.samples
    }
    let channels = max(1, info.channels)
    let frames = info.samples.count / channels
    var mono: [Int16] = []
    mono.reserveCapacity(frames)
    for frame in 0..<frames {
      var sum = 0
      for channel in 0..<channels {
        sum += Int(info.samples[frame * channels + channel])
      }
      mono.append(Int16(clamping: sum / channels))
    }
    return mono
  }

  /// Human-readable realtime failure for logs/errors (fail-closed surface).
  static func describeRealtime(_ error: RealtimeTranscriptionError) -> String {
    switch error {
    case .notConnected:
      return "realtime session not connected"
    case .alreadyConnected:
      return "realtime session already connected"
    case .invalidState(let message):
      return message.isEmpty ? "realtime session invalid state" : message
    case .transport(let message):
      return message.isEmpty ? "realtime transport error" : message
    case .protocolError(let message):
      return message.isEmpty ? "realtime protocol error" : message
    case .sessionFailed(let message):
      return message.isEmpty ? "realtime session failed" : message
    case .timeout(let message):
      return message.isEmpty ? "realtime session timeout" : message
    case .cancelled:
      return "Request cancelled"
    }
  }

  /// Whether realtime bypasses configured routing (pure, unit-tested).
  /// True when a custom `baseURL` (differs from the adapter default),
  /// `httpProxy`, `proxyKey`, or cookie-relay layer is configured: the fixed
  /// `wss://api.openai.com/v1/realtime` transport ignores all of them.
  static func realtimeBypassesRouting(
    baseURL: String, adapterID: String?, httpProxy: String, proxyKey: String,
    hasCookieRelay: Bool
  ) -> Bool {
    if !httpProxy.isEmpty || !proxyKey.isEmpty || hasCookieRelay {
      return true
    }
    guard !baseURL.isEmpty else { return false }
    let adapterDefault = STTAdapterID.from(adapterID ?? "").defaultBaseURL
    return baseURL != adapterDefault
  }

  /// Warn when realtime bypasses custom routing so credentials and audio are
  /// not silently sent directly to the fixed endpoint.
  private static func warnIfRealtimeBypassesRouting(
    baseURL: String, adapterID: String?, httpProxy: String, proxyKey: String,
    hasCookieRelay: Bool
  ) {
    guard
      realtimeBypassesRouting(
        baseURL: baseURL, adapterID: adapterID, httpProxy: httpProxy, proxyKey: proxyKey,
        hasCookieRelay: hasCookieRelay)
    else { return }
    Logger.log(
      "realtime transcription bypasses custom routing "
        + "(baseURL/httpProxy/proxyKey/cookie-relay); audio and API key go directly to "
        + "wss://api.openai.com/v1/realtime",
      level: "warn")
  }
}

extension Transcriber {
  // MARK: - Debug dump (log_level == "debug")

  /// With `log_level == "debug"`, saves the WAV to `recordingsDirectory` and
  /// returns the file info (path + size) for the dump; else `nil`.
  /// Empty data not saved. Write errors never thrown outward.
  private func saveRecordingIfDebug(wav: Data) -> DebugDump.RecordingInfo? {
    guard logLevel.lowercased() == "debug", !wav.isEmpty else { return nil }
    let path = DebugDump.recordingPath(for: Date())
    DebugDump.saveRecording(data: wav, to: path)
    return DebugDump.RecordingInfo(path: path, byteCount: wav.count)
  }

  /// With `log_level == "debug"`, appends to `~/Library/Logs/NanoDictate/
  /// transcriber-debug.log` the exact outgoing request (method, URL, masked
  /// headers, form fields, file-part metadata), the saved recording's path
  /// and size — and the response (HTTP status + full body). When `response`
  /// is nil (all attempts died at the transport level before HTTP), the
  /// response section gets `(no response — transport error)`. Changes no
  /// behavior; throws no errors.
  private func debugDump(
    context: SendContext, recording: DebugDump.RecordingInfo?, response: STTHTTPResponse?
  ) {
    guard logLevel.lowercased() == "debug" else { return }

    var headers: [(name: String, value: String)] = []
    for (name, value) in context.request.allHTTPHeaderFields ?? [:] {
      headers.append((name: name, value: value))
    }

    var fields: [(name: String, value: String)] = [(name: "model", value: model)]
    if !language.isEmpty {
      // Multi-hint profiles (gpt-transcribe) send the hint as languages[],
      // never as singular language — the dump mirrors the real request.
      let hintName =
        ProviderRequestBuilder.profile(adapterID: adapterID ?? "", model: model).capabilities
        .languageHint == .multi ? "languages[]" : "language"
      fields.append((name: hintName, value: language))
    }
    if let prompt = context.prompt, !prompt.isEmpty {
      fields.append(
        (name: "prompt", value: String(prompt.prefix(80)) + (prompt.count > 80 ? "…" : "")))
    }
    // Contextual bias: counts only, never the terms themselves (config
    // privacy: vocabulary may contain product names; debug log must not
    // become a vocabulary dump).
    let normalizedVocabulary = STTContextualBiasing.normalizeVocabulary(contextualBias.vocabulary)
    if !normalizedVocabulary.isEmpty {
      fields.append((name: "vocabulary_terms", value: "\(normalizedVocabulary.count)"))
    }
    let normalizedExtras = STTContextualBiasing.normalizeExtraLanguages(contextualBias.extraLanguages)
    if !normalizedExtras.isEmpty {
      fields.append((name: "extra_languages", value: normalizedExtras.joined(separator: ",")))
    }

    let filePart = DebugDump.FilePart(
      fieldName: "file",
      filename: context.filePartFilename,
      contentType: context.filePartContentType,
      byteCount: context.filePartByteCount
    )

    let entry = DebugDump.summarize(
      method: context.request.httpMethod ?? "POST",
      url: context.request.url?.absoluteString ?? baseURL,
      headers: headers,
      fields: fields,
      filePart: filePart,
      recording: recording,
      status: response?.status,
      responseBody: response?.body
    )
    DebugDump.append(entry: entry)
  }
}

extension Transcriber {
  // MARK: - Shared send loop (adapter path)

  /// Cookie relay layer (transport == "cookie-relay"): unified browser UA +
  /// cookie header. `ensureFresh()` is non-blocking: a fresh token
  /// (< 120 s) returns instantly, offline; a stale one refreshes IN
  /// BACKGROUND, the request goes with the current token. A challenge is
  /// answered by the retry in `sendWithRetry` (refreshBlocking until
  /// result).
  private func applyCookieRelayHeaders(to request: inout URLRequest) async {
    guard let relay = cookieRelayProvider else { return }
    request.setValue(CookieRelayProvider.chromeUA, forHTTPHeaderField: "User-Agent")
    if let cookie = await relay.ensureFresh() {
      request.setValue(cookie, forHTTPHeaderField: "Cookie")
    }
  }

  /// Shared "send + retry as needed" loop for both paths.
  /// - up to `maxAttempts` attempts: initial + retries with exponential
  ///   backoff and jitter (retryable only: HTTP 429/5xx, transport errors
  ///   including timeout); HTTP 429 waits Retry-After (cap 10 s);
  /// - cookie challenge retried once with a fresh cookie (attempt not burned);
  /// - `transcriptPath == nil` — flat "text" key; else extracted via the
  ///   adapter JSON path (cloudflare).
  /// - `skipPreflight: true` — adapter path already did preflight before.
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func sendWithRetry(context: SendContext) async throws -> TranscriptionResult {
    var context = context

    // With log_level == "debug", save the WAV itself to disk once, before
    // sending; the file info goes to the debug dump.
    let recording = saveRecordingIfDebug(wav: context.wav)

    // Network preflight: no network — no HTTP request at all, instant
    // error ("No internet") instead of an overlay hanging for 120 s.
    if !context.skipPreflight, await !networkChecker() {
      Logger.log("STT not sent: no internet (preflight)", level: "error")
      debugDump(context: context, recording: nil, response: nil)
      throw TranscribeError.network(Self.noInternetMessage)
    }

    // maxAttempts tries (initial + up to maxAttempts-1 retries) with
    // exponential backoff and jitter. Retried only retryable errors
    // (HTTP 429/5xx, transport errors including timeout); cancel and
    // invalidResponse — terminal, a retry never burns the overlay budget.
    var lastError: TranscribeError?
    var attempt = 0
    // Retry-After from the HTTP 429 header — wait what the server says.
    var retryAfterHeader: TimeInterval?
    // Cookie challenge retried at most once (with a fresh cookie).
    var challengeRetried = false
    while attempt < Self.maxAttempts {
      // Parent cancellation (e.g. the first success of parallel failover
      // cancelled siblings — cancelAll): no repeated POST sent. The
      // default retrySleep swallows cancellation via try?, so the check
      // lives here — guarantees no "extra" requests after a win.
      if Task.isCancelled {
        throw CancellationError()
      }
      attempt += 1
      retryAfterHeader = nil
      do {
        let started = CFAbsoluteTimeGetCurrent()
        let response = try await send(request: context.request)
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        debugDump(context: context, recording: recording, response: response)
        if logLevel.lowercased() == "debug" {
          let logLine = String(
            format: "STT response: HTTP %d in %.2f s, bodyBytes=%d",
            response.status,
            elapsed,
            response.body.count
          )
          Logger.log(logLine, level: "debug")
        }
        // HTTP 429: with a Retry-After header, back off what the server
        // says (cap ~10 s — overlay watchdog budget).
        if response.status == 429 {
          retryAfterHeader = Self.retryAfterSeconds(from: response.headers)
        }
        // Cookie challenge (transport == "cookie-relay"): the server sent a
        // JS stub instead of content. The single retry — with a fresh
        // cookie (refreshBlocking until result); attempt not burned.
        // A challenge after a fresh token — a serious error.
        let responseIsChallenge = CookieRelayProvider.looksLikeChallenge(response.body)
        if let relay = cookieRelayProvider, !challengeRetried, responseIsChallenge {
          if let freshCookie = await relay.refreshBlocking() {
            challengeRetried = true
            context.request.setValue(freshCookie, forHTTPHeaderField: "Cookie")
            attempt -= 1
            Logger.log(
              "STT cookie challenge: cookie обновлён, повтор с новым __test", level: "info")
            continue
          }
          Logger.log("STT cookie challenge: свежий cookie не получен", level: "error")
          throw TranscribeError.invalidResponse(
            "Cookie challenge page received; cookie refresh failed")
        }
        let result = try Self.parseResponse(response, transcriptPath: context.transcriptPath)
        if logLevel.lowercased() == "debug" {
          let text = result.text
          let head = text.count > 80 ? String(text.prefix(80)) + "…" : text
          Logger.log("STT text: \"\(head)\" (\(text.count) chars)", level: "debug")
        }
        return result
      } catch let error as TranscribeError {
        // HTTP 4xx (except 429)/invalidResponse — no retry.
        guard Self.isRetryable(error) else {
          Logger.log("STT error (attempt \(attempt)): \(Self.describe(error))", level: "error")
          throw error
        }
        lastError = error
        Logger.log(
          "STT retryable error (attempt \(attempt)/\(Self.maxAttempts)): \(Self.describe(error))",
          level: "error"
        )
        if attempt >= Self.maxAttempts {
          break
        }
        // Pause: Retry-After on 429 (cap 10 s), else backoff.
        var delay = Self.backoffDelay(beforeRetry: attempt)
        if case .http(429, _) = error, let retryAfter = retryAfterHeader {
          delay = min(retryAfter, 10)
        }
        await retrySleep(delay)
      } catch is CancellationError {
        // Do not retry cancelled requests.
        Logger.log("STT cancelled (attempt \(attempt))", level: "error")
        throw TranscribeError.network("Request cancelled")
      } catch let error as URLError where error.code == .cancelled {
        Logger.log("STT cancelled (URLError.cancelled, attempt \(attempt))", level: "error")
        throw TranscribeError.network("Request cancelled")
      } catch let error as URLError where error.code == .timedOut {
        // Hard network request timeout (networkRequestTimeout) — terminal,
        // NO retry: a retried request would almost surely hit the same
        // timeout again and keep the overlay spinning dots, so the
        // "processing" phase never outlives the timeout + a small margin
        // (see OverlayController.processingMaxDuration).
        Logger.log(
          "STT timeout (attempt \(attempt)): \(error.localizedDescription)", level: "error")
        throw TranscribeError.network(Self.sttTimeoutMessage)
      } catch {
        // Transport-level (network) failure — eligible for retry.
        let message = error.localizedDescription
        lastError = TranscribeError.network(message)
        Logger.log(
          "STT network error (attempt \(attempt)/\(Self.maxAttempts)): \(message)", level: "error")
        if attempt >= Self.maxAttempts {
          break
        }
        await retrySleep(Self.backoffDelay(beforeRetry: attempt))
      }
    }
    // All attempts died at the transport level — no response at all.
    // The debug dump records the request itself (method/URL/headers/fields)
    // so it's visible HTTP was never reached; dump errors never crash.
    debugDump(context: context, recording: recording, response: nil)
    if let lastError {
      Logger.log(
        "STT failed after \(Self.maxAttempts) attempts: \(Self.describe(lastError))", level: "error"
      )
      throw lastError
    }
    throw TranscribeError.network("Unknown transport error")
  }

  /// Human-readable error description for logs. The HTTP body is masked via
  /// `DebugDump.maskedResponseBody` (secrets wiped over the FULL body),
  /// then truncated to ~120 characters so provider api_key/proxy_key never
  /// land in the log.
  public static func describe(_ error: TranscribeError) -> String {
    switch error {
    case .network(let message):
      return "network: \(message)"
    case let .http(code, body):
      // Mask the FULL body (a secret may cross the truncation boundary),
      // then cut to ~120 characters.
      return "HTTP \(code): \(String(DebugDump.maskedResponseBody(Data(body.utf8)).prefix(120)))"
    case .invalidResponse(let message):
      return "invalid response: \(message)"
    }
  }
}

// MARK: - Multipart body

// Single source of truth for the multipart format — ProviderRequestBuilder
// (STTAdapter.swift): all OpenAI-compatible adapters produce byte-identical
// bodies (see ProviderRequestBuilder.multipartBody).

// swiftlint:disable:this file_length
