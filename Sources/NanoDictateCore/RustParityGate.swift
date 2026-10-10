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
//   (startup latency and block-oriented FFI overhead around the bridge
//   call; never physical microphone latency or resource parity from mocks).
//   CPU/memory/audio-copy ratios have no CI-measurable baseline in this
//   repository, so the software gate records them as unavailable
//   (`nil` => `notes` entry "resource parity not qualified") instead of
//   asserting parity from constants. No human-operated hardware run, owner
//   attestation, or out-of-band evidence is required. Passing this gate
//   unblocks the dependent Windows implementation (#137/#167) and release
//   publication. Release publication enforces it: the release
//   candidate-gate requires the exact-head CI run (which executes
//   `NanoDictateCoreTests` via `scripts/ci-validation.sh`, including the
//   `evaluateSoftware` unit coverage and the real FFI overhead probes) to be
//   green alongside the exact-head Packaging smoke run; fixed synthetic
//   fixtures in gate unit tests are oracles for the gate logic, not release
//   evidence on their own. The evidence-to-verdict test feeds only
//   really measured numbers plus per-area proven automated checks into
//   `evaluateSoftware`.
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
  ///
  /// The resource ratios are optional: `nil` means unavailable (no
  /// CI-measurable baseline in this repository, or the run did not report
  /// one). A `nil` ratio never counts as measured parity and is reported
  /// as "not qualified", never as 1.0. Only a non-`nil` value with baseline
  /// provenance is validated against the budgets.
  public struct Measurements: Equatable {
    /// `RustEngine.checkAvailable()` wall clock.
    public var startupLatencyMs: Double
    /// Worst observed block-oriented FFI call (VAD/gain/autostop block).
    public var maxBlockCallMs: Double
    /// Mean block-oriented FFI call over the probe window.
    public var meanBlockCallMs: Double
    /// Relative CPU change vs baseline (1.0 = unchanged, 1.1 = +10%).
    /// `nil` = unavailable, not measured parity.
    public var cpuRatio: Double?
    /// Relative peak-memory change vs baseline (1.0 = unchanged).
    /// `nil` = unavailable, not measured parity.
    public var memoryRatio: Double?
    /// Relative audio-copy/allocation change vs baseline (1.0 = unchanged).
    /// Covers the audio-copy/allocation impact required by #123.
    /// `nil` = unavailable, not measured parity.
    public var copyAllocationRatio: Double?

    public init(
      startupLatencyMs: Double,
      maxBlockCallMs: Double,
      meanBlockCallMs: Double,
      cpuRatio: Double?,
      memoryRatio: Double?,
      copyAllocationRatio: Double?
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
    /// Non-blocking scope notes: dimensions explicitly not qualified
    /// (e.g. resource parity without a CI baseline). Notes never turn a
    /// red verdict green and never claim parity for those dimensions.
    public var notes: [String]

    public init(passed: Bool, reasons: [String] = [], notes: [String] = []) {
      self.passed = passed
      self.reasons = reasons
      self.notes = notes
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
  /// Done for #123. `passedAutomated` must hold exactly the coverage areas
  /// with green automated runs actually executed on this commit (each value
  /// needs provenance from a real check result, never an unconditional
  /// `allCases` constant); `measurements` carries CI-generated performance
  /// numbers for supported, measurable cases (nil when CI has not reported
  /// numbers yet). Resource ratios inside `measurements` are `nil` when
  /// this repository has no CI-measurable baseline for them: they are then
  /// reported in `Verdict.notes` as "not qualified" and never claimed as
  /// parity. `supersededSwiftRemoved` must stay false until this gate passes —
  /// and even then only actually superseded duplicate business logic may
  /// go, after ensuring a safe fallback where required (the Swift
  /// reference implementations stay on as parity oracles; OS-native
  /// capture/TCC/Accessibility adapters stay in their hosts).
  ///
  /// Missing manual/hardware evidence never fails this gate: it is
  /// tracked separately in #35. Passing this gate unblocks the dependent
  /// Windows implementation (#137/#167) and release publication, and
  /// claims no macOS 12 runtime compatibility (CI runs on newer macOS
  /// runners against the 12.0 deployment target). It also claims no
  /// CPU/memory/copy-allocation parity when those baselines are absent.
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

    let softwareMeasurements = validateSoftwareMeasurements(measurements, budgets: budgets)
    reasons.append(contentsOf: softwareMeasurements.reasons)
    reasons.append(
      contentsOf: removalBlockReasons(
        supersededSwiftRemoved: supersededSwiftRemoved,
        evidenceMissing: !missing.isEmpty,
        measurementsMissing: measurements == nil,
        otherReasons: reasons
      ))

    return Verdict(passed: reasons.isEmpty, reasons: reasons, notes: softwareMeasurements.notes)
  }

  /// Evaluates the real-hardware qualification contract. `passedItems`
  /// holds the checklist items with recorded hardware evidence;
  /// `measurements` is nil when the hardware run has not reported numbers
  /// yet. Unlike the software gate, hardware qualification requires real
  /// resource baselines: a `nil` CPU/memory/copy ratio fails here with an
  /// explicit "missing resource baseline" reason. `supersededSwiftRemoved`
  /// must stay false until the automated software gate passes (see #123 DoD).
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

    reasons.append(contentsOf: validateHardwareMeasurements(measurements, budgets: budgets))
    reasons.append(
      contentsOf: removalBlockReasons(
        supersededSwiftRemoved: supersededSwiftRemoved,
        evidenceMissing: !missing.isEmpty,
        measurementsMissing: measurements == nil,
        otherReasons: reasons
      ))

    return Verdict(passed: reasons.isEmpty, reasons: reasons)
  }

  /// Standalone resource-parity qualification for contracts that require
  /// real baselines. Any unavailable (`nil`), invalid, or over-budget
  /// ratio fails: absent baselines can never become measured parity.
  /// The software gate does not call this (CI has no resource baselines);
  /// hardware qualification enforces it through
  /// `validateHardwareMeasurements`.
  public static func evaluateResourceParity(
    cpuRatio: Double?,
    memoryRatio: Double?,
    copyAllocationRatio: Double?,
    budgets: Budgets = .default
  ) -> Verdict {
    var reasons: [String] = []
    reasons.append(contentsOf: budgets.invalidReasons())
    reasons.append(contentsOf: validateResourceRatio(cpuRatio, name: "cpuRatio", budget: budgets.maxCPURatio, regressionPrefix: "CPU regression"))
    reasons.append(contentsOf: validateResourceRatio(memoryRatio, name: "memoryRatio", budget: budgets.maxMemoryRatio, regressionPrefix: "memory regression"))
    reasons.append(
      contentsOf: validateResourceRatio(
        copyAllocationRatio, name: "copyAllocationRatio", budget: budgets.maxCopyAllocationRatio,
        regressionPrefix: "audio-copy/allocation regression"))
    return Verdict(passed: reasons.isEmpty, reasons: reasons)
  }

  // MARK: - Shared validation

  /// Validates the software-gate performance numbers. Startup and
  /// block-call timings are required and fail the gate when missing,
  /// invalid, or over budget. Resource ratios are optional here: a present
  /// value is validated, an absent one is reported in `notes` as explicitly
  /// not qualified (never as parity, never a failure of this gate).
  private static func validateSoftwareMeasurements(
    _ measurements: Measurements?, budgets: Budgets
  ) -> (reasons: [String], notes: [String]) {
    guard let measurements else {
      return (reasons: ["missing performance measurements"], notes: [])
    }
    var reasons: [String] = []
    var notes: [String] = []
    reasons.append(contentsOf: budgets.invalidReasons())
    reasons.append(contentsOf: validateTimingMeasurements(measurements, budgets: budgets))
    let resource = validateOptionalResourceRatios(
      cpuRatio: measurements.cpuRatio,
      memoryRatio: measurements.memoryRatio,
      copyAllocationRatio: measurements.copyAllocationRatio,
      budgets: budgets)
    reasons.append(contentsOf: resource.reasons)
    notes.append(contentsOf: resource.notes)
    return (reasons: reasons, notes: notes)
  }

  /// Validates hardware-run performance numbers. Identical to the software
  /// gate for timings, but resource baselines are mandatory: `nil` fails
  /// with an explicit missing-baseline reason so absent measurements can
  /// never silently become parity.
  private static func validateHardwareMeasurements(
    _ measurements: Measurements?, budgets: Budgets
  ) -> [String] {
    guard let measurements else {
      return ["missing performance measurements"]
    }
    var reasons: [String] = []
    reasons.append(contentsOf: budgets.invalidReasons())
    reasons.append(contentsOf: validateTimingMeasurements(measurements, budgets: budgets))
    reasons.append(contentsOf: validateRequiredResourceRatios(
      cpuRatio: measurements.cpuRatio,
      memoryRatio: measurements.memoryRatio,
      copyAllocationRatio: measurements.copyAllocationRatio,
      budgets: budgets))
    return reasons
  }

  /// Timing validation shared by both gates: startup plus block-call
  /// overhead for supported, measurable cases.
  private static func validateTimingMeasurements(
    _ measurements: Measurements, budgets: Budgets
  ) -> [String] {
    var reasons: [String] = []
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
    return reasons
  }

  /// Optional resource validation for the software gate: present values
  /// are budget-checked, absent values become explicit not-qualified notes.
  private static func validateOptionalResourceRatios(
    cpuRatio: Double?,
    memoryRatio: Double?,
    copyAllocationRatio: Double?,
    budgets: Budgets
  ) -> (reasons: [String], notes: [String]) {
    var reasons: [String] = []
    var notes: [String] = []
    let fields: [(name: String, value: Double?)] = [
      ("cpuRatio", cpuRatio),
      ("memoryRatio", memoryRatio),
      ("copyAllocationRatio", copyAllocationRatio),
    ]
    for field in fields {
      guard let value = field.value else {
        notes.append(
          "resource parity not qualified: \(field.name) has no CI baseline (not measured, not claimed)")
        continue
      }
      reasons.append(
        contentsOf: validateResourceValue(value, name: field.name, budgets: budgets))
    }
    return (reasons: reasons, notes: notes)
  }

  /// Required resource validation for hardware qualification: absent
  /// baselines fail explicitly instead of becoming parity.
  private static func validateRequiredResourceRatios(
    cpuRatio: Double?,
    memoryRatio: Double?,
    copyAllocationRatio: Double?,
    budgets: Budgets
  ) -> [String] {
    var reasons: [String] = []
    let fields: [(name: String, value: Double?)] = [
      ("cpuRatio", cpuRatio),
      ("memoryRatio", memoryRatio),
      ("copyAllocationRatio", copyAllocationRatio),
    ]
    for field in fields {
      guard let value = field.value else {
        reasons.append(
          "missing resource baseline: \(field.name) has no hardware baseline")
        continue
      }
      reasons.append(
        contentsOf: validateResourceValue(value, name: field.name, budgets: budgets))
    }
    return reasons
  }

  private static func validateResourceValue(
    _ value: Double, name: String, budgets: Budgets
  ) -> [String] {
    let budget: Double
    let regressionPrefix: String
    switch name {
    case "cpuRatio":
      budget = budgets.maxCPURatio
      regressionPrefix = "CPU regression"
    case "memoryRatio":
      budget = budgets.maxMemoryRatio
      regressionPrefix = "memory regression"
    default:
      budget = budgets.maxCopyAllocationRatio
      regressionPrefix = "audio-copy/allocation regression"
    }
    return validateResourceRatio(value, name: name, budget: budget, regressionPrefix: regressionPrefix)
  }

  private static func validateResourceRatio(
    _ value: Double?, name: String, budget: Double, regressionPrefix: String
  ) -> [String] {
    guard let value else {
      return ["missing resource baseline: \(name) has no baseline"]
    }
    if !(value > 0 && value.isFinite) {
      return ["invalid performance measurement: \(name)=\(value) must be positive and finite"]
    }
    if !(value <= budget) {
      return ["\(regressionPrefix): ratio \(value) exceeds budget \(budget)"]
    }
    return []
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
