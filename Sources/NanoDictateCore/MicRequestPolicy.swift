import Foundation

// MARK: - Анти-штормовый сторож TCC-запросов микрофона

/// Anti-storm guard for microphone TCC requests.
///
/// Problem: bundle-less background agent — system dialog window may not show,
/// `requestAccess` callback never comes, each Alt+Alt opens a NEW access
/// request. Repeated dialogs jam tccd (permission center) and freeze the whole
/// machine. After N request timeouts in a 6h window, new access requests are
/// blocked — user gets "enable mic in System Settings" instruction instead.
///
/// State persistent (survives agent restart): file
/// `~/Library/Application Support/NanoDictate/mic-request-state.json`
/// (path injected via init — tests write into temp dir). Atomic writes;
/// corrupt/missing file treated as fresh state (request allowed). Never throws
/// outward: anti-storm is auxiliary, its failure must not break recording.
public struct MicRequestPolicy {
  /// Watchdog threshold: N timeouts in window.
  public static let maxTimeoutsInWindow = 3
  /// Window within which timeouts count: 6 hours in seconds.
  public static let windowDuration: TimeInterval = 6 * 3600

  /// State file URL; nil — memory only (persistence off).
  private let fileURL: URL?
  /// Request timeout moments. May be older than window — filtered on count
  /// (time-based reset), not trimmed until next save.
  private var timeoutTimestamps: [Date]

  public init(fileURL: URL?) {
    self.fileURL = fileURL
    timeoutTimestamps = []
    if let fileURL {
      timeoutTimestamps = Self.loadState(from: fileURL)
    }
  }

  /// Default state file: Application Support/NanoDictate.
  public static func defaultFileURL() -> URL {
    let base =
      FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("NanoDictate/mic-request-state.json", isDirectory: false)
  }

  /// Whether a NEW access request allowed: timeouts inside current window below
  /// threshold. Guard non-mutating: check changes nothing by itself.
  public func allowRequest(now: Date) -> Bool {
    timeouts(inWindow: now).count < Self.maxTimeoutsInWindow
  }

  /// Record request timeout (requestAccess callback never came): timeout added
  /// to window — after maxTimeoutsInWindow repeats access request blocked
  /// (see allowRequest). Stale timeouts trimmed, state persisted.
  public mutating func recordTimeout(now: Date) {
    timeoutTimestamps = timeouts(inWindow: now) + [now]
    persist()
  }

  /// Access granted — timeout counter reset: problem solved, storm no longer
  /// relevant. State persisted.
  public mutating func recordGranted(now _: Date) {
    timeoutTimestamps = []
    persist()
  }

  // MARK: - Private

  /// Timeouts still alive inside window (0 <= now - t < windowDuration).
  /// Negative age (system clock moved backward) is excluded — a future
  /// timestamp must not keep blocking requests beyond the window.
  private func timeouts(inWindow now: Date) -> [Date] {
    timeoutTimestamps.filter {
      let age = now.timeIntervalSince($0)
      return age >= 0 && age < Self.windowDuration
    }
  }

  /// Load state. Missing or corrupted file — fresh state (empty list):
  /// garbage in file must not break the guard.
  private static func loadState(from url: URL) -> [Date] {
    guard
      let data = try? Data(contentsOf: url),
      let state = try? JSONDecoder().decode(State.self, from: data)
    else {
      return []
    }
    return state.timeoutTimestamps.map { Date(timeIntervalSince1970: $0) }
  }

  /// Atomic persistence: dir created as needed, file written via `.atomic`
  /// (rename — reader sees either old or new state, never "half-write").
  /// Write failure does not break guard: counter stays in memory until next
  /// successful save.
  private func persist() {
    guard let fileURL else { return }
    do {
      let dir = fileURL.deletingLastPathComponent()
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let state = State(timeoutTimestamps: timeoutTimestamps.map(\.timeIntervalSince1970))
      let data = try JSONEncoder().encode(state)
      try data.write(to: fileURL, options: .atomic)
    } catch {
      Logger.log(
        "mic request policy: state persist failed: \(error.localizedDescription)", level: "error")
    }
  }

  /// State file format (JSON): timeout moments in epoch seconds.
  private struct State: Codable {
    var timeoutTimestamps: [Double]
  }
}
