import Foundation

// MARK: - RustParityGate: automated software gate plus hardware tracking (#123)
//
// Two-track form of the Definition of Done for the production cutover
// tracked by #123 (built on #131, #132, #133). The shared Rust engine
// foundation from PR #67 is linked and parity-tested, and the production
// call sites in #131/#132/#133 drive the engine by default.
//
// - The automated software gate (`evaluateSoftware`) is executable by a
//   coding agent using existing CI alone: deterministic engine behavior,
//   ABI/lifetime ownership, bridge/session lifecycle, retry/failover,
//   realtime audio/VAD, and text insertion transitions are all covered by
//   CI-runnable tests with fake audio devices and permissions, plus
//   CI-generated performance measurements for supported, measurable cases
//   (block-oriented FFI overhead around the bridge call; never physical
//   microphone latency or resource parity from mocks). No human-operated
//   hardware run, owner attestation, or out-of-band evidence is required.
//   Passing this gate unblocks the dependent Windows implementation
//   (#137/#167) and release publication. Release publication enforces it:
//   the release candidate-gate requires the exact-head CI run (which executes
//   `NanoDictateCoreTests` via `scripts/ci-validation.sh`, including the
//   `evaluateSoftware` unit coverage and the real FFI overhead probes) to be
//   green alongside the exact-head Packaging smoke run; fixed
//   `passingMeasurements()` fixtures in gate unit tests are oracles for the
//   gate logic, not release evidence on their own.
// - Real-hardware and manual validation (`ChecklistItem` / `evaluate`)
//   remains tracked separately in #35 and must not block Windows work or
//   release publication. A macOS 15 CI run is not a macOS 12 runtime test;
//   no compatibility with macOS 12 is claimed here.
//
// The model is intentionally pure (no AVFoundation, no FFI): tests and
// CI runs feed automated results and measurements in, and the gate
// computes a verdict with human-readable reasons. FFI overhead probes
// live in tests so CI measures the linked engine without audio hardware.

public enum RustParityGate {
  // MARK: - Required validation checklist

  /// Required real-hardware validation items, tracked separately in
  /// #35. Case order matches the issue text so evidence tables can
  /// iterate `allCases` directly. Missing items here never fail the
  /// automated software gate (`evaluateSoftware`) and never block the
  /// Windows implementation (#137/#167) or release publication.
  public enum ChecklistItem: String, CaseIterable, Hashable {
    case repeatedStartStop = "repeated-start-stop"
    case rapidSpeechAfterActivation = "rapid-speech-after-activation"
    case microphonePermissionStates = "microphone-permission-states"
    case accessibilityPermissionStates = "accessibility-permission-states"
    case deviceChanges = "device-changes"
    case engineFailureWedgeRecovery = "engine-failure-wedge-recovery"
    case normalDictation = "normal-dictation"
    case chunkedDictation = "chunked-dictation"
    case silenceAutoStop = "silence-auto-stop"
    case longRecordingLimit = "long-recording-limit"
    case providerRoutingFailover = "provider-routing-failover"
    case reviewBeforeInsert = "review-before-insert"
    case directInsertion = "direct-insertion"
    case clipboardInsertion = "clipboard-insertion"
    case escapeReturnUndo = "escape-return-undo"
  }

  // MARK: - Measurements

  /// Baseline-vs-post-cutover comparison for one shipping flow.
  /// All durations are wall clock measured on the macOS host side around
  /// the bridge call, matching docs/architecture-rust-engine.md.
  public struct Measurements: Equatable {
    /// `RustEngine.checkAvailable()` wall clock.
    public var startupLatencyMs: Double
    /// Worst observed block-oriented FFI call (VAD/gain/autostop block).
    public var maxBlockCallMs: Double
    /// Mean block-oriented FFI call over the probe window.
    public var meanBlockCallMs: Double
    /// Relative CPU change vs baseline (1.0 = unchanged, 1.1 = +10%).
    public var cpuRatio: Double
    /// Relative peak-memory change vs baseline (1.0 = unchanged).
    public var memoryRatio: Double
    /// Relative audio-copy/allocation change vs baseline (1.0 = unchanged).
    /// Covers the audio-copy/allocation impact required by #123.
    public var copyAllocationRatio: Double

