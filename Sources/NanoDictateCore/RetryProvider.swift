import Foundation

// MARK: - RetryProvider

//
// Last WAV kept in MEMORY (not on disk) + re-recognition by another provider.
// Two use scenarios:
//   1. Auto-failover: primary provider network/server error — agent tries
//      next from list (`providers`/`auto_failover` config keys). Mic/record
//      errors (NOT TranscribeError) never trigger failover.
//   2. Manual retry: `nanodictate retry <provider>` re-recognizes last WAV
//      by the chosen provider.
//
// Struct itself thread-safe (NSLock); async transcribe calls run by caller.

public typealias TranscribeFunction = (Data, AppConfig.Provider) async throws -> TranscriptionResult

public final class RetryProvider {
  // MARK: Состояние последней записи

  private let lock = NSLock()
  private var _lastWAV: Data?
  private var _lastWAVCreatedAt: Date?

  /// Recognition function; default — Transcriber built from provider fields
  /// (base_url/model/api_key/proxy_key/language/timeout).
  public var transcribeFunction: TranscribeFunction

  /// Provider whose last recording already failed recognition — excluded
  /// from failover queue.
  /// Lock-backed: parallel failover (main.swift transcribeAutomatically)
  /// may read/write from different Tasks concurrently.
  private var _lastFailedProviderID: String?
  public var lastFailedProviderID: String? {
    get {
      lock.lock()
      defer { lock.unlock() }
      return _lastFailedProviderID
    }
    set {
      lock.lock()
      defer { lock.unlock() }
      _lastFailedProviderID = newValue
    }
  }

  public init(transcribeFunction: TranscribeFunction? = nil) {
    self.transcribeFunction = transcribeFunction ?? RetryProvider.defaultTranscribe
  }

  /// Default impl: Transcriber from provider fields.
  /// `transport == "cookie-relay"` (legacy aliases canonicalized at parse)
  /// enables cookie-relay layer. Cookie-relay cache by baseURL — ONE
  /// instance per origin (cookie token lives in instance memory): else each
  /// retry/failover would build a fresh provider without token and the first
  /// request would go without cookie for an extra challenge round-trip.
  /// Values shared across all RetryProvider instances.
  private static func defaultTranscribe(
    _ wav: Data,
    _ provider: AppConfig.Provider
  ) async throws -> TranscriptionResult {
    let relay = await Self.sharedCookieRelay(for: provider)
    let transcriber = Transcriber(
      baseURL: provider.baseURL,
      model: provider.model,
      // Default has no config context (init runs without config): env key
      // NOT issued (fail-closed) — provider uses own api_key/api_key_file,
      // else request fails normally.
      apiKey: resolveAPIKey(for: provider, activeProviderID: nil),
      proxyKey: provider.proxyKey,
      cookieRelayProvider: relay,
      httpProxy: provider.httpProxy,
      proxyUser: provider.proxyUser,
      proxyPassword: provider.proxyPassword,
      adapterID: provider.id
    )
    return try await transcriber.transcribe(wav: wav)
  }

  /// Shared cookie-relay cache (key — provider baseURL).
  private static let cookieRelayLock = NSLock()
  private static var cookieRelayByURL: [String: CookieRelayProvider] = [:]

  /// Cookie-relay for provider: reuse cached instance, else create and store.
  /// Sync cache access via helpers (no NSLock from async context).
  private static func sharedCookieRelay(for provider: AppConfig.Provider) async
    -> CookieRelayProvider?
  {  // swiftlint:disable:this opening_brace
    guard provider.transport == "cookie-relay" else { return nil }
    if let existing = cachedCookieRelay(provider.baseURL) {
      return existing
    }
    guard let made = CookieRelayProvider.makeForCookieRelay(baseURL: provider.baseURL) else {
      return nil
    }
    storeCookieRelay(provider.baseURL, made)
    return made
  }

  private static func cachedCookieRelay(_ baseURL: String) -> CookieRelayProvider? {
    cookieRelayLock.lock()
    defer { cookieRelayLock.unlock() }
    return cookieRelayByURL[baseURL]
  }

  private static func storeCookieRelay(_ baseURL: String, _ provider: CookieRelayProvider) {
    cookieRelayLock.lock()
    defer { cookieRelayLock.unlock() }
    cookieRelayByURL[baseURL] = provider
  }

  /// Provider key FOR REQUEST. Env NANODICTATE_API_KEY (highest priority,
  /// never written to file) goes ONLY to active provider — id matches
  /// `activeProviderID` (see applyEnvAPIKey in Config). Inactive providers
  /// (failover candidates, retry, routing roles) get no env key: own key
  /// (config api_key → api_key_file), no key → empty string (request fails
  /// normally).
  /// `activeProviderID` — active section id; nil (no active / legacy config /
  /// no config context) — env issued to nobody (fail-closed). public —
  /// agent reuses it in config-aware recognition function.
  public static func resolveAPIKey(
    for provider: AppConfig.Provider,
    activeProviderID: String?
  ) -> String {
    // Env key only for active provider (same source as applyEnvAPIKey;
    // here — config may have been read without env).
    let envKey = ProcessInfo.processInfo.environment["NANODICTATE_API_KEY"]
    if provider.id == activeProviderID, let envKey, !envKey.isEmpty {
      return envKey
    }
    if !provider.apiKey.isEmpty {
      return provider.apiKey
    }
    guard let file = provider.apiKeyFile else { return "" }
    return AppConfig.readAPIKeyFile(at: file)
  }

