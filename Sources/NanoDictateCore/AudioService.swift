import AVFoundation
import AudioEngineGuard
import Foundation

// MARK: - Протоколы движка (инъекция в тестах)

/// Minimal AVAudioEngine input-node interface used by AudioService. Real
/// AVAudioInputNode conforms via extension; tests inject a fake and imitate
/// start failures without audio hardware.
public protocol AudioInputNodeLike: AnyObject {
  func outputFormat(forBus bus: AVAudioNodeBus) -> AVAudioFormat
  func installTap(
    onBus bus: AVAudioNodeBus,
    bufferSize: AVAudioFrameCount,
    format: AVAudioFormat?,
    block tapBlock: @escaping AVAudioNodeTapBlock
  )
  func removeTap(onBus bus: AVAudioNodeBus)
}

public protocol AudioEngineLike: AnyObject {
  func makeInputNode() -> AudioInputNodeLike
  func prepare()
  func start() throws
  func stop()
}

extension AVAudioInputNode: AudioInputNodeLike {}
extension AVAudioEngine: AudioEngineLike {
  public func makeInputNode() -> AudioInputNodeLike {
    inputNode
  }
}

// MARK: - ObjC-шлюз для NSException AVFAudio

// AudioEngineGuard touch functions (see AudioEngineExceptionGuard.h/m):
// NanoDictateRunAudioEngineBlockGuarded runs a block under ObjC @try/@catch and
// returns NSError, not the NSException AVFAudio can raise inside
// installTap/prepare/start (SetOutputFormat) — Swift cannot catch it via try,
// would SIGABRT.

public protocol AudioLevelDelegate: AnyObject {
  func audioLevelChanged(rms: Float)
}

/// Hard recording limit: no more than `maxDuration` seconds and no more than
/// `maxSamples` in the buffer (16000 Hz × 60 s = 960 000 samples ≈ 1.9 MB Int16).
/// Pure testable unit: independent of audio devices, stop decision verified in
/// mini-XCTest directly.
public struct RecordingLimit {
  public let maxDuration: TimeInterval
  public let maxSamples: Int
  /// Latch: stays `true` once the limit fires — recording cannot resume until
  /// a new session (new instance).
  public private(set) var isExhausted = false

  public init(maxDuration: TimeInterval, sampleRate: Int) {
    self.maxDuration = maxDuration
    // Guard against a pathological zero sampleRate: intake can always accumulate
    // at least one sample before the forced stop.
    maxSamples = max(1, Int(Double(sampleRate) * maxDuration))
  }

  /// Limit reached (by time OR by volume)? After the first fire the method
  /// always returns `true` — stop is irreversible within the session.
  public mutating func shouldStop(elapsed: TimeInterval, totalSamples: Int) -> Bool {
    if isExhausted {
      return true
    }
    if elapsed >= maxDuration || totalSamples >= maxSamples {
      isExhausted = true
    }
    return isExhausted
  }

  public func remainingSamples(after totalSamples: Int) -> Int {
    max(0, maxSamples - totalSamples)
  }
}

/// Mic recording via AVAudioEngine (16 kHz mono).
///
/// On macOS the input node runs in hardware format (usually 48 kHz), and
/// `connect(input, to:format:)` with a foreign sample rate throws
/// (`format.sampleRate == hwFormat.sampleRate`). So the tap goes on the
/// hardware format; AVAudioConverter resamples into 16 kHz mono.
///
/// Three engine life/death guarantees (crash and "freeze" regression):
/// 1. Every engine op (installTap/prepare/start/stop/removeTap) runs ONLY on
///    `engineQueue` under the ObjC gateway `guardedEngineCall`: an AVFAudio
///    NSException (SetOutputFormat) becomes an Error, not SIGABRT.
/// 2. Any start error ALWAYS removes the tap and stops the engine
///    (teardownOnEngineQueue) — a restart on the same instance never hits
///    "tap already installed".
/// 3. Start is async (completion on main): engine bring-up never blocks the
///    main thread (observed UI freeze ~11 s on device change).
// swiftlint:disable:next type_body_length
public final class AudioService {
  public weak var levelDelegate: AudioLevelDelegate?

  /// Audio-device change during recording: the engine input format changed
  /// (`AVAudioEngineConfigurationChangeNotification`), the live tap converter
  /// was not recreated for the new format. Recording ends immediately —
  /// continuing on the old converter would give silence or sample desync. User
  /// restarts recording with one command.
  public var onDeviceChange: ((Error) -> Void)?

  /// Log level: `"debug"` enables metering (min/avg/max RMS, near-silence flag).
  /// Mic-access and recording-lifecycle logs write always at `info`.
  private let logLevel: String

  /// Called after a FORCED limit stop (on main) with the collected samples —
  /// same finalization path as `stop()` (samples → WAV → transcription).
  /// nil-safe: nobody subscribed — recording still stops, samples dropped.
  public var onRecordingLimitReached: (([Int16]) -> Void)?

  /// Speech segment gathered by live-VAD (pause ≥ pauseDuration closed the
  /// utterance) or the "tail" of an open utterance handed at recording stop
  /// (stop() or forced limit stop). Samples are a COPY from the shared buffer:
  /// `collectedSamples` stays untouched and keeps gathering the WHOLE recording
  /// for the final pass. `isTail == true` — delivery at recording stop (segment
  /// covers recording to the end); false — mid-recording live-VAD segment.
  /// Called on the audio thread (segments) or main (tail of stop()/limit); the
  /// handler must be light (no blocking).
  public var onSpeechSegment: (([Int16], _ isTail: Bool) -> Void)?

  /// Auto-stop on continuous silence (~3 s): fires when the live recording
  /// accumulated continuous silence ≥ `autoStopConfig.requiredSilenceDuration`
  /// (each buffer RMS strictly below `silenceRMSThreshold`). Called on main
  /// with the collected samples — same finalization path as
  /// `onRecordingLimitReached` (equals a manual Alt+Alt, but without a press).
  /// In live dictation the "tail" of an open utterance goes to `onSpeechSegment`
  /// BEFORE this callback — the client queues it ahead of whole-recording
  /// finalization. nil-safe: recording still stops, samples dropped.
  public var onAutoStop: (([Int16]) -> Void)?

  /// Capture-readiness signal: fired exactly once per successful session on
  /// the main queue when the first valid microphone buffer has been appended
  /// to the recording. This is the truthful "ready to receive speech" point:
  /// `engine.start()` returning does NOT prove a microphone buffer reached
  /// NanoDictate, so the normal start cue (sound + "Recording" UI) must be
  /// gated on this callback, never on `start(completion:)` alone.
  /// Startup failure/timeout paths never fire it (error path only).
  public var onCaptureReady: ((CaptureReadyInfo) -> Void)?

  /// Startup-to-first-buffer timing for one session (monotonic clock, no audio
  /// content). All values in milliseconds.
  public struct CaptureReadyInfo {
    /// Alt+Alt trigger → `start` request entry. nil when the trigger stamp
    /// was not provided (legacy `start(completion:)` callers, tests).
    public let triggerToRequestMs: Double?
    public let requestToEngineStartedMs: Double
    public let engineStartedToFirstBufferMs: Double
    public let requestToFirstBufferMs: Double
    public init(
      triggerToRequestMs: Double?,
      requestToEngineStartedMs: Double,
      engineStartedToFirstBufferMs: Double,
      requestToFirstBufferMs: Double
    ) {
      self.triggerToRequestMs = triggerToRequestMs
      self.requestToEngineStartedMs = requestToEngineStartedMs
      self.engineStartedToFirstBufferMs = engineStartedToFirstBufferMs
      self.requestToFirstBufferMs = requestToFirstBufferMs
    }
  }

  /// True once the current session appended its first valid microphone buffer
  /// (and the session is still live). False after `start` until that point,
  /// and after `stop()`/`cancel()`/teardown/wedge. Read under lock.
  public var isCaptureReady: Bool {
    lock.lock()
    defer { lock.unlock() }
    return captureReadyLive
  }

  // var, not let: replaceEngineAfterWedge() swaps a "wedged" engine for a fresh
  // instance (recovery after a record-start timeout).
  private var engine: AudioEngineLike
  private let targetFormat: AVAudioFormat
  private var converter: AVAudioConverter?
  /// Reusable resample output buffer for the steady-state tap path. The tap
  /// callback is serial within one engine generation, so one instance serves
  /// the whole session: it is grown only when an input buffer needs more
  /// capacity, never reallocated per callback. Touched only in `process()`
  /// (audio thread) via per-generation checkout — never shared across
  /// generations (see `reusableBuffersGeneration`).
  private var reusableConvertedBuffer: AVAudioPCMBuffer?
  /// Reusable Float32->Int16 staging for one converted buffer. Filled outside
  /// the shared lock, then bulk-appended to `collectedSamples` under lock.
  /// Grows monotonically within capacity needs; touched only in `process()`
  /// via per-generation checkout.
  private var scratchInt16: [Int16] = []
  /// Generation the cached reuse buffers above belong to (nil — invalid).
  /// Callbacks from different engine generations must never share the mutable
  /// `reusableConvertedBuffer`/`scratchInt16` outside the lock: an old tap
  /// callback that passed its generation check before `replaceEngineAfterWedge()`
  /// can otherwise run concurrently with the fresh engine's callback and
  /// corrupt samples. Checkout moves these buffers to locals only on a tag
  /// match; the wedge swap invalidates the tag so the fresh generation
  /// allocates its own instances. Guarded by `lock`.
  private var reusableBuffersGeneration: Int?
  private var collectedSamples: [Int16] = []
  private var tapInstalled = false
  /// Engine generation: incremented on EVERY "wedged" engine swap
  /// (replaceEngineAfterWedge). With (engine, queue) it forms an atomic slot:
  /// starts capture the generation at dispatch, the tap block and start
  /// terminal branches check "am I still the current generation?". Stale
  /// engines (discarded by the swap) silently drop buffers and never touch
  /// new-session state.
  /// The `session` ledger holds the SINGLE copy of the trio (generation,
  /// isRecording, autoStopScheduled) — readable under `lock` (buffer snapshot)
  /// and lock-free from the realtime path without diverging from the recorded
  /// value.
  private let session: SessionLedger
  /// Hard limit: 60.0 s, 960 000 samples. Recording can never exceed these
  /// (see `process` and `scheduleLimitStop`).
  private var limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
  private var recordStartTime: CFAbsoluteTime = 0
  /// Per-buffer RMS history (linear 0...1) of the current recording — source of
  /// level summary metrics (min/avg/max) in `logRecordingFinale`.
  private var rmsHistory: [Float] = []
  /// Ensures the forced stop is scheduled exactly once.
  private let lock = NSLock()
  private var limitStopScheduled = false
  /// Auto-stop: silence threshold/duration + `enabled` kill switch (from init;
  /// Agent takes them from environment — see `AutoStopConfig.fromEnvironment`)
  /// and the "finalization already scheduled" latch — in the `session` ledger
  /// (autoStop bit), like the limit: exactly one callback.
  private let autoStopConfig: AutoStopConfig
  private var autoStopDetector = SilenceAutoStopDetector()
  /// First session buffer logged separately (debug): piece duration and energy
  /// show whether real sound reached the engine after start.
  private var didLogFirstBuffer = false
  // MARK: - Capture-readiness + startup timing (P0 first-word clipping)

  /// Monotonic-clock startup marks for the current session (DispatchTime
  /// uptime nanoseconds — never wall-clock, never audio content).
  private var startupTriggerNanos: UInt64?
  private var startupRequestNanos: UInt64 = 0
  private var startupQueueEntryNanos: UInt64 = 0
  private var startupEngineStartedNanos: UInt64 = 0
  /// Fine-grained stage marks for the current session (monotonic nanos).
  private var startupFirstAltNanos: UInt64?
  private var startupSecondAltNanos: UInt64?
  private var startupInputReadyNanos: UInt64 = 0
  private var startupTapInstalledNanos: UInt64 = 0
  private var startupPrepareDoneNanos: UInt64 = 0
  private var startupFirstRawNanos: UInt64 = 0
  /// Generation the marks above belong to; stale sessions never fire readiness.
  private var startupGeneration: Int = -1
  /// Exactly-once latch for `onCaptureReady` within one session.
  private var captureReadyFired = false
  /// Live readiness flag behind `isCaptureReady` (cleared on stop/cancel/
  /// teardown/wedge/new-session reset).
  private var captureReadyLive = false
  /// Pre-warmed converter cache (no microphone capture): built by `prewarm()`
  /// or refreshed after teardown, reused by the next `start` when the hardware
  /// input format signature still matches. Cleared on wedge replacement.
  private var warmedConverter: AVAudioConverter?
  private var warmedHWSignature: String?

