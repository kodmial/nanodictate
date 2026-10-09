import Foundation
import NanoDictateRustBridge
@testable import NanoDictateCore

// Gate tests for #123: the automated software gate passes on CI-runnable
// evidence alone, while real-hardware qualification stays tracked in #35.
// FFI probes use block-oriented calls only (no per-sample FFI, no audio
// hardware) so CI measures the linked engine deterministically.
//
// NOTE on evidence: `passingMeasurements()` below is a unit-test oracle for
// the gate logic (it pins what "in budget" means). Release evidence is a
// green CI run of this whole suite: the `evaluateSoftware` unit coverage
// plus the real FFI probes at the bottom of this file
// (`testEngineStartupLatencyWithinBudget`,
// `testRealtimeBlockFFIOverheadWithinBudget`), which measure the linked
// engine on the CI runner. The release candidate-gate requires that
// exact-head CI run alongside Packaging smoke; packaging alone never
// publishes.
final class RustParityGateTests: XCTestCase {

  private func passingMeasurements() -> RustParityGate.Measurements {
    RustParityGate.Measurements(
      startupLatencyMs: 5,
      maxBlockCallMs: 2,
      meanBlockCallMs: 0.2,
      cpuRatio: 1.0,
      memoryRatio: 1.0,
      copyAllocationRatio: 1.0
    )
  }

  private func fullChecklist() -> Set<RustParityGate.ChecklistItem> {
    Set(RustParityGate.ChecklistItem.allCases)
  }

  private func fullAutomated() -> Set<RustParityGate.AutomatedCheck> {
    Set(RustParityGate.AutomatedCheck.allCases)
  }

  @objc func testGateFailsWhenChecklistIncomplete() {
    let verdict = RustParityGate.evaluate(
      passedItems: [],
      measurements: passingMeasurements(),
      supersededSwiftRemoved: false
    )
    XCTAssertFalse(verdict.passed, "empty checklist must keep the gate red")
    XCTAssertTrue(
      verdict.reasons.contains { $0.contains("repeated-start-stop") },
      "reasons must name missing items: \(verdict.reasons)")
  }

  @objc func testGateFailsWithoutMeasurements() {
    let verdict = RustParityGate.evaluate(
      passedItems: fullChecklist(),
      measurements: nil,
      supersededSwiftRemoved: false
    )
    XCTAssertFalse(verdict.passed, "gate needs performance numbers")
  }

  @objc func testGateFailsOnLatencyRegression() {
    var bad = passingMeasurements()
    bad.meanBlockCallMs = RustParityGate.Budgets.default.maxMeanBlockCallMs + 1
    let verdict = RustParityGate.evaluate(
      passedItems: fullChecklist(),
      measurements: bad,
      supersededSwiftRemoved: false
    )
    XCTAssertFalse(verdict.passed, "mean block regression must fail the gate")
  }

  @objc func testGateFailsOnInvalidMeasurements() {
    var bad = passingMeasurements()
    bad.startupLatencyMs = -1
    bad.cpuRatio = 0
    let verdict = RustParityGate.evaluate(
      passedItems: fullChecklist(),
      measurements: bad,
      supersededSwiftRemoved: false
    )
    XCTAssertFalse(verdict.passed, "invalid measurements must fail the gate")
    XCTAssertTrue(
      verdict.reasons.contains { $0.contains("invalid performance measurement") },
      "reasons must flag invalid measurements: \(verdict.reasons)")
  }

  @objc func testGateRejectsNaNMeasurements() {
    var nanStartup = passingMeasurements()
    nanStartup.startupLatencyMs = .nan
    var nanMax = passingMeasurements()
    nanMax.maxBlockCallMs = .nan
    var nanMean = passingMeasurements()
    nanMean.meanBlockCallMs = .nan
    var nanCPU = passingMeasurements()
    nanCPU.cpuRatio = .nan
    var nanMemory = passingMeasurements()
    nanMemory.memoryRatio = .nan
    var nanCopy = passingMeasurements()
    nanCopy.copyAllocationRatio = .nan
    let cases: [(String, RustParityGate.Measurements)] = [
      ("startupLatencyMs", nanStartup),
      ("maxBlockCallMs", nanMax),
      ("meanBlockCallMs", nanMean),
      ("cpuRatio", nanCPU),
      ("memoryRatio", nanMemory),
      ("copyAllocationRatio", nanCopy),
    ]
    for (field, measurements) in cases {
      let verdict = RustParityGate.evaluate(
        passedItems: fullChecklist(),
        measurements: measurements,
        supersededSwiftRemoved: false
      )
      XCTAssertFalse(verdict.passed, "NaN \(field) must fail the gate")
      XCTAssertTrue(
        verdict.reasons.contains { $0.contains("invalid performance measurement") && $0.contains(field) },
        "NaN \(field) must produce a field-specific reason: \(verdict.reasons)")
    }
  }

