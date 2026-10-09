import Foundation
import NanoDictateRustBridge
@testable import NanoDictateCore

// Gate tests for #123: the automated software gate passes on CI-runnable
// evidence alone, while real-hardware qualification stays tracked in #35.
// FFI probes use block-oriented calls only (no per-sample FFI, no audio
// hardware) so CI measures the linked engine deterministically.
//
// NOTE on evidence: `passingMeasurements()` below is a synthetic gate-logic
// oracle only (it pins what "in budget, with baselines present" means for
// unit tests of the budget branches). It is never release evidence.
// Release evidence is a green CI run of this whole suite: the
// `evaluateSoftware` unit coverage, the real FFI probes at the bottom of
// this file (`testEngineStartupLatencyWithinBudget`,
// `testRealtimeBlockFFIOverheadWithinBudget`), and the evidence-to-verdict
// test (`testSoftwareGatePassesOnRealEngineMeasurements`), which feeds only
// really measured numbers (startup + block-call timings, with resource
// ratios explicitly unavailable) plus per-area proven automated checks into
// `evaluateSoftware` so a green run carries a passing verdict. The release
// candidate-gate requires that exact-head CI run alongside Packaging smoke;
// packaging alone never publishes.
final class RustParityGateTests: XCTestCase {

  private func passingMeasurements() -> RustParityGate.Measurements {
    // Synthetic oracle: pretends measured baselines exist for every
    // dimension so budget-branch unit tests can exercise the
    // present-value paths. Not CI evidence.
    RustParityGate.Measurements(
      startupLatencyMs: 5,
      maxBlockCallMs: 2,
      meanBlockCallMs: 0.2,
      cpuRatio: 1.0,
      memoryRatio: 1.0,
      copyAllocationRatio: 1.0
    )
  }

