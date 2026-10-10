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
    // Section `upload_format` selects the container per target provider; the
    // Transcriber FLAC-encodes the stored WAV bytes per request (PCM
    // recovered via WAV decode), so failover never relabels WAV as FLAC.
    // No top-level config here: empty section inherits `auto` (WAV default).
    let preference = STTUploadPreference.parse(
      provider.uploadFormat.isEmpty ? nil : provider.uploadFormat) ?? .auto
    let profile = ProviderRequestBuilder.profile(adapterID: provider.id, model: provider.model)
    let audioFormat = AudioTransportSelection.resolve(
      preference: preference, profile: profile.audio)
    return try await transcriber.transcribe(wav: wav, audioFormat: audioFormat)
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
    // Failover queue policy from the shared engine (canonical ordering):
    // with auto-failover the last-failed provider moves to the end of the
    // queue so it is retried only after every other candidate; without
    // auto-failover the order is untouched (only the first candidate runs).
    // Engine failure throws loudly — never a silent Swift-only order.
    let orderedIDs = try RustEngine.failoverOrder(
      ids: order.map(\.id), failedID: lastFailedProviderID, autoFailover: autoFailover)
    var byID: [String: AppConfig.Provider] = [:]
    for provider in order {
      byID[provider.id] = provider
    }
    let attempts = orderedIDs.compactMap { byID[$0] }
    let candidateCount = RustEngine.failoverCandidateCount(
      orderLen: attempts.count, autoFailover: autoFailover)
    let candidates = Array(attempts.prefix(candidateCount))

    var lastError: TranscribeError?
    for provider in candidates {
      do {
        let result = try await transcribeFunction(wav, provider)
        lastFailedProviderID = nil
        return (result, provider.id)
      } catch let error as TranscribeError {
        // Failover classification from the shared engine: provider
        // (`TranscribeError`) failures proceed to the next candidate.
        // Anything else (mic etc.) rethrows at once, no failover.
        guard RustEngine.shouldFailover(error: error) else {
          throw error
        }
        lastError = error
        lastFailedProviderID = provider.id
      } catch {
        // Non-TranscribeError (mic etc.) — no failover.
        throw error
      }
    }
    throw lastError ?? TranscribeError.invalidResponse("failover failed without a provider error")
  }

  // MARK: - Bounded hedged failover

  /// Bounded hedged failover policy.
  ///
  /// - `maxConcurrentAttempts`: strict cap on simultaneous fallback uploads.
  ///   The first (highest-priority) fallback starts alone; extra fallbacks
  ///   launch only when needed (first attempt is slow or fails fast) and
  ///   never exceed this cap. Total STT uploads stay bounded: at most
  ///   `candidates.count` fallback attempts overall, at most
  ///   `maxConcurrentAttempts` in flight at once.
  /// - `hedgeDelaySeconds`: how long to wait for the in-flight attempt(s)
  ///   before hedging with the next ordered candidate. Small on purpose
  ///   (STT requests take seconds; a ~1 s hedge preserves recovery latency
  ///   while a fast first fallback sends the only upload).
  public struct HedgedFailoverPolicy: Equatable, Sendable {
    public var maxConcurrentAttempts: Int
    public var hedgeDelaySeconds: TimeInterval

    public init(maxConcurrentAttempts: Int = 2, hedgeDelaySeconds: TimeInterval = 1.0) {
      self.maxConcurrentAttempts = maxConcurrentAttempts
      self.hedgeDelaySeconds = hedgeDelaySeconds
    }

    /// Default budget: at most 2 simultaneous fallback uploads, 1 s hedge.
    public static let `default` = HedgedFailoverPolicy()
  }

  /// Hedged failover event inside the group (transcribe completion vs hedge tick).
  private enum HedgedEvent {
    case done(Int, Result<(TranscriptionResult, String), Error>)
    case hedge
    case hedgeCancelled
  }

  /// Bounded hedged failover over ordered candidates.
  ///
  /// Ordered priority: `candidates[0]` (the most appropriate fallback, e.g.
  /// the failover queue after the engine `failoverOrder` rotation) starts
  /// first and alone. The next candidate launches only when needed:
  /// - the in-flight attempt fails with a `TranscribeError` (fast-fail hedge:
  ///   the next ordered candidate starts immediately when a concurrency slot
  ///   is free), or
  /// - no attempt completes within `policy.hedgeDelaySeconds` (slow hedge)
  ///   and a concurrency slot is free.
  /// Concurrency is strictly bounded by `policy.maxConcurrentAttempts`; total
  /// attempts are bounded by `candidates.count` (each candidate is started at
  /// most once; every started attempt runs its own `Transcriber` retry budget
  /// of up to `Transcriber.maxAttempts` requests for retryable errors, while
  /// terminal errors such as HTTP 4xx (except 429) and invalid responses use
  /// exactly one request per candidate).
  ///
  /// Error classification is preserved: `TranscribeError` (network/server/
  /// response, terminal or retryable) is remembered as `lastFailure` and the
  /// failover proceeds to the next candidate (gated by
  /// `RustEngine.shouldFailover`); any other error aborts the whole group at
  /// once. `CancellationError` from a cancelled loser is neutral and never
  /// overwrites the winner or the first abort error.
  ///
  /// Winner commitment: the first `.success` cancels the group (`cancelAll`)
  /// and is the single returned result, so losing uploads are cancelled
  /// before they can commit a duplicate transcript. Callers must still insert
  /// the returned text exactly once.
  ///
  /// - Parameters:
  ///   - candidates: ordered fallback candidates (priority order).
  ///   - policy: concurrency/hedge budget (default: 2 concurrent, 1 s hedge).
  ///   - hedgeSleep: hedge timer (default: cancellable `Task.sleep`); tests
  ///     inject an instant/short sleep for determinism.
  ///   - transcribe: one fallback attempt.
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  public static func hedgedFailover<Candidate>(
    candidates: [Candidate],
    policy: HedgedFailoverPolicy = .default,
    hedgeSleep: ((TimeInterval) async throws -> Void)? = nil,
    transcribe: @escaping (Candidate) async throws -> (TranscriptionResult, String)
  ) async throws -> (TranscriptionResult, String) {
    guard !candidates.isEmpty else {
      throw TranscribeError.invalidResponse("failover has no candidates")
    }
    let maxConcurrent = max(1, policy.maxConcurrentAttempts)
    let hedgeDelay = max(0, policy.hedgeDelaySeconds)
    let sleep: (TimeInterval) async throws -> Void =
      hedgeSleep ?? { seconds in
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      }
    let outcome = await withTaskGroup(
      of: HedgedEvent.self,
      returning: Result<(TranscriptionResult, String), Error>.self
    ) { group in
      var nextIndex = 0
      var inFlight = 0
      var lastFailure: TranscribeError?

      func launchNext() {
        let index = nextIndex
        let candidate = candidates[index]
        nextIndex += 1
        inFlight += 1
        group.addTask {
          if Task.isCancelled {
            return .done(index, .failure(CancellationError()))
          }
          do {
            let value = try await transcribe(candidate)
            return .done(index, .success(value))
          } catch {
            return .done(index, .failure(error))
          }
        }
        // Arm the next hedge tick while candidates remain. The tick itself
        // re-checks the concurrency bound before launching.
        if nextIndex < candidates.count {
          group.addTask {
            do {
              try await sleep(hedgeDelay)
              return .hedge
            } catch {
              return .hedgeCancelled
            }
          }
        }
      }

      launchNext()
      while let event = await group.next() {
        // A committed winner or abort returns immediately with cancelAll;
        // remaining events are discarded by the group cancellation.
        switch event {
        case .hedge:
          if nextIndex < candidates.count, inFlight < maxConcurrent {
            // Slow first fallback: hedge with the next ordered candidate.
            launchNext()
          }
          // At capacity: wait for a completion (a failure frees a slot and
          // hedges immediately; a success wins). No re-arm here: the
          // completion path arms the next hedge when it launches.
          if inFlight == 0, nextIndex >= candidates.count, let lastFailure {
            return .failure(lastFailure)
          }
        case .hedgeCancelled:
          if Task.isCancelled {
            group.cancelAll()
            return .failure(CancellationError())
          }
          // Stray hedge cancellation (sibling cancelAll after a winner that
          // already returned is unreachable here); otherwise ignore.
        case .done(_, .success(let hit)):
          group.cancelAll()
          return .success(hit)
        case .done(_, .failure(let error)):
          if error is CancellationError {
            inFlight = max(0, inFlight - 1)
            if Task.isCancelled {
              group.cancelAll()
              return .failure(CancellationError())
            }
            // Neutral loser cancellation: no failure recorded, no abort.
            // If everything settled with no winner and no failure, surface
            // cancellation so callers do not see a phantom empty failure.
            if inFlight == 0, nextIndex >= candidates.count {
              if let lastFailure {
                return .failure(lastFailure)
              }
              return .failure(CancellationError())
            }
            continue
          }
          guard let transcribeError = error as? TranscribeError else {
            // Non-TranscribeError (mic etc.): abort at once, first abort wins.
            group.cancelAll()
            return .failure(error)
          }
          // Provider error: fail over only per engine classification.
          guard RustEngine.shouldFailover(error: transcribeError) else {
            group.cancelAll()
            return .failure(transcribeError)
          }
          inFlight = max(0, inFlight - 1)
          lastFailure = transcribeError
          if nextIndex < candidates.count, inFlight < maxConcurrent {
            // Fast-fail hedge: the failed slot immediately goes to the next
            // ordered candidate without waiting for the hedge delay.
            launchNext()
          } else if inFlight == 0, nextIndex >= candidates.count {
            return .failure(transcribeError)
          }
        }
      }
      if let lastFailure {
        return .failure(lastFailure)
      }
      return .failure(TranscribeError.invalidResponse("failover has no candidates"))
    }
    return try outcome.get()
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