  /// Tap buffer size (frames per callback request). 1024 at 48 kHz is ~21 ms
  /// per requested buffer vs ~85 ms at 4096, so first-buffer delivery itself
  /// stops dominating perceived startup latency. 512 would halve that again
  /// but doubles callback/lock traffic for a marginal gain and risks allocator
  /// churn on slow HALs; 2048 keeps ~43 ms of first-buffer floor. 1024 is the
  /// smallest stable value with the #29 reuse path (reusable converted buffer
  /// + scratch staging, no per-callback allocation). HAL delivery is not
  /// guaranteed to match the request exactly; measured on hardware via the
  /// startup timing log (engineStarted->firstBuffer).
  static let tapBufferSize: AVAudioFrameCount = 1024

  /// Fine-grained monotonic startup stages for one session (uptime nanos).
  /// Timing only, never audio content. Reported once per session on capture
  /// readiness alongside CaptureReadyInfo.
  public struct StartupBreakdown {
    public let firstAltNanos: UInt64?
    public let secondAltNanos: UInt64?
    public let requestNanos: UInt64
    public let queueEntryNanos: UInt64
    public let inputReadyNanos: UInt64
    public let tapInstalledNanos: UInt64
    public let prepareDoneNanos: UInt64
    public let engineStartedNanos: UInt64
    public let firstRawCallbackNanos: UInt64
    public let firstAcceptedNanos: UInt64
  }

  /// Last completed startup breakdown (for diagnostics/tests). Set when
  /// capture readiness fires; nil before the first successful session.
  public var lastStartupBreakdown: StartupBreakdown? {
    lock.lock()
    defer { lock.unlock() }
    return completedBreakdown
  }

  private var completedBreakdown: StartupBreakdown?
  /// First-Alt / second-Alt stamps (monotonic nanos) recorded via
  /// noteFirstAltTap()/noteSecondAltTap() during the double-tap window.
  /// Consumed by the next start into its breakdown, then cleared.
  private var pendingFirstAltNanos: UInt64?
  private var pendingSecondAltNanos: UInt64?

  /// Non-capturing pre-armed state built during the first-Alt window.
  /// Safe subset only: input format resolved, converter built/reset,
  /// engine.prepare() called, session buffers preallocated. Never installs a
  /// tap, never starts the engine, never stores audio. Invalidated by timeout,
  /// foreign key, device change, permission-relevant teardown, wedge swap and
  /// any new start that does not consume it.
  private struct ArmedState {
    var generation: Int
    var hwSignature: String
    var prepared: Bool
  }

  private var pendingArm: ArmedState?
  /// Session-store capacity target (60 s at 16 kHz). Preallocated once and
  /// preserved across sessions via removeAll(keepingCapacity:) so the
  /// latency-critical start path never grows under the shared lock.
  private let sessionStoreCapacity = 960_000

  /// Monotonic now for startup timing (uptime nanoseconds).
  private static func monotonicNanos() -> UInt64 {
    DispatchTime.now().uptimeNanoseconds
  }

  private static func ms(fromNanos start: UInt64, to end: UInt64) -> Double {
    Double(end >= start ? end - start : 0) / 1_000_000.0
  }

  /// Single-line fine-grained startup stage log (timing only, never audio).
  /// Covers first Alt → second Alt → request → queue entry → input ready →
  /// tap installed → prepare done → engine started → first raw callback →
  /// first accepted buffer. Missing stamps (legacy callers without Alt taps)
  /// render as absence of that segment, never as zero.
  private func logStartupStages(_ stages: StartupBreakdown) {
    var parts: [String] = []
    func append(_ label: String, from start: UInt64, to end: UInt64) {
      guard end >= start, end > 0 else { return }
      parts.append(String(format: "%@=%.1f ms", label, Self.ms(fromNanos: start, to: end)))
    }
    if let first = stages.firstAltNanos, let second = stages.secondAltNanos {
      append("firstAlt->secondAlt", from: first, to: second)
      append("secondAlt->request", from: second, to: stages.requestNanos)
    }
    append("request->queue", from: stages.requestNanos, to: stages.queueEntryNanos)
    append("queue->input", from: stages.queueEntryNanos, to: stages.inputReadyNanos)
    append("input->tap", from: stages.inputReadyNanos, to: stages.tapInstalledNanos)
    append("tap->prepare", from: stages.tapInstalledNanos, to: stages.prepareDoneNanos)
    append("prepare->started", from: stages.prepareDoneNanos, to: stages.engineStartedNanos)
    append("started->raw", from: stages.engineStartedNanos, to: stages.firstRawCallbackNanos)
    append("raw->accepted", from: stages.firstRawCallbackNanos, to: stages.firstAcceptedNanos)
    guard !parts.isEmpty else { return }
    Logger.log("record startup stages: " + parts.joined(separator: " "), level: "info")
  }

  /// Hardware input-format signature for converter-cache matching.
  /// Sample rate + channel count identify the resample path; a device change
  /// alters at least one of them, forcing a rebuild.
  static func hwSignature(sampleRate: Double, channels: UInt32) -> String {
    "\(Int(sampleRate))Hz-ch\(channels)"
  }
  /// Digital input gain (AGC): applied to the Float32 buffer AFTER 16 kHz/mono
  /// conversion and BEFORE Int16 conversion/level metering — level animation
  /// and recording see the conditioned signal. VAD and auto-stop decisions use
  /// the raw/pre-gain RMS, never the amplified value (issue #21).
  /// Env config (`NANODICTATE_GAIN_*`); kill switch
  /// `NANODICTATE_GAIN_DISABLED=1` passes the buffer unchanged.
  private let gain: InputGain
  /// Adaptive speech detector on the raw/pre-gain signal (issue #21):
  /// noise-floor tracker plus hysteresis. Independent from the AGC floor
  /// tracker on purpose — level conditioning never drives speech decisions.
  private var vad = AdaptiveVAD()
  /// Last VAD speech state for debug transition logs (no raw audio logged).
  private var lastVadSpeech = false

  // MARK: - Live-VAD (stepwise dictation)

  /// Live-VAD pause handling: `segmenterConfig.pauseDuration` closes an
  /// utterance. Speech/silence classification itself is adaptive on the
  /// raw signal (see `vad`); the fixed `segmenterConfig.silenceRMS` threshold
  /// no longer drives live decisions (issue #21).
  /// Pause ≥ this many samples (16 kHz) closes an utterance.
  private let livePauseSamples: Int
  /// Pre-roll: speech samples (16 kHz) captured BEFORE the detected utterance
  /// start — first-word attack not cut.
  private let livePreRollSamples: Int
  /// Post-roll: trailing silence samples (16 kHz) after the last speech —
  /// last-word tail not cut.
  private let livePostRollSamples: Int
  /// Continuous-speech window (16 kHz): accumulated SPEECH of the current
  /// utterance reached this volume — chunk ready at the next micro-pause (see
  /// `liveMicroPauseSamples`), no full `pauseDuration` wait. 3.0 s = 48000
  /// samples — comfortable STT portion.
  private let liveChunkWindowSamples: Int
  /// Micro-pause (16 kHz): with accumulated speech ≥ `liveChunkWindowSamples`,
  /// a pause ≥ this threshold cuts a chunk during continuous speech.
  /// 0.25 s = 4000 samples — shorter than a normal inter-word gap.
  private let liveMicroPauseSamples: Int
  /// Utterance start index in `collectedSamples`; nil — no speech yet.
  private var liveUtteranceStart: Int?
  /// Exclusive index of the last SPEECH portion end — trailing silence not
  /// included.
  private var liveUtteranceEnd = 0
  /// Current in-utterance pause start; nil — no pause. Pause shorter than
  /// `livePauseSamples` — inner gap, utterance lives.
  private var liveSilenceStart: Int?
  /// Index right after the last delivered live segment: pre-roll cannot
  /// re-enter an already delivered piece.
  private var liveLastCutIndex = 0
  /// Accumulated SPEECH duration of the current utterance (16 kHz): grows per
  /// speech portion, NOT reset by micro-pause (inter-word gap does not zero
  /// chunk progress); zeroed on VAD reset after delivery.
  private var liveSpeechDurationSamples = 0

  /// Serial queue for ALL engine operations: installTap/removeTap/prepare/start/
  /// stop. Never call them off-queue — that is the guarantee of no
  /// teardown↔start races and no main-thread blocking.
  /// NOT `let`: a wedged engine swaps its queue too
  /// (replaceEngineAfterWedge) — a blocked engine.start() holds only ITS queue,
  /// operations for the fresh engine go to the fresh queue.
  private var engineQueue: DispatchQueue
  /// Fresh-engine factory for post-wedge replacement (see
  /// replaceEngineAfterWedge). Test injection; default — real AVAudioEngine.
  private let engineFactory: () -> AudioEngineLike
  /// Device-change observer + the engine it subscribed on. The token
  /// (NSObjectProtocol) does not keep the subscription object, so we keep the
  /// engine alongside: a stale start removes ONLY ITS subscription (by engine
  /// identity), not the live session's observer on the fresh pair.
  private struct ConfigurationChangeObserver {
    var token: NSObjectProtocol
    var engine: AudioEngineLike
  }
  /// `AVAudioEngineConfigurationChangeNotification` observer: audio-device
  /// change during recording invalidates the live tap converter (engine input
  /// format changed). Token (+ engine) kept so teardown removes the
  /// subscription — else the callback hits released state.
  private var configChangeObserver: ConfigurationChangeObserver?
  /// Background engine queue or main — decided by the engine, not the calling
  /// thread. Diagnostics only.
  private var isDebug: Bool {
    logLevel.lowercased() == "debug"
  }

