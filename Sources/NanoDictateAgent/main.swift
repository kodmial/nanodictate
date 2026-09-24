//
//  main.swift
//  NanoDictateAgent
//
//  NanoDictate background dictation agent orchestrator.
//  State machine: idle → recording → transcribing → idle.
//  Swift 5.7, macOS 12, Intel. AppKit/Foundation/AVFoundation via NanoDictateCore.
//

import AVFoundation
import AppKit
import ApplicationServices
import NanoDictateCore

// MARK: - Agent

// swiftlint:disable:next type_body_length
final class Agent: NSObject, HotkeyDelegate, AudioLevelDelegate {
  // Strong refs keep services alive.
  private let sounds: SysSounds
  private let overlay: OverlayController
  private let audio: AudioService
  private let hotkeys: HotkeyService
  private let transcriber: Transcriber

  /// Stored last WAV, re-transcribable by another provider; serves auto-failover and CLI retry.
  private let retryProvider: RetryProvider

  /// UX config copies: cgevent insert, failover/review off by default.
  private let insertMethod: InsertMethod
  private let autoFailover: Bool
  private let reviewBeforeInsert: Bool

  /// Failover order (active excluded): candidates for auto-retry.
  private let failoverCandidates: [AppConfig.Provider]
  /// All providers by id: for manual retry via IPC.
  private let providersByID: [String: AppConfig.Provider]
  /// Active provider id (nil — legacy config without sections).
  private let activeProviderID: String?

  // MARK: Маршрутизация STT по ролям ([routing])

  /// Segment-role provider id ([routing]); nil — unset, fallback active; resolved in init from config.
  private let segmentRoleProviderID: String?
  /// Final-pass provider id ([routing]); nil — unset, fallback active.
  private let finalRoleProviderID: String?
  /// Single Transcriber builder (provider section + shared config); retries/roles behave like main path.
  private let makeTranscriber: (AppConfig.Provider) -> Transcriber

  /// Resolved session config — source of truth for request path and overlay STT label; never re-read.
  private let resolvedConfig: AppConfig

  /// DistributedNotificationCenter observer for manual retry from CLI.
  private var retryObserver: NSObjectProtocol?

  /// Log level from config: at "debug" the log also gets metrology
/// (recording RMS level before STT send).
  private let logLevel: String

  /// Step dictation (`chunked = true` in config): segments → incremental insert →
  /// final pass over the whole WAV. OFF — current behavior (single request).
  private let chunked: Bool

  // MARK: Live dictation (chunked = true)

  /// Serial executor of the live loop: utterances recognized STRICTLY in queue
  /// order — the stop tail lands before the final pass, and each next segment's
  /// prompt carries all previous text. submit never blocks main; each serial
  /// block waits its own Task (pattern from ChunkedPipelineTests.testInsertAndPhaseAreSynchronous).
  private let liveExecutor = SerialAsyncExecutor()
  /// Live-loop token: new recording start / Esc invalidate prior loop segment
  /// processing (early insert guard). Read/written on main; every loop callback
  /// captures its own token.
  private var liveSession = 0
  /// Live-loop accumulation (segments, prompt, flags). Written ONLY on
  /// liveExecutor (serially); created on main at each recording start.
  private var liveRunState: LiveRunState?

  /// Accumulated state of one live dictation loop. Fields grow incrementally on
  /// liveExecutor; main reads them only for guards (session tokens).
  private final class LiveRunState {
    let session: Int
    /// How many segments recognized and queued for insertion.
    var segmentCount = 0
    /// Text already committed to insertion (with separating spaces) —
    /// base for final word-diff and prompt accumulation.
    var insertedText = ""
    /// Earlier segment parts for the next prompt (clean text, no leading spaces).
    var promptParts: [String] = []
    /// Stop tail (unclosed utterance) delivered: with one segment it covers the
    /// whole recording — no final pass needed.
    var tailDelivered = false
    /// At least one segment failed — final pass is mandatory
    /// (it recovers the missed phrase from the whole WAV).
    var anySegmentFailed = false
    /// Text of the last segment failure: on a FULL failure of all segments
    /// (segmentCount == 0) the final pass shows an explicit STT error message
    /// instead of the confusing "Empty result" (review #112).
    var lastErrorText: String?
    /// Set on main at cancel time (Esc / device change / restart); read on
    /// liveExecutor — stale queued segments skip their STT call.
    private let cancelLock = NSLock()
    private var cancelled = false
    var isCancelled: Bool {
      get {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelled
      }
      set {
        cancelLock.lock()
        cancelled = newValue
        cancelLock.unlock()
      }
    }

    init(session: Int) {
      self.session = session
    }
  }

  /// Serial async executor: each task runs strictly after the previous one
  /// (until it finishes); submit never blocks the caller. Why serial matters:
  /// insertion order and tail delivery before the final pass — the finalization
  /// DIFF counts already-inserted segment text, so it must be processed earlier.
  private final class SerialAsyncExecutor {
    private let queue = DispatchQueue(label: "nanodictate.live.serial", qos: .userInitiated)
    private let pendingLock = NSLock()
    private var pending = 0

    /// Submitted but not finished tasks (queued + running).
    var pendingCount: Int {
      pendingLock.lock()
      defer { pendingLock.unlock() }
      return pending
    }

    func submit(_ body: @escaping () async -> Void) {
      pendingLock.lock()
      pending += 1
      pendingLock.unlock()
      queue.async {
        let sema = DispatchSemaphore(value: 0)
        Task {
          await body()
          sema.signal()
        }
        sema.wait()
        self.pendingLock.lock()
        self.pending -= 1
        self.pendingLock.unlock()
      }
    }
  }

  private var state: NanoDictateState = .idle

  /// Session token of the "processing" phase: each new STT send increments it;
  /// the old loop's watchdog sees the mismatch and does not disturb the new loop.
  private var processingSession = 0

  /// Recording start "in flight" (engine boots asynchronously on AudioService's
  /// background queue): repeated Alt+Alt in this window is ignored, not duplicated.
  private var isStarting = false
  /// Start session token: incremented on each new start and on boot watchdog
  /// firing — invalidates stale completion callbacks.
  private var startSession = 0
  /// Microphone access coordinator: session token + watchdog + MicRequestPolicy
  /// anti-storm (after 3 request timeouts in a 6 h window no new system dialog —
  /// repeated dialogs from a bundle-less background agent wedge tccd and freeze
  /// the system). Policy state persists across agent restarts (file in
  /// Application Support). Lives in Core so late-grant watchdog behavior is
  /// covered by mini-XCTest (NanoDictateCoreTests).
  private let micAccessRequester: MicAccessRequester
  /// Cooldown for terminal mic errors (showMicrophoneError): while mic access
  /// is not granted / engine not up, each Alt+Alt must not replay Basso and
  /// flash the overlay — message once per 3 s.
  private var micErrorCooldown = MicErrorCooldown(interval: 3.0)

  // MARK: UX quick wins

  /// Cancel token for the "Recognizing…" phase: Esc during STT sets it, and the
  /// returning request's result is ignored (text not inserted). Reset at each
  /// new loop (processSamples).
  private var cancelRecognition = false

  /// While ReviewGate.confirmAsync waits for the terminal decision, a
  /// physical Return MUST pass through the event tap — the terminal's
  /// readLine needs it (ReviewGate reads stdin on a background queue). Set
  /// true right before each confirmAsync, cleared when the decision arrives
  /// (the completion, delivered to the main queue) and on Esc (handleCancel).
  /// Main-thread only — the tap and the completions run on the same run loop.
  private var awaitingReviewDecision = false

  /// Synthetic-Enter latch after Enter-stop of recording: Enter during
  /// .recording stops recording, starts recognition, sets the latch; after a
  /// successful insert EXACTLY ONE synthetic Enter is posted. Read at insert
  /// points (postSyntheticReturnIfPending), cleared in handleEmptyResult /
  /// failTranscription / handleCancel / after posting.
  private let enterSendLatch = EnterSendLatch()
  /// Cancellable scheduling of the synthetic Enter:
  /// postSyntheticReturnIfPending schedules the post after a ~250 ms pause,
  /// handleCancel (in ANY branch, including .idle) cancels the already
  /// scheduled post — Esc extinguishes not only the latch but also the
  /// scheduled firing.
  private let scheduledEnterPoster = ScheduledEnterPoster()

  /// Undo state: the last SUCCESSFUL insertion (text + timestamp). A double
  /// Alt within undoMaxInterval after the insertion erases it.
  private var lastInsertedText: String?
  private var lastInsertedAt: TimeInterval?

  /// Undo window and rollback sound — from config (undo_max_interval /
  /// undo_sound_enabled). Copies made in init so the live config data class
  /// stays untouched.
  private let undoMaxInterval: TimeInterval
  private let undoSoundEnabled: Bool

  /// Cooldown for the "empty result" sound: repeated Alt+Alt in silence (<2 words
  /// recognized) does not spam Funk on every press. Separate from
  /// micErrorCooldown: "empty dictation" ≠ "mic error".
  private var emptyResultCooldown = MicErrorCooldown(interval: 3.0)

  /// Hard watchdog for audio engine boot: `engine.start()` can block (device
  /// switch, init after TCC grant). Start runs on AudioService's background
  /// queue — main thread never freezes, but without the watchdog a hung queue
  /// would leave the "Recording…" overlay forever. On timeout — terminal error
  /// (overlay goes out, next Alt+Alt works).
  private static let recordStartTimeout: TimeInterval = 10
  /// Watchdog for the system mic-access request: a bundle-less background agent
  /// may never show the TCC window, and the `requestAccess` callback never
  /// fires — the watchdog yields a terminal error instead of an endless wait.
  private static let micRequestTimeout: TimeInterval = 10

  /// Retain property for the Accessibility auto-grant poll timer
  /// (Timer.scheduledTimer with repeats:true must not fall to ARC/GC).
  private var accessibilityPollTimer: Timer?
  /// Rate limit for opening the Accessibility panel: a series of presses/starts
  /// without the grant must not spawn settings windows (at most once per 10 min).
  /// Last-open stamp lives in UserDefaults, not process memory: a background
  /// agent respawn (KeepAlive) resets memory, and without persistence the panel
  /// would open on EVERY respawn.
  private static let accessibilityPanelCooldown: TimeInterval = 10 * 60
  private static let lastAccessibilityPanelOpenAtKey = "NanoDictate.lastAccessibilityPanelOpenAt"

