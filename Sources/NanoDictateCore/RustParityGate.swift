import Foundation

// MARK: - RustParityGate: final hardware parity/performance gate (#123)
//
// Executable form of the Definition of Done for the production cutover
// tracked by #123 (blocked by #131, #132, #133). The shared Rust engine
// foundation from PR #67 is linked and parity-tested, but production
// call-site activation lands in #131/#132/#133. This gate stays red until:
//   - every required real-hardware validation item passes,
//   - realtime/latency/resource measurements show no material regression,
//   - any superseded Swift implementation is removed only after parity.
//
// The model is intentionally pure (no AVFoundation, no FFI): tests and
// hardware runs feed checklist results and measurements in, and the gate
// computes a verdict with human-readable reasons. FFI overhead probes
// live in tests so CI measures the linked engine without audio hardware.

public enum RustParityGate {
  // MARK: - Required validation checklist

  /// Required real-hardware validation items from #123. Case order matches
  /// the issue text so evidence tables can iterate `allCases` directly.
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

    public init(
      startupLatencyMs: Double,
      maxBlockCallMs: Double,
      meanBlockCallMs: Double,
      cpuRatio: Double,
      memoryRatio: Double
    ) {
      self.startupLatencyMs = startupLatencyMs
      self.maxBlockCallMs = maxBlockCallMs
      self.meanBlockCallMs = meanBlockCallMs
      self.cpuRatio = cpuRatio
      self.memoryRatio = memoryRatio
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

    public static let `default` = Budgets(
      maxStartupLatencyMs: 500,
      maxBlockCallMs: 25,
      maxMeanBlockCallMs: 5,
      maxCPURatio: 1.2,
      maxMemoryRatio: 1.2
    )

    public init(
      maxStartupLatencyMs: Double,
      maxBlockCallMs: Double,
      maxMeanBlockCallMs: Double,
      maxCPURatio: Double,
      maxMemoryRatio: Double
    ) {
      self.maxStartupLatencyMs = maxStartupLatencyMs
      self.maxBlockCallMs = maxBlockCallMs
      self.maxMeanBlockCallMs = maxMeanBlockCallMs
      self.maxCPURatio = maxCPURatio
      self.maxMemoryRatio = maxMemoryRatio
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

  // MARK: - Evaluation

  /// Evaluates the gate. `passedItems` holds the checklist items with
  /// recorded hardware evidence; `measurements` is nil when the hardware
  /// run has not reported numbers yet. `supersededSwiftRemoved` must stay
  /// false until the gate passes (see #123 DoD).
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

    if let measurements {
      if !(measurements.startupLatencyMs <= budgets.maxStartupLatencyMs) {
        reasons.append(
          "startup latency regression: \(measurements.startupLatencyMs)ms exceeds budget \(budgets.maxStartupLatencyMs)ms"
        )
      }
      if !(measurements.maxBlockCallMs <= budgets.maxBlockCallMs) {
        reasons.append(
          "realtime block regression: max \(measurements.maxBlockCallMs)ms exceeds budget \(budgets.maxBlockCallMs)ms"
        )
      }
      if !(measurements.meanBlockCallMs <= budgets.maxMeanBlockCallMs) {
        reasons.append(
          "realtime block regression: mean \(measurements.meanBlockCallMs)ms exceeds budget \(budgets.maxMeanBlockCallMs)ms"
        )
      }
      if !(measurements.cpuRatio <= budgets.maxCPURatio) {
        reasons.append(
          "CPU regression: ratio \(measurements.cpuRatio) exceeds budget \(budgets.maxCPURatio)"
        )
      }
      if !(measurements.memoryRatio <= budgets.maxMemoryRatio) {
        reasons.append(
          "memory regression: ratio \(measurements.memoryRatio) exceeds budget \(budgets.maxMemoryRatio)"
        )
      }
    } else {
      reasons.append("missing performance measurements")
    }

    if supersededSwiftRemoved, !missing.isEmpty || measurements == nil {
      reasons.append("superseded Swift must not be removed before parity validation passes")
    }

    // Removal with passing checklist but regressed measurements is still
    // a regression, yet deserves an explicit removal reason for audits.
    if supersededSwiftRemoved, !reasons.isEmpty {
      reasons.append("gate is red: superseded Swift removal is blocked")
    }

    return Verdict(passed: reasons.isEmpty, reasons: reasons)
  }
}