  public init(
    logLevel: String = "info",
    engine: AudioEngineLike? = nil,
    makeEngine: (() -> AudioEngineLike)? = nil,
    segmenterConfig: AudioSegmenterConfig = .defaults,
    autoStopConfig: AutoStopConfig = .defaults,
    gainConfig: InputGainConfig = .fromEnvironment(),
    vadConfig: AdaptiveVADConfig = .defaults
  ) {
    self.logLevel = logLevel
    // Engine factory: the initial instance (if not injected) and the wedge
    // replacement are created BY it — tests swap it and control the "fresh"
    // post-swap engine.
    let factory = makeEngine ?? { AVAudioEngine() }
    engineFactory = factory
    self.engine = engine ?? factory()
    // Lifecycle ledger: the single copy of (generation/isRecording/
    // autoStopScheduled). Starts at generation 0, flags clear.
    session = SessionLedger(generation: 0)
    engineQueue = DispatchQueue(label: "nanodictate.audio.engine", qos: .userInitiated)
    self.autoStopConfig = autoStopConfig
    gain = InputGain(config: gainConfig)
    vad = AdaptiveVAD(config: vadConfig)
    autoStopDetector = SilenceAutoStopDetector(
      silenceRMSThreshold: autoStopConfig.silenceRMSThreshold,
      speechRMSThreshold: autoStopConfig.speechRMSThreshold,
      requiredSilenceDuration: autoStopConfig.requiredSilenceDuration,
      gracePeriod: autoStopConfig.gracePeriod,
      minSpeechRun: autoStopConfig.minSpeechRun,
      minRecordingDuration: autoStopConfig.minRecordingDuration
    )
    // Live-VAD pause handling reuses the offline pause duration; speech/silence
    // classification is adaptive on the raw signal (issue #21).
    livePauseSamples = max(1, Int((segmenterConfig.pauseDuration * 16000).rounded()))
    // Pre-roll 0.5 s (8000 samples) and post-roll 0.25 s (4000 samples) at
    // 16 kHz — margin keeping word attack and tail uncut.
    livePreRollSamples = Int((0.5 * 16000).rounded())
    livePostRollSamples = Int((0.25 * 16000).rounded())
    // Chunk mode for continuous speech: window 3.0 s (48000 samples) of
    // accumulated SPEECH + micro-pause 0.25 s (4000 samples) allow text
    // delivery mid-flow — no full 1 s pause wait.
    liveChunkWindowSamples = Int((3.0 * 16000).rounded())
    liveMicroPauseSamples = Int((0.25 * 16000).rounded())
    // Target format for all resampling: 16 kHz mono Float32. This init is
    // guaranteed valid on macOS 12+.
    guard
      let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16000,
        channels: 1,
        interleaved: false
      )
    else {
      fatalError("AudioService: 16 kHz Float32 mono AVAudioFormat is guaranteed valid on macOS 12+")
    }
    targetFormat = format
  }

  // MARK: - Старт

  /// Starts recording. Async: engine bring-up on the background queue
  /// (`engineQueue`), completion on main. Mic unavailable or engine failure —
  /// `.failure` (engine torn down, ready for restart, see `startOnEngineQueue`).
  ///
  /// IMPORTANT: `.success` means only "engine started" — NOT "microphone
  /// buffers are flowing". The truthful capture-ready signal is the separate
  /// `onCaptureReady` callback (first valid buffer appended). Gate the normal
  /// start cue (sound + "Recording" UI) on `onCaptureReady`, never on this
  /// completion alone — otherwise speech begun immediately after the cue is
  /// clipped (P0).
  ///
  /// - Parameter triggerUptimeNanos: monotonic trigger stamp (e.g. Alt+Alt
  ///   dispatch, `DispatchTime.now().uptimeNanoseconds`) for startup-gap
  ///   measurement. nil — trigger→request delay not measured.
  public func start(
    triggerUptimeNanos: UInt64? = nil,
    completion: @escaping (Result<Void, Error>) -> Void
  ) {
    // Monotonic request stamp BEFORE dispatch: measures main-thread/hotkey
    // delay (trigger → request) plus engine bring-up below.
    let requestNanos = Self.monotonicNanos()
    // Pair snapshot (engine, queue, generation) under lock, BEFORE dispatch:
    // the block goes to THIS engine's queue and works with IT. A wedged start
    // blocks only its own pair — after the swap (replaceEngineAfterWedge) the
    // fresh pair works without waiting for the blocked queue. The generation
    // captured here is the start "stamp": the tap block and terminal branches
    // verify against it that the engine is still current (see startOnEngineQueue).
    let slot = captureEngineSlot()
    slot.queue.async {
      [weak self, engine = slot.engine, startGeneration = slot.generation] in
      guard let self else {
        DispatchQueue.main.async { completion(.failure(AudioServiceError.engineGone)) }
        return
      }
      let result = self.startOnEngineQueue(
        using: engine,
        startGeneration: startGeneration,
        triggerNanos: triggerUptimeNanos,
        requestNanos: requestNanos
      )
      DispatchQueue.main.async { completion(result) }
    }
  }

  /// Safe pre-warm without microphone capture (no tap, no `engine.start()`,
  /// no audio recording): resolves the input format and builds the
  /// resample converter into the cache so the next `start` can reuse it when
  /// the device format is unchanged. Best-effort and silent on failure.
  /// No-op while recording (never disturbs the live converter) and on stale
  /// generations. Never keeps the microphone active.
  public func prewarm() {
    let slot = captureEngineSlot()
    slot.queue.async { [weak self, engine = slot.engine, generation = slot.generation] in
      guard let self else { return }
      self.prewarmOnEngineQueue(using: engine, generation: generation)
    }
  }

  /// Records the first-Alt tap stamp (double-tap window opened). Called from
  /// the main thread; consumed by the next start into its timing breakdown.
  public func noteFirstAltTap(atNanos nanos: UInt64? = nil) {
    lock.lock()
    pendingFirstAltNanos = nanos ?? Self.monotonicNanos()
    // A new first tap supersedes any previous second-tap stamp.
    pendingSecondAltNanos = nil
    lock.unlock()
  }

  /// Records the confirmed second-Alt tap stamp. Called from the main thread
  /// just before the start request; the start path moves it into the session.
  public func noteSecondAltTap(atNanos nanos: UInt64? = nil) {
    lock.lock()
    pendingSecondAltNanos = nanos ?? Self.monotonicNanos()
    lock.unlock()
  }

  /// Non-capturing pre-arm for an imminent double-Alt confirm: resolves the
  /// input format, builds/resets the converter into the warm cache, calls
  /// engine.prepare() and preallocates bounded session buffers — all without
  /// installing a tap, starting the engine, or storing audio. Best-effort and
  /// silent on failure. No-op while recording or on stale generations.
  /// A prepared tap/graph cannot safely remain armed across the window (the
  /// tap belongs to a live engine session and device-change invalidation must
  /// stay synchronous), so the tap install stays in the confirmed-start path.
  public func armForImminentStart() {
    let slot = captureEngineSlot()
    slot.queue.async { [weak self, engine = slot.engine, generation = slot.generation] in
      guard let self else { return }
      self.armOnEngineQueue(using: engine, generation: generation)
    }
  }

  /// Discards a pending pre-arm without touching a live session. Safe to call
  /// when no arm exists. Runs on the engine queue to serialize with arm/start.
  public func cancelPendingArm() {
    let slot = captureEngineSlot()
    slot.queue.async { [weak self, generation = slot.generation] in
      guard let self else { return }
      self.lock.lock()
      if let arm = self.pendingArm, arm.generation == generation {
        self.pendingArm = nil
      } else if self.pendingArm == nil {
        // No arm: still clear stale Alt stamps so a lone single-Alt leaves no
        // persistent timing residue.
        self.pendingFirstAltNanos = nil
        self.pendingSecondAltNanos = nil
      }
      self.lock.unlock()
    }
  }

  /// Synchronous test hook: true while a pre-arm is pending for the current
  /// generation. For unit tests only; production uses generation-gated start.
  func isArmedForTests() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return pendingArm != nil
  }

  /// Pre-arm body — strictly on the given engine's queue.
  private func armOnEngineQueue(using engine: AudioEngineLike, generation: Int) {
    guard !isRecordingLocked else { return }
    guard isCurrentGeneration(generation) else { return }
    lock.lock()
    if pendingArm?.generation == generation {
      lock.unlock()
      return
    }
    lock.unlock()
    var hwFormat: AVAudioFormat?
    let setupError = guardedEngineCall {
      hwFormat = engine.makeInputNode().outputFormat(forBus: 0)
    }
    guard setupError == nil, let hw = hwFormat else { return }
    let signature = Self.hwSignature(sampleRate: hw.sampleRate, channels: hw.channelCount)
    lock.lock()
    let alreadyWarm = warmedHWSignature == signature && warmedConverter != nil
    lock.unlock()
    if !alreadyWarm {
      var built: AVAudioConverter?
      let converterError = guardedEngineCall {
        built = AVAudioConverter(from: hw, to: self.targetFormat)
      }
      guard converterError == nil, let fresh = built else { return }
      lock.lock()
      if isCurrentGeneration(generation) {
        warmedConverter = fresh
        warmedHWSignature = signature
      }
      lock.unlock()
    } else {
      lock.lock()
      warmedConverter?.reset()
      lock.unlock()
    }
    // engine.prepare() without a tap or start: preallocates the graph without
    // opening microphone capture. Guarded: HAL exceptions become silent abort.
    _ = guardedEngineCall {
      engine.prepare()
    }
    guard isCurrentGeneration(generation) else { return }
    // Preallocate bounded session buffers now so the confirmed start path
    // performs no growth under the shared lock.
    lock.lock()
    if isCurrentGeneration(generation), !isRecordingLocked {
      if collectedSamples.capacity < sessionStoreCapacity {
        collectedSamples.reserveCapacity(sessionStoreCapacity)
      }
      if rmsHistory.capacity < 4096 {
        rmsHistory.reserveCapacity(4096)
      }
      if scratchInt16.capacity < 4096 {
        scratchInt16.reserveCapacity(4096)
      }
      pendingArm = ArmedState(generation: generation, hwSignature: signature, prepared: true)
    }
    lock.unlock()
  }

  /// Pre-warm body — strictly on the given engine's queue.
  private func prewarmOnEngineQueue(using engine: AudioEngineLike, generation: Int) {
    guard !isRecordingLocked else { return }
    guard isCurrentGeneration(generation) else { return }
    var hwFormat: AVAudioFormat?
    let setupError = guardedEngineCall {
      hwFormat = engine.makeInputNode().outputFormat(forBus: 0)
    }
    guard setupError == nil, let hw = hwFormat else { return }
    let signature = Self.hwSignature(sampleRate: hw.sampleRate, channels: hw.channelCount)
    lock.lock()
    let alreadyWarm = warmedHWSignature == signature && warmedConverter != nil
    lock.unlock()
    guard !alreadyWarm else { return }
    var converter: AVAudioConverter?
    let converterError = guardedEngineCall {
      converter = AVAudioConverter(from: hw, to: self.targetFormat)
    }
    guard converterError == nil, let built = converter else { return }
    lock.lock()
    // Re-check under the same lock: a concurrent start may have advanced the
    // session; only cache for the generation we warmed.
    if isCurrentGeneration(generation) {
      warmedConverter = built
      warmedHWSignature = signature
    }
    lock.unlock()
    if isDebug {
      Logger.log("record prewarm: converter warmed (hw=\(Int(hw.sampleRate)) Hz)", level: "debug")
    }
  }

  /// Atomic snapshot of "engine + its serial queue + generation" at operation
  /// dispatch. The pair changes only whole (replaceEngineAfterWedge), so the
  /// operation always lands on ITS engine's queue: seriality of
  /// installTap/removeTap/prepare/start/stop on one instance is preserved, and
  /// a blocked queue of a wedged engine holds nobody else. Generation — the
  /// start "stamp": by it the tap block and terminal branches tell the current
  /// engine from the discarded one.
  private struct EngineSlot {
    var engine: AudioEngineLike
    var queue: DispatchQueue
    var generation: Int
  }

  private func captureEngineSlot() -> EngineSlot {
    lock.lock()
    defer { lock.unlock() }
    // Generation from the `session` ledger (single copy — see SessionLedger):
    // only replaceEngineAfterWedge advances it, always under this same `lock`,
    // so the pair (engine, generation) still snapshots consistently.
    return EngineSlot(
      engine: engine,
      queue: engineQueue,
      generation: session.snapshot.generation
    )
  }

  /// Whole engine bring-up — strictly on THIS engine's queue. `startGeneration`
  /// — slot generation at start dispatch: terminal branches tear the engine
  /// down and touch session state ONLY if the engine that started is still
  /// current (not wedge-swapped after the watchdog timeout).
  ///
  /// NOTE: success here means "engine started", NOT "capture ready". The
  /// capture-ready signal fires later from `process()` on the first valid
  /// buffer. Callers must gate the normal start cue on `onCaptureReady`.
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func startOnEngineQueue(
    using engine: AudioEngineLike,
    startGeneration: Int,
    triggerNanos: UInt64?,
    requestNanos: UInt64
  ) -> Result<Void, Error> {
    // Queue-entry stamp: measures dispatch/queueing delay (request → engine
    // queue entry) on the monotonic clock.
    let queueEntryNanos = Self.monotonicNanos()
    // New session: clean buffers, clean limit (after forced stop or failure
    // branch). All state under lock — start runs on the engine queue,
    // process/stop may read in parallel. The WHOLE reset is gated by the
    // generation check under the SAME lock: a stale start (queued behind a
    // wedged engine, run after the swap) must not reset the live session —
    // the swap advances the generation under this same lock, so the check
    // and the reset form one atomic step. A stale start skips the reset and
    // falls through to the generation gate after the converter setup, which
    // tears down only its own (stale) engine.
    lock.lock()
    if isCurrentGeneration(startGeneration) {
      didLogFirstBuffer = false
      limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
      recordStartTime = CFAbsoluteTimeGetCurrent()
      // Capacity-preserving reuse: a pre-armed session (or the previous
      // session's store kept by teardown) already holds the bounded capacity,
      // so steady-state appends never regrow under the shared lock. First
      // session without capacity reserves once; later sessions reuse.
      collectedSamples.removeAll(keepingCapacity: true)
      if collectedSamples.capacity < sessionStoreCapacity {
        collectedSamples.reserveCapacity(sessionStoreCapacity)
      }
      rmsHistory.removeAll(keepingCapacity: true)
      if rmsHistory.capacity < 4096 {
        rmsHistory.reserveCapacity(4096)
      }
      limitStopScheduled = false
      // Auto-stop latch — in the ledger (autoStop bit): a new session starts
      // without "finalization already scheduled".
      session.clearAutoStop()
      autoStopDetector.reset()
      gain.reset()  // new session — zero gain, no residue from the previous recording
      vad.reset()
      lastVadSpeech = false
      liveLastCutIndex = 0
      resetLiveVADLocked()
      // Capture-readiness + timing reset for the new session: no ready cue
      // may fire before the first valid buffer of THIS generation.
      startupTriggerNanos = triggerNanos
      startupRequestNanos = requestNanos
      startupQueueEntryNanos = queueEntryNanos
      startupEngineStartedNanos = 0
      startupFirstAltNanos = pendingFirstAltNanos
      startupSecondAltNanos = pendingSecondAltNanos ?? triggerNanos
      pendingFirstAltNanos = nil
      pendingSecondAltNanos = nil
      startupInputReadyNanos = 0
      startupTapInstalledNanos = 0
      startupPrepareDoneNanos = 0
      startupFirstRawNanos = 0
      startupGeneration = startGeneration
      captureReadyFired = false
      captureReadyLive = false
    }
    lock.unlock()

    // Safe start from scratch: if the previous session left the engine with a
    // tap installed (failure branch), remove it BEFORE installTap — a repeat
    // installTap on the same bus raises NSException (crash). Generation gate:
    // a start DISPATCHED before the wedge but EXECUTED after it (queued behind
    // the hung engine) is stale — its top-of-start teardown would tear down
    // the LIVE fresh session (the tap on `tapInstalled` belongs to the new
    // engine; teardownOnEngineQueue also setRecording(false) + wipes buffers).
    // A stale start never reaches installTap (generation guard below), so the
    // leftover-tap removal is unnecessary for it; its stale engine is torn
    // down alone at that guard. Current start — unchanged behavior.
    if isTapInstalled, isCurrentGeneration(startGeneration) {
      teardownOnEngineQueue(using: engine)
    }

    // Input node and format bring-up under the same ObjC gateway as the whole
    // engine below: makeInputNode/outputFormat(forBus:)/AVAudioConverter can
    // raise NSException (SetOutputFormat on format desync after an
    // audio-device change or TCC-grant issue — Swift cannot catch it with try,
    // a bare call would crash the process SIGABRT). Results go into outer
    // capture variables (gateway body returns Void), the exception becomes
    // NSError and goes to the terminal branch below.
    var capturedInput: AudioInputNodeLike?
    var capturedHWFormat: AVAudioFormat?
    var capturedConverter: AVAudioConverter?
    var setupFailure = guardedEngineCall {
      capturedInput = engine.makeInputNode()
      capturedHWFormat = capturedInput?.outputFormat(forBus: 0)
    }
    // Converter reuse: a pre-warmed converter for the SAME hardware format
    // signature is reused instead of rebuilding expensive audio state on every
    // dictation. A device change alters the signature → rebuild, preserving
    // the device-change protection. No microphone capture involved.
    var reusedWarmedConverter = false
    var usedArmedFastPath = false
    if setupFailure == nil, let fmt = capturedHWFormat {
      let signature = Self.hwSignature(sampleRate: fmt.sampleRate, channels: fmt.channelCount)
      lock.lock()
      let warmed = (warmedHWSignature == signature) ? warmedConverter : nil
      let armedMatches =
        pendingArm?.generation == startGeneration && pendingArm?.hwSignature == signature
      if armedMatches {
        // Consume the pre-arm exactly once: a late duplicate start must not
        // reuse the same prepared graph.
        usedArmedFastPath = pendingArm?.prepared ?? false
        pendingArm = nil
      }
      // Stage stamp: input node/format resolved (whether armed or fresh).
      if isCurrentGeneration(startGeneration) {
        startupInputReadyNanos = Self.monotonicNanos()
      }
      lock.unlock()
      if let warmed {
        // AVAudioConverter is stateful (resample filter state): an instance
        // used by a previous session must be reset before reuse, otherwise
        // leftover state leaks into the next session (extra output samples,
        // VAD ringing on silence after prior speech).
        warmed.reset()
        capturedConverter = warmed
        reusedWarmedConverter = true
      } else {
        setupFailure = guardedEngineCall {
          capturedConverter = AVAudioConverter(from: fmt, to: self.targetFormat)
        }
        if setupFailure == nil, let built = capturedConverter {
          lock.lock()
          warmedConverter = built
          warmedHWSignature = signature
          lock.unlock()
        }
      }
    }
    if let setupFailure {
      // Terminal branch — like engine.start() below: the engine MUST be torn
      // down, else the next Alt+Alt crashes on a repeat installTap. Generation
      // guard first: if the engine that started was already wedge-swapped —
      // new-session state (session.end()/buffer reset) is off-limits, tear
      // down only the stale engine itself.
      guard isCurrentGeneration(startGeneration) else {
        teardownEngineOnly(using: engine)
        return .failure(setupFailure)
      }
      setRecording(false)
      teardownOnEngineQueue(using: engine)
      Logger.log(
        "record engine: input setup failed: \(setupFailure.localizedDescription)", level: "error")
      return .failure(setupFailure)
    }
    guard let input = capturedInput, let hwFormat = capturedHWFormat else {
      // Unreachable (makeInputNode never returns nil) — compiler reassurance.
      Logger.log("record engine: input node unavailable", level: "error")
      return .failure(AudioServiceError.unsupportedFormat)
    }
    guard let converter = capturedConverter else {
      Logger.log(
        "record engine: AVAudioConverter init failed (hw=\(Int(hwFormat.sampleRate)) Hz -> "
          + "target=\(Int(targetFormat.sampleRate)) Hz)",
        level: "error"
      )
      return .failure(AudioServiceError.unsupportedFormat)
    }
    lock.lock()
    guard isCurrentGeneration(startGeneration) else {
      lock.unlock()
      teardownEngineOnly(using: engine)
      return .failure(AudioServiceError.engineSuperseded)
    }
    self.converter = converter
    lock.unlock()
    // A stale start (unblocked AFTER the wedge swap) must not subscribe: its
    // engine is already discarded, and the token would clobber the fresh
    // session's observer, leaving the live device without a reaction to
    // device change. Generation guard here — BEFORE subscription; terminal
    // guards below stay for the tap/prepare/start stages.
    // Device-change subscription AFTER the converter is in state: a
    // notification may arrive right after registration.
    observeConfigurationChanges(for: engine)

    // Latency-critical path starts here: only tap install + prepare (unless
    // pre-armed) + engine.start(). Diagnostics logging moved AFTER a
    // successful start so string formatting never delays capture.
    // Breadcrumb before installTap: if the next AVFoundation call crashes, the
    // last log line pinpoints the exact place. No re-poll of the hardware
    // format here — the same call was already taken under the ObjC gateway in
    // the bring-up above (duplication added no information).
    if isDebug {
      Logger.log(
        "record engine: installing tap (bus 0, bufferSize \(Self.tapBufferSize), hwFormat=\(Int(hwFormat.sampleRate)) Hz)",
        level: "debug"
      )
    }

    // Tap on the hardware format; conversion happens in the block.
    var failure = guardedEngineCall {
      input.installTap(
        onBus: 0,
        bufferSize: Self.tapBufferSize,
        format: hwFormat
      ) { [weak self, tapGeneration = startGeneration] buffer, _ in
        guard let self else { return }
        // Tap of a discarded generation (engine wedge-swapped AFTER tap
        // install) silently drops buffers: a foreign audio stream must not
        // feed the new session. The old tap itself cannot be removed (its
        // engine may be stuck) — the generation guard is cheaper and safer.
        guard self.isCurrentGeneration(tapGeneration) else { return }
        self.process(buffer, tapGeneration: tapGeneration)
      }
    }
    if failure == nil, isCurrentGeneration(startGeneration) {
      setTapInstalled(true)
      lock.lock()
      startupTapInstalledNanos = Self.monotonicNanos()
      lock.unlock()
    }
    if failure == nil, isDebug {
      Logger.log("record engine: tap installed, engine.prepare()…", level: "debug")
    }
    // Pre-armed sessions already called engine.prepare() during the first-Alt
    // window on the same generation and format: skip the redundant second
    // prepare and go straight to engine.start(). Fresh sessions prepare here.
    if failure == nil, !usedArmedFastPath {
      failure = guardedEngineCall {
        engine.prepare()
      }
    }
    if failure == nil, isCurrentGeneration(startGeneration) {
      lock.lock()
      startupPrepareDoneNanos = Self.monotonicNanos()
      lock.unlock()
    }
    if failure == nil, isDebug {
      Logger.log("record engine: prepared, engine.start()…", level: "debug")
    }
    // isRecording set BEFORE engine.start(): the first buffer arriving right
    // after the audio stream starts must not be dropped. Capture readiness
    // still fires only on the first valid buffer (see process()), never here:
    // engine.start() success alone does not prove microphone data flows.
    if failure == nil {
      if isCurrentGeneration(startGeneration) {
        setRecording(true)
      }
      failure = guardedEngineCall {
        try engine.start()
      }
      if failure == nil, isCurrentGeneration(startGeneration) {
        lock.lock()
        startupEngineStartedNanos = Self.monotonicNanos()
        lock.unlock()
      }
    }
    if let failure {
      // Terminal branch: the engine MUST be torn down (tap removed, engine
      // stopped, buffers cleared) — else the next Alt+Alt crashes on a repeat
      // installTap on a busy bus. Generation guard, as in the setup-failure
      // branch: a start unblocked AFTER the swap does not touch the new
      // session's state — only tears down the stale engine itself.
      guard isCurrentGeneration(startGeneration) else {
        teardownEngineOnly(using: engine)
        return .failure(failure)
      }
      setRecording(false)
      teardownOnEngineQueue(using: engine)
      Logger.log("record engine: start failed: \(failure.localizedDescription)", level: "error")
      return .failure(failure)
    }
    // Success-branch generation guard: if the engine that STARTED recording is
    // no longer current (its start() unblocked after the wedge swap) — .success
    // cannot be returned: the agent would call audio.cancel() on the CURRENT
    // (possibly live) fresh pair. Tear down only the stale engine and mark the
    // start .failure(.engineSuperseded) — the agent's watchdog completion
    // ignores it, no cancel() follows.
    guard isCurrentGeneration(startGeneration) else {
      Logger.log("record engine: stale start completed after wedge — discarded", level: "info")
      teardownEngineOnly(using: engine)
      return .failure(AudioServiceError.engineSuperseded)
    }
    if isDebug {
      Logger.log("record engine: started OK", level: "debug")
    }
    // Engine-started breadcrumb (monotonic): request → engine-started delay is
    // now measurable even before the first buffer arrives. The full
    // request → engine-started → first-buffer timeline completes in process()
    // on capture readiness. No ready cue is emitted here by design.
    lock.lock()
    let reqNanos = startupRequestNanos
    let engNanos = startupEngineStartedNanos
    lock.unlock()
    if engNanos > 0, engNanos >= reqNanos, reqNanos > 0 {
      let ms = Self.ms(fromNanos: reqNanos, to: engNanos)
      Logger.log(
        String(format: "record startup: engine started in %.1f ms (capture pending)", ms),
        level: "info"
      )
    }
    if reusedWarmedConverter, isDebug {
      Logger.log("record prewarm: warmed converter reused for start", level: "debug")
    }
    if usedArmedFastPath {
      Logger.log("record pre-arm: armed fast path consumed (prepare skipped)", level: "info")
    }
    // Deferred diagnostics: string formatting stays off the latency-critical
    // path above (tap install → prepare → engine.start). Safe here — capture
    // is already flowing or imminent, and these logs carry no timing.
    let mic = MicrophoneAuth.statusText(AVCaptureDevice.authorizationStatus(for: .audio))
    Logger.log("mic permission: \(mic) (record start)", level: "info")
    Logger.log(
      "record start: sampleRate=\(Int(targetFormat.sampleRate)) Hz, channels=\(targetFormat.channelCount), "
        + "hwFormat=\(Int(hwFormat.sampleRate)) Hz tap=\(Self.tapBufferSize)",
      level: "info"
    )
    Logger.log(
      "record auto-stop: enabled=\(autoStopConfig.enabled), "
        + "speech>=\(autoStopConfig.speechRMSThreshold), silence<\(autoStopConfig.silenceRMSThreshold), "
        + "silence>=\(String(format: "%.1f", autoStopConfig.requiredSilenceDuration))s, "
        + "grace=\(String(format: "%.1f", autoStopConfig.gracePeriod))s, "
        + "gate>=\(String(format: "%.1f", autoStopConfig.minSpeechRun))s, "
        + "minRecord=\(String(format: "%.1f", autoStopConfig.minRecordingDuration))s",
      level: "info"
    )
    Logger.log(
      "record input-gain: enabled=\(gain.config.enabled), "
        + "target=\(String(format: "%.1f", gain.config.targetRmsDb)) dBFS, "
        + "max=\(String(format: "%.1f", gain.config.maxGainDb)) dB",
      level: "info"
    )
    return .success(())
  }

  // MARK: - Стоп / отмена

  /// Stops recording and returns the collected samples (Int16, 16 kHz). Sample
  /// snapshot is synchronous (as before); engine teardown goes to engineQueue
  /// so the main thread never blocks.
  public func stop() -> [Int16] {
    lock.lock()
    guard isRecordingLocked else {
      lock.unlock()
      return []
    }
    let duration = CFAbsoluteTimeGetCurrent() - recordStartTime
    setRecording(false)
    // Capture readiness ends with the session: the next start resets it, and
    // no late buffer may re-fire it (process drops buffers once !isRecording).
    captureReadyLive = false
    // "Tail" range + COW snapshot under one lock (VAD state and recording
    // buffer stay consistent); Array materialization AFTER unlock so the
    // lock holds only O(1) bookkeeping.
    let tailRange = liveTailRangeLocked()
    let tailSnapshot = tailRange != nil ? collectedSamples : [Int16]()
    let samples = collectedSamples
    collectedSamples.removeAll(keepingCapacity: true)
    let rms = rmsHistory
    rmsHistory.removeAll(keepingCapacity: true)
    lock.unlock()
    var tail: [Int16] = []
    if let range = tailRange {
      let lo = max(0, range.lowerBound)
      let hi = min(tailSnapshot.count, range.upperBound)
      if hi > lo {
        tail = Array(tailSnapshot[lo..<hi])
      }
    }

    // Teardown on the queue of THE engine this recording used (pair snapshot
    // under lock): seriality with operations already staged there is kept, and
    // after a wedge swap the concrete teardown goes to its own (already
    // discarded) instance's queue, holding nobody else.
    let slot = captureEngineSlot()
    slot.queue.async { [weak self, engine = slot.engine, generation = slot.generation] in
      guard let self else { return }
      // Stale engine (wedge swap after the snapshot): teardown the engine
      // only — the live session's state belongs to the fresh pair.
      if self.isCurrentGeneration(generation) {
        self.teardownOnEngineQueue(using: engine)
      } else {
        self.teardownEngineOnly(using: engine)
      }
    }
    logRecordingFinale(samples: samples, duration: duration, rmsHistory: rms)
    // Open utterance recognized as the last segment: no speech since its
    // start, so it covers the final phrase whole.
    if !tail.isEmpty {
      onSpeechSegment?(tail, true)
    }
    return samples
  }

  public func cancel() {
    lock.lock()
    guard isRecordingLocked else {
      lock.unlock()
      return
    }
    let duration = CFAbsoluteTimeGetCurrent() - recordStartTime
    let frames = collectedSamples.count
    setRecording(false)
    // Cancel aborts a pending capture-ready wait too: the session never
    // becomes ready, and the ready cue must never fire for it.
    captureReadyLive = false
    captureReadyFired = true
    collectedSamples.removeAll(keepingCapacity: true)
    // Cancel discards EVERYTHING, including the open utterance: no
    // onSpeechSegment callback (Esc = no delivery).
    liveLastCutIndex = 0
    resetLiveVADLocked()
    lock.unlock()

    // Teardown on the same engine's queue (pair snapshot under lock), see the
    // stop() comment.
    let cancelSlot = captureEngineSlot()
    cancelSlot.queue.async { [weak self, engine = cancelSlot.engine, generation = cancelSlot.generation] in
      guard let self else { return }
      // Generation guard as in stop(): a stale engine is torn down only,
      // the live session's state stays untouched.
      if self.isCurrentGeneration(generation) {
        self.teardownOnEngineQueue(using: engine)
      } else {
        self.teardownEngineOnly(using: engine)
      }
    }
    // Cancel also finishes the recording — no STT send; duration and volume tell
    // an "empty" cancel from one after real speech.
    if isDebug {
      Logger.log(
        String(
          format: "record cancel: duration=%.2f s, frames=%d, bytes=%d",
          duration,
          frames,
          frames * 2
        ),
        level: "debug"
      )
    }
  }

  // MARK: - Восстановление после зависания

  /// Replaces a "wedged" engine — recovery after a record-start timeout (the
  /// Agent's bring-up watchdog calls it when engine.start() did not return in
  /// time; typical scenario — audio-device change after the TCC grant blocks
  /// start in HAL forever). The old instance is discarded, a FRESH
  /// AVAudioEngine lands in the property — the next start() reinstalls
  /// tap/format/converter from scratch.
  /// Swap runs SYNCHRONOUSLY on the calling thread (not via the engine queue!):
  /// the wedged instance's queue may be blocked forever by its engine.start() —
  /// staging the swap on the same queue would mean recovery NEVER happens
  /// (exactly the defective scheme this method exists for). Under lock the WHOLE
  /// pair changes (engine + its queue): the fresh factory engine gets ITS OWN
  /// queue, the old pair is discarded whole. Teardown and release of the OLD
  /// engine — on a separate global queue: its stop() may get stuck on the same
  /// HAL that hung in start(), and must hold nobody's queue.
  /// Safe in any state, idempotent: a repeat call just replaces the already
  /// fresh engine once more.
  public func replaceEngineAfterWedge() {
    let oldEngine: AudioEngineLike
    lock.lock()
    oldEngine = engine
    engine = engineFactory()
    engineQueue = DispatchQueue(label: "nanodictate.audio.engine", qos: .userInitiated)
    // New generation: operations and tap blocks of the old engine (if its
    // start() unblocks later) see the generation mismatch and do not touch
    // state; new starts get a fresh stamp.
    session.advanceGeneration()
    // tap and converter belonged to the old engine — fresh start reinstalls
    // them from scratch (repeat installTap on a busy bus = NSException).
    tapInstalled = false
    converter = nil
    // Reuse buffers belonged to the old generation's tap callback: invalidate
    // so an in-flight stale callback never shares mutable instances with the
    // fresh engine's callback (a stale callback that already checked out its
    // locals keeps them privately; the fresh generation allocates its own).
    reusableConvertedBuffer = nil
    scratchInt16 = []
    reusableBuffersGeneration = nil
    // Warmed converter belonged to the old engine/format path — drop it; the
    // next start (or prewarm) rebuilds for the fresh engine. A pending
    // capture-ready wait is invalidated with the generation: the ready cue
    // must never fire for the discarded session.
    warmedConverter = nil
    warmedHWSignature = nil
    // A pre-arm built for the wedged engine is meaningless on the fresh
    // engine: drop it so the next start performs a full bring-up.
    pendingArm = nil
    pendingFirstAltNanos = nil
    pendingSecondAltNanos = nil
    captureReadyFired = true
    captureReadyLive = false
    startupGeneration = -1
    lock.unlock()
    // Device-change subscription belonged to the OLD engine: its
    // configuration-change must not stop recording on the fresh pair.
    removeConfigurationObserver()
    Logger.log(
      "record engine: wedged engine replaced — fresh AVAudioEngine installed", level: "info")
    // Old-engine teardown off the engine queues (see the method comment).
    DispatchQueue.global(qos: .utility).async { [weak self] in
      guard let self else { return }
      _ = self.guardedEngineCall {
        oldEngine.stop()
      }
      // oldEngine released on block exit — dealloc away from engine queues.
    }
  }

  // MARK: - Private

  /// Runs a block of engine operations under the ObjC gateway: an AVFAudio
  /// NSException becomes NSError, a Swift error (engine.start() throws) passes
  /// through as-is. nil — the operation completed without errors.
  func guardedEngineCall(_ body: @escaping () throws -> Void) -> Error? {
    final class ErrorBox {
      var captured: Error?
    }
    let box = ErrorBox()
    let nsError = NanoDictateRunAudioEngineBlockGuarded {
      do {
        try body()
      } catch {
        box.captured = error
      }
    }
    return nsError ?? box.captured
  }

  /// Engine teardown — strictly on THIS engine's queue. Idempotent: removing an
  /// uninstalled tap / stopping a non-running engine is safe (all calls under
  /// the NSException gateway). Engine passed explicitly (pair snapshot), not
  /// taken from the property: teardown may run for an instance already
  /// discarded by the swap.
  private func teardownOnEngineQueue(using engine: AudioEngineLike) {
    if isTapInstalled {
      _ = guardedEngineCall {
        engine.makeInputNode().removeTap(onBus: 0)
      }
      setTapInstalled(false)
    }
    _ = guardedEngineCall {
      engine.stop()
    }
    setRecording(false)
    // Device-change subscription removed BEFORE the state reset: the
    // notification is about a recording session — after teardown it has
    // nothing to do.
    removeConfigurationObserver()
    lock.lock()
    converter = nil
    // Preserve bounded capacity across sessions: the next start (or pre-arm)
    // reuses the store without regrowing under the shared lock.
    collectedSamples.removeAll(keepingCapacity: true)
    rmsHistory.removeAll(keepingCapacity: true)
    liveLastCutIndex = 0
    session.clearAutoStop()
    autoStopDetector.reset()
    vad.reset()
    lastVadSpeech = false
    resetLiveVADLocked()
    // Session ended: capture readiness lapses with it (next start resets).
    // The warmed converter cache is KEPT — it holds no microphone state and
    // makes the next start cheaper (reused when the format matches).
    // A pending pre-arm does not survive teardown: the graph it prepared
    // belongs to the torn-down session (device-change safety).
    pendingArm = nil
    captureReadyLive = false
    lock.unlock()
    // Best-effort re-warm for the next dictation (still on this engine's
    // queue, no capture): keeps cold-start latency low without an always-on
    // microphone. Failures are silent — the next start rebuilds as before.
    refreshWarmedConverterBestEffort(using: engine)
  }

  /// Best-effort converter re-warm after teardown (engine queue only).
  /// Queries the current input format and caches a fresh converter when the
  /// cached signature no longer matches. Never touches session state.
  private func refreshWarmedConverterBestEffort(using engine: AudioEngineLike) {
    var hwFormat: AVAudioFormat?
    let setupError = guardedEngineCall {
      hwFormat = engine.makeInputNode().outputFormat(forBus: 0)
    }
    guard setupError == nil, let hw = hwFormat else { return }
    let signature = Self.hwSignature(sampleRate: hw.sampleRate, channels: hw.channelCount)
    lock.lock()
    let cached = (warmedHWSignature == signature) ? warmedConverter : nil
    lock.unlock()
    // The cached instance may be the converter just used for live streaming
    // (same object as the session converter): reset its filter state so the
    // next start reuses a clean converter, identical to a fresh instance.
    if let cached {
      cached.reset()
      return
    }
    var converter: AVAudioConverter?
    let converterError = guardedEngineCall {
      converter = AVAudioConverter(from: hw, to: self.targetFormat)
    }
    guard converterError == nil, let built = converter else { return }
    lock.lock()
    warmedConverter = built
    warmedHWSignature = signature
    lock.unlock()
  }

  /// Teardown of ONLY the stale engine (remove its tap, stop it) — without
  /// touching the global session state (isRecording, buffers, converter). For
  /// starts that completed after a generation swap: a full teardown
  /// (teardownOnEngineQueue) would reset the live NEW session on the fresh
  /// engine. Device-change subscription removed only for ITS engine: the live
  /// session's observer belongs to another instance and stays in place.
  private func teardownEngineOnly(using engine: AudioEngineLike) {
    _ = guardedEngineCall {
      engine.makeInputNode().removeTap(onBus: 0)
    }
    _ = guardedEngineCall {
      engine.stop()
    }
    removeConfigurationObserver(for: engine)
  }

  /// Device-change subscription for a recording session. AVFAudio headers have
  /// NO `configurationChangeHandler` property — the only channel is
  /// `AVAudioEngineConfigurationChangeNotification` (AVAudioEngine.h,
  /// macOS 10.10+). Observed via NotificationCenter with the object of THIS
  /// session: foreign engines (wedge swap) do not wake their observers.
  /// `userInfo` not parsed — `handleConfigurationChange` decides (recording
  /// stops with an explicit error). Token lives under lock:
  /// `replaceEngineAfterWedge` removes the subscription from the calling
  /// thread, not the engine queue.
  private func observeConfigurationChanges(for engine: AudioEngineLike) {
    let token = NotificationCenter.default.addObserver(
      forName: .AVAudioEngineConfigurationChange,
      object: engine as? AVAudioEngine,
      queue: nil
    ) { [weak self] _ in
      self?.handleConfigurationChange()
    }
    lock.lock()
    let stale = configChangeObserver
    configChangeObserver = ConfigurationChangeObserver(token: token, engine: engine)
    lock.unlock()
    // Old token removed outside lock: NotificationCenter is foreign code — no
    // state work under the lock.
    if let stale = stale { NotificationCenter.default.removeObserver(stale.token) }
  }

  /// Removes the device-change subscription. Callers: teardown points
  /// (teardownOnEngineQueue), engine replacement after wedge, new session
  /// recording (via observeConfigurationChanges).
  private func removeConfigurationObserver() {
    lock.lock()
    let observer = configChangeObserver
    configChangeObserver = nil
    lock.unlock()
    if let observer = observer { NotificationCenter.default.removeObserver(observer.token) }
  }

  /// Removes the subscription ONLY for a given engine (stale start branches):
  /// the live session's token on the fresh engine is untouched.
  private func removeConfigurationObserver(for engine: AudioEngineLike) {
    lock.lock()
    let token: NSObjectProtocol?
    if let observer = configChangeObserver, observer.engine === engine {
      token = observer.token
      configChangeObserver = nil
    } else {
      token = nil
    }
    lock.unlock()
    if let token = token { NotificationCenter.default.removeObserver(token) }
  }

  /// Device-change handler during recording: tap and converter are bound to the
  /// OLD input format, the engine rebuilt its graph. Live recovery of
  /// tap/converter is IMPOSSIBLE: the tap hangs on the old input node, a
  /// repeat installTap on the rebuilt bus throws NSException; the resample
  /// converter was computed from the old hwFormat. So recording stops, and
  /// the user gets an EXPLICIT `.deviceChanged` error via onDeviceChange
  /// (callback — the UI decides: toast/alert/auto re-record).
  /// Locking: isRecording read under lock, state NOT reset HERE — stop()
  /// itself clears flags and tears down tap/engine. Double stop safe (stop is
  /// idempotent through the same isRecording guard).
  private func handleConfigurationChange() {
    // A device change invalidates any non-capturing pre-arm even when idle:
    // the armed converter/prepare belong to the old input format.
    lock.lock()
    pendingArm = nil
    lock.unlock()
    // isRecording read without NSLock: the notification may arrive on a
    // foreign queue, and the `session` ledger holds no state lock.
    guard isRecordingLocked else { return }
    Logger.log("record engine: configuration changed — stopping, user must restart", level: "warn")
    // Whole finalization on the main queue: the notification arrives on the
    // poster's thread (system AVFAudio thread), while the stop()/
    // onSpeechSegment/onDeviceChange contract requires "tail and callbacks on
    // main". Re-check of the flag inside — if the user already stopped, do
    // nothing. Session samples are delivered by stop() itself (its
    // finalization path) — not needed here.
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isRecordingLocked else { return }
      _ = self.stop()
      self.onDeviceChange?(AudioServiceError.deviceChanged)
    }
  }

  private func resetLiveVADLocked() {
    liveUtteranceStart = nil
    liveUtteranceEnd = 0
    liveSilenceStart = nil
    liveSpeechDurationSamples = 0
  }

  /// Snapshot of the open utterance ("tail") under lock. Tail — speech from
  /// utterance start to the last SPEECH portion (no trailing silence); when
  /// the pause lasts to the very stop, this hides the "silence" after the
  /// phrase. Empty if speech never started. VAD state reset. The shared
  /// recording buffer untouched — the tail is passed by COPY.
  private func takeLiveTailLocked() -> [Int16] {
    guard let range = liveTailRangeLocked() else { return [] }
    let lo = max(0, range.lowerBound)
    let hi = min(collectedSamples.count, range.upperBound)
    guard hi > lo else { return [] }
    return Array(collectedSamples[lo..<hi])
  }

  /// Range of the open utterance without copying. Caller materializes the
  /// Array AFTER unlock from a COW snapshot, so large memcpy never extends
  /// the lock hold. Resets VAD state like `takeLiveTailLocked`.
  private func liveTailRangeLocked() -> Range<Int>? {
    defer { resetLiveVADLocked() }
    guard let start = liveUtteranceStart else { return nil }
    let end = min(liveUtteranceEnd, collectedSamples.count)
    guard end > start else { return nil }
    return start..<end
  }

  /// The value truly belongs to the recording: `begin` sets the recording bit
  /// in the ledger with one atomic operation (generation untouched — only the
  /// wedge swap's advanceGeneration changes it), `end` clears recording and
  /// auto-stop.
  private func setRecording(_ value: Bool) {
    if value {
      session.begin()
    } else {
      session.end()
    }
  }

  private var isRecordingLocked: Bool {
    session.isRecording
  }

  /// Generation check from the realtime path, without NSLock: a discarded
  /// engine's tap block must not touch the new session's state (see
  /// SessionLedger).
  private func isCurrentGeneration(_ generation: Int) -> Bool {
    session.isCurrentGeneration(generation)
  }

  private var isAutoStopScheduled: Bool {
    session.snapshot.autoStopScheduled
  }

  private func setTapInstalled(_ value: Bool) {
    lock.lock()
    tapInstalled = value
    lock.unlock()
  }

  private var isTapInstalled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return tapInstalled
  }

  /// Intake-state snapshot under one lock: recording flag, forced-stop flags
  /// and the converter. Closes the start/stop/swap race — process sees a
  /// consistent trio.
  private struct BufferedSnapshot {
    var alive: Bool
    var converter: AVAudioConverter?
  }

  private func takeBufferedSnapshot() -> BufferedSnapshot {
    // Session flags read FIRST and without NSLock: on a blocked lock (e.g.
    // during a VAD rebuild inside stop/performForcedStop) the realtime
    // tap thread gets to see "no recording" and exits instead of queueing
    // behind the lock. The counter latches at session start, so a live buffer
    // after the flag cleared is not needed. Then the full-weight snapshot
    // (converter) — under NSLock; both sources are consistent because the
    // session-owner thread writes both.
    guard isRecordingLocked else {
      return BufferedSnapshot(alive: false, converter: nil)
    }
    lock.lock()
    defer { lock.unlock() }
    let alive = !limit.isExhausted && !isAutoStopScheduled
    return BufferedSnapshot(alive: alive, converter: converter)
  }

  /// Session-lifecycle ledger: takes NSLock (mutex with possible syscall and
  /// priority inversion) off the realtime tap-callback path. Primitive —
  /// `os_unfair_lock`: uncontended it is one atomic CAS in userspace, no
  /// system calls or ObjC runtime (raw C11 atomics would need edits outside
  /// the zone — C wrappers in AudioEngineGuard; no swift-atomics dependency in
  /// the package). The state word packs the trio
  /// (generation/isRecording/autoStopScheduled): generation in the high word,
  /// flags in the low two bits; read in one packet under a single acquisition.
  /// Acquisitions are short (a few instructions). Nesting allowed ONLY one
  /// way: NSLock→unfair — NSLock taken and, while held, unfair is taken (that
  /// is how all ledger accesses from under `lock` run: nested stop/start/
  /// teardown calls and their bodies). The reverse nesting (taking NSLock
  /// while holding unfair) does not occur in code and is forbidden. A cycle is
  /// impossible: unfair is never held when taking NSLock (unfair acquisitions
  /// are short, with no blocking calls or foreign queues). Full-weight
  /// buffer/converter snapshots — still NSLock in `takeBufferedSnapshot`.
  struct SessionSnapshot {
    let generation: Int
    let isRecording: Bool
    let autoStopScheduled: Bool
  }

  final class SessionLedger: @unchecked Sendable {
    /// Heap-allocated lock: `&unfair` on a stored property is not a stable
    /// address (property can move with the struct/class), so the lock lives
    /// on the heap and is initialized in `init`.
    private let lock: os_unfair_lock_t = .allocate(capacity: 1)
    private var word: UInt64 = 0
    /// Bit 0 — recording; bit 1 — auto-stop scheduler latch.
    private static let recordingBit: UInt64 = 1
    private static let autoStopBit: UInt64 = 2
    /// High word — generation counter; low — flag field.
    private static let generationShift: UInt64 = 32

    init(generation: Int) {
      lock.initialize(to: os_unfair_lock())
      word = UInt64(clamping: generation) << Self.generationShift
    }

    deinit {
      lock.deinitialize(count: 1)
      lock.deallocate()
    }

    var snapshot: SessionSnapshot {
      os_unfair_lock_lock(lock)
      defer { os_unfair_lock_unlock(lock) }
      return unpack(word)
    }

    /// `isRecording` read outside NSLock for the realtime thread's early exit
    /// (full snapshot — see `takeBufferedSnapshot`).
    var isRecording: Bool {
      os_unfair_lock_lock(lock)
      defer { os_unfair_lock_unlock(lock) }
      return word & Self.recordingBit != 0
    }

    /// Lock-free generation check (tap block, start terminal branches).
    func isCurrentGeneration(_ generation: Int) -> Bool {
      os_unfair_lock_lock(lock)
      defer { os_unfair_lock_unlock(lock) }
      return Int(word >> Self.generationShift) == generation
    }

    /// Start transition: sets ONLY the recording bit, one atomic OR. Generation
    /// NOT written: the single `advanceGeneration` (wedge swap) changes it,
    /// and a read-modify-write of the generation across two separate unfair
    /// acquisitions (take snapshot, put the generation back) would be TOCTOU —
    /// a parallel advanceGeneration between them would roll the generation
    /// back. The flag is read from the ledger without a lock — `begin` is
    /// called on the thread that already owns the session (engine queue or
    /// main).
    func begin() {
      os_unfair_lock_lock(lock)
      defer { os_unfair_lock_unlock(lock) }
      word |= Self.recordingBit
    }

    /// Stop transition: clears recording + autoStop, generation kept.
    func end() {
      os_unfair_lock_lock(lock)
      defer { os_unfair_lock_unlock(lock) }
      word &= ~(Self.recordingBit | Self.autoStopBit)
    }

    /// Clears the auto-stop latch — a new session starts without "finalization
    /// already scheduled" (recording flag untouched: `begin` sets it).
    func clearAutoStop() {
      os_unfair_lock_lock(lock)
      defer { os_unfair_lock_unlock(lock) }
      word &= ~Self.autoStopBit
    }

    /// Auto-stop latch: the scheduler bit; generation/recording kept.
    func latchAutoStop() {
      os_unfair_lock_lock(lock)
      defer { os_unfair_lock_unlock(lock) }
      word |= Self.autoStopBit
    }

    /// Wedge-swap generation step: counter +1, recording/autoStop cleared.
    @discardableResult
    func advanceGeneration() -> Int {
      os_unfair_lock_lock(lock)
      defer { os_unfair_lock_unlock(lock) }
      let generation = Int(word >> Self.generationShift) + 1
      word = UInt64(clamping: generation) << Self.generationShift
      return generation
    }

    private func unpack(_ packed: UInt64) -> SessionSnapshot {
      SessionSnapshot(
        generation: Int(packed >> Self.generationShift),
        isRecording: packed & Self.recordingBit != 0,
        autoStopScheduled: packed & Self.autoStopBit != 0
      )
    }
  }

  /// Real resample output size scales with rates:
  /// `inputFrames × outputRate / inputRate` + a ¼ margin, so the converter
  /// fills the output in one pass from one input buffer.
  static func outputFrameCapacity(
    forInputFrames inputFrames: AVAudioFrameCount,
    inputRate: Double,
    outputRate: Double
  ) -> AVAudioFrameCount {
    // Zero-division guard: unreachable in prod, but the helper is internal
    // and tested.
    guard inputRate > 0, outputRate > 0 else { return 0 }
    let base = Int(Double(inputFrames) * outputRate / inputRate)
    return AVAudioFrameCount(base + max(1, base / 4))
  }

  /// One converter pass (input drive). The input buffer is handed exactly ONCE
  /// (`.haveData`); on all later requests — nil + `.noDataNow`: the converter
  /// does not pull the same piece again, and `.noDataNow` (unlike
  /// `.endOfStream`) does not latch the converter — it stays alive for the
  /// next buffers.
  /// Non-empty output valid at `.haveData`/`.inputRanDry`/`.endOfStream`;
  /// only empty results and errors are discarded.
  static func convertOnce(
    input: AVAudioPCMBuffer,
    inputFormat: AVAudioFormat,
    converter: AVAudioConverter,
    targetFormat: AVAudioFormat
  ) -> (converted: AVAudioPCMBuffer, status: AVAudioConverterOutputStatus)? {
    guard
      let result = convertOnce(
        input: input, inputFormat: inputFormat, converter: converter, targetFormat: targetFormat,
        reusing: nil)
    else { return nil }
    return (result.converted, result.status)
  }

  /// Reusable-buffer variant of `convertOnce` for the steady-state tap path.
  /// When `reusing` fits (same target format and enough frameCapacity) it is
  /// refilled in place and returned with `reused == true`, so the callback
  /// allocates no new AVAudioPCMBuffer. Otherwise a new buffer is allocated
  /// and returned with `reused == false` for the caller to cache.
  static func convertOnce(
    input: AVAudioPCMBuffer,
    inputFormat: AVAudioFormat,
    converter: AVAudioConverter,
    targetFormat: AVAudioFormat,
    reusing reusable: AVAudioPCMBuffer?
  ) -> (converted: AVAudioPCMBuffer, status: AVAudioConverterOutputStatus, reused: Bool)? {
    let required = outputFrameCapacity(
      forInputFrames: input.frameLength,
      inputRate: inputFormat.sampleRate,
      outputRate: targetFormat.sampleRate
    )
    var output: AVAudioPCMBuffer?
    var reused = false
    if let reusable,
      reusable.format.sampleRate == targetFormat.sampleRate,
      reusable.format.channelCount == targetFormat.channelCount,
      reusable.frameCapacity >= required
    {
      reusable.frameLength = 0
      output = reusable
      reused = true
    } else {
      output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: required)
    }
    guard let converted = output else { return nil }

    var fedInput = false
    let status = converter.convert(to: converted, error: nil) { _, outStatus in
      if fedInput {
        outStatus.pointee = .noDataNow
        return nil
      }
      fedInput = true
      outStatus.pointee = .haveData
      return input
    }
    guard converted.frameLength > 0, status != .error else { return nil }
    return (converted, status, reused)
  }

  /// Single-sample Float32 -> Int16 clipping conversion shared by the tap path
  /// and tests. No allocation; order-preserving.
  static func clipFloatToInt16(_ sample: Float) -> Int16 {
    if sample > 1.0 { return Int16(32767) }
    if sample <= -1.0 { return Int16(-32768) }
    return Int16(sample * 32767)
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func process(_ buffer: AVAudioPCMBuffer, tapGeneration: Int) {
    // Generation gate at process entry: the tap block checked before dispatch,
    // but `replaceEngineAfterWedge()` may have advanced the generation since —
    // a stale callback must not touch the fresh session's buffers or state.
    guard isCurrentGeneration(tapGeneration) else { return }
    // Early "is recording?" guard BEFORE conversion and AGC: after stop()/start()
    // a late buffer of the old tap must not touch InputGain state — reset() of
    // the new session (engineQueue, under lock) and apply (audio stream) do
    // not overlap (the guard below stays — protection duplicated).
    // All flags and the converter are taken under lock in one snapshot: the
    // lock-free guard is gone — start/stop race closed (see takeBufferedSnapshot).
    // First raw tap callback stamp (before conversion): proves HAL delivery
    // independent of converter/VAD cost. Exactly once per session generation.
    lock.lock()
    if isCurrentGeneration(tapGeneration), isCurrentGeneration(startupGeneration),
      startupFirstRawNanos == 0, startupEngineStartedNanos > 0
    {
      startupFirstRawNanos = Self.monotonicNanos()
    }
    lock.unlock()
    let snapshot = takeBufferedSnapshot()
    guard snapshot.alive else { return }
    guard isCurrentGeneration(tapGeneration) else { return }
    guard let converter = snapshot.converter else {
      logDroppedBuffer(reason: "converter is nil (stopped?)", frames: buffer.frameLength)
      return
    }
    // Per-generation checkout of the reuse buffers (O(1) under lock). A tag
    // match moves the staging storage to a local so the fill below mutates
    // uniquely-owned memory (no COW copy) that no other generation shares; a
    // mismatch (fresh generation after a wedge swap) starts from empty locals
    // so old and new callbacks never share mutable instances outside the lock.
    let cachedConverted: AVAudioPCMBuffer?
    var localScratch: [Int16]
    lock.lock()
    if reusableBuffersGeneration == tapGeneration {
      cachedConverted = reusableConvertedBuffer
      localScratch = scratchInt16
      scratchInt16 = []
    } else {
      cachedConverted = nil
      localScratch = []
    }
    lock.unlock()
    guard
      let result = AudioService.convertOnce(
        input: buffer,
        inputFormat: buffer.format,
        converter: converter,
        targetFormat: targetFormat,
        reusing: cachedConverted
      )
    else {
      // Conversion failed: restore the moved staging storage when this
      // generation still owns the slots, so steady-state reuse keeps its
      // capacity. A stale generation discards its locals — the fresh
      // generation owns the slots now and must not be clobbered.
      lock.lock()
      if isCurrentGeneration(tapGeneration),
        reusableBuffersGeneration == tapGeneration
      {
        scratchInt16 = localScratch
      }
      lock.unlock()
      logDroppedBuffer(
        reason: "convertOnce -> nil (empty output or error)", frames: buffer.frameLength)
      return
    }
    // Stale during conversion (the wedge swap unblocked mid-convert): drop
    // before touching VAD/gain/recording state or caching buffers — the fresh
    // generation owns the slots now.
    guard isCurrentGeneration(tapGeneration) else { return }
    guard let channel = result.converted.floatChannelData?[0] else {
      lock.lock()
      if isCurrentGeneration(tapGeneration),
        reusableBuffersGeneration == tapGeneration
      {
        scratchInt16 = localScratch
      }
      lock.unlock()
      logDroppedBuffer(reason: "converted buffer has no float channel", frames: buffer.frameLength)
      return
    }
    let converted = result.converted
    let frameLength = Int(converted.frameLength)

    // RMS BEFORE gain — raw/pre-gain signal. VAD and auto-stop decide on this
    // raw value (issue #21); AGC conditions the buffer below without driving
    // speech decisions.
    var sum: Float = 0
    for i in 0..<frameLength {
      let sample = channel[i]
      sum += sample * sample
    }
    let rms = frameLength > 0 ? sqrt(sum / Float(frameLength)) : 0
    let bufferDuration = frameLength > 0 ? Double(frameLength) / Double(targetFormat.sampleRate) : 0
    // Adaptive speech decision on the raw signal (noise floor + hysteresis).
    // Independent from the AGC floor tracker: gain never drives VAD.
    // process() runs on the audio thread; vad state is confined here behind
    // the session liveness checks (takeBufferedSnapshot + isRecordingLocked
    // below). Teardown/start resets run under lock on other queues but only
    // when not recording, so no concurrent mutation with live buffers.
    vad.update(rms: rms, duration: bufferDuration)
    let vadIsSpeech: Bool = vad.isSpeech
    let vadFloor = vad.noiseFloor
    let vadEnter = vad.enterThreshold
    let vadExit = vad.exitThreshold
    // Digital gain (AGC) here, mutating the buffer in place: level metric and
    // Int16 recording see the conditioned signal. Metering recomputed from the
    // amplified buffer (soft limiter accounted); with AGC off
    // (`NANODICTATE_GAIN_DISABLED=1`) the buffer passes unchanged, metric = rms.
    let meteredRms = gain.apply(
      to: channel,
      frameLength: frameLength,
      rms: rms,
      sampleRate: Int(targetFormat.sampleRate)
    )
    let appliedGainDb = gain.currentGainDb
    // Float32->Int16 staging OUTSIDE the shared lock: per-sample clipping here,
    // bulk append under the lock below. `localScratch` is the checked-out
    // per-generation staging (grows only), so steady state allocates no
    // temporary Array and no generation shares mutable staging outside the lock.
    if localScratch.count < frameLength {
      localScratch.reserveCapacity(frameLength)
      while localScratch.count < frameLength {
        localScratch.append(0)
      }
    }
    for i in 0..<frameLength {
      localScratch[i] = Self.clipFloatToInt16(channel[i])
    }
    // Synchronous delegate delivery (no queue, no allocation): the UI-side
    // coalescing lives in the Agent (`audioLevelChanged` keeps at most one
    // pending main-queue update), so stale levels never pile up.
    levelDelegate?.audioLevelChanged(rms: meteredRms)
    // Debug diagnostics: raw level, floor, VAD state and gain. No raw audio.
    if isDebug, vadIsSpeech != lastVadSpeech {
      lastVadSpeech = vadIsSpeech
      Logger.log(
        String(
          format:
            "record vad: %@ raw=%.4f (%.1f dBFS) floor=%.4f (%.1f dBFS) enter=%.4f exit=%.4f gain=%+.1f dB",
          vadIsSpeech ? "speech" : "silence",
          Double(rms),
          Double(AudioMetrics.dbfs(rms)),
          Double(vadFloor),
          Double(AudioMetrics.dbfs(vadFloor)),
          Double(vadEnter),
          Double(vadExit),
          Double(appliedGainDb)
        ),
        level: "debug"
      )
    } else if isDebug {
      lastVadSpeech = vadIsSpeech
    }

    // All shared memory (isRecording, collectedSamples, rmsHistory, limit,
    // live-VAD) — under the lock: stop()/cancel() take a snapshot on main
    // synchronously with the accumulation here. Kept minimal: bulk append plus
    // O(1) bookkeeping. The completed-segment copy happens AFTER unlock from a
    // COW snapshot + range, so large memcpy never extends the hold time.
    var segmentRangeToDeliver: Range<Int>?
    var segmentSnapshot: [Int16]?
    var deliveredSegment: [Int16]?
    lock.lock()
    guard isCurrentGeneration(tapGeneration) else {
      lock.unlock()
      return
    }
    guard isRecordingLocked else {
      // Not recording (stop/cancel raced the fill): park the locals back when
      // this generation still owns the slots so reuse capacity is kept.
      if reusableBuffersGeneration == tapGeneration {
        scratchInt16 = localScratch
      } else if reusableBuffersGeneration == nil {
        reusableConvertedBuffer = result.converted
        scratchInt16 = localScratch
        reusableBuffersGeneration = tapGeneration
      }
      lock.unlock()
      return
    }
    // Per-buffer RMS history — final level summary metrics. 60 s at 1024
    // frames and 48 kHz ≈ 2800 values — memory fine.
    rmsHistory.append(meteredRms)

    // First session buffer — proof sound really reached the engine (piece
    // duration and energy; broken mic → rms ≈ 0). Includes raw level, adaptive
    // floor, VAD state and applied gain for frontend diagnostics.
    if !didLogFirstBuffer {
      didLogFirstBuffer = true
      if isDebug {
        Logger.log(
          String(
            format:
              "record first buffer: inFrames=%d (%.3f s @ %.0f Hz), outFrames=%d, raw=%.4f (%.1f dBFS), floor=%.4f (%.1f dBFS), vad=%@, metered=%.4f (%.1f dBFS), gain=%+.1f dB",
            buffer.frameLength,
            Double(buffer.frameLength) / buffer.format.sampleRate,
            buffer.format.sampleRate,
            frameLength,
            Double(rms),
            Double(AudioMetrics.dbfs(rms)),
            Double(vadFloor),
            Double(AudioMetrics.dbfs(vadFloor)),
            vadIsSpeech ? "speech" : "silence",
            Double(meteredRms),
            Double(AudioMetrics.dbfs(meteredRms)),
            Double(appliedGainDb)
          ),
          level: "debug"
        )
      }
    }

    // Memory bound: append no more than the limit allows (960 000 samples per
    // 60 s). Buffer never exceeds it. Store pre-reserved at session start, so
    // this is a bounded memcpy with no regrow allocation in steady state.
    // Cache the per-generation reuse buffers (converted output + staging) for
    // the next callback of this generation: steady state allocates no new
    // AVAudioPCMBuffer per callback and reuses staging storage. Reached only
    // on a generation match above, so a stale callback never clobbers the
    // fresh generation's instances.
    reusableConvertedBuffer = result.converted
    scratchInt16 = localScratch
    reusableBuffersGeneration = tapGeneration
    let sampleStart = collectedSamples.count
    let appendCount = min(frameLength, limit.remainingSamples(after: collectedSamples.count))
    if appendCount > 0 {
      collectedSamples.append(contentsOf: localScratch[0..<appendCount])
    }
    let sampleEnd = collectedSamples.count

    // Capture readiness (P0 first-word clipping): the first valid appended
    // buffer proves microphone data actually flows. It is retained
    // unconditionally above regardless of VAD classification — the live
    // pre-roll below stays segmentation-only and never gates retention, and no
    // VAD/AGC rule may discard this initial attack from the full recording.
    // Exactly once per session generation; startup failure/timeout/cancel
    // paths never fire (error path only, no false ready cue).
    var pendingCaptureInfo: CaptureReadyInfo?
    var pendingBreakdown: StartupBreakdown?
    if appendCount > 0, !captureReadyFired, startupGeneration >= 0,
      isCurrentGeneration(startupGeneration)
    {
      let firstNanos = Self.monotonicNanos()
      if startupEngineStartedNanos == 0 {
        // Rare race: the tap delivered before the engineQueue stamped
        // engine.start() completion. Stamp now so readiness still fires on
        // the true first buffer (engine→first delay reads 0).
        startupEngineStartedNanos = firstNanos
      }
      if startupFirstRawNanos == 0 {
        startupFirstRawNanos = firstNanos
      }
      if startupEngineStartedNanos > 0 {
        captureReadyFired = true
        captureReadyLive = true
        pendingCaptureInfo = CaptureReadyInfo(
          triggerToRequestMs: startupTriggerNanos.map {
            Self.ms(fromNanos: $0, to: startupRequestNanos)
          },
          requestToEngineStartedMs: Self.ms(
            fromNanos: startupRequestNanos, to: startupEngineStartedNanos),
          engineStartedToFirstBufferMs: Self.ms(
            fromNanos: startupEngineStartedNanos, to: firstNanos),
          requestToFirstBufferMs: Self.ms(fromNanos: startupRequestNanos, to: firstNanos)
        )
        pendingBreakdown = StartupBreakdown(
          firstAltNanos: startupFirstAltNanos,
          secondAltNanos: startupSecondAltNanos,
          requestNanos: startupRequestNanos,
          queueEntryNanos: startupQueueEntryNanos,
          inputReadyNanos: startupInputReadyNanos,
          tapInstalledNanos: startupTapInstalledNanos,
          prepareDoneNanos: startupPrepareDoneNanos,
          engineStartedNanos: startupEngineStartedNanos,
          firstRawCallbackNanos: startupFirstRawNanos,
          firstAcceptedNanos: firstNanos
        )
        completedBreakdown = pendingBreakdown
      }
    }

    // Live-VAD on the raw/adaptive speech flag: continuous speech — one utterance; a
    // pause ≥ pauseDuration (in samples) closes it with a segment, and with
    // accumulated speech ≥ liveChunkWindowSamples the same segment is cut by
    // the micro-pause liveMicroPauseSamples — text flows while speaking, no
    // long-pause wait. Pause/sample accounting below is unchanged (issue #21
    // only swaps the speech/silence classifier from fixed amplified threshold
    // to adaptive raw detection). Segment delivery — by COPY outside
    // (onSpeechSegment AFTER unlock); collectedSamples itself untouched and
    // keeps collecting the whole recording for the final pass.
    //
    // Shared delivery code for both branches (full pause and chunk): post-roll
    // 0.25 s of silence after the last speech portion (index clamped by the
    // buffer end — post-roll never leaves the recording), the cut index is
    // remembered (the next utterance's pre-roll cannot re-enter an already
    // delivered piece) and VAD reset. The range is provably non-empty: the
    // utterance holds ≥1 speech sample (liveUtteranceEnd > liveUtteranceStart),
    // post-roll non-negative — cut without an empty-range branch.
    // Lock holds only the range + a COW snapshot (O(1), no element copy); the
    // Array materialization happens after unlock below.
    let deliverSegment: () -> Void = {
      // Called only with liveUtteranceStart != nil (see below) — nil is
      // impossible by the invariant, the guard is compiler reassurance.
      guard let start = self.liveUtteranceStart else { return }
      let postEnd = min(
        self.liveUtteranceEnd + self.livePostRollSamples, self.collectedSamples.count)
      let cutIndex = postEnd
      segmentRangeToDeliver = start..<postEnd
      segmentSnapshot = self.collectedSamples
      self.liveLastCutIndex = cutIndex
      self.resetLiveVADLocked()
    }

    if !vadIsSpeech {
      if liveUtteranceStart != nil {
        // Pause inside the utterance: opened. The utterance closes on a
        // FULL pause pauseDuration (as before) — or on the micro-pause
        // liveMicroPauseSamples if continuous speech accumulated the window
        // liveChunkWindowSamples (chunk cut at the nearest inter-word gap).
        // Pause shorter than both — inner gap (a phantom "sigh" does not
        // break the phrase): accumulated speech NOT reset, chunk progress kept.
        if liveSilenceStart == nil {
          liveSilenceStart = sampleStart
        }
        // nil impossible: sampleStart just initialized (or set earlier) —
        // ?? is compiler reassurance.
        let silenceStart = liveSilenceStart ?? sampleStart
        let pauseLen = sampleEnd - silenceStart
        let dueForChunk = liveSpeechDurationSamples >= liveChunkWindowSamples
        if (dueForChunk && pauseLen >= liveMicroPauseSamples) || pauseLen >= livePauseSamples {
          deliverSegment()
        }
      }
    } else {
      // Speech: starts the utterance (or extends the last speech portion),
      // accumulated pause resets, SPEECH duration grows — chunk counter,
      // inter-word micro-pauses never zero it. Pre-roll steps 0.5 s back from
      // speech start but never re-enters an already delivered segment
      // (liveLastCutIndex) nor goes negative.
      if liveUtteranceStart == nil {
        liveUtteranceStart = max(sampleStart - livePreRollSamples, liveLastCutIndex)
      }
      liveUtteranceEnd = sampleEnd
      liveSilenceStart = nil
      liveSpeechDurationSamples += sampleEnd - sampleStart
    }

    // Hard limits — time (60 s) and/or buffer size — forced stop via the
    // same path as a user stop.
    let elapsed = CFAbsoluteTimeGetCurrent() - recordStartTime
    let shouldStop = limit.shouldStop(elapsed: elapsed, totalSamples: collectedSamples.count)
    // Auto-stop on continuous silence (~3 s): fed with the raw/pre-gain RMS
    // (issue #21 — VAD-side decision, never the amplified level), ONLY
    // when the feature is on (`autoStopConfig.enabled` — env kill switch,
    // see AutoStopConfig.fromEnvironment) and the limit did not fire in this
    // buffer (limit wins — the recording ends either way, one finalization
    // type). The adaptive VAD speech flag opens the speech gate so raw quiet
    // speech below the fixed speech threshold still arms auto-stop; VAD
    // silence counts as silence even when raw RMS is loud, so steady noise
    // converged to the adaptive floor does not block auto-stop (issue #21).
    // Buffer duration — real:
    // converted frames / target rate 16 kHz.
    // Accumulation by audio time, not buffer count — callback frequency
    // tracks the tap request size (1024 frames ≈ 21 ms @ 48 kHz, ≈ 23 ms
    // @ 44.1 kHz), "3 s of silence" measured by sound.
    let autoStopFired =
      autoStopConfig.enabled && !shouldStop
      && autoStopDetector.feed(
        rms: rms,
        duration: Double(frameLength) / Double(targetFormat.sampleRate),
        isSpeech: vadIsSpeech
      )
    lock.unlock()
    // Capture-ready delivery (outside the state lock): measurable startup
    // timeline + the truthful ready signal. Exactly once per session, on main
    // like the other session callbacks. No raw audio logged.
    if let info = pendingCaptureInfo {
      if let trigToReq = info.triggerToRequestMs {
        Logger.log(
          String(
            format:
              "record startup timing: trigger->request=%.1f ms request->engineStarted=%.1f ms engineStarted->firstBuffer=%.1f ms request->firstBuffer=%.1f ms",
            trigToReq,
            info.requestToEngineStartedMs,
            info.engineStartedToFirstBufferMs,
            info.requestToFirstBufferMs
          ),
          level: "info"
        )
      } else {
        Logger.log(
          String(
            format:
              "record startup timing: request->engineStarted=%.1f ms engineStarted->firstBuffer=%.1f ms request->firstBuffer=%.1f ms",
            info.requestToEngineStartedMs,
            info.engineStartedToFirstBufferMs,
            info.requestToFirstBufferMs
          ),
          level: "info"
        )
      }
      if let stages = pendingBreakdown {
        logStartupStages(stages)
      }
      DispatchQueue.main.async { [weak self] in
        self?.onCaptureReady?(info)
      }
    }
    if shouldStop {
      scheduleLimitStop()
    } else if autoStopFired {
      scheduleAutoStop()
    }
    // Materialize the completed segment outside the shared lock from the COW
    // snapshot + range captured above: no voiced samples lost or reordered
    // (range covers utterance start through last speech + post-roll), and the
    // lock was held only for O(1) bookkeeping.
    if let range = segmentRangeToDeliver, let snapshot = segmentSnapshot {
      let lo = max(0, range.lowerBound)
      let hi = min(snapshot.count, range.upperBound)
      if hi > lo {
        deliveredSegment = Array(snapshot[lo..<hi])
      }
    }
    if let segment = deliveredSegment, !segment.isEmpty {
      onSpeechSegment?(segment, false)
    }
  }

  /// Diagnostics of a silently dropped input buffer in `process` (debug-only,
  /// no behavior change): reason + piece size.
  private func logDroppedBuffer(reason: String, frames: AVAudioFrameCount) {
    guard isDebug else { return }
    Logger.log("record drop buffer: \(reason) frames=\(frames)", level: "debug")
  }

  /// Schedules a forced stop exactly once. The sample + tail snapshot (open
  /// utterance) is taken in `performForcedStop` on the main queue under one
  /// lock — buffers keep accumulating between scheduling and finalization,
  /// the tail loses nothing.
  private func scheduleLimitStop() {
    lock.lock()
    guard !limitStopScheduled else {
      lock.unlock()
      return
    }
    limitStopScheduled = true
    lock.unlock()

    // removeTap/engine.stop not callable from the tap callback (deadlock +
    // re-entry risk) — hop to the main queue, whence teardown goes to
    // engineQueue like a regular stop().
    DispatchQueue.main.async { [weak self] in
      self?.performForcedStop(reason: .limit)
    }
  }

  /// Schedules an auto-stop on silence exactly once — same late snapshot in
  /// `performForcedStop` as `scheduleLimitStop`: the open-utterance tail and
  /// full samples are taken on the main queue, engine teardown hops there too
  /// (removeTap not callable from the tap callback).
  private func scheduleAutoStop() {
    lock.lock()
    // The latch lives in the `session` register (autoStop bit) but is checked
    // under NSLock: the scheduler runs on the realtime path, where early
    // rejection without entering buffers matters (auto-stop is an event, not
    // every buffer).
    guard !isAutoStopScheduled else {
      lock.unlock()
      return
    }
    session.latchAutoStop()
    lock.unlock()

    DispatchQueue.main.async { [weak self] in
      self?.performForcedStop(reason: .autoStopSilence)
    }
  }

  /// Forced-stop cause: duration limit or auto-stop on silence. One
  /// finalization mechanic — only the callback receiving the samples differs.
  private enum ForcedStopReason {
    case limit
    case autoStopSilence
  }

  /// Same path as `stop()`: tap removal, engine stop, converter "drain",
  /// delivery of collected samples via the finalization callback.
  /// The "tail" is delivered BEFORE the callback — the client queues it for
  /// recognition before the whole recording finalizes.
  /// Snapshot on the main queue, as late as possible: between `schedule*`
  /// (audio thread) and finalization the tap picks up ~100-200 ms more,
  /// otherwise the last phrase's tail was lost.
  private func performForcedStop(reason: ForcedStopReason) {
    lock.lock()
    // User already stopped the recording — finalization not duplicated.
    guard isRecordingLocked else {
      lock.unlock()
      return
    }
    let duration = CFAbsoluteTimeGetCurrent() - recordStartTime
    setRecording(false)
    // Session ended: capture readiness lapses with it (as in stop()).
    captureReadyLive = false
    let rms = rmsHistory
    rmsHistory = []
    // Same range+snapshot tail handoff as stop(): copy after unlock.
    let tailRange = liveTailRangeLocked()
    let tailSnapshot = tailRange != nil ? collectedSamples : [Int16]()
    let samples = collectedSamples
    lock.unlock()
    var tail: [Int16] = []
    if let range = tailRange {
      let lo = max(0, range.lowerBound)
      let hi = min(tailSnapshot.count, range.upperBound)
      if hi > lo {
        tail = Array(tailSnapshot[lo..<hi])
      }
    }

    if isDebug {
      Logger.log(
        "record forced stop (\(reason == .limit ? "limit" : "silence auto-stop")): "
          + "tearing engine down (samples=\(samples.count))",
        level: "debug"
      )
    }
    // Teardown on the same engine's queue (pair snapshot under lock), see
    // comment in stop().
    let forcedSlot = captureEngineSlot()
    forcedSlot.queue.async { [weak self, engine = forcedSlot.engine, generation = forcedSlot.generation] in
      guard let self else { return }
      // Generation guard as in stop(): a stale engine is torn down only,
      // the live session's state stays untouched.
      if self.isCurrentGeneration(generation) {
        self.teardownOnEngineQueue(using: engine)
      } else {
        self.teardownEngineOnly(using: engine)
      }
    }
    logRecordingFinale(samples: samples, duration: duration, rmsHistory: rms)
    if !tail.isEmpty {
      onSpeechSegment?(tail, true)
    }
    switch reason {
    case .limit:
      onRecordingLimitReached?(samples)
    case .autoStopSilence:
      onAutoStop?(samples)
    }
  }

  /// Single final recording log for `stop()` and forced stop by limit:
  /// lifecycle (always, `info`) + level metering (only when
  /// `logLevel == "debug"`). Never throws: logging must not drop the
  /// recording.
  private func logRecordingFinale(samples: [Int16], duration: TimeInterval, rmsHistory: [Float]) {
    Logger.log(
      String(
        format: "record stop: duration=%.2f s, sampleRate=%d, channels=%d, frames=%d, bytes=%d",
        duration,
        16000,
        1,
        samples.count,
        samples.count * 2
      ),
      level: "info"
    )

    guard isDebug else { return }
    let summary = AudioMetrics.summarize(rmsValues: rmsHistory)
    Logger.log(
      String(
        format:
          "record metering: rms min=%.4f (%.1f dBFS), avg=%.4f (%.1f dBFS), max=%.4f (%.1f dBFS), nearSilence=%@, vadFloor=%.4f (%.1f dBFS), gain=%+.1f dB",
        Double(summary.minRMS),
        Double(AudioMetrics.dbfs(summary.minRMS)),
        Double(summary.avgRMS),
        Double(AudioMetrics.dbfs(summary.avgRMS)),
        Double(summary.maxRMS),
        Double(AudioMetrics.dbfs(summary.maxRMS)),
        summary.nearSilence ? "true" : "false",
        Double(vad.noiseFloor),
        Double(AudioMetrics.dbfs(vad.noiseFloor)),
        Double(gain.currentGainDb)
      ),
      level: "debug"
    )
  }
}