  // swiftlint:disable:next function_body_length
  init(config: AppConfig) {
    logLevel = config.logLevel
    // Same resolved config the Transcriber below was built from —
    // source of truth for the overlay label (RecognitionLabel.forSession).
    resolvedConfig = config
    undoMaxInterval = config.undoMaxInterval
    undoSoundEnabled = config.undoSoundEnabled
    chunked = config.chunked
    sounds = SysSounds(enabled: config.soundsEnabled)
    overlay = OverlayController(logLevel: config.logLevel)
    audio = AudioService(
      logLevel: config.logLevel,
      // Silence auto-stop sealing from environment (the feature itself lives
      // in NanoDictateCore/AudioService): empty env → `.defaults`, exactly per
      // task (on, ~3 s, −50 dBFS). Escape hatch: NANODICTATE_AUTOSTOP_DISABLED
      // / _DURATION / _RMS, see AutoStopConfig.
      autoStopConfig: AutoStopConfig.fromEnvironment()
    )
    // Mic TCC-request coordinator: timeout watchdog + anti-storm
    // (MicRequestPolicy). Tokens and request flags live inside it —
    // stale callbacks (late grant after timeout) are dropped by session token,
    // recording under a shown error never starts.
    micAccessRequester = MicAccessRequester(
      status: { AVCaptureDevice.authorizationStatus(for: .audio) },
      requestAccess: { completion in
        AVCaptureDevice.requestAccess(for: .audio, completionHandler: completion)
      },
      policy: MicRequestPolicy(fileURL: MicRequestPolicy.defaultFileURL()),
      timeout: Self.micRequestTimeout
    )
    hotkeys = HotkeyService(
      doubleTapMaxInterval: config.doubleAltMaxInterval,
      logLevel: config.logLevel
    )
    // Cookie-relay layer only for transport = "cookie-relay" (legacy aliases
    // of the old config are canonicalized at parse; root key or active
    // provider section: resolveActiveProvider already copied it into the
    // effective config). nil — previous behavior.
    let cookieRelayProvider =
      config.transport == "cookie-relay"
      ? CookieRelayProvider.makeForCookieRelay(baseURL: config.baseURL)
      : nil
    // Single registry of cookie-relay providers by baseURL (the cookie is
    // issued for the proxy origin; the same baseURL → same origin → same
    // instance). Key: the registry is built ONCE in init and only read in the
    // closure — no races; failover/retry reuse THE SAME instance as the main
    // path, with its warmed token (otherwise the first retry request would go
    // without a cookie on an extra challenge roundtrip).
    var cookieRelayByURL: [String: CookieRelayProvider] = [:]
    if let cookieRelayProvider {
      cookieRelayByURL[config.baseURL] = cookieRelayProvider
    }
    for retryCandidate in config.providers {
      let transport = retryCandidate.transport.isEmpty ? config.transport : retryCandidate.transport
      guard
        transport == "cookie-relay", cookieRelayByURL[retryCandidate.baseURL] == nil,
        let made = CookieRelayProvider.makeForCookieRelay(baseURL: retryCandidate.baseURL)
      else { continue }
      cookieRelayByURL[retryCandidate.baseURL] = made
    }
    let retryTransport = { (provider: AppConfig.Provider) -> CookieRelayProvider? in
      let transport = provider.transport.isEmpty ? config.transport : provider.transport
      guard transport == "cookie-relay" else { return nil }
      return cookieRelayByURL[provider.baseURL]
    }
    // Active provider: explicit active_provider, or (documented "sections only,
    // no active_provider" scenario) the first provider in order. It decides
    // WHO is excluded from the failover queue and which adapter the main
    // request path uses: re-picking a main-provider failure on auto-failover
    // is not allowed.
    activeProviderID =
      config.activeProvider.isEmpty
      ? config.providers.first?.id
      : config.activeProvider
    failoverCandidates = config.failoverProviders(excluding: activeProviderID)
    var byID: [String: AppConfig.Provider] = [:]
    for provider in config.providers {
      byID[provider.id] = provider
    }
    providersByID = byID
    // Single Transcriber builder from provider-section fields + SHARED config
    // settings (language/timeout/log_level/root proxyKeyHeader): the active
    // path, failover/retry and routing roles all go through it — retries and
    // roles behave like the main path (same language, timeout, log level).
    // Provider id goes to adapterID — a known provider gets its request format
    // (groq/cloudflare), unknown — OpenAI-compatible with its own
    // base_url/model from the section.
    // Env key NANODICTATE_API_KEY is scoped to the ACTIVE provider
    // (resolveAPIKey + activeProviderID): failover candidates and routing
    // roles go through this same builder and get THEIR OWN key
    // (api_key/api_key_file); a role/candidate provider without its own key
    // gets empty — the request fails normally, not sneaking an env key.
    // Local copy of the active id for the closure: referencing
    // self.activeProviderID inside the closure is impossible — self is not
    // fully initialized before super.init (retryProvider/roles assigned
    // below), and the closure is captured by the makeTranscriber property.
    let builderActiveID = activeProviderID
    let makeTranscriber = { (provider: AppConfig.Provider) -> Transcriber in
      Transcriber(
        baseURL: provider.baseURL,
        model: provider.model,
        apiKey: RetryProvider.resolveAPIKey(for: provider, activeProviderID: builderActiveID),
        proxyKey: provider.proxyKey,
        proxyKeyHeader: provider.proxyKeyHeader.isEmpty
          ? config.proxyKeyHeader : provider.proxyKeyHeader,
        language: config.language,
        timeout: config.timeoutSeconds,
        logLevel: config.logLevel,
        cookieRelayProvider: retryTransport(provider),
        httpProxy: provider.httpProxy.isEmpty ? config.httpProxy : provider.httpProxy,
        proxyUser: provider.proxyUser.isEmpty ? config.proxyUser : provider.proxyUser,
        proxyPassword: provider.proxyPassword.isEmpty
          ? config.proxyPassword : provider.proxyPassword,
        adapterID: provider.id
      )
    }
    self.makeTranscriber = makeTranscriber
    // The active transcriber — by the active provider's section through the
    // same builder (unified logic with failover/retry/roles). A legacy
    // config (without sections) — exactly the previous construction from the
    // effective fields.
    if let activeID = activeProviderID, let activeProvider = byID[activeID] {
      transcriber = makeTranscriber(activeProvider)
    } else {
      transcriber = Transcriber(
        baseURL: config.baseURL,
        model: config.model,
        apiKey: config.apiKey,
        proxyKey: config.proxyKey,
        proxyKeyHeader: config.proxyKeyHeader,
        language: config.language,
        timeout: config.timeoutSeconds,
        logLevel: config.logLevel,
        cookieRelayProvider: cookieRelayProvider,
        httpProxy: config.httpProxy,
        proxyUser: config.proxyUser,
        proxyPassword: config.proxyPassword,
        adapterID: activeProviderID
      )
    }
    // Routing roles from [routing]: resolvers fall back to the active provider;
    // empty id (legacy config) → nil — role unused, exactly current behavior.
    let segmentRoleID = config.segmentProviderID()
    segmentRoleProviderID = segmentRoleID.isEmpty ? nil : segmentRoleID
    let finalRoleID = config.finalProviderID()
    finalRoleProviderID = finalRoleID.isEmpty ? nil : finalRoleID
    insertMethod = config.insertMethod
    autoFailover = config.autoFailover
    reviewBeforeInsert = config.reviewBeforeInsert
    // Failover/retry recognizes BY PROVIDER SECTION through the same builder
    // (see above): retries behave like the main path.
    retryProvider = RetryProvider { wav, provider in
      let transcriber = makeTranscriber(provider)
      return try await transcriber.transcribe(wav: wav)
    }
    super.init()

    // Cookie-relay token warm-up: first Alt+Alt must not go out with a stale or
    // empty cookie — background token prep starts right away (non-blocking).
    if let cookieRelayProvider {
      Task { _ = await cookieRelayProvider.refreshBlocking() }
    }

    audio.levelDelegate = self
    hotkeys.delegate = self

    // Forced stop on the hard limit (60 s) goes the same way as a normal stop:
    // samples → WAV → transcription.
    audio.onRecordingLimitReached = { [weak self] samples in
      DispatchQueue.main.async {
        self?.handleRecordingLimitReached(samples: samples)
      }
    }

    // Auto-stop on continuous silence (~3 s): equivalent to a repeated Alt+Alt
    // without a press — recording stops inside AudioService, here only sample
    // finalization through the same standard path.
    audio.onAutoStop = { [weak self] samples in
      DispatchQueue.main.async {
        self?.handleAutoStop(samples: samples)
      }
    }

    // Audio device changed mid-recording (headphones unplugged, default
    // output switched): AudioService already stopped the engine — end the
    // loop with an error instead of leaving the state stuck in recording.
    audio.onDeviceChange = { [weak self] error in
      DispatchQueue.main.async {
        self?.handleDeviceChange(error)
      }
    }

    // Manual retry from nanodictate: "Re-transcribe with another provider".
    // CLI posts a distributed notification — the agent picks up its in-memory
    // lastWAV (availability and insertion — as in the normal loop).
    retryObserver = DistributedNotificationCenter.default().addObserver(
      forName: Notification.Name("com.nanodictate.agent.retryRequest"),
      object: nil,
      queue: .main
    ) { [weak self] notification in
      guard let self else { return }
      guard
        let userInfo = notification.userInfo,
        let providerID = userInfo["provider"] as? String,
        let provider = self.providersByID[providerID]
      else {
        Logger.log("retry request ignored: unknown provider payload", level: "error")
        return
      }
      self.handleRetryRequest(provider: provider)
    }
  }

  func start() throws {
    try hotkeys.start()
  }

  // MARK: - Accessibility grant