  // MARK: Последняя запись (в памяти, без диска)

  /// Saves last WAV buffer (called from agent's sample handler).
  public func store(wav: Data) {
    lock.lock()
    defer { lock.unlock() }
    _lastWAV = wav
    _lastWAVCreatedAt = Date()
  }

  /// Last WAV buffer (nil — no recording in this session yet).
  public var lastWAV: Data? {
    lock.lock()
    defer { lock.unlock() }
    return _lastWAV
  }

  /// Last recording save time (retry freshness from CLI).
  public var lastWAVCreatedAt: Date? {
    lock.lock()
    defer { lock.unlock() }
    return _lastWAVCreatedAt
  }

  public var hasLastRecording: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _lastWAV != nil
  }

  // MARK: Retry одним провайдером

  /// Re-recognize last WAV with given provider. nil — no last recording.
  public func retranscribe(
    with provider: AppConfig.Provider
  ) async throws -> TranscriptionResult? {
    guard let wav = lastWAV else { return nil }
    let result = try await transcribeFunction(wav, provider)
    lastFailedProviderID = nil
    return result
  }

  // MARK: Failover-цепочка

  /// Recognize WAV with auto-failover over `order`.
  /// - `autoFailover == false` — only first provider from `order` tried.
  /// - TranscribeError (network/server/response) → next provider in queue;
  ///   last-failed provider moved to the end (autoFailover only).
  /// - NON-TranscribeError (e.g. mic error) → rethrown at once, no failover.
  /// - Returns (result, successful provider id).
  public func transcribeWithFailover(
    wav: Data,
    order: [AppConfig.Provider],
    autoFailover: Bool = false
  ) async throws -> (result: TranscriptionResult, providerID: String) {
    guard !order.isEmpty else {
      throw TranscribeError.invalidResponse("no providers configured for failover")
    }
    var attempts = order
    // Last-failed провайдер — в конец очереди: повторная попытка после всех
    // остальных. При выключенном autoFailover порядок attempts не трогаем.
    if autoFailover, let failed = lastFailedProviderID {
      if let index = attempts.firstIndex(where: { $0.id == failed }) {
        let provider = attempts.remove(at: index)
        attempts.append(provider)
      }
    }
    let candidateCount = autoFailover ? attempts.count : min(1, attempts.count)
    let candidates = Array(attempts.prefix(candidateCount))

    var lastError: TranscribeError?
    for provider in candidates {
      do {
        let result = try await transcribeFunction(wav, provider)
        lastFailedProviderID = nil
        return (result, provider.id)
      } catch let error as TranscribeError {
        lastError = error
        lastFailedProviderID = provider.id
      } catch {
        // Non-TranscribeError (mic etc.) — no failover.
        throw error
      }
    }
    throw lastError ?? TranscribeError.invalidResponse("failover failed without a provider error")
  }

  // MARK: - Параллельный failover (withTaskGroup)

  /// Parallel failover over candidates: all transcriptions in one
  /// withTaskGroup (independent STT requests), first success wins and
  /// cancels the rest (cancelAll). Semantics (moved from NanoDictateAgent
  /// transcribeAutomatically 1:1):
  /// - first `.success` → `group.cancelAll()` and return;
  /// - TranscribeError → remembered as `lastFailure`, LAST finished wins
  ///   (outcome returned as Result, unwrapped after withTaskGroup — group
  ///   body does not throw);
  /// - NON-TranscribeError (abortError, e.g. mic error) → aborts group and
  ///   rethrown regardless of accumulated `lastFailure`;
  /// - empty candidates → `TranscribeError.invalidResponse("failover has no
  ///   candidates")`.
  ///
  /// `lastFailedProviderID` untouched here: caller sets it BEFORE the group,
  /// cleared on success in `retranscribe`/`transcribeWithFailover`.
  /// `Candidate` — minimal type transcribe reads fields from (prod —
  /// `AppConfig.Provider`, tests — plain id).
  public static func parallelFailover<Candidate>(
    candidates: [Candidate],
    transcribe: @escaping (Candidate) async throws -> (TranscriptionResult, String)
  ) async throws -> (TranscriptionResult, String) {
    guard !candidates.isEmpty else {
      throw TranscribeError.invalidResponse("failover has no candidates")
    }
    let outcome = await withTaskGroup(
      of: Result<(TranscriptionResult, String), Error>.self,
      returning: Result<(TranscriptionResult, String), Error>.self
    ) { group in
      for candidate in candidates {
        group.addTask {
          do {
            return try await .success(transcribe(candidate))
          } catch {
            return .failure(error)
          }
        }
      }
      var lastFailure: TranscribeError?
      var abortError: Error?
      drain: while let outcome = await group.next() {
        switch outcome {
        case .success(let hit):
          group.cancelAll()
          return .success(hit)
        case .failure(let error):
          if let transcribeError = error as? TranscribeError {
            lastFailure = transcribeError
          } else {
            abortError = error
            group.cancelAll()
            // Non-TranscribeError (mic etc.): keep the FIRST abort error and
            // stop draining — cancelled siblings may throw CancellationError.
            break drain
          }
        }
      }
      if let abortError {
        return .failure(abortError)
      }
      if let lastFailure {
        return .failure(lastFailure)
      }
      return .failure(TranscribeError.invalidResponse("failover has no candidates"))
    }
    return try outcome.get()
  }
}