    public init(
      startupLatencyMs: Double,
      maxBlockCallMs: Double,
      meanBlockCallMs: Double,
      cpuRatio: Double,
      memoryRatio: Double,
      copyAllocationRatio: Double
    ) {
      self.startupLatencyMs = startupLatencyMs
      self.maxBlockCallMs = maxBlockCallMs
      self.meanBlockCallMs = meanBlockCallMs
      self.cpuRatio = cpuRatio
      self.memoryRatio = memoryRatio
      self.copyAllocationRatio = copyAllocationRatio
    }
  }

  /// Budgets before a difference counts as a material regression.
  /// Generous by design: CI probes assert far below these, while hardware
  /// runs fail only on user-visible degradation.
  public struct Budgets: Equatable {
    public var maxStartupLatencyMs: Double
    public var maxBlockCallMs: Double
    public var maxMeanBlockCallMs: Double
    public var maxCPURatio: Double
    public var maxMemoryRatio: Double
    public var maxCopyAllocationRatio: Double

    public static let `default` = Budgets(
      maxStartupLatencyMs: 500,
      maxBlockCallMs: 25,
      maxMeanBlockCallMs: 5,
      maxCPURatio: 1.2,
      maxMemoryRatio: 1.2,
      maxCopyAllocationRatio: 1.2
    )

    public init(
      maxStartupLatencyMs: Double,
      maxBlockCallMs: Double,
      maxMeanBlockCallMs: Double,
      maxCPURatio: Double,
      maxMemoryRatio: Double,
      maxCopyAllocationRatio: Double
    ) {
      self.maxStartupLatencyMs = maxStartupLatencyMs
      self.maxBlockCallMs = maxBlockCallMs
      self.maxMeanBlockCallMs = maxMeanBlockCallMs
      self.maxCPURatio = maxCPURatio
      self.maxMemoryRatio = maxMemoryRatio
      self.maxCopyAllocationRatio = maxCopyAllocationRatio
    }

    /// Human-readable reasons for budgets that cannot enforce a regression
    /// check. Every budget must be positive and finite: `.infinity` (or NaN,
    /// zero, or negative values) would let any finite measurement pass and
    /// silently disable that dimension of the gate.
    func invalidReasons() -> [String] {
      var invalid: [String] = []
      let values: [(name: String, value: Double)] = [
        ("maxStartupLatencyMs", maxStartupLatencyMs),
        ("maxBlockCallMs", maxBlockCallMs),
        ("maxMeanBlockCallMs", maxMeanBlockCallMs),
        ("maxCPURatio", maxCPURatio),
        ("maxMemoryRatio", maxMemoryRatio),
        ("maxCopyAllocationRatio", maxCopyAllocationRatio),
      ]
      for (name, value) in values {
        if !(value > 0 && value.isFinite) {
          invalid.append("invalid budget: \(name)=\(value) must be positive and finite")
        }
      }
      return invalid
    }
  }

  public struct Verdict: Equatable {
    public var passed: Bool
    public var reasons: [String]

    public init(passed: Bool, reasons: [String] = []) {
      self.passed = passed
      self.reasons = reasons
    }
  }

  // MARK: - Automated software gate (#123, CI-executable)

  /// CI-runnable automated coverage areas for the software gate. Every
  /// area runs on the repository's configured CI runners with fake audio
  /// devices and permissions; none requires physical hardware, a
  /// microphone, owner attestation, or out-of-band evidence. Case order
  /// matches the Definition of Done so evidence tables can iterate
  /// `allCases` directly.
  public enum AutomatedCheck: String, CaseIterable, Hashable {
    case abiLifetimeOwnership = "abi-lifetime-ownership"
    case swiftBridge = "swift-bridge"
    case sessionLifecycle = "session-lifecycle"
    case sttRetryFailover = "stt-retry-failover"
    case realtimeAudioVAD = "realtime-audio-vad"
    case textInsertion = "text-insertion"
  }