  @objc func testGateRejectsInvalidBlockDurations() {
    var negativeMax = passingMeasurements()
    negativeMax.maxBlockCallMs = -1
    var negativeMean = passingMeasurements()
    negativeMean.meanBlockCallMs = -1
    var infiniteMax = passingMeasurements()
    infiniteMax.maxBlockCallMs = .infinity
    var infiniteMean = passingMeasurements()
    infiniteMean.meanBlockCallMs = .infinity
    let cases: [(String, RustParityGate.Measurements)] = [
      ("maxBlockCallMs", negativeMax),
      ("meanBlockCallMs", negativeMean),
      ("maxBlockCallMs", infiniteMax),
      ("meanBlockCallMs", infiniteMean),
    ]
    for (field, measurements) in cases {
      let verdict = RustParityGate.evaluate(
        passedItems: fullChecklist(),
        measurements: measurements,
        supersededSwiftRemoved: false
      )
      XCTAssertFalse(verdict.passed, "invalid \(field)=\(field == "maxBlockCallMs" ? measurements.maxBlockCallMs : measurements.meanBlockCallMs) must fail the gate")
      XCTAssertTrue(
        verdict.reasons.contains { $0.contains("invalid performance measurement") && $0.contains(field) },
        "invalid \(field) must produce a field-specific reason: \(verdict.reasons)")
    }
  }

  @objc func testGateRejectsInvalidMemoryAndCopyRatios() {
    var zeroMemory = passingMeasurements()
    zeroMemory.memoryRatio = 0
    var negativeCopy = passingMeasurements()
    negativeCopy.copyAllocationRatio = -0.5
    var nanMemory = passingMeasurements()
    nanMemory.memoryRatio = .nan
    var infiniteCopy = passingMeasurements()
    infiniteCopy.copyAllocationRatio = .infinity
    let cases: [(String, RustParityGate.Measurements)] = [
      ("memoryRatio", zeroMemory),
      ("copyAllocationRatio", negativeCopy),
      ("memoryRatio", nanMemory),
      ("copyAllocationRatio", infiniteCopy),
    ]
    for (field, measurements) in cases {
      let verdict = RustParityGate.evaluate(
        passedItems: fullChecklist(),
        measurements: measurements,
        supersededSwiftRemoved: false
      )
      XCTAssertFalse(verdict.passed, "invalid \(field) must fail the gate")
      XCTAssertTrue(
        verdict.reasons.contains { $0.contains("invalid performance measurement") && $0.contains(field) },
        "invalid \(field) must produce a field-specific reason: \(verdict.reasons)")
    }
  }

  @objc func testGateFailsOnEachOverBudgetBranch() {
    var overStartup = passingMeasurements()
    overStartup.startupLatencyMs = RustParityGate.Budgets.default.maxStartupLatencyMs + 1
    var overMax = passingMeasurements()
    overMax.maxBlockCallMs = RustParityGate.Budgets.default.maxBlockCallMs + 1
    var overMean = passingMeasurements()
    overMean.maxBlockCallMs = RustParityGate.Budgets.default.maxBlockCallMs
    overMean.meanBlockCallMs = RustParityGate.Budgets.default.maxMeanBlockCallMs + 1
    var overCPU = passingMeasurements()
    overCPU.cpuRatio = RustParityGate.Budgets.default.maxCPURatio + 0.1
    var overMemory = passingMeasurements()
    overMemory.memoryRatio = RustParityGate.Budgets.default.maxMemoryRatio + 0.1
    let cases: [(String, RustParityGate.Measurements, String)] = [
      ("startupLatencyMs", overStartup, "startup latency regression"),
      ("maxBlockCallMs", overMax, "realtime block regression: max"),
      ("meanBlockCallMs", overMean, "realtime block regression: mean"),
      ("cpuRatio", overCPU, "CPU regression"),
      ("memoryRatio", overMemory, "memory regression"),
    ]
    for (field, measurements, reason) in cases {
      let verdict = RustParityGate.evaluate(
        passedItems: fullChecklist(),
        measurements: measurements,
        supersededSwiftRemoved: false
      )
      XCTAssertFalse(verdict.passed, "over-budget \(field) must fail the gate")
      XCTAssertTrue(
        verdict.reasons.contains { $0.contains(reason) },
        "over-budget \(field) must report '\(reason)': \(verdict.reasons)")
    }
  }