  /// Starts the hotkey if the Accessibility grant is already given; otherwise
  /// polls AXIsProcessTrusted() every 2 seconds until the user enables it —
  /// then starts the hotkey and stops polling. Without the grant — quiet status
  /// and opening the system panel with rate limit
  /// (openAccessibilitySettingsIfDue, at most once per 10 min; stamp persists
  /// in UserDefaults — a background respawn does not reopen the panel).
  func startWithAccessibilityRequest() throws {
    if AXIsProcessTrusted() {
      try start()
      Logger.log("Hotkey service started", level: "info")
      return
    }

    // No error sound: a missing grant at start/respawn is not a mic failure
    // but a wait for the user (KeepAlive respawns must not play Basso). The
    // overlay status hints what to enable; the panel opens itself (at most
    // once per 10 min), and an explicit Alt+Alt is needed only when the grant
    // is revoked mid-flight.
    Logger.log(L10n.tr("error.accessibilityRequired"), level: "info")
    overlay.setStatus(L10n.tr("error.accessibilityRequired"))
    hideAfter(2.0, reason: "accessibility required")
    openAccessibilitySettingsIfDue()

    // Auto-pickup of the grant: poll every 2 seconds on the main thread.
    accessibilityPollTimer?.invalidate()
    accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) {
      [weak self] timer in  // swiftlint:disable:this closure_parameter_position
      guard let self else {
        timer.invalidate()
        return
      }
      guard AXIsProcessTrusted() else { return }
      timer.invalidate()
      if self.accessibilityPollTimer === timer {
        self.accessibilityPollTimer = nil
      }
      do {
        try self.start()
        Logger.log("Hotkey service started", level: "info")
      } catch {
        Logger.log("hotkey service failed to start: \(error.localizedDescription)", level: "error")
      }
    }
    guard let pollTimer = accessibilityPollTimer else { return }
    RunLoop.main.add(pollTimer, forMode: .common)
  }

  /// Opens the system panel "Privacy & Security → Accessibility" — at
  /// start/respawn without the grant (see startWithAccessibilityRequest), at
  /// most once per accessibilityPanelCooldown. Last open stamp lives in
  /// UserDefaults: an agent respawn (KeepAlive) resets memory, and without
  /// persistence the panel would open on EVERY respawn — window spam with a
  /// missing grant.
  private func openAccessibilitySettingsIfDue() {
    // Debug entry marker: the start/respawn branch (startWithAccessibilityRequest)
    // is thus visible in the log even when the open below is suppressed.
    if isDebug {
      Logger.log("accessibility settings open requested", level: "debug")
    }
    let now = CFAbsoluteTimeGetCurrent()
    let defaults = UserDefaults.standard
    // Missing stamp (double == 0) means "never opened":
    // now - 0 is certainly above the cooldown.
    let lastOpen = defaults.double(forKey: Self.lastAccessibilityPanelOpenAtKey)
    guard now - lastOpen >= Self.accessibilityPanelCooldown else {
      // Info, not debug: at the default log level the user must be able to
      // tell a suppressed panel from a freshly opened one; the remaining
      // seconds name the reason (cooldown not elapsed).
      Logger.log(
        "accessibility settings panel suppressed (last opened \(Int(lastOpen)), "
          + "retry in \(Int(Self.accessibilityPanelCooldown - (now - lastOpen))) s)",
        level: "info")
      return
    }
    // Panel opens the way Karabiner and similar apps do. Static string literal
    // is guaranteed valid on macOS 12+.
    guard
      let url = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    else { return }
    // Stamp only a successful open; a failed open keeps the cooldown free so
    // the next start/respawn can retry.
    guard NSWorkspace.shared.open(url) else {
      Logger.log(
        "accessibility settings panel open failed (NSWorkspace.shared.open returned false)",
        level: "error")
      return
    }
    defaults.set(now, forKey: Self.lastAccessibilityPanelOpenAtKey)
    Logger.log("accessibility settings panel opened", level: "info")
  }

  // MARK: - HotkeyDelegate

  func altDoubleTapped() {
    DispatchQueue.main.async {
      self.handleAltDoubleTap()
    }
  }

  func cancelKeyPressed() {
    DispatchQueue.main.async {
      self.handleCancel()
    }
  }

  func enterKeyPressed() {
    DispatchQueue.main.async {
      self.handleEnterKeyPressed()
    }
  }

  /// Synchronous swallowing predicate for a physical Return: outside .idle
  /// (recording or recognizing) — swallow. Exception: while the review gate
  /// waits for the terminal decision (awaitingReviewDecision) the physical
  /// Return must pass through — the terminal's readLine needs it. Our own
  /// synthetic Return is NOT excluded here: posting marks the event with
  /// SyntheticReturnMarker, and HotkeyService does not swallow it by the
  /// event field — a synchronous flag would be gone by the tap's next visit
  /// (event reaches .cgSessionEventTap on the next run-loop iteration).
  /// Called from the event tap on the main run loop — no state races.
  func shouldSwallowReturnKeyEvent() -> Bool {
    state != .idle && !awaitingReviewDecision
  }

  // MARK: - AudioLevelDelegate

  func audioLevelChanged(rms: Float) {
    // installTap callback runs on the audio thread — hop to main,
    // since overlay.updateLevel touches SwiftUI @Published.
    DispatchQueue.main.async {
      self.overlay.updateLevel(rms)
    }
  }

  // MARK: - Handlers

  private var isDebug: Bool {
    logLevel.lowercased() == "debug"
  }

  private func handleAltDoubleTap() {
    // Without the Accessibility grant the agent can neither hear Alt+Alt nor
    // post keys — recording is useless. An explicit user action (hotkey press
    // with a missing grant) prompts the system dialog (see the guard below)
    // plus a clear message; at start/respawn the settings panel opens with
    // its own rate limit (see startWithAccessibilityRequest).
    guard AXIsProcessTrusted() else {
      // "Not yet granted" case on an explicit user action: plain
      // AXIsProcessTrusted() alone never surfaces a prompt, so Alt+Alt was
      // silently dead. AXIsProcessTrustedWithOptions + kAXTrustedCheckOptionPrompt
      // makes macOS show the "…would like to control this computer using
      // accessibility features" dialog. The dialog is the prompt for "not yet
      // granted"; the rate-limited Settings deep link
      // (openAccessibilitySettingsIfDue, at most once per 10 min) serves the
      // same missing-grant case at start/respawn (startWithAccessibilityRequest)
      // and is deliberately not opened right after the dialog — the dialog
      // already offers to open System Settings.
      AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
      showMicrophoneError(L10n.tr("error.accessibilityRequired"))
      return
    }
    if isDebug {
      Logger.log("Alt+Alt handled: state=\(String(describing: state))", level: "debug")
    }
    switch state {
    case .idle:
      // Undo window: a second Alt within undoMaxInterval after a successful
      // insert (state = .idle) erases the inserted text. In every other state
      // Alt behaves as before (see .recording).
      if NanoDictateFlow.shouldUndoInsteadOfStart(
        state: state,
        lastInsertedAt: lastInsertedAt,
        now: CFAbsoluteTimeGetCurrent(),
        undoWindow: undoMaxInterval
      ) {
        undoLastInsertion()
      } else {
        requestMicrophoneAndStart()
      }
    case .recording:
      if chunked {
        // Live dictation: stop (hands the tail to liveExecutor) +
        // final pass over the whole WAV (same path as processChunked).
        liveFinalize()
      } else {
        sendRecording()
      }
    case .transcribing:
      // Busy sending — ignore.
      break
    }
  }

  /// Enter/Keypad Enter: during .recording — stop recording and start
  /// recognition (like the second Alt in .recording: chunked → liveFinalize,
  /// else sendRecording) + latch of EXACTLY ONE synthetic Enter after text
  /// insertion. During .transcribing — no-op (spec: repeated Enter does not
  /// increment the latch, no second Enter posted). Never lands in .idle: the
  /// tap passes a physical Enter through (swallow predicate = false), the
  /// .idle branch is a safety net.
  private func handleEnterKeyPressed() {
    if isDebug {
      Logger.log("Enter handled: state=\(String(describing: state))", level: "debug")
    }
    switch state {
    case .recording:
      enterSendLatch.arm()
      if chunked {
        liveFinalize()
      } else {
        sendRecording()
      }
    case .transcribing:
      // Spec item 3: Enter during recognition does not react.
      break
    case .idle:
      break
    }
  }

  /// Synthetic-Enter point: called AFTER a successful text insertion
  /// (completeInsertion / completeChunkedInsertion / retryInsertion). If the
  /// latch is armed — consume it (one-shot) and after ~250 ms pause (target
  /// app has time to process the inserted text) post a synthetic Return
  /// (keyDown + keyUp) to the focused app. After posting the latch is clear.
  /// Silence auto-stop and the duration limit never arm the latch — they do
  /// not arrive here with a pending latch. Scheduling lives in
  /// ScheduledEnterPoster: Esc cancels an ALREADY scheduled post.
  private func postSyntheticReturnIfPending() {
    guard enterSendLatch.consume() else { return }
    // No self in the closure: posting and log are static. Agent lives the
    // whole process, Poster is its own — no retain cycle.
    scheduledEnterPoster.action = {
      // Event is stamped with SyntheticReturnMarker BEFORE posting: our
      // session tap sees the synthetic Return again on the next run-loop
      // iteration and by the event field neither swallows it (reaches the
      // app) nor duplicates enterKeyPressed (will not stop a new recording
      // started in the pause window).
      Inserter.postReturnKeyDownUp()
      Logger.log("synthetic Enter posted after Enter-stop insert", level: "info")
    }
    scheduledEnterPoster.schedule()
  }

  // MARK: - Recording

  /// Pre-flight: mic access check before the engine starts. We do not request
  /// access forcibly from under launchd (the request window may not appear):
  /// only check status, and for .notDetermined try to request — on granted,
  /// start recording.
  /// The whole "request permission → message pops out → hang" mechanics is
  /// in Core (MicAccessRequester); here only logging and reacting to the
  /// outcome:
  /// 1) repeated Alt+Alt while the TCC dialog hangs does not open a second
  ///    request (isInFlight in the coordinator);
  /// 2) micRequestTimeout watchdog: if the requestAccess callback never fires
  ///    (a bundle-less background agent may not show the window) — terminal
  ///    error in the overlay instead of endless waiting; a late granted after
  ///    timeout is dropped by session token (recording does not start under an
  ///    already-shown error, the storm counter does not reset);
  /// 3) .denied/.restricted branches give a clear message and do NOT touch the
  ///    engine;
  /// 4) MicRequestPolicy anti-storm: after 3 timeouts in a 6 h window the
  ///    access request does not open at all (repeat presses do not spawn
  ///    tccd-wedging dialogs) — instead a clear instruction; the next Alt+Alt
  ///    tries again until the grant appears manually.
  private func requestMicrophoneAndStart() {
    let status = AVCaptureDevice.authorizationStatus(for: .audio)
    // Every mic access request is logged: the check itself, the current TCC
    // status, and the system dialog result (granted/denied).
    Logger.log("mic permission check: \(MicrophoneAuth.statusText(status))", level: "info")
    // Repeated Alt+Alt while the dialog hangs — only a log, no second request
    // (the coordinator's internal guard does the same; here it is for a
    // readable message).
    guard !micAccessRequester.isInFlight else {
      Logger.log("mic permission request already in flight — ignoring Alt+Alt", level: "info")
      // The system request can stay unresolved forever (watchdog `.timedOut`
      // leaves isInFlight true): show the instruction instead of silent drops —
      // MicErrorCooldown limits it to one message per 3 s.
      showMicrophoneError(L10n.tr("error.micPermissionUnhandled"))
      return
    }
    micAccessRequester.requestIfNeeded { [weak self] outcome in
      guard let self else { return }
      switch outcome {
      case .granted:
        Logger.log("mic permission request result: granted", level: "info")
        self.startRecording()
      case .denied:
        Logger.log("mic permission request result: denied", level: "info")
        self.showMicrophoneError(L10n.tr("error.micPermission"))
      case .timedOut:
        Logger.log(
          "mic permission request timed out after \(Int(Self.micRequestTimeout)) s", level: "error")
        self.showMicrophoneError(L10n.tr("error.micPermissionUnhandled"))
      case .suppressedByPolicy:
        Logger.log(
          "mic permission request suppressed: \(MicRequestPolicy.maxTimeoutsInWindow) timeouts within "
            + "\(Int(MicRequestPolicy.windowDuration / 3600)) h",
          level: "error"
        )
        self.showMicrophoneError(L10n.tr("error.micPermissionUnhandled"))
      }
    }
  }

  /// Recording start logic: moves the agent to .recording.
  /// Panel shows here and stays the WHOLE record/recognize loop; hide() is
  /// called only from terminal points (stop/error/insert). Engine boot is
  /// async (AudioService.start(completion:) on a background queue, completion
  /// on main) + recordStartTimeout watchdog: a hung engine gives a terminal
  /// error, not an endless overlay.
  private func startRecording() {
    guard !isStarting else {
      Logger.log("record start ignored: already starting", level: "info")
      return
    }
    sounds.playStart()
    overlay.show()
    // Label "what recognition goes through" ("<provider> · <model>") — from
    // THE SAME resolved provider the session transcriber was built with in
    // init (resolvedConfig): single source of truth, config not re-read here.
    overlay.setSTTLabel(RecognitionLabel.forSession(resolvedConfig))
    // "Recording" phase: mic + timer, start time fixed here.
    overlay.setRecordingPhase()
    overlay.setStatus(L10n.tr("overlay.recording"))
    Logger.log("record start")

    isStarting = true
    startSession += 1
    let session = startSession

    // Engine boot watchdog: if the engine does not start within
    // recordStartTimeout — terminal error (overlay goes out, next Alt+Alt
    // works). startSession increments here too: a delayed start completion
    // (engine did boot later) sees the token mismatch.
    // audio.cancel() is intentionally NOT called here: its teardown would go
    // to the hung engine's queue (blocked forever), and a start that unlocked
    // AFTER the swap would run it WITHOUT a generation guard — setRecording(
    // false)/buffer reset/tapInstalled=false would kill a live new session on
    // the fresh engine. The old engine is dismantled by the wedge (stop on the
    // global queue) and by the stale start itself (terminal branch
    // teardownEngineOnly, .failure(.engineSuperseded)); the new session state
    // (isRecording/buffers) is reinitialized by the new session's start.
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.recordStartTimeout) { [weak self] in
      guard let self, self.startSession == session, self.isStarting else { return }
      Logger.log("record start timed out after \(Int(Self.recordStartTimeout)) s", level: "error")
      self.startSession += 1
      self.isStarting = false
      // The wedged engine is replaced with a fresh one: engine.start() may
      // never have returned (HAL blocked by a device switch) — the old
      // instance is unusable, the next Alt+Alt starts from a clean engine.
      self.audio.replaceEngineAfterWedge()
      Logger.log("record start recovery: wedged engine replaced", level: "info")
      self.showMicrophoneError(L10n.tr("error.micNoResponse"))
    }

    audio.start { [weak self] result in
      guard let self else { return }
      guard self.startSession == session else {
        // Start finished after the watchdog (or a new loop began).
        // If the engine did boot — do not leave recording hanging.
        // cancel() here runs ONLY when the engine that started recording is
        // still current: starts that unlocked AFTER the wedge swap are
        // flagged by AudioService itself (.failure(.engineSuperseded), see
        // AudioService.startOnEngineQueue) and never reach .success —
        // otherwise cancel() would kill a live new session on the fresh engine.
        if case .success = result {
          self.audio.cancel()
        }
        return
      }
      self.isStarting = false
      switch result {
      case .success:
        self.state = .recording
        if self.chunked {
          // Live dictation: each utterance (pause ≥ pauseDuration) is
          // recognized and inserted on the fly; by the time of Alt+Alt the
          // text is already partly in the input field.
          self.subscribeLiveNanoDictate()
        }
        if self.isDebug {
          Logger.log("record started: state = .recording", level: "debug")
        }
      case .failure(let error):
        Logger.log("microphone unavailable: \(error.localizedDescription)", level: "error")
        self.showMicrophoneError(L10n.tr("error.micEnableFailed"))
      }
    }
  }

  /// Terminal mic error: clear message in the overlay + error sound (Basso).
  /// One hide point — overlay goes out, state already .idle, the next Alt+Alt
  /// starts a new loop.
  private func showMicrophoneError(_ message: String) {
    // Cooldown: repeated Alt+Alt in a broken state (denied / silent engine)
    // must not replay the error sound and redraw the overlay — otherwise every
    // press plays Basso and flashes the panel. The cooldown suppresses ONLY
    // the sound and message; hide below is always: a panel shown by a failed
    // startRecording does not hang with the "Recording…" status until the next
    // Alt+Alt.
    let showFeedback = micErrorCooldown.allow(at: CFAbsoluteTimeGetCurrent())
    if showFeedback {
      overlay.setStatus(message)
      sounds.playError()
    } else if isDebug {
      Logger.log("mic error suppressed (cooldown active)", level: "debug")
    }
    hideAfter(2.0, reason: "mic failed")
  }

  private func sendRecording() {
    let samples = audio.stop()
    if isDebug {
      Logger.log("record stopped by user: \(samples.count) samples collected", level: "debug")
    }
    processSamples(samples)
  }

  /// Standard recording finalization path: samples → WAV → transcription.
  /// Called both on user stop and after the forced duration limit
  /// (see `onRecordingLimitReached`).
  private func processSamples(_ samples: [Int16]) {
    if chunked {
      processChunked(samples)
      return
    }
    processSingleRequest(samples)
  }

  /// Standard recording finalization path: samples → WAV → ONE transcription.
  /// Exactly current behavior (regression path at chunked = false).
  // swiftlint:disable:next function_body_length
  private func processSingleRequest(_ samples: [Int16]) {
    state = .transcribing
    // New loop — previous recognition's cancel token does not apply.
    cancelRecognition = false
    // "Processing" phase: dots animation instead of the icon while STT runs.
    overlay.setProcessingPhase()
    overlay.setStatus(L10n.tr("overlay.recognizing"))
    // Duration from actually collected samples (16 kHz mono) — shows in which
    // units audio goes to STT. The finish sound plays NOT here but in
    // completeInsertion AFTER text insertion.
    let duration = Double(samples.count) / 16000.0
    Logger.log(
      String(format: "transcribe submit (\(samples.count) samples, %.2f s)", duration),
      level: "info")

    // What exactly goes to the LLM: duration + RMS level + "near-silence" flag.
    // Metrology only at log_level == "debug" (no spam).
    if logLevel.lowercased() == "debug" {
      let rms = AudioMetrics.rms(samples: samples)
      let nearSilence = AudioMetrics.isNearSilence(avgRMS: rms)
      let inputMetrics = String(
        format: "STT input: duration=%.2f s, rms=%.4f (%.1f dBFS), nearSilence=%@",
        duration,
        Double(rms),
        Double(AudioMetrics.dbfs(rms)),
        nearSilence ? "true" : "false"
      )
      Logger.log(inputMetrics, level: "debug")
    }

    // Watchdog of the "processing" phase: the dots animation cannot outlive
    // the hard request timeout plus a small margin (processingMaxDuration).
    // If STT has not finished by then (network hung, transport silent) — end
    // the loop ourselves, with the "STT timeout" message. The session token
    // keeps an old loop's watchdog from cutting a new one (the user already
    // started a new dictation); the state == .transcribing check makes the
    // watchdog a no-op after any terminal event.
    processingSession += 1
    let session = processingSession
    // Auto-failover runs the candidates (parallel) AFTER the primary request
    // timeout: the processing watchdog needs one more networkRequestTimeout
    // as margin, else it would cut a valid failover mid-flight.
    let watchdogDuration =
      OverlayController.processingMaxDuration
      + (autoFailover && !failoverCandidates.isEmpty ? Transcriber.networkRequestTimeout : 0)
    DispatchQueue.main.asyncAfter(deadline: .now() + watchdogDuration) {
      [weak self] in  // swiftlint:disable:this closure_parameter_position
      guard
        let self,
        self.processingSession == session,
        self.state == .transcribing
      else { return }
      self.failTranscription(Transcriber.sttTimeoutMessage, isNetworkFailure: true)
    }

    Task { [weak self] in
      guard let self else { return }

      // Same guard as the watchdog above: the "processing" session fixed at
      // send time. If by the end of the Task the session changed (new
      // dictation) or the loop already ended with a terminal event (the
      // "STT timeout" watchdog set state to .idle) — terminal calls become
      // no-ops; a repeated failTranscription/completeInsertion is impossible.
      let wav = WAVEncoder.encode(samples: samples)
      // Last WAV kept in memory (RetryProvider): manual retry with another
      // provider (`nanodictate retry`) and auto-failover reuse it.
      self.retryProvider.store(wav: wav)

      do {
        let (result, providerID) = try await self.transcribeAutomatically(wav: wav)
        if let providerID {
          Logger.log("transcription succeeded via failover provider '\(providerID)'", level: "info")
        }
        let text = TextRefinement.finalize(result.text)

        DispatchQueue.main.async {
          // Delivery guard: the "processing" session is active (token
          // matched, state still .transcribing) AND recognition not cancelled
          // by Esc. Esc cancel sets cancelRecognition and moves state to
          // .idle — text will not be inserted.
          guard
            NanoDictateFlow.shouldDeliverResult(
              isCancelled: self.cancelRecognition,
              sessionActive: self.processingSession == session && self.state == .transcribing
            )
          else { return }
          self.completeInsertion(text)
        }
      } catch {
        let networkText = OverlayErrorText.text(for: error)
        let message = networkText ?? Self.message(for: error)
        DispatchQueue.main.async {
          guard
            self.processingSession == session,
            self.state == .transcribing
          else { return }
          self.failTranscription(message, isNetworkFailure: networkText != nil)
        }
      }
    }
  }

  /// Step dictation (chunked = true): VAD segmentation of the recording → each
  /// segment as a request (prompt = already-recognized text) → incremental
  /// insert → final pass over the whole WAV in one request → word diff →
  /// replacement of the changed range in a single action.
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func processChunked(_ samples: [Int16]) {
    state = .transcribing
    // New loop — previous recognition's cancel token does not apply
    // (same reset as in processSingleRequest).
    cancelRecognition = false
    overlay.setProcessingPhase()
    overlay.setStatus(L10n.tr("overlay.recognizing"))
    sounds.playEnd()
    let duration = Double(samples.count) / 16000.0
    Logger.log(
      String(format: "chunked transcribe submit (\(samples.count) samples, %.2f s)", duration),
      level: "info")

    // "Processing" phase watchdog: several segments + final pass — each
    // request up to networkRequestTimeout; the guard counts by request number
    // (N segments, count > 1 ⇒ one more final). Same session-token mechanism
    // as processSingleRequest.
    let segments = AudioSegmenter.segments(samples: samples)
    let requestCount = segments.count <= 1 ? 1 : segments.count + 1
    let chunkedMaxDuration = Double(requestCount) * Transcriber.networkRequestTimeout + 5

    processingSession += 1
    let session = processingSession
    DispatchQueue.main.asyncAfter(deadline: .now() + chunkedMaxDuration) { [weak self] in
      guard
        let self,
        self.processingSession == session,
        self.state == .transcribing
      else { return }
      self.failTranscription(Transcriber.sttTimeoutMessage, isNetworkFailure: true)
    }

    Task { [weak self] in
      guard let self else { return }
      do {
        let outcome = try await ChunkedPipeline().run(
          samples: samples,
          stt: { wav, filename, prompt in
            // Roles from [routing]: segments (filename "segment-N.wav") go to
            // segment_provider, the final pass over the whole WAV
            // ("final.wav") — final_provider. Role unset (= fallback to the
            // active one) — active transcriber, exactly current behavior.
            // No failover on roles — the role provider is used directly.
            // A segment failure aborts the whole run (ChunkedPipeline.run
            // does not catch segment errors); no final pass then.
            let selected: Transcriber
            if filename == "final.wav" {
              selected = self.roleTranscriber(self.finalRoleProviderID) ?? self.transcriber
            } else {
              selected = self.roleTranscriber(self.segmentRoleProviderID) ?? self.transcriber
            }
            let result = try await selected.transcribe(wav: wav, filename: filename, prompt: prompt)
            return ChunkedPipeline.SttResult(text: result.text, words: result.words)
          },
          insert: { operation in
            DispatchQueue.main.async {
              // Same session guard as in the single path: if the
              // "processing" session changed or the loop ended with a
              // terminal event — insert/status is a no-op.
              guard
                self.processingSession == session,
                self.state == .transcribing
              else { return }
              switch operation {
              case let .appendSegment(index, text):
                Inserter.append(text)
                Logger.log(
                  "chunked append segment \(index + 1) (\(text.count) chars)", level: "info")
              case let .replaceTail(old, new):
                Inserter.replaceRange(old: old, new: new)
                Logger.log(
                  "chunked final replace: backspace \(old.count) chars, type \(new.count) chars",
                  level: "info"
                )
              }
            }
          },
          onPhase: { phase in
            DispatchQueue.main.async {
              // Guard against an old loop overwriting the new dictation's
              // status or a terminal message.
              guard
                self.processingSession == session,
                self.state == .transcribing
              else { return }
              switch phase {
              case .segment(let index):
                let recognizingTemplate = L10n.tr("overlay.recognizingPart")
                let recognizingStatus = recognizingTemplate.replacingOccurrences(
                  of: "{n}", with: "\(index + 1)")
                self.overlay.setStatus(recognizingStatus)
              case .finalizing:
                self.overlay.setStatus(L10n.tr("overlay.finalProcessing"))
              }
            }
          }
        )
        DispatchQueue.main.async {
          guard
            self.processingSession == session,
            self.state == .transcribing
          else { return }
          self.completeChunkedInsertion(outcome: outcome)
        }
      } catch {
        let networkText = OverlayErrorText.text(for: error)
        let message = networkText ?? Self.message(for: error)
        DispatchQueue.main.async {
          guard
            self.processingSession == session,
            self.state == .transcribing
          else { return }
          self.failTranscription(message, isNetworkFailure: networkText != nil)
        }
      }
    }
  }

  /// Terminal point of the chunked loop: insertion was already done by the
  /// pipeline (append operations and the final replace), here — final UX
  /// decisions (synthesized with the main branch): undo bookkeeping gets the
  /// session's final text, the review gate confirms/cancels the already-typed
  /// result, an empty result goes the same way as in the single path
  /// (handleEmptyResult).
  private func completeChunkedInsertion(outcome: ChunkedPipeline.Outcome) {
    let text = outcome.insertedText

    // Empty result: the pipeline typed nothing (0 segments or empty
    // transcriptions) — separate "empty" sound, no undo window, exactly as in
    // the single path (completeInsertion).
    if NanoDictateFlow.outcome(for: text) == .empty {
      handleEmptyResult()
      return
    }

    // Review before insert (review_before_insert = true): a chunked session's
    // segments were already typed incrementally by the pipeline, so the gate
    // works as a final confirmation — on cancel the typed text is deleted
    // entirely (one delete action), no undo window then.
    if reviewBeforeInsert, hasInteractiveStdin {
      // CR16: confirmAsync reads stdin on a background serial queue and
      // delivers the Decision to the main queue — the hotkey event tap keeps
      // running while the user decides. State stays .transcribing (non-idle)
      // until the completion processes the decision in finishChunkedInsertion.
      // The token is advanced here: the STT work is done, so THIS loop's
      // processing watchdog must not cut the user's decision time (the sync
      // confirm parked it the same way by blocking the main run loop). The
      // completion re-validates against the advanced token.
      processingSession += 1
      let session = processingSession
      awaitingReviewDecision = true
      ReviewGate.confirmAsync(text: text) { [weak self] decision in
        guard
          let self,
          self.processingSession == session,
          self.state == .transcribing
        else { return }
        // The decision arrived — a physical Return may be swallowed again.
        self.awaitingReviewDecision = false
        // Re-validated above: Esc may have cancelled THIS loop (state → .idle)
        // while the user typed the decision — the chunked text must not be
        // finalized/cancelled then.
        self.finishChunkedInsertion(outcome: outcome, decision: decision)
      }
      return
    } else if reviewBeforeInsert {
      Logger.log(
        "review_before_insert включён, но stdin не терминал — ревью чанка пропущено", level: "info")
    }
    finishChunkedInsertion(outcome: outcome, decision: .insert)
  }

  /// Insertion continuation of completeChunkedInsertion, run after the review
  /// decision (or immediately when the gate is skipped): on cancel the typed
  /// text is deleted entirely (one delete action); on insert — the final UX
  /// decisions (undo bookkeeping gets the session's final text, final status,
  /// last-text marker, synthetic Enter).
  private func finishChunkedInsertion(
    outcome: ChunkedPipeline.Outcome,
    decision: ReviewGate.Decision
  ) {
    let text = outcome.insertedText
    switch decision {
    case .insert:
      break
    case .cancel:
      // Typed text erased, no insert — clear the synthetic-Enter latch
      // (see completeInsertion review-cancel).
      enterSendLatch.cancel()
      Inserter.delete(characters: text)
      overlay.resetPhase()
      overlay.setStatus(L10n.tr("overlay.cancelled"))
      hideAfter(0.8, reason: "chunked review cancelled")
      state = .idle
      Logger.log("chunked transcription cancelled by review gate")
      return
    }

    // Undo bookkeeping: a second Alt within undoMaxInterval erases the
    // chunked session's final text in one action.
    lastInsertedText = text
    lastInsertedAt = CFAbsoluteTimeGetCurrent()

    overlay.resetPhase()
    overlay.setStatus(L10n.tr("overlay.finishing"))
    sounds.playCompletionAfterInsert()
    hideAfter(0.8, reason: "chunked insert done")
    state = .idle
    Logger.log(
      "chunked transcription inserted: segments=\(outcome.segmentCount) finalized=\(outcome.finalized) "
        + "finalChanged=\(outcome.finalChanged) (\(text.count) chars)",
      level: "info"
    )
    // Marker for `nanodictate last` — the chunked session's final text:
    // persisted to the mode-0600 state file, NOT into agent.log (CWE-532).
    persistLastText(text)
    // Final piece inserted and finalized — only now the synthetic
    // Enter (not mid-stream of pieces).
    postSyntheticReturnIfPending()
  }

  /// Recording stopped by the hard limit (60 s / 960 000 samples) —
  /// finalize the collected samples the standard way.
  private func handleRecordingLimitReached(samples: [Int16]) {
    guard state == .recording else { return }
    Logger.log("record limit reached (\(samples.count) samples)", level: "info")
    if chunked {
      // Live dictation: the tail was already handed by onSpeechSegment BEFORE
      // this call (performForcedStop: tail → onRecordingLimitReached) and
      // stands first in liveExecutor; here — only the guard and the final
      // pass over the passed samples (no audio.stop()).
      liveFinalizeFromSamples(samples)
    } else {
      processSamples(samples)
    }
  }

  /// Recording auto-stopped on continuous silence (~3 s) — same path as a
  /// manual repeated Alt+Alt: finalize the collected samples.
  /// The detector lived in AudioService (the real buffer duration is known
  /// there), the callback arrives on the main queue; the live-dictation tail
  /// was already handed by onSpeechSegment before this call.
  private func handleAutoStop(samples: [Int16]) {
    guard state == .recording else { return }
    Logger.log("auto-stop by silence (\(samples.count) samples)", level: "info")
    if chunked {
      // Live dictation: the tail stands first in liveExecutor (tail was
      // delivered by onSpeechSegment before onAutoStop), here — the final
      // pass over the snapshot. No audio.stop(): AudioService already tears
      // the engine down its own way (teardown on engineQueue).
      liveFinalizeFromSamples(samples)
    } else {
      processSamples(samples)
    }
  }

  /// Audio device changed mid-recording: AudioService stopped the engine and
  /// handed the error here. The samples gathered so far are unusable — drop
  /// the live loop and end with an error status (the state must not stay
  /// .recording with a dead engine).
  private func handleDeviceChange(_ error: Error) {
    guard state == .recording else { return }
    Logger.log("audio device changed: \(error.localizedDescription)", level: "warn")
    // Invalidate the live loop: a segment being recognized on liveExecutor
    // right now will not insert (the liveSession guard in handleLiveSegment);
    // queued stale segments skip STT (isCancelled guard).
    liveSession += 1
    liveRunState?.isCancelled = true
    liveRunState = nil
    failTranscription(error.localizedDescription, isNetworkFailure: false)
  }

  // MARK: - Live dictation (chunked = true)

  /// Subscribes to live speech segments. The "who answers for segments today"
  /// logic is fixed AT DELIVERY TIME: the callback is replaced on every start,
  /// each captures its own run state, and a stale loop cannot service the new
  /// loop's segments (its run is cancelled; the entry guard drops them, and
  /// handleLiveSegment re-checks on the executor).
  private func subscribeLiveNanoDictate() {
    liveSession += 1
    liveRunState?.isCancelled = true
    let runState = LiveRunState(session: liveSession)
    liveRunState = runState
    audio.onSpeechSegment = { [weak self] segment, isTail in
      guard let self else { return }
      // Cancel guard: loop cancelled by Esc / device change / restart sets the
      // NSLock-protected isCancelled flag BEFORE the liveRunState reference is
      // dropped (LiveRunState.isCancelled is safe to read from the audio-tap
      // thread, unlike the main-only liveSession). Old-loop segments are
      // dropped here instead of racing the main-only liveSession counter.
      guard !runState.isCancelled else { return }
      self.liveExecutor.submit {
        await self.handleLiveSegment(segment, isTail: isTail, runState: runState)
      }
    }
  }

  /// Handles one delivered segment (live VAD or the tail). Always on
  /// liveExecutor — segments are recognized strictly in order, each next one's
  /// accumulated prompt includes all previous; the stop tail is guaranteed
  /// processed BEFORE the final pass.
  private func handleLiveSegment(
    _ segmentSamples: [Int16],
    isTail: Bool,
    runState: LiveRunState
  ) async {
    // Stale loop (Esc / device change / restart): do not send its audio to
    // STT — the queued segment would also hold the serial queue.
    guard !runState.isCancelled else { return }
    let index = runState.segmentCount

    // Overlay: "Recognizing… (part N)" while the segment's STT runs; the
    // recording phase stays (user still talks) — only status changes.
    DispatchQueue.main.async { [weak self] in
      guard
        let self,
        self.liveSession == runState.session,
        self.state == .recording || self.state == .transcribing
      else { return }
      self.overlay.setStatus(
        L10n.tr("overlay.recognizingPart").replacingOccurrences(of: "{n}", with: "\(index + 1)"))
    }

    do {
      // Same per-segment path as in offline chunking (ChunkedPipeline.
      // recognizeSegment): WAV → STT with prompt context → finalization.
      // No failover here — the final pass over the whole WAV recovers the
      // error (in offline chunking a segment failure, by contrast, aborts
      // the run).
      let result = try await ChunkedPipeline.recognizeSegment(
        samples: segmentSamples,
        index: index,
        insertedText: runState.insertedText,
        prompt: runState.promptParts.isEmpty
          ? nil : ChunkedPipeline.truncatedPrompt(runState.promptParts),
        stt: { wav, filename, prompt in
          // The segment role from [routing] — as in processChunked: the
          // segment provider; unset — active transcriber (no failover here
          // either — the final pass recovers).
          let transcriber = self.roleTranscriber(self.segmentRoleProviderID) ?? self.transcriber
          let segmentResult = try await transcriber.transcribe(
            wav: wav, filename: filename, prompt: prompt)
          return ChunkedPipeline.SttResult(text: segmentResult.text, words: segmentResult.words)
        },
        filename: "live-segment-\(index + 1).wav"
      )

      // Accumulation — on liveExecutor AFTER successful STT: only recognized
      // text enters the next segment's prompt and the final diff base.
      runState.insertedText += result.insertText
      runState.promptParts.append(result.promptText)
      runState.segmentCount += 1
      if isTail {
        runState.tailDelivered = true
      }

      DispatchQueue.main.async { [weak self] in
        guard
          let self,
          self.liveSession == runState.session,
          self.state == .recording || self.state == .transcribing
        else { return }
        // Incremental insert into the input field: "appears gradually".
        Inserter.append(result.insertText)
        Logger.log(
          "live append segment \(index + 1) (\(result.insertText.count) chars)", level: "info")
        // Status returns to the recording phase — except for the tail
        // (finalization runs: "Recognizing…" shows the guard/final pass).
        if self.state == .recording {
          self.overlay.setStatus(L10n.tr("overlay.recording"))
        }
      }
    } catch {
      let networkText = OverlayErrorText.text(for: error)
      let message = networkText ?? Self.message(for: error)
      Logger.log(
        "live segment \(index + 1) failed: \(message) — фраза «докрутится» финальным проходом",
        level: "error"
      )
      // A segment failure never interrupts dictation: the whole phrase (or
      // part of it) is recognized by the final pass over the WHOLE WAV at
      // commit.
      runState.anySegmentFailed = true
      // Remember the last failure text: if ALL segments fail (segmentCount
      // == 0, STT unavailable), the final pass ends with an explicit
      // failTranscription carrying this text, not an "Empty result".
      runState.lastErrorText = message
    }
  }

  /// Live dictation commit (2nd Alt): stop → the unclosed utterance's tail
  /// goes to liveExecutor (stands after unfinished segments) → final pass
  /// over the whole WAV → the common terminal path completeChunkedInsertion.
  private func liveFinalize() {
    guard state == .recording else { return }
    guard let runState = liveRunState else {
      // Logically unreachable (the subscription is set on successful start
      // together with state = .recording) — safety path into offline chunking.
      sendRecording()
      return
    }

    // "Processing" phase — as in processChunked: watchdog for the whole
    // loop, finish sound, recognizing status.
    state = .transcribing
    cancelRecognition = false
    overlay.setProcessingPhase()
    overlay.setStatus(L10n.tr("overlay.recognizing"))
    sounds.playEnd()

    // Synchronous stop: the unclosed utterance is handed by the callback
    // BEFORE stop() returns and stands first in liveExecutor's finalization
    // queue.
    let samples = audio.stop()
    let duration = Double(samples.count) / 16000.0
    Logger.log(
      String(format: "live finalize (\(samples.count) samples, %.2f s)", duration), level: "info")

    // "Processing" phase watchdog: queued/running segments + tail (already
    // submitted by stop()) + final pass — each request up to
    // networkRequestTimeout (margin for all).
    let requestCount = max(2, liveExecutor.pendingCount + 1)
    let liveMaxDuration = Double(requestCount) * Transcriber.networkRequestTimeout + 5
    processingSession += 1
    let session = processingSession
    DispatchQueue.main.asyncAfter(deadline: .now() + liveMaxDuration) { [weak self] in
      guard let self = self else { return }
      guard self.processingSession == session, self.state == .transcribing else { return }
      self.failTranscription(Transcriber.sttTimeoutMessage, isNetworkFailure: true)
    }

    liveExecutor.submit { [weak self] in
      guard let self else { return }
      await self.finishLiveRun(samples: samples, session: session, runState: runState)
    }
  }

  /// Finalization of a live loop on a forced stop (duration limit or
  /// auto-stop by silence ~3 s). The tail was already delivered by
  /// onSpeechSegment BEFORE this call (order in performForcedStop: tail →
  /// callback) and stands first in liveExecutor; here — only the guard and
  /// the final pass over the passed samples (no audio.stop()).
  private func liveFinalizeFromSamples(_ samples: [Int16]) {
    guard let runState = liveRunState else {
      processChunked(samples)
      return
    }
    state = .transcribing
    cancelRecognition = false
    overlay.setProcessingPhase()
    overlay.setStatus(L10n.tr("overlay.recognizing"))
    sounds.playEnd()
    let duration = Double(samples.count) / 16000.0
    Logger.log(
      String(format: "live limit finalize (\(samples.count) samples, %.2f s)", duration),
      level: "info")

    // Watchdog (same budget as liveFinalize): queued/running segments +
    // tail + final pass.
    let requestCount = max(2, liveExecutor.pendingCount + 1)
    let liveMaxDuration = Double(requestCount) * Transcriber.networkRequestTimeout + 5
    processingSession += 1
    let session = processingSession
    DispatchQueue.main.asyncAfter(deadline: .now() + liveMaxDuration) { [weak self] in
      guard let self = self else { return }
      guard self.processingSession == session, self.state == .transcribing else { return }
      self.failTranscription(Transcriber.sttTimeoutMessage, isNetworkFailure: true)
    }

    liveExecutor.submit { [weak self] in
      guard let self else { return }
      await self.finishLiveRun(samples: samples, session: session, runState: runState)
    }
  }

  /// Final pass of a live loop (always on liveExecutor, AFTER the tail and
  /// all segments — the serial queue guarantees the order). "One segment
  /// without pauses" — the only segment is the tail (covers the recording to
  /// its end) and no segment failed: a double STT request is not needed
  /// (nothing to "polish"). Otherwise — the static helper
  /// ChunkedPipeline.finalize (the same path as in offline chunking):
  /// word-diff → replace one range.
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func finishLiveRun(samples: [Int16], session: Int, runState: LiveRunState) async {
    // A cancelled run (Esc / device change / new recording started) must not
    // send its audio to STT: the final pass would hold the serial liveExecutor
    // while a new recording's segments wait behind it. handleLiveSegment's
    // isCancelled guard blocks segment inserts the same way.
    guard !runState.isCancelled else { return }
    // Empty recording — no extra STT request (reachable only in a contrived
    // process, but symmetric to offline chunking).
    if runState.segmentCount == 0 {
      // Full failure of all segments (STT unavailable: disconnected network /
      // provider): the user actually spoke, but no segment was recognized.
      // This is an STT error, NOT an "empty dictation" — an explicit
      // failTranscription with the last error text (as agreed with offline
      // chunking, review #112), not a masking "Empty result" failure
      // (Funk sound).
      if runState.anySegmentFailed {
        // Text is remembered in the catch of handleLiveSegment; fallback
        // for the unreachable case — the standard timeout message.
        let message = runState.lastErrorText ?? Transcriber.sttTimeoutMessage
        DispatchQueue.main.async {
          guard self.processingSession == session, self.state == .transcribing else { return }
          self.failTranscription(message, isNetworkFailure: true)
        }
        return
      }
      let outcome = ChunkedPipeline.Outcome(
        segmentCount: 0, insertedText: "", finalized: false, finalChanged: false
      )
      DispatchQueue.main.async {
        guard self.processingSession == session, self.state == .transcribing else { return }
        self.completeChunkedInsertion(outcome: outcome)
      }
      return
    }

    // Single segment + the tail covers the recording to its end + no
    // failures — skip the final pass.
    // swiftformat:disable:next andOperator
    if runState.segmentCount == 1 && runState.tailDelivered && !runState.anySegmentFailed {
      let outcome = ChunkedPipeline.Outcome(
        segmentCount: 1, insertedText: runState.insertedText, finalized: false, finalChanged: false
      )
      DispatchQueue.main.async {
        guard self.processingSession == session, self.state == .transcribing else { return }
        self.completeChunkedInsertion(outcome: outcome)
      }
      return
    }

    do {
      let result = try await ChunkedPipeline.finalize(
        samples: samples,
        insertedText: runState.insertedText,
        stt: { wav, filename, prompt in
          // The final role from [routing]: the final pass over the whole
          // recording goes to the role's provider; unset — the active
          // transcriber (exactly the current behavior: no failover — the
          // role is chosen explicitly).
          let transcriber = self.roleTranscriber(self.finalRoleProviderID) ?? self.transcriber
          let finalResult = try await transcriber.transcribe(
            wav: wav, filename: filename, prompt: prompt)
          return ChunkedPipeline.SttResult(text: finalResult.text, words: finalResult.words)
        },
        insert: { operation in
          DispatchQueue.main.async {
            guard self.processingSession == session, self.state == .transcribing else { return }
            if case .replaceTail(let old, let new) = operation {
              Inserter.replaceRange(old: old, new: new)
              Logger.log(
                "live final replace: backspace \(old.count) chars, type \(new.count) chars",
                level: "info")
            }
          }
        },
        onFinalizing: {
          DispatchQueue.main.async {
            guard self.processingSession == session, self.state == .transcribing else { return }
            self.overlay.setStatus(L10n.tr("overlay.finalProcessing"))
          }
        }
      )
      let outcome = ChunkedPipeline.Outcome(
        segmentCount: runState.segmentCount,
        insertedText: result.changed ? result.finalText : runState.insertedText,
        finalized: true,
        finalChanged: result.changed
      )
      DispatchQueue.main.async {
        guard self.processingSession == session, self.state == .transcribing else { return }
        self.completeChunkedInsertion(outcome: outcome)
      }
    } catch {
      let networkText = OverlayErrorText.text(for: error)
      let message = networkText ?? Self.message(for: error)
      DispatchQueue.main.async {
        guard self.processingSession == session, self.state == .transcribing else { return }
        self.failTranscription(message, isNetworkFailure: networkText != nil)
      }
    }
  }

  /// Inserts the STT result into the active application.
  /// An empty result (no letter/digit at all) must not be inserted: garbage
  /// does not appear in the text; instead of the success sound — the
  /// "empty" sound (Funk), not more often than once per 3 s. A single word
  /// is a valid result and is inserted.
  /// The completion sound plays AFTER the insertion (CGEvent), not before.
  private func completeInsertion(_ text: String) {
    if NanoDictateFlow.outcome(for: text) == .empty {
      handleEmptyResult()
      return
    }

    // Review before insert (review_before_insert = true): the text is
    // printed to stdout, insertion only on Enter; Esc/other — cancel. Under
    // launchd (agent without a terminal) ReviewGate.confirm would return
    // nil → silent cancel of ALL insertions — the gate is skipped (the text
    // inserts as usual).

    // The terminal continuation of the review decision — the terminal point
    // of completeInsertion: BOTH decision branches (review cancelled /
    // insert done) plan their own hide and reset the state here. The review
    // branch invokes it from the async delivery on the main queue, the
    // no-review branch directly.
    let finish: (ReviewGate.Decision) -> Void = { decision in
      switch decision {
      case .insert:
        break
      case .cancel:
        // No insertion happened — extinguish the synthetic-Enter latch
        // (Enter-stop): a fresh Enter-stop must not hang waiting.
        self.enterSendLatch.cancel()
        self.overlay.resetPhase()
        self.overlay.setStatus(L10n.tr("overlay.cancelled"))
        self.hideAfter(0.8, reason: "review cancelled")
        self.state = .idle
        Logger.log("transcription cancelled by review gate")
        return
      }

      // Text insertion by the chosen method (cgevent / clipboard) — the only
      // operation that undo below can roll back (lastInserted*).
      Inserter.insert(text: text, method: self.insertMethod)
      self.lastInsertedText = text
      self.lastInsertedAt = CFAbsoluteTimeGetCurrent()

      // UI+sound — only after the guaranteed insertion.
      self.overlay.resetPhase()
      self.overlay.setStatus(L10n.tr("overlay.finishing"))
      self.sounds.playCompletionAfterInsert()
      self.hideAfter(0.8, reason: "insert done")
      self.state = .idle
      Logger.log("transcription inserted (\(text.count) chars)")
      // Marker for `nanodictate last` (last recognized text) — persisted to
      // the mode-0600 state file, NOT into agent.log (CWE-532).
      self.persistLastText(text)
      // Enter-stop latch: exactly one synthetic Enter after the insertion.
      // state is already .idle — by posting time (~250 ms) the swallow
      // predicate returns false, the synthetic Return reaches the app.
      self.postSyntheticReturnIfPending()
    }

    if reviewBeforeInsert, hasInteractiveStdin {
      // CR16: confirmAsync reads stdin on a background serial queue and
      // delivers the Decision to the main queue — the hotkey event tap
      // keeps running while the user decides. State stays .transcribing
      // (non-idle) until the continuation above processes the decision. The
      // token is advanced here: the STT work is done, so THIS loop's
      // processing watchdog must not cut the user's decision time (the sync
      // confirm parked it by blocking the main run loop). The continuation
      // re-validates against the advanced token.
      processingSession += 1
      let session = processingSession
      awaitingReviewDecision = true
      ReviewGate.confirmAsync(text: text) { [weak self] decision in
        // Re-validate the caller's delivery guard: Esc (then possibly a new
        // loop) may have ended THIS loop while the user typed the decision —
        // the stale text must not be inserted.
        guard
          let self,
          NanoDictateFlow.shouldDeliverResult(
            isCancelled: self.cancelRecognition,
            sessionActive: self.processingSession == session && self.state == .transcribing
          )
        else { return }
        // The decision arrived — a physical Return may be swallowed again.
        self.awaitingReviewDecision = false
        finish(decision)
      }
      return
    } else if reviewBeforeInsert {
      Logger.log(
        "review_before_insert включён, но stdin не терминал (launchd?) — ревью пропущено",
        level: "info")
    }
    finish(.insert)
  }

  /// Transcriber of a routing role (segment/final). Returns nil when the role
  /// is unset or points to the active provider — then the caller uses the
  /// active transcriber (strictly the current behavior). Otherwise — a direct
  /// Transcriber of the role's provider from its section, WITHOUT a failover
  /// chain (roles are chosen explicitly; auto-failover stays only for the
  /// main path).
  private func roleTranscriber(_ roleProviderID: String?) -> Transcriber? {
    guard
      let roleProviderID,
      roleProviderID != activeProviderID,
      let provider = providersByID[roleProviderID]
    else {
      return nil
    }
    return makeTranscriber(provider)
  }

  /// Recognition with automatic failover (auto_failover = true): the primary
  /// provider is self.transcriber (the active one from the config); on a
  /// TranscribeError the candidates from the failover order are tried. An
  /// error NOT related to the provider (microphone etc.) does not start a
  /// failover. Returns (result, id of the failover provider; nil — primary).
  private func transcribeAutomatically(wav: Data) async throws -> (TranscriptionResult, String?) {
    // The final role from [routing] (whole recording non-chunked): set and
    // different from the active — the direct role provider WITHOUT a
    // failover chain. Role unset/equal to active — exactly the current
    // behavior below.
    if let transcriber = roleTranscriber(finalRoleProviderID) {
      let result = try await transcriber.transcribe(wav: wav)
      return (result, nil)
    }
    do {
      let result = try await transcriber.transcribe(wav: wav)
      return (result, nil)
    } catch {
      guard
        autoFailover,
        let transcribeError = error as? TranscribeError,
        !failoverCandidates.isEmpty
      else {
        throw error
      }
      Logger.log(
        "primary provider failed (\(Transcriber.describe(transcribeError))) — trying failover providers",
        level: "info"
      )
      retryProvider.lastFailedProviderID = activeProviderID
      // The parallel failover is moved to NanoDictateCore (a testable
      // function): RetryProvider.parallelFailover — all candidates run in
      // one withTaskGroup (independent STT requests), the first success
      // wins and cancels the rest (cancelAll); TranscribeErrors accumulate —
      // the last one that finished wins; a non-TranscribeError breaks the
      // chain like the sequential loop (microphone etc.).
      // lastFailedProviderID is set BEFORE the group and reset on a success
      // in retranscribe.
      return try await RetryProvider.parallelFailover(
        candidates: failoverCandidates
      ) { provider in
        guard let retryResult = try await self.retryProvider.retranscribe(with: provider) else {
          throw TranscribeError.invalidResponse("failover retry lost the stored WAV")
        }
        return (retryResult, provider.id)
      }
    }
  }

  /// Handles a manual retry from the CLI (`nanodictate retry <provider>`).
  /// Recognizes the last WAV from memory (if any) with the chosen provider
  /// and inserts the result by the standard path (review/insertion method
  /// are respected).
  private func handleRetryRequest(provider: AppConfig.Provider) {
    guard retryProvider.hasLastRecording else {
      Logger.log("retry request ignored: no recording in this session", level: "info")
      return
    }
    let display = provider.name.isEmpty ? provider.id : provider.name
    Logger.log("retry with provider '\(display)' started", level: "info")
    Task { [weak self] in
      guard let self else { return }
      do {
        guard let result = try await self.retryProvider.retranscribe(with: provider) else {
          Logger.log("retry with provider '\(display)': no stored WAV", level: "info")
          return
        }
        let text = TextRefinement.finalize(result.text)
        DispatchQueue.main.async {
          self.retryInsertion(text)
        }
      } catch {
        let networkText = OverlayErrorText.text(for: error)
        let described = (error as? TranscribeError).map(Transcriber.describe) ?? error.localizedDescription
        Logger.log("retry with provider '\(display)' failed: \(described)", level: "error")
        DispatchQueue.main.async {
          // Show the error ONLY if the dictation loop is not active:
          // otherwise the live loop's overlay ("Recording…"/"Recognizing…")
          // would be wiped.
          guard self.state == .idle else {
            Logger.log("retry error ignored: nanodictate cycle active", level: "info")
            return
          }
          self.overlay.resetPhase()
          let retryErrorText = networkText ?? Self.message(for: error)
          self.overlay.setStatus(
            L10n.tr("overlay.retryError").replacingOccurrences(
              of: "{message}", with: retryErrorText))
          self.hideAfter(2.0, reason: "retry failed")
        }
      }
    }
  }

  /// Insertion of a manual retry result: the common completeInsertion path
  /// (review gate, insertion method, last-text persistence), but outside the
  /// recording state machine — retry does not touch state and the
  /// processing session.
  private func retryInsertion(_ text: String) {
    // Retry outside the loop's state machine: if the user already started a
    // new loop (recording/recognition), the stale retry text is not inserted
    // and the live loop's overlay is not touched.
    guard state == .idle else {
      Logger.log(
        "retry result dropped: nanodictate cycle active (state=\(String(describing: state)))",
        level: "info"
      )
      return
    }
    if reviewBeforeInsert, hasInteractiveStdin {
      // CR16: confirmAsync reads stdin on a background serial queue and
      // delivers the Decision to the main queue — the hotkey event tap keeps
      // running while the user decides. The retry stays "in flight" until the
      // completion processes the decision in finishRetryInsertion; a new loop
      // started meanwhile makes the re-validating guard drop the stale text.
      awaitingReviewDecision = true
      ReviewGate.confirmAsync(text: text) { [weak self] decision in
        guard let self else { return }
        // The decision arrived — a physical Return may be swallowed again.
        self.awaitingReviewDecision = false
        // Re-validate the entry guard: a new nanodictate cycle may have
        // started while the user typed the decision.
        guard self.state == .idle else {
          Logger.log(
            "retry result dropped: nanodictate cycle active (state=\(String(describing: self.state)))",
            level: "info"
          )
          return
        }
        self.finishRetryInsertion(text: text, decision: decision)
      }
      return
    } else if reviewBeforeInsert {
      Logger.log(
        "review_before_insert включён, но stdin не терминал — ревью ретрая пропущено", level: "info"
      )
    }
    finishRetryInsertion(text: text, decision: .insert)
  }

  /// Insertion continuation of retryInsertion: review decision (.insert) or
  /// immediate run when the gate is skipped.
  private func finishRetryInsertion(text: String, decision: ReviewGate.Decision) {
    switch decision {
    case .insert:
      break
    case .cancel:
      enterSendLatch.cancel()
      overlay.setStatus(L10n.tr("overlay.retryCancelled"))
      hideAfter(0.8, reason: "retry review cancelled")
      Logger.log("retry cancelled by review gate")
      return
    }
    Inserter.insert(text: text, method: insertMethod)
    overlay.resetPhase()
    overlay.setStatus(L10n.tr("overlay.retryInserted"))
    hideAfter(1.0, reason: "retry inserted")
    Logger.log("retry transcription inserted (\(text.count) chars)")
    persistLastText(text)
    postSyntheticReturnIfPending()
  }

  /// Persists the last transcribed text for `nanodictate last` into the
  /// state file `~/Library/Application Support/NanoDictate/last_text.txt`
  /// (mode 0600). The dictation text must NOT go into agent.log (CWE-532 —
  /// the transcript would leak into the log); the CLI reads this file
  /// instead. Overwritten on every successful insert (chunked/normal/retry);
  /// a failed or cancelled loop does not touch it — `nanodictate last` keeps
  /// returning the last COMPLETED insertion, exactly like the old LAST_TEXT
  /// log marker. Newlines are replaced so the stored value stays one line.
  private func persistLastText(_ text: String) {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support")
    let fileURL = base.appendingPathComponent("NanoDictate/last_text.txt", isDirectory: false)
    let cleaned = text.replacingOccurrences(of: "\n", with: " ")
    do {
      try FileManager.default.createDirectory(
        at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try cleaned.data(using: .utf8)?.write(to: fileURL, options: .atomic)
      // .atomic renames a fresh temp file — explicitly enforce mode 0600 on
      // the final file (the transcript is private, user-readable only).
      try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    } catch {
      Logger.log("last text persist failed: \(error.localizedDescription)", level: "error")
    }
  }

  /// "Empty" dictation: STT returned <2 words (or silence). The text is not
  /// inserted, the success sound is not played. A separate Funk sound
  /// instead of Basso — empty dictation is NOT a microphone error; a
  /// separate cooldown for empty results.
  private func handleEmptyResult() {
    // No insertion happened — extinguish the synthetic-Enter latch
    // (Enter-stop): an empty result does not post Enter.
    enterSendLatch.cancel()
    if emptyResultCooldown.allow(at: CFAbsoluteTimeGetCurrent()) {
      sounds.playEmptyResult()
    } else if isDebug {
      Logger.log("empty-result sound suppressed (cooldown active)", level: "debug")
    }
    // A fresh "insertion" did not happen — the undo window does not open.
    lastInsertedText = nil
    lastInsertedAt = nil
    overlay.resetPhase()
    overlay.setStatus(L10n.tr("overlay.emptyResult"))
    hideAfter(0.8, reason: "empty result")
    state = .idle
    Logger.log("empty transcription result — not inserted", level: "info")
  }

  /// Rollback of the last insertion by double Alt within undoMaxInterval.
  /// Deletes exactly as many characters as were inserted (backspace is a
  /// mirror of Inserter.insert), overlay status — "Insertion undone", undo
  /// sound — per config (undo_sound_enabled). May restart the overlay if the
  /// panel managed to hide after "Finishing…".
  private func undoLastInsertion() {
    guard let text = lastInsertedText else {
      // No insertion (e.g. the window expired during a deferred interrupt) —
      // close the undo window and leave.
      lastInsertedAt = nil
      lastInsertedText = nil
      return
    }
    overlay.show()
    overlay.resetPhase()
    overlay.setStatus(L10n.tr("overlay.insertCancelled"))
    Inserter.delete(characters: text)
    if undoSoundEnabled {
      sounds.playUndo()
    }
    lastInsertedText = nil
    lastInsertedAt = nil
    // state is already .idle — the next Alt+Alt starts a new recording.
    hideAfter(0.8, reason: "insertion undone")
    Logger.log("insertion undone (\(text.count) chars)")
  }

  /// Terminal point of the loop on an STT error (network, HTTP, timeout).
  /// `isNetworkFailure == true` (no internet / STT timeout) — additionally
  /// plays the system error sound (Basso) so the user understands the
  /// failure even without looking at the overlay.
  private func failTranscription(_ message: String, isNetworkFailure: Bool) {
    // Recognition failed — the synthetic Enter is not posted, the
    // Enter-stop latch is extinguished.
    enterSendLatch.cancel()
    if isNetworkFailure {
      sounds.playError()
    }
    overlay.resetPhase()
    overlay.setStatus(L10n.tr("overlay.error").replacingOccurrences(of: "{message}", with: message))
    hideAfter(2.0, reason: "transcription failed")
    state = .idle
    Logger.log("transcription failed: \(message)", level: "error")
  }

  /// Esc: cancels the current phase. The state branches differ only in the
  /// first step (recording — stop the engine; transcribing — set the cancel
  /// token so the result of a returning STT request is not inserted), then a
  /// common terminal tail: "Cancelled" status, cancel sound (Ping, NOT Basso —
  /// this is not an error), exactly one hide. Every terminal point schedules
  /// hide exactly once.
  private func handleCancel() {
    // Esc ends a pending review wait: the flag must clear before ANY branch
    // — the retry wait holds state == .idle, whose early return below would
    // otherwise leave the flag set.
    awaitingReviewDecision = false
    // Esc cancels an ALREADY SCHEDULED synthetic Enter: the latch was
    // consumed at insertion time, the post hangs in the OS queue — cancel
    // it before any branch (including .idle, where an early return would
    // have happened before the terminal tail).
    scheduledEnterPoster.cancelScheduled()
    switch state {
    case .recording:
      audio.cancel()
      // Invalidate the live loop: a segment being recognized on
      // liveExecutor right now will not insert (the liveSession guard in
      // handleLiveSegment); queued stale segments skip STT (isCancelled
      // guard).
      liveSession += 1
      liveRunState?.isCancelled = true
      liveRunState = nil
      Logger.log("record cancelled")
    case .transcribing:
      cancelRecognition = true
      // Esc during transcription stops the queued work immediately, not only
      // at the next segment: the isCancelled guard in finishLiveRun drops the
      // final pass, so a cancelled run never sends audio to STT.
      liveRunState?.isCancelled = true
      // Exit note: Esc during the chunked review wait cancels the loop
      // (state → .idle) and the completion's state guard drops the decision;
      // the already printed text is NOT removed here — cancel only blocks
      // unprocessed inserts (handleLiveSegment's isCancelled/session guards).
      Logger.log("recognition cancelled by Esc")
    case .idle:
      return
    }
    // Spec: Esc extinguishes the synthetic-Enter latch — a cancelled
    // recording/recognition does not post Enter. In .idle we return above
    // (the latch does not arm in .idle — arm() only in .recording).
    enterSendLatch.cancel()
    overlay.resetPhase()
    overlay.setStatus(L10n.tr("overlay.cancelled"))
    sounds.playCancel()
    hideAfter(0.8, reason: "cancelled")
    state = .idle
  }

  // MARK: - Helpers

  /// Is the standard input a terminal? ReviewGate reads stdin; under
  /// launchd (a GUI agent without a terminal) the gate neither blocks nor
  /// cancels insertions (see completeInsertion/retryInsertion).
  private var hasInteractiveStdin: Bool {
    isatty(STDIN_FILENO) == 1
  }

  /// The single call site of hide() — the loop's terminal events
  /// (mic denied, insert done, transcription failed, cancelled; the limit
  /// goes the same way through processSamples). The delay keeps the final
  /// status ("Finishing…"/"Cancelled") on screen. The hiding decision is the
  /// pure OverlayLifecycle logic in NanoDictateCore: the panel does NOT hide
  /// if by the time the timer fires a recording has already started again
  /// (state != .idle) — the overlay stays visible for the whole new loop.
  private func hideAfter(_ seconds: TimeInterval, reason: String) {
    if isDebug {
      Logger.log("overlay hide scheduled after \(seconds) s, reason=\(reason)", level: "debug")
    }
    // The delayed hide belongs to the dictation cycle that scheduled it:
    // if a new cycle started before the timer fires, this hide is stale —
    // the new cycle's own terminal point will schedule its hide.
    let cycle = startSession
    OverlayLifecycle.scheduleHide(
      after: seconds,
      stateProvider: { [weak self] in self?.state ?? .idle },
      isCurrentCycle: { [weak self] in self?.startSession == cycle },
      hide: { [weak self] in
        self?.overlay.hide(reason: reason)
      }
    )
  }

  private static func message(for error: Error) -> String {
    guard let transcribeError = error as? TranscribeError else {
      return error.localizedDescription
    }
    switch transcribeError {
    case .network(let message):
      return message
    case let .http(code, body):
      return Transcriber.describe(.http(code, body))
    case .invalidResponse(let message):
      return message
    }
  }
}