  // MARK: - Evaluation

  /// Evaluates the automated software gate: the executable Definition of
  /// Done for #123. `passedAutomated` holds the CI-runnable coverage
  /// areas with green automated runs; `measurements` carries
  /// CI-generated performance numbers for supported, measurable cases
  /// (nil when CI has not reported numbers yet);
  /// `supersededSwiftRemoved` must stay false until this gate passes —
  /// and even then only actually superseded duplicate business logic may
  /// go, after ensuring a safe fallback where required (the Swift
  /// reference implementations stay on as parity oracles; OS-native
  /// capture/TCC/Accessibility adapters stay in their hosts).
  ///
  /// Missing manual/hardware evidence never fails this gate: it is
  /// tracked separately in #35. Passing this gate unblocks the dependent
  /// Windows implementation (#137/#167) and release publication, and
  /// claims no macOS 12 runtime compatibility (CI runs on newer macOS
  /// runners against the 12.0 deployment target).
  public static func evaluateSoftware(
    passedAutomated: Set<AutomatedCheck>,
    measurements: Measurements?,
    supersededSwiftRemoved: Bool,
    budgets: Budgets = .default
  ) -> Verdict {
    var reasons: [String] = []

    let missing = AutomatedCheck.allCases.filter { !passedAutomated.contains($0) }
    for check in missing {
      reasons.append("missing automated evidence: \(check.rawValue)")
    }

    reasons.append(contentsOf: validateMeasurements(measurements, budgets: budgets))
    reasons.append(
      contentsOf: removalBlockReasons(
        supersededSwiftRemoved: supersededSwiftRemoved,
        evidenceMissing: !missing.isEmpty,
        measurementsMissing: measurements == nil,
        otherReasons: reasons
      ))

    return Verdict(passed: reasons.isEmpty, reasons: reasons)
  }

  /// Evaluates the real-hardware qualification contract. `passedItems`
  /// holds the checklist items with recorded hardware evidence;
  /// `measurements` is nil when the hardware run has not reported numbers
  /// yet. `supersededSwiftRemoved` must stay false until the automated
  /// software gate passes (see #123 DoD).
  ///
  /// Missing hardware evidence here is tracked in #35. It never fails the
  /// automated software gate (`evaluateSoftware`) and never blocks the
  /// Windows implementation (#137/#167) or release publication.
  public static func evaluate(
    passedItems: Set<ChecklistItem>,
    measurements: Measurements?,
    supersededSwiftRemoved: Bool,
    budgets: Budgets = .default
  ) -> Verdict {
    var reasons: [String] = []

    let missing = ChecklistItem.allCases.filter { !passedItems.contains($0) }
    for item in missing {
      reasons.append("missing hardware evidence: \(item.rawValue)")
    }

    reasons.append(contentsOf: validateMeasurements(measurements, budgets: budgets))
    reasons.append(
      contentsOf: removalBlockReasons(
        supersededSwiftRemoved: supersededSwiftRemoved,
        evidenceMissing: !missing.isEmpty,
        measurementsMissing: measurements == nil,
        otherReasons: reasons
      ))

    return Verdict(passed: reasons.isEmpty, reasons: reasons)
  }

  // MARK: - Shared validation