  @objc func testGateFailsOnCopyAllocationRegression() {
    var bad = passingMeasurements()
    bad.copyAllocationRatio = RustParityGate.Budgets.default.maxCopyAllocationRatio + 0.1
    let verdict = RustParityGate.evaluate(
      passedItems: fullChecklist(),
      measurements: bad,
      supersededSwiftRemoved: false
    )
    XCTAssertFalse(verdict.passed, "audio-copy/allocation regression must fail the gate")
    XCTAssertTrue(
      verdict.reasons.contains { $0.contains("audio-copy/allocation") },
      "reasons must name copy/allocation regression: \(verdict.reasons)")
  }

  @objc func testGateBlocksSwiftRemovalBeforeParity() {
    let verdict = RustParityGate.evaluate(
      passedItems: [],
      measurements: nil,
      supersededSwiftRemoved: true
    )
    XCTAssertFalse(verdict.passed, "Swift removal before parity must fail")
    XCTAssertTrue(
      verdict.reasons.contains { $0.contains("must not be removed") },
      "removal rule must be explicit: \(verdict.reasons)")
  }

  @objc func testGateFailsWhenMeanExceedsMax() {
    var inconsistent = passingMeasurements()
    inconsistent.maxBlockCallMs = 1
    inconsistent.meanBlockCallMs = 4
    let verdict = RustParityGate.evaluate(
      passedItems: fullChecklist(),
      measurements: inconsistent,
      supersededSwiftRemoved: false
    )
    XCTAssertFalse(verdict.passed, "mean exceeding max must fail the gate")
    XCTAssertTrue(
      verdict.reasons.contains { $0.contains("mean") && $0.contains("max") },
      "reasons must flag inconsistent block-call measurements: \(verdict.reasons)")
  }

  @objc func testGateFailsOnInvalidBudgets() {
    var infiniteBudget = RustParityGate.Budgets.default
    infiniteBudget.maxBlockCallMs = .infinity
    let verdict = RustParityGate.evaluate(
      passedItems: fullChecklist(),
      measurements: passingMeasurements(),
      supersededSwiftRemoved: false,
      budgets: infiniteBudget
    )
    XCTAssertFalse(verdict.passed, "non-finite budget must fail the gate")
    XCTAssertTrue(
      verdict.reasons.contains { $0.contains("invalid budget") },
      "reasons must flag invalid budgets: \(verdict.reasons)")
  }

  @objc func testGatePassesWhenEvidenceAndBudgetsHold() {
    let verdict = RustParityGate.evaluate(
      passedItems: fullChecklist(),
      measurements: passingMeasurements(),
      supersededSwiftRemoved: false
    )
    XCTAssertTrue(verdict.passed, "complete evidence without regression passes: \(verdict.reasons)")
    XCTAssertTrue(verdict.reasons.isEmpty)
  }

  @objc func testChecklistCoversRequiredValidation() {
    // The issue lists 15 validation areas; the gate must not silently drop one.
    XCTAssertEqual(RustParityGate.ChecklistItem.allCases.count, 15)
  }

  // MARK: - Automated software gate (#123, no hardware prerequisite)

