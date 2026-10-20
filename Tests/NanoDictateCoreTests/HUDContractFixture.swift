import CoreGraphics
import Foundation
@testable import NanoDictateCore

/// Decoded view of `Tests/Fixtures/HUD/hud-contract-v1.json`.
///
/// The fixture is a versioned golden trace of the shipping macOS HUD
/// behavior. It is data only: tests drive the existing `OverlayController`,
/// `OverlayLifecycle`, and `OverlayLevel` primitives and compare their
/// observations with these checkpoints. No presentation state machine is
/// added to the product or to this helper.
struct HUDContractFixture: Decodable {
  struct Constants: Decodable {
    let dbfsFloor: Float
    let attackSeconds: Double
    let releaseSeconds: Double
    let peakHoldSeconds: Double
    let peakFallRatePerSecond: Float
    let meterTickSeconds: Double
    let startingGraceSeconds: Double
    let strokeMinPoints: Float
    let strokeMaxPoints: Float
    let hotThresholdDbfs: Float
    let ringDiameterPoints: Float
    let panelMinWidthPoints: Double
    let panelMaxWidthPoints: Double
    let panelHeightIdlePoints: Double
    let panelHeightRecordingPoints: Double
    let clockTickSeconds: Double
  }

  struct Timing: Decodable {
    struct TerminalHide: Decodable {
      let insert: Double
      let cancelled: Double
      let emptyResult: Double
      let error: Double
      let microphoneError: Double
    }

    let terminalHideSeconds: TerminalHide
  }

  struct RMSVector: Decodable {
    let rms: Float
    let dbfs: Float
    let meter: Float
    let strokePoints: Float
    let hot: Bool
  }

  struct VUTrace: Decodable {
    struct Step: Decodable {
      let atMs: Double
      let rms: Float
      let targetMeter: Float
      let meter: Float
      let peak: Float
      let strokePoints: Float
    }

    let name: String
    let tickSeconds: Double
    let reduceMotion: Bool
    let steps: [Step]
  }

  struct PresentationScenario: Decodable {
    struct Event: Decodable {
      let atMs: Double
      let event: String
      let generation: UInt64
    }

    struct Checkpoint: Decodable {
      let atMs: Double
      let visible: Bool
      let phase: String
      let recordingStarted: Bool
      let statusKey: String?
      let statusArgumentKey: String?
      let generation: UInt64
      let rustState: String?
    }

    let name: String
    let description: String
    let sessionGeneration: UInt64
    let events: [Event]
    let checkpoints: [Checkpoint]
  }

  let contract: String
  let version: Int
  let constants: Constants
  let timing: Timing
  let rmsVectors: [RMSVector]
  let vuTraces: [VUTrace]
  let presentationScenarios: [PresentationScenario]

  func scenario(named name: String) -> PresentationScenario? {
    presentationScenarios.first { $0.name == name }
  }

  func requiredScenario(named name: String) -> PresentationScenario? {
    guard let scenario = scenario(named: name) else {
      XCTFail("HUD fixture is missing scenario '\(name)'")
      return nil
    }
    return scenario
  }
}

enum HUDContractFixtureLoader {
  static let relativePath = "Tests/Fixtures/HUD/hud-contract-v1.json"

  static func load() -> HUDContractFixture {
    guard let url = fixtureURL() else {
      fatalError("HUD contract fixture not found at \(relativePath)")
    }
    do {
      let data = try Data(contentsOf: url)
      let decoder = JSONDecoder()
      decoder.keyDecodingStrategy = .convertFromSnakeCase
      return try decoder.decode(HUDContractFixture.self, from: data)
    } catch {
      fatalError("HUD contract fixture could not be decoded: \(error)")
    }
  }

  private static func fixtureURL() -> URL? {
    let fileDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    let candidates = [
      fileDirectory
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent(relativePath),
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(relativePath),
    ]
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
  }
}

/// Test-only presentation bookkeeping for scenarios that use the real
/// `OverlayController`. It only records whether the scenario called `show`
/// (`OverlayController.isVisible` is intentionally false in the headless test
/// runner) and forwards every phase/status operation to the shipping
/// controller. It does not decide phases or timing.
final class HUDScenarioPresentation {
  let controller: OverlayController

  init(controller: OverlayController = OverlayController()) {
    self.controller = controller
  }

  /// Follows the controller's own logical presentation state instead of
  /// test-side bookkeeping, so a no-op `hide()` cannot pass a hidden
  /// checkpoint.
  var presented: Bool {
    controller.testIsPresented
  }

  func show(at point: CGPoint = CGPoint(x: 700, y: 500)) {
    controller.show(at: point)
  }

  func setStarting() {
    controller.setStartingPhase()
  }

  func setRecording(startedAt: Date = Date()) {
    controller.setRecordingPhase(startedAt: startedAt)
  }

  func setProcessing() {
    controller.setProcessingPhase()
  }

  func reset() {
    controller.resetPhase()
  }

  func setStatus(_ status: String) {
    controller.setStatus(status)
  }

  func setSTTLabel(_ label: String) {
    controller.setSTTLabel(label)
  }

  func hide() {
    controller.hide()
  }

  var phase: OverlayPhase? {
    controller.testState?.phase
  }

  var status: String? {
    controller.testState?.status
  }

  /// The timer is visible only in Recording. `recordingStart` can outlive the
  /// phase as an internal timestamp, so the fixture observation must follow
  /// the rendered contract: phase == Recording with a start date.
  var recordingStarted: Bool {
    guard let state = controller.testState else { return false }
    return state.phase == .recording && state.recordingStart != nil
  }
}

func hudPhaseName(_ phase: OverlayPhase?) -> String {
  switch phase {
  case .some(.idle): return "idle"
  case .some(.starting): return "starting"
  case .some(.recording): return "recording"
  case .some(.processing): return "processing"
  case .none: return "missing"
  }
}

func hudStatusText(
  for checkpoint: HUDContractFixture.PresentationScenario.Checkpoint
) -> String? {
  guard let key = checkpoint.statusKey else { return nil }
  let base = L10n.tr(key)
  guard let argumentKey = checkpoint.statusArgumentKey else { return base }
  return base.replacingOccurrences(of: "{message}", with: L10n.tr(argumentKey))
}