public enum AudioServiceError: Error, LocalizedError {
  case unsupportedFormat
  /// AudioService deallocated before start finished (unreachable in prod).
  case engineGone
  /// Engine already replaced when start finished (wedge after watchdog
  /// timeout): session stale. NOT shown to the user — the agent ignores the
  /// stale start's completion. Key: such a start never leads to
  /// audio.cancel()/transition to .recording on the live fresh pair.
  case engineSuperseded
  /// Audio device changed mid-recording: the live tap converter is built for
  /// the old input format and cannot be rebuilt without breaking the session.
  /// A clear error to the user instead of silence in the recording.
  case deviceChanged
  public var errorDescription: String? {
    switch self {
    case .unsupportedFormat: return L10n.tr("error.unsupportedAudioFormat")
    case .engineGone: return L10n.tr("error.audioServiceUnavailable")
    case .engineSuperseded: return L10n.tr("error.audioServiceUnavailable")
    case .deviceChanged:
      // Key error.audioDeviceChanged planned for L10n tables; none exist
      // yet — explicit string by L10n.language, not a raw key in UI.
      switch L10n.language {
      case .ru: return "Аудио-устройство изменилось — запись остановлена. Начните запись заново."
      case .en: return "Audio device changed — recording stopped. Please start recording again."
      }
    }
  }
}

// swiftlint:disable file_length
// Why disabled: AudioService is the single audio pipeline (start/stop/VAD/
// лимиты/метрики); сокращение тела без удаления кода контракты не сохраняет.