  @objc func testSoftwareGatePassesWithoutHardwareEvidence() {
    // The automated gate never requires the #35 hardware checklist: full
    // automated evidence plus in-budget CI measurements passes on its own.
    let verdict = RustParityGate.evaluateSoftware(
      passedAutomated: fullAutomated(),
      measurements: passingMeasurements(),
      supersededSwiftRemoved: false
    )
    XCTAssertTrue(verdict.passed, "automated evidence without regression passes: \(verdict.reasons)")
    XCTAssertTrue(verdict.reasons.isEmpty)
  }

  @objc func testSoftwareGateIgnoresMissingHardwareWhileHardwareGateStaysRed() {
    // Pins the two-track split: with no hardware evidence at all, the
    // software gate passes while the hardware qualification contract
    // stays red for #35 tracking.
    let software = RustParityGate.evaluateSoftware(
      passedAutomated: fullAutomated(),
      measurements: passingMeasurements(),
      supersededSwiftRemoved: false
    )
    XCTAssertTrue(software.passed, "software gate needs no hardware: \(software.reasons)")
    let hardware = RustParityGate.evaluate(
      passedItems: [],
      measurements: passingMeasurements(),
      supersededSwiftRemoved: false
    )
    XCTAssertFalse(hardware.passed, "hardware gate stays red without hardware evidence")
    XCTAssertTrue(
      hardware.reasons.contains { $0.contains("missing hardware evidence") },
      "hardware reasons must name the gap for #35: \(hardware.reasons)")
  }

  @objc func testSoftwareGateFailsWhenAutomatedIncomplete() {
    let verdict = RustParityGate.evaluateSoftware(
      passedAutomated: [],
      measurements: passingMeasurements(),
      supersededSwiftRemoved: false
    )
    XCTAssertFalse(verdict.passed, "empty automated evidence must keep the gate red")
    XCTAssertTrue(
      verdict.reasons.contains { $0.contains("abi-lifetime-ownership") },
      "reasons must name missing areas: \(verdict.reasons)")
    XCTAssertTrue(
      verdict.reasons.contains { $0.contains("text-insertion") },
      "reasons must name every missing area: \(verdict.reasons)")
  }

  @objc func testSoftwareGateFailsWhenOneAutomatedAreaMissing() {
    var automated = fullAutomated()
    automated.remove(.sessionLifecycle)
    let verdict = RustParityGate.evaluateSoftware(
      passedAutomated: automated,
      measurements: passingMeasurements(),
      supersededSwiftRemoved: false
    )
    XCTAssertFalse(verdict.passed, "one missing area must keep the gate red")
    XCTAssertEqual(
      verdict.reasons.filter { $0.contains("missing automated evidence") }.count, 1,
      "exactly the missing area is reported: \(verdict.reasons)")
  }

  @objc func testSoftwareGateFailsWithoutMeasurements() {
    let verdict = RustParityGate.evaluateSoftware(
      passedAutomated: fullAutomated(),
      measurements: nil,
      supersededSwiftRemoved: false
    )
    XCTAssertFalse(verdict.passed, "software gate needs CI-generated numbers")
    XCTAssertTrue(
      verdict.reasons.contains { $0.contains("missing performance measurements") },
      "reasons must ask for measurements: \(verdict.reasons)")
  }

  @objc func testSoftwareGateFailsOnRegression() {
    var regressed = passingMeasurements()
    regressed.meanBlockCallMs = RustParityGate.Budgets.default.maxMeanBlockCallMs + 1
    regressed.cpuRatio = RustParityGate.Budgets.default.maxCPURatio + 0.1
    let verdict = RustParityGate.evaluateSoftware(
      passedAutomated: fullAutomated(),
      measurements: regressed,
      supersededSwiftRemoved: false
    )
    XCTAssertFalse(verdict.passed, "regressed measurements must fail the software gate")
    XCTAssertTrue(
      verdict.reasons.contains { $0.contains("realtime block regression: mean") },
      "reasons must name the block regression: \(verdict.reasons)")
    XCTAssertTrue(
      verdict.reasons.contains { $0.contains("CPU regression") },
      "reasons must name the CPU regression: \(verdict.reasons)")
  }