// MARK: - Main

/// Exclusive flock singleton lock: <tmp>/nanodictate-agent-<uid>.lock.
/// The fd lives in a global variable for the whole process — the lock is
/// released only when the process exits. A second instance (a duplicate
/// launchd start) does NOT exit the process: both LaunchAgents hold
/// KeepAlive=true, and a clean exit would go into an infinite respawn.
/// Instead of exiting — passive waiting on the main run loop.
var instanceLockFD: Int32 = -1

/// Tries to take the singleton lock. true — the lock is taken, services
/// may start; false — another instance is already running (logged), the
/// process must idle, starting nothing.
@discardableResult
func ensureSingleInstance() -> Bool {
  let lockPath = FileManager.default.temporaryDirectory
    .appendingPathComponent("nanodictate-agent-\(getuid()).lock").path
  let fileDescriptor = lockPath.withCString { Darwin.open($0, O_CREAT | O_RDWR, mode_t(0o600)) }
  guard fileDescriptor >= 0 else {
    let error = errno
    Logger.log(
      "single-instance lock open failed (errno \(error)): \(String(cString: strerror(error)))",
      level: "error")
    exit(1)
  }
  guard flock(fileDescriptor, LOCK_EX | LOCK_NB) == 0 else {
    let error = errno
    guard error == EWOULDBLOCK else {
      Logger.log(
        "single-instance lock failed (errno \(error)): \(String(cString: strerror(error)))",
        level: "error")
      close(fileDescriptor)
      exit(1)
    }
    Logger.log(
      "another dictation agent instance already running — entering idle wait", level: "info")
    close(fileDescriptor)
    return false
  }
  instanceLockFD = fileDescriptor
  return true
}