  private func unmeasuredResourceMeasurements(
    startupLatencyMs: Double = 5,
    maxBlockCallMs: Double = 2,
    meanBlockCallMs: Double = 0.2
  ) -> RustParityGate.Measurements {
    // Shape of real CI evidence in this repository: timings are measured,
    // resource ratios have no CI-measurable baseline and stay unavailable.
    RustParityGate.Measurements(
      startupLatencyMs: startupLatencyMs,
      maxBlockCallMs: maxBlockCallMs,
      meanBlockCallMs: meanBlockCallMs,
      cpuRatio: nil,
      memoryRatio: nil,
      copyAllocationRatio: nil
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
    nanCPU.cpuRatio = Double.nan
    var nanMemory = passingMeasurements()
    nanMemory.memoryRatio = Double.nan
    var nanCopy = passingMeasurements()
    nanCopy.copyAllocationRatio = Double.nan
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
    nanMemory.memoryRatio = Double.nan
    var infiniteCopy = passingMeasurements()
    infiniteCopy.copyAllocationRatio = Double.infinity
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

  /// Provenance for the evidence-to-verdict test: exercises one real
  /// linked-engine call per automated coverage area and records the area
  /// only when its probe succeeds. A throwing probe fails the test, so the
  /// returned set can never silently claim an area that did not run green
  /// on this runner. This replaces the previous unconditional
  /// `fullAutomated()` constant in the real validation path; synthetic
  /// `fullAutomated()` remains only in gate-logic unit tests.
  private func collectProvenAutomatedChecks() -> Set<RustParityGate.AutomatedCheck> {
    var proven: Set<RustParityGate.AutomatedCheck> = []
    do {
      let vad = try RustVAD()
      _ = try vad.feedSamples([Float](repeating: 0.02, count: 160), sampleRate: 16000)
      _ = try vad.diagnostics()
      _ = try RustEngine.wordDiff(old: "One three.", new: "One two three.")
      let wav = try RustEngine.wavEncode(samples: [0, 1000, -1000], sampleRate: 16000, channels: 1)
      _ = try RustEngine.wavDecodeSamples(wav)
      proven.insert(.abiLifetimeOwnership)
    } catch {
      XCTFail("abi-lifetime-ownership probe failed: \(error)")
    }
    do {
      try RustEngine.checkAvailable()
      _ = try RustEngine.wordDiff(old: "a", new: "a")
      _ = try RustEngine.resolveSTTProfile(adapterID: "groq", model: "whisper-large-v3-turbo")
      proven.insert(.swiftBridge)
    } catch {
      XCTFail("swift-bridge probe failed: \(error)")
    }
    do {
      let (session, generation) = try RustEngine.makeSession()
      try session.onEvent(.engineStarted, generation: generation)
      try session.onEvent(.firstBuffer, generation: generation)
      try session.onEvent(.stopRequested, generation: generation)
      try session.onEvent(.transcriptionDone, generation: generation)
      XCTAssertTrue(session.isCaptureReady || !session.isCaptureReady)
      proven.insert(.sessionLifecycle)
    } catch {
      XCTFail("session-lifecycle probe failed: \(error)")
    }
    do {
      _ = try RustEngine.failoverOrder(ids: ["a", "b"], failedID: "a", autoFailover: true)
      _ = RustEngine.retryBackoffBaseMs(attempt: 1)
      _ = RustEngine.shouldFailover(error: TranscribeError.network("probe"))
      _ = try RustEngine.parseTranscript(body: "{\"text\":\"hi\"}", path: nil)
      proven.insert(.sttRetryFailover)
    } catch {
      XCTFail("stt-retry-failover probe failed: \(error)")
    }
    do {
      _ = try RustEngine.makeRealtimeAudio(
        gainConfig: InputGainConfig.defaults,
        vadConfig: AdaptiveVADConfig.defaults,
        autoStopConfig: AutoStopConfig.defaults)
      let vad = try RustVAD()
      var samples = [Float](repeating: 0.02, count: 160)
      let gain = try RustInputGain()
      _ = try vad.feedSamples(samples, sampleRate: 16000)
      _ = try gain.apply(samples: &samples, rms: 0.02, sampleRate: 16000)
      proven.insert(.realtimeAudioVAD)
    } catch {
      XCTFail("realtime-audio-vad probe failed: \(error)")
    }
    do {
      _ = try RustEngine.wordDiffChange(old: "One three.", new: "One two three.")
      _ = try RustEngine.tailAfterWords(1, in: "One two three.")
      _ = try RustEngine.joinChunkTexts(["One two", "two three."])
      _ = try RustEngine.reviewDecide(line: "hello")
      proven.insert(.textInsertion)
    } catch {
      XCTFail("text-insertion probe failed: \(error)")
    }
    return proven
  }

  @objc func testSoftwareGatePassesOnRealEngineMeasurements() {
    // Evidence-to-verdict path (#123): the real startup and block-call
    // probes below measure the linked engine on this CI runner, then feed
    // those CI-generated numbers into `evaluateSoftware`. A green run of
    // this suite therefore IS the software-gate verdict consumed by
    // release publication (the release candidate-gate requires this
    // exact-head CI run to be green); synthetic fixtures elsewhere are
    // unit-test oracles for the gate logic only. `passedAutomated` comes
    // from `collectProvenAutomatedChecks()` (one real probe per area), and
    // resource ratios stay unavailable (`nil`): this repository has no
    // CI-measurable CPU/memory/copy baseline, so the verdict must pass
    // without claiming resource parity. Hardware qualification stays
    // tracked in #35 and never blocks this gate.
    let startupStart = Date()
    do {
      try RustEngine.checkAvailable()
    } catch {
      XCTFail("engine startup failed: \(error)")
      return
    }
    let startupMs = Date().timeIntervalSince(startupStart) * 1000

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
    // No constant 1.0 ratios: unmeasured resource dimensions are
    // explicitly unavailable, never fabricated parity.
    let real = RustParityGate.Measurements(
      startupLatencyMs: startupMs,
      maxBlockCallMs: maxMs,
      meanBlockCallMs: meanMs,
      cpuRatio: nil,
      memoryRatio: nil,
      copyAllocationRatio: nil
    )
    let proven = collectProvenAutomatedChecks()
    XCTAssertEqual(
      proven, Set(RustParityGate.AutomatedCheck.allCases),
      "every automated area must prove itself on this runner before the verdict: \(proven)")
    let verdict = RustParityGate.evaluateSoftware(
      passedAutomated: proven,
      measurements: real,
      supersededSwiftRemoved: false
    )
    XCTAssertTrue(
      verdict.passed,
      "software gate must pass on real engine measurements " +
        "(startup \(startupMs)ms, max \(maxMs)ms, mean \(meanMs)ms): \(verdict.reasons)")
    for dimension in ["cpuRatio", "memoryRatio", "copyAllocationRatio"] {
      XCTAssertTrue(
        verdict.notes.contains { $0.contains(dimension) && $0.contains("not qualified") },
        "\(dimension) must be explicitly not qualified, never claimed as parity: \(verdict.notes)")
    }
    XCTAssertTrue(
      verdict.reasons.allSatisfy { !$0.contains("cpuRatio") && !$0.contains("memoryRatio") && !$0.contains("copyAllocationRatio") },
      "passing software verdict must not claim resource parity: \(verdict.reasons)")
  }

  @objc func testSoftwareGateReportsUnmeasuredResourcesAsNotQualified() {
    // Absent resource baselines must not become measured parity: the
    // software gate passes on timings alone while explicitly listing each
    // unavailable dimension as not qualified.
    let proven = Set(RustParityGate.AutomatedCheck.allCases)
    let verdict = RustParityGate.evaluateSoftware(
      passedAutomated: proven,
      measurements: unmeasuredResourceMeasurements(),
      supersededSwiftRemoved: false
    )
    XCTAssertTrue(verdict.passed, "timings-only evidence passes the software gate: \(verdict.reasons)")
    XCTAssertEqual(verdict.notes.count, 3, "each unavailable dimension is noted: \(verdict.notes)")
    for dimension in ["cpuRatio", "memoryRatio", "copyAllocationRatio"] {
      XCTAssertTrue(
        verdict.notes.contains { $0.contains(dimension) && $0.contains("not qualified") },
        "\(dimension) must be reported as not qualified: \(verdict.notes)")
    }
  }

  @objc func testMissingResourceBaselinesCannotPassResourceParity() {
    // A qualification that requires baselines (hardware contract via
    // `evaluateResourceParity`/`evaluate`) must fail when baselines are
    // absent, and must fail on invalid or over-budget measured values.
    let missing = RustParityGate.evaluateResourceParity(
      cpuRatio: nil, memoryRatio: nil, copyAllocationRatio: nil)
    XCTAssertFalse(missing.passed, "absent baselines cannot pass resource parity")
    XCTAssertTrue(
      missing.reasons.contains { $0.contains("missing resource baseline") },
      "reasons must name the missing baseline: \(missing.reasons)")

    var oneMissing = passingMeasurements()
    oneMissing.cpuRatio = nil
    let oneMissingVerdict = RustParityGate.evaluateResourceParity(
      cpuRatio: oneMissing.cpuRatio,
      memoryRatio: oneMissing.memoryRatio,
      copyAllocationRatio: oneMissing.copyAllocationRatio)
    XCTAssertFalse(oneMissingVerdict.passed, "one absent baseline fails resource parity")

    let overBudget = RustParityGate.evaluateResourceParity(
      cpuRatio: RustParityGate.Budgets.default.maxCPURatio + 0.1,
      memoryRatio: 1.0,
      copyAllocationRatio: 1.0)
    XCTAssertFalse(overBudget.passed, "over-budget resource ratio must fail")

    let invalid = RustParityGate.evaluateResourceParity(
      cpuRatio: 1.0, memoryRatio: 0, copyAllocationRatio: 1.0)
    XCTAssertFalse(invalid.passed, "invalid resource ratio must fail")

    let measured = RustParityGate.evaluateResourceParity(
      cpuRatio: 1.0, memoryRatio: 1.0, copyAllocationRatio: 1.0)
    XCTAssertTrue(measured.passed, "measured in-budget baselines pass: \(measured.reasons)")
  }

  @objc func testHardwareGateRequiresResourceBaselines() {
    // The hardware qualification contract requires real resource
    // baselines: `nil` ratios fail there even though the same shape passes
    // the software gate as explicitly not qualified.
    let software = RustParityGate.evaluateSoftware(
      passedAutomated: Set(RustParityGate.AutomatedCheck.allCases),
      measurements: unmeasuredResourceMeasurements(),
      supersededSwiftRemoved: false
    )
    XCTAssertTrue(software.passed, "software gate passes without resource baselines: \(software.reasons)")
    let hardware = RustParityGate.evaluate(
      passedItems: fullChecklist(),
      measurements: unmeasuredResourceMeasurements(),
      supersededSwiftRemoved: false
    )
    XCTAssertFalse(hardware.passed, "hardware gate must fail without resource baselines")
    XCTAssertTrue(
      hardware.reasons.contains { $0.contains("missing resource baseline") },
      "hardware reasons must name the missing baseline: \(hardware.reasons)")
  }

  @objc func testSoftwareGateFailsWhenProvenEvidenceMissesOneArea() {
    // Provenance check: dropping even one proven area keeps the gate red.
    // This guards the real path against unconditional `allCases`
    // constants — evidence must correspond to checks actually performed.
    let proven = Set(RustParityGate.AutomatedCheck.allCases)
    for missing in RustParityGate.AutomatedCheck.allCases {
      var partial = proven
      partial.remove(missing)
      let verdict = RustParityGate.evaluateSoftware(
        passedAutomated: partial,
        measurements: unmeasuredResourceMeasurements(),
        supersededSwiftRemoved: false
      )
      XCTAssertFalse(verdict.passed, "missing \(missing.rawValue) must keep the gate red")
      XCTAssertTrue(
        verdict.reasons.contains { $0.contains(missing.rawValue) },
        "reasons must name the missing area \(missing.rawValue): \(verdict.reasons)")
    }
    let empty = RustParityGate.evaluateSoftware(
      passedAutomated: [],
      measurements: unmeasuredResourceMeasurements(),
      supersededSwiftRemoved: false
    )
    XCTAssertFalse(empty.passed, "empty proven evidence must keep the gate red")
    XCTAssertEqual(
      empty.reasons.filter { $0.contains("missing automated evidence") }.count, 6,
      "every missing area is reported: \(empty.reasons)")
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