  @objc func testSoftwareGateRejectsInvalidBudgets() {
    var infiniteBudget = RustParityGate.Budgets.default
    infiniteBudget.maxMemoryRatio = .infinity
    let verdict = RustParityGate.evaluateSoftware(
      passedAutomated: fullAutomated(),
      measurements: passingMeasurements(),
      supersededSwiftRemoved: false,
      budgets: infiniteBudget
    )
    XCTAssertFalse(verdict.passed, "non-finite budget must fail the software gate")
    XCTAssertTrue(
      verdict.reasons.contains { $0.contains("invalid budget") },
      "reasons must flag invalid budgets: \(verdict.reasons)")
  }

  @objc func testSoftwareGateBlocksSwiftRemovalBeforeAutomatedParity() {
    let verdict = RustParityGate.evaluateSoftware(
      passedAutomated: [],
      measurements: nil,
      supersededSwiftRemoved: true
    )
    XCTAssertFalse(verdict.passed, "Swift removal before automated parity must fail")
    XCTAssertTrue(
      verdict.reasons.contains { $0.contains("must not be removed") },
      "removal rule must be explicit: \(verdict.reasons)")
    XCTAssertTrue(
      verdict.reasons.contains { $0.contains("removal is blocked") },
      "blocked removal must be explicit for audits: \(verdict.reasons)")
  }

  @objc func testSoftwareGateAllowsRemovalOnlyWhenAutomatedPasses() {
    // Removal with passing automated evidence but regressed measurements
    // is still a regression with an explicit removal trail.
    var regressed = passingMeasurements()
    regressed.copyAllocationRatio = RustParityGate.Budgets.default.maxCopyAllocationRatio + 0.1
    let blocked = RustParityGate.evaluateSoftware(
      passedAutomated: fullAutomated(),
      measurements: regressed,
      supersededSwiftRemoved: true
    )
    XCTAssertFalse(blocked.passed, "removal with regressed measurements stays blocked")
    XCTAssertTrue(
      blocked.reasons.contains { $0.contains("audio-copy/allocation") },
      "reasons must name the regression: \(blocked.reasons)")
    XCTAssertTrue(
      blocked.reasons.contains { $0.contains("removal is blocked") },
      "reasons must carry the removal trail: \(blocked.reasons)")

    let allowed = RustParityGate.evaluateSoftware(
      passedAutomated: fullAutomated(),
      measurements: passingMeasurements(),
      supersededSwiftRemoved: true
    )
    XCTAssertTrue(allowed.passed, "removal with green automated evidence passes: \(allowed.reasons)")
  }

  @objc func testAutomatedChecklistCoversRequiredAreas() {
    // The Definition of Done lists six automated areas; the gate must not
    // silently drop one.
    XCTAssertEqual(RustParityGate.AutomatedCheck.allCases.count, 6)
  }

  @objc func testEngineStartupLatencyWithinBudget() {
    let start = Date()
    do {
      try RustEngine.checkAvailable()
    } catch {
      XCTFail("engine startup failed: \(error)")
      return
    }
    let elapsedMs = Date().timeIntervalSince(start) * 1000
    XCTAssertLessThan(
      elapsedMs,
      RustParityGate.Budgets.default.maxStartupLatencyMs,
      "ABI check must stay far below the startup budget")
  }

  @objc func testRealtimeBlockFFIOverheadWithinBudget() {
    let block = [Float](repeating: 0.02, count: 1600)
    let iterations = 50
    var samples = block
    var maxMs: Double = 0
    var totalMs: Double = 0
    do {
      let vad = try RustVAD()
      let gain = try RustInputGain()
      for _ in 0..<iterations {
        let start = Date()
        _ = try vad.feedSamples(block, sampleRate: 16000)
        _ = try gain.apply(samples: &samples, rms: 0.02, sampleRate: 16000)
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        totalMs += elapsedMs
        maxMs = max(maxMs, elapsedMs)
      }
    } catch {
      XCTFail("block FFI probe failed: \(error)")
      return
    }
    let meanMs = totalMs / Double(iterations)
    XCTAssertLessThan(
      meanMs,
      RustParityGate.Budgets.default.maxMeanBlockCallMs,
      "mean block FFI overhead must stay within budget (mean \(meanMs)ms)")
    XCTAssertLessThan(
      maxMs,
      RustParityGate.Budgets.default.maxBlockCallMs,
      "max block FFI call must stay within budget (max \(maxMs)ms)")
  }
}