// Singleton gate — the first executable code, BEFORE the config load and
// before any services (HotkeyService, microphone, STT, CGEvent tap,
// observers).
guard ensureSingleInstance() else {
  // A second instance is already running — passively wait on the main
  // dispatch queue. dispatchMain() needs no run loop source and never
  // returns.
  dispatchMain()
}

let config: AppConfig
do {
  config = try AppConfig.load(from: nil)
} catch {
  Logger.log("config load failed: \(error.localizedDescription)", level: "error")
  config = AppConfig.defaults
}

// UI language from the config — BEFORE the first L10n.tr use (static
// Transcriber.noInternetMessage/… messages resolve on first access).
L10n.language = AppLanguage(rawValue: config.uiLanguage) ?? .en

let app = NSApplication.shared
let agent = Agent(config: config)

do {
  // Checks AXIsProcessTrusted(); if the right is missing — shows a clear
  // message and polls every 2 s until granted (auto-grab). The
  // "Accessibility" panel opens ITSELF at start when the grant is missing
  // (rate-limit 10 min, see openAccessibilitySettingsIfDue); an explicit
  // Alt+Alt with the grant revoked shows the SYSTEM dialog
  // (AXIsProcessTrustedWithOptions + kAXTrustedCheckOptionPrompt), not the
  // settings panel.
  try agent.startWithAccessibilityRequest()
} catch {
  Logger.log("hotkey service failed to start: \(error.localizedDescription)", level: "error")
  let alert = NSAlert()
  alert.messageText = L10n.tr("error.agentLaunchFailed")
  alert.informativeText = error.localizedDescription
  alert.runModal()
  exit(1)
}

// Background agent: no Dock icon and no menu-bar app.
NSApp.setActivationPolicy(.accessory)

app.run()
// swiftlint:disable:this file_length