  /// Validates CI- or hardware-reported performance numbers against the
  /// budgets. Nil measurements mean the run has not reported numbers yet.
  private static func validateMeasurements(
    _ measurements: Measurements?, budgets: Budgets
  ) -> [String] {
    guard let measurements else {
      return ["missing performance measurements"]
    }
    var reasons: [String] = []
    reasons.append(contentsOf: budgets.invalidReasons())
    if !(measurements.startupLatencyMs >= 0 && measurements.startupLatencyMs.isFinite) {
      reasons.append(
        "invalid performance measurement: startupLatencyMs=\(measurements.startupLatencyMs)ms must be non-negative and finite"
      )
    } else if !(measurements.startupLatencyMs <= budgets.maxStartupLatencyMs) {
      reasons.append(
        "startup latency regression: \(measurements.startupLatencyMs)ms exceeds budget \(budgets.maxStartupLatencyMs)ms"
      )
    }
    if !(measurements.maxBlockCallMs >= 0 && measurements.maxBlockCallMs.isFinite) {
      reasons.append(
        "invalid performance measurement: maxBlockCallMs=\(measurements.maxBlockCallMs)ms must be non-negative and finite"
      )
    } else if !(measurements.maxBlockCallMs <= budgets.maxBlockCallMs) {
      reasons.append(
        "realtime block regression: max \(measurements.maxBlockCallMs)ms exceeds budget \(budgets.maxBlockCallMs)ms"
      )
    }
    if !(measurements.meanBlockCallMs >= 0 && measurements.meanBlockCallMs.isFinite) {
      reasons.append(
        "invalid performance measurement: meanBlockCallMs=\(measurements.meanBlockCallMs)ms must be non-negative and finite"
      )
    } else if !(measurements.meanBlockCallMs <= budgets.maxMeanBlockCallMs) {
      reasons.append(
        "realtime block regression: mean \(measurements.meanBlockCallMs)ms exceeds budget \(budgets.maxMeanBlockCallMs)ms"
      )
    }
    if measurements.maxBlockCallMs >= 0 && measurements.maxBlockCallMs.isFinite
      && measurements.meanBlockCallMs >= 0 && measurements.meanBlockCallMs.isFinite
      && measurements.meanBlockCallMs > measurements.maxBlockCallMs
    {
      reasons.append(
        "inconsistent block-call measurements: mean \(measurements.meanBlockCallMs)ms exceeds max \(measurements.maxBlockCallMs)ms"
      )
    }
    if !(measurements.cpuRatio > 0 && measurements.cpuRatio.isFinite) {
      reasons.append(
        "invalid performance measurement: cpuRatio=\(measurements.cpuRatio) must be positive and finite"
      )
    } else if !(measurements.cpuRatio <= budgets.maxCPURatio) {
      reasons.append(
        "CPU regression: ratio \(measurements.cpuRatio) exceeds budget \(budgets.maxCPURatio)"
      )
    }
    if !(measurements.memoryRatio > 0 && measurements.memoryRatio.isFinite) {
      reasons.append(
        "invalid performance measurement: memoryRatio=\(measurements.memoryRatio) must be positive and finite"
      )
    } else if !(measurements.memoryRatio <= budgets.maxMemoryRatio) {
      reasons.append(
        "memory regression: ratio \(measurements.memoryRatio) exceeds budget \(budgets.maxMemoryRatio)"
      )
    }
    if !(measurements.copyAllocationRatio > 0 && measurements.copyAllocationRatio.isFinite) {
      reasons.append(
        "invalid performance measurement: copyAllocationRatio=\(measurements.copyAllocationRatio) must be positive and finite"
      )
    } else if !(measurements.copyAllocationRatio <= budgets.maxCopyAllocationRatio) {
      reasons.append(
        "audio-copy/allocation regression: ratio \(measurements.copyAllocationRatio) exceeds budget \(budgets.maxCopyAllocationRatio)"
      )
    }
    return reasons
  }

  /// Removal-guard reasons shared by both gates. `otherReasons` carries
  /// the evidence/measurement reasons already collected, so a removal
  /// with regressed measurements still gets its explicit audit trail.
  private static func removalBlockReasons(
    supersededSwiftRemoved: Bool,
    evidenceMissing: Bool,
    measurementsMissing: Bool,
    otherReasons: [String]
  ) -> [String] {
    var extra: [String] = []
    if supersededSwiftRemoved, evidenceMissing || measurementsMissing {
      extra.append("superseded Swift must not be removed before parity validation passes")
    }

    // Removal with passing evidence but regressed measurements is still
    // a regression, yet deserves an explicit removal reason for audits.
    if supersededSwiftRemoved, !otherReasons.isEmpty || !extra.isEmpty {
      extra.append("gate is red: superseded Swift removal is blocked")
    }
    return extra
  }
}
