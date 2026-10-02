import Foundation
import NanoDictateRustBridge
@testable import NanoDictateCore

// Gate tests for #123: the final hardware parity/performance gate stays red
// until every required validation item has evidence, measurements show no
// material regression, and superseded Swift is kept until parity passes.
// FFI probes use block-oriented calls only (no per-sample FFI, no audio
// hardware) so CI measures the linked engine deterministically.
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
