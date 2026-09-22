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

  // var, not let: replaceEngineAfterWedge() swaps a "wedged" engine for a fresh
  // instance (recovery after a record-start timeout).
  private var engine: AudioEngineLike
  private let targetFormat: AVAudioFormat
  private var converter: AVAudioConverter?
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
  /// Digital input gain (AGC): applied to the Float32 buffer AFTER 16 kHz/mono
  /// conversion and BEFORE Int16 conversion/level metering — all consumers
  /// (level animation, live-VAD, auto-stop, recording) see the amplified
  /// signal. Env config (`NANODICTATE_GAIN_*`); kill switch
  /// `NANODICTATE_GAIN_DISABLED=1` passes the buffer unchanged.
  private let gain: InputGain

  // MARK: - Live-VAD (пошаговая диктовка)

  /// Live-VAD params — same as the offline segmenter: `silenceRMS` threshold
  /// and the pause duration that closes an utterance.
  private let liveSilenceRMS: Float
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
    gainConfig: InputGainConfig = .fromEnvironment()
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
    autoStopDetector = SilenceAutoStopDetector(
      silenceRMSThreshold: autoStopConfig.silenceRMSThreshold,
      speechRMSThreshold: autoStopConfig.speechRMSThreshold,
      requiredSilenceDuration: autoStopConfig.requiredSilenceDuration,
      gracePeriod: autoStopConfig.gracePeriod,
      minSpeechRun: autoStopConfig.minSpeechRun,
      minRecordingDuration: autoStopConfig.minRecordingDuration
    )
    // Live-VAD lives on the same thresholds as offline recording segmentation:
    // same `silenceRMS`, same `pauseDuration`.
    liveSilenceRMS = segmenterConfig.silenceRMS
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
  public func start(completion: @escaping (Result<Void, Error>) -> Void) {
    // Pair snapshot (engine, queue, generation) under lock, BEFORE dispatch:
    // the block goes to THIS engine's queue and works with IT. A wedged start
    // blocks only its own pair — after the swap (replaceEngineAfterWedge) the
    // fresh pair works without waiting for the blocked queue. The generation
    // captured here is the start "stamp": the tap block and terminal branches
    // verify against it that the engine is still current (see startOnEngineQueue).
    let slot = captureEngineSlot()
    slot.queue.async { [weak self, engine = slot.engine, startGeneration = slot.generation] in
      guard let self else {
        DispatchQueue.main.async { completion(.failure(AudioServiceError.engineGone)) }
        return
      }
      let result = self.startOnEngineQueue(using: engine, startGeneration: startGeneration)
      DispatchQueue.main.async { completion(result) }
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
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func startOnEngineQueue(using engine: AudioEngineLike, startGeneration: Int) -> Result<
    Void, Error
  > {
    // New session: clean buffers, clean limit (after forced stop or failure
    // branch). All state under lock — start runs on the engine queue,
    // process/stop may read in parallel.
    didLogFirstBuffer = false
    limit = RecordingLimit(maxDuration: 60.0, sampleRate: 16000)
    recordStartTime = CFAbsoluteTimeGetCurrent()
    lock.lock()
    collectedSamples = []
    rmsHistory = []
    limitStopScheduled = false
    // Auto-stop latch — in the ledger (autoStop bit): a new session starts
    // without "finalization already scheduled".
    session.clearAutoStop()
    autoStopDetector.reset()
    gain.reset()  // new session — zero gain, no residue from the previous recording
    liveLastCutIndex = 0
    resetLiveVADLocked()
    lock.unlock()

    // Safe start from scratch: if the previous session left the engine with a
    // tap installed (failure branch), remove it BEFORE installTap — a repeat
    // installTap on the same bus raises NSException (crash).
    if isTapInstalled {
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
    if setupFailure == nil, let fmt = capturedHWFormat {
      setupFailure = guardedEngineCall {
        capturedConverter = AVAudioConverter(from: fmt, to: self.targetFormat)
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
    self.converter = converter
    lock.unlock()
    // A stale start (unblocked AFTER the wedge swap) must not subscribe: its
    // engine is already discarded, and the token would clobber the fresh
    // session's observer, leaving the live device without a reaction to
    // device change. Generation guard here — BEFORE subscription; terminal
    // guards below stay for the tap/prepare/start stages.
    guard isCurrentGeneration(startGeneration) else {
      teardownEngineOnly(using: engine)
      return .failure(AudioServiceError.engineSuperseded)
    }
    // Device-change subscription AFTER the converter is in state: a
    // notification may arrive right after registration.
    observeConfigurationChanges(for: engine)

    // Mic permission (TCC) on every create/restart of recording. A repeated
    // system access prompt (top complaint) shows in the log as status
    // notDetermined before start — instantly visible that the grant is lost.
    let mic = MicrophoneAuth.statusText(AVCaptureDevice.authorizationStatus(for: .audio))
    Logger.log("mic permission: \(mic) (record start)", level: "info")
    Logger.log(
      "record start: sampleRate=\(Int(targetFormat.sampleRate)) Hz, channels=\(targetFormat.channelCount), "
        + "hwFormat=\(Int(hwFormat.sampleRate)) Hz",
      level: "info"
    )
    // Auto-stop diagnostics: visible whether the feature is on, the pair of
    // hysteresis thresholds, grace, the "speech happened" gate and the
    // recording floor (all values from environment — see fromEnvironment).
    Logger.log(
      "record auto-stop: enabled=\(autoStopConfig.enabled), "
        + "speech>=\(autoStopConfig.speechRMSThreshold), silence<\(autoStopConfig.silenceRMSThreshold), "
        + "silence>=\(String(format: "%.1f", autoStopConfig.requiredSilenceDuration))s, "
        + "grace=\(String(format: "%.1f", autoStopConfig.gracePeriod))s, "
        + "gate>=\(String(format: "%.1f", autoStopConfig.minSpeechRun))s, "
        + "minRecord=\(String(format: "%.1f", autoStopConfig.minRecordingDuration))s",
      level: "info"
    )
    // AGC diagnostics: visible whether gain is on and with what params (kill
    // switch/target/ceiling from environment — see InputGainConfig.fromEnvironment).
    Logger.log(
      "record input-gain: enabled=\(gain.config.enabled), "
        + "target=\(String(format: "%.1f", gain.config.targetRmsDb)) dBFS, "
        + "max=\(String(format: "%.1f", gain.config.maxGainDb)) dB",
      level: "info"
    )

    // Breadcrumb before installTap: if the next AVFoundation call crashes, the
    // last log line pinpoints the exact place. No re-poll of the hardware
    // format here — the same call was already taken under the ObjC gateway in
    // the bring-up above (duplication added no information).
    if isDebug {
      Logger.log(
        "record engine: installing tap (bus 0, bufferSize 4096, hwFormat=\(Int(hwFormat.sampleRate)) Hz)",
        level: "debug"
      )
    }

    // Tap on the hardware format; conversion happens in the block.
    var failure = guardedEngineCall {
      input.installTap(
        onBus: 0,
        bufferSize: 4096,
        format: hwFormat
      ) { [weak self, tapGeneration = startGeneration] buffer, _ in
        guard let self else { return }
        // Tap of a discarded generation (engine wedge-swapped AFTER tap
        // install) silently drops buffers: a foreign audio stream must not
        // feed the new session. The old tap itself cannot be removed (its
        // engine may be stuck) — the generation guard is cheaper and safer.
        guard self.isCurrentGeneration(tapGeneration) else { return }
        self.process(buffer)
      }
    }
    if failure == nil {
      setTapInstalled(true)
    }
    if failure == nil, isDebug {
      Logger.log("record engine: tap installed, engine.prepare()…", level: "debug")
    }
    if failure == nil {
      failure = guardedEngineCall {
        engine.prepare()
      }
    }
    if failure == nil, isDebug {
      Logger.log("record engine: prepared, engine.start()…", level: "debug")
    }
    // isRecording set BEFORE engine.start(): the first buffer arriving right
    // after the audio stream starts must not be dropped.
    if failure == nil {
      setRecording(true)
      failure = guardedEngineCall {
        try engine.start()
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
    // "Tail" (open utterance) taken in the same snapshot, under the same
    // lock — VAD state and recording buffer stay consistent.
    let tail = takeLiveTailLocked()
    let samples = collectedSamples
    collectedSamples = []
    let rms = rmsHistory
    rmsHistory = []
    lock.unlock()

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
    collectedSamples = []
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
    collectedSamples = []
    rmsHistory = []
    liveLastCutIndex = 0
    session.clearAutoStop()
    autoStopDetector.reset()
    resetLiveVADLocked()
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
    defer { resetLiveVADLocked() }
    guard let start = liveUtteranceStart else { return [] }
    let end = min(liveUtteranceEnd, collectedSamples.count)
    guard end > start else { return [] }
    return Array(collectedSamples[start..<end])
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
      let converted = AVAudioPCMBuffer(
        pcmFormat: targetFormat,
        frameCapacity: outputFrameCapacity(
          forInputFrames: input.frameLength,
          inputRate: inputFormat.sampleRate,
          outputRate: targetFormat.sampleRate
        )
      )
    else { return nil }

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
    return (converted, status)
  }

  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private func process(_ buffer: AVAudioPCMBuffer) {
    // Early "is recording?" guard BEFORE conversion and AGC: after stop()/start()
    // a late buffer of the old tap must not touch InputGain state — reset() of
    // the new session (engineQueue, under lock) and apply (audio stream) do
    // not overlap (the guard below stays — protection duplicated).
    // All flags and the converter are taken under lock in one snapshot: the
    // lock-free guard is gone — start/stop race closed (see takeBufferedSnapshot).
    let snapshot = takeBufferedSnapshot()
    guard snapshot.alive else { return }
    guard let converter = snapshot.converter else {
      logDroppedBuffer(reason: "converter is nil (stopped?)", frames: buffer.frameLength)
      return
    }
    guard
      let result = AudioService.convertOnce(
        input: buffer,
        inputFormat: buffer.format,
        converter: converter,
        targetFormat: targetFormat
      )
    else {
      logDroppedBuffer(
        reason: "convertOnce -> nil (empty output or error)", frames: buffer.frameLength)
      return
    }
    guard let channel = result.converted.floatChannelData?[0] else {
      logDroppedBuffer(reason: "converted buffer has no float channel", frames: buffer.frameLength)
      return
    }
    let converted = result.converted
    let frameLength = Int(converted.frameLength)

    // RMS BEFORE gain — AGC input: "how many dB short of the target speech
    // level" (raw-tap-signal metering).
    var sum: Float = 0
    for i in 0..<frameLength {
      let sample = channel[i]
      sum += sample * sample
    }
    let rms = frameLength > 0 ? sqrt(sum / Float(frameLength)) : 0
    // Digital gain (AGC) here, mutating the buffer in place: all consumers
    // below (level metric, live-VAD, auto-stop, Int16 recording) see the
    // amplified signal. The metering level is recomputed from the amplified
    // buffer (peak clamp accounted); with AGC off
    // (`NANODICTATE_GAIN_DISABLED=1`) the buffer passes unchanged, metric = rms.
    let meteredRms = gain.apply(
      to: channel,
      frameLength: frameLength,
      rms: rms,
      sampleRate: Int(targetFormat.sampleRate)
    )
    levelDelegate?.audioLevelChanged(rms: meteredRms)

    // All shared memory (isRecording, collectedSamples, rmsHistory, limit,
    // live-VAD) — under the lock: stop()/cancel() take a snapshot on main
    // synchronously with the accumulation here.
    var deliveredSegment: [Int16]?
    lock.lock()
    guard isRecordingLocked else {
      lock.unlock()
      return
    }
    // Per-buffer RMS history — final level summary metrics. 60 s at 4096
    // frames and 48 kHz ≈ 700 values — memory fine.
    rmsHistory.append(meteredRms)

    // First session buffer — proof sound really reached the engine (piece
    // duration and energy; broken mic → rms ≈ 0).
    if !didLogFirstBuffer {
      didLogFirstBuffer = true
      if isDebug {
        Logger.log(
          String(
            format:
              "record first buffer: inFrames=%d (%.3f s @ %.0f Hz), outFrames=%d, rms=%.4f (%.1f dBFS)",
            buffer.frameLength,
            Double(buffer.frameLength) / buffer.format.sampleRate,
            buffer.format.sampleRate,
            frameLength,
            meteredRms,
            AudioMetrics.dbfs(meteredRms)
          ),
          level: "debug"
        )
      }
    }

    // Memory bound: append no more than the limit allows (960 000 samples per
    // 60 s). Buffer never exceeds it.
    let sampleStart = collectedSamples.count
    let appendCount = min(frameLength, limit.remainingSamples(after: collectedSamples.count))
    collectedSamples.reserveCapacity(
      min(collectedSamples.count + frameLength, limit.maxSamples)
    )
    for i in 0..<appendCount {
      let sample = channel[i]
      if sample > 1.0 {
        collectedSamples.append(Int16(32767))
      } else if sample < -1.0 {
        collectedSamples.append(Int16(-32768))
      } else {
        collectedSamples.append(Int16(sample * 32767))
      }
    }
    let sampleEnd = collectedSamples.count

    // Live-VAD over the just-computed RMS: continuous speech — one utterance; a
    // pause ≥ pauseDuration (in samples) closes it with a segment, and with
    // accumulated speech ≥ liveChunkWindowSamples the same segment is cut by
    // the micro-pause liveMicroPauseSamples — text flows while speaking, no
    // long-pause wait. Same thresholds as the offline segmenter (silenceRMS,
    // pauseDuration). Segment delivery — by COPY outside (onSpeechSegment
    // AFTER unlock); collectedSamples itself untouched and keeps collecting
    // the whole recording for the final pass.
    //
    // Shared delivery code for both branches (full pause and chunk): post-roll
    // 0.25 s of silence after the last speech portion (index clamped by the
    // buffer end — post-roll never leaves the recording), the cut index is
    // remembered (the next utterance's pre-roll cannot re-enter an already
    // delivered piece) and VAD reset. The range is provably non-empty: the
    // utterance holds ≥1 speech sample (liveUtteranceEnd > liveUtteranceStart),
    // post-roll non-negative — cut without an empty-range branch.
    let deliverSegment: () -> Void = {
      // Called only with liveUtteranceStart != nil (see below) — nil is
      // impossible by the invariant, the guard is compiler reassurance.
      guard let start = self.liveUtteranceStart else { return }
      let postEnd = min(
        self.liveUtteranceEnd + self.livePostRollSamples, self.collectedSamples.count)
      let cutIndex = postEnd
      deliveredSegment = Array(self.collectedSamples[start..<postEnd])
      self.liveLastCutIndex = cutIndex
      self.resetLiveVADLocked()
    }

    if meteredRms < liveSilenceRMS {
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
    // Auto-stop on continuous silence (~3 s): the detector is fed ONLY
    // when the feature is on (`autoStopConfig.enabled` — env kill switch,
    // see AutoStopConfig.fromEnvironment) and the limit did not fire in this
    // buffer (limit wins — the recording ends either way, one finalization
    // type). Buffer duration — real: converted frames / target rate 16 kHz.
    // Accumulation by audio time, not buffer count — callback frequency
    // tracks hardware sample rate (~85 ms @ 48 kHz, ~93 ms @ 44.1 kHz),
    // "3 s of silence" measured by sound.
    let autoStopFired =
      autoStopConfig.enabled && !shouldStop
      && autoStopDetector.feed(
        rms: meteredRms,
        duration: Double(frameLength) / Double(targetFormat.sampleRate)
      )
    lock.unlock()
    if shouldStop {
      scheduleLimitStop()
    } else if autoStopFired {
      scheduleAutoStop()
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
    let rms = rmsHistory
    rmsHistory = []
    let tail = takeLiveTailLocked()
    let samples = collectedSamples
    lock.unlock()

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
          "record metering: rms min=%.4f (%.1f dBFS), avg=%.4f (%.1f dBFS), max=%.4f (%.1f dBFS), nearSilence=%@",
        Double(summary.minRMS),
        Double(AudioMetrics.dbfs(summary.minRMS)),
        Double(summary.avgRMS),
        Double(AudioMetrics.dbfs(summary.avgRMS)),
        Double(summary.maxRMS),
        Double(AudioMetrics.dbfs(summary.maxRMS)),
        summary.nearSilence ? "true" : "false"
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
