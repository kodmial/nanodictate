import Foundation

// MARK: - Chunked final-pass policy
//
// The chunked path transcribes VAD segments incrementally and historically
// re-uploaded the complete recording for a final coherence pass. That final
// request nearly doubles uploaded speech bytes and adds a full extra STT
// round trip even when segment results are already good. This policy makes
// the final full-recording pass explicit and conditional.
//
// Policies:
// - always: historical behavior, final pass runs whenever more than one
//   segment was recognized (single-segment recordings still skip it: the
//   single request already covered the whole recording).
// - onUncertainty (default): skip the full re-upload when every segment
//   looks acceptable; run it only when segment results signal that
//   reconciliation is needed.
// - never: never re-upload the complete recording after successful segments.
//   A thrown segment error (offline path aborts) or a failed live segment
//   still recovers via the full pass: "never" skips reconciliation, not
//   error recovery.
//
// Uncertainty signals (recorded per segment, no extra STT metadata needed):
// - empty segment text after finalization: the provider returned nothing
//   useful for voiced audio;
// - missing word timestamps on a segment with glued overlap: the seam
//   duplicate cannot be verified by timestamps, so only the full-pass word
//   diff can clean the boundary.
//
// Interaction with true streaming: a streaming provider delivers the final
// transcript incrementally with server-side context, so this client-side
// final replay is normally unnecessary there. The chunked policy exists for
// the batch request-per-segment path; streaming should prefer `never` (or
// no replay at all) and rely on the stream's own final hypothesis.

/// When the chunked pipeline re-uploads the complete recording for a final pass.
public enum ChunkedFinalPassPolicy: String, Equatable, CaseIterable, Codable {
  /// Historical behavior: final pass whenever more than one segment ran.
  case always
  /// Skip the final pass when all segments look acceptable (default).
  case onUncertainty
  /// Never re-upload the complete recording after successful segments.
  case never

  /// Canonical config spelling: `chunked_final_pass = "on-uncertainty"`.
  public var configValue: String {
    switch self {
    case .always: return "always"
    case .onUncertainty: return "on-uncertainty"
    case .never: return "never"
    }
  }

  /// Default from benchmark evidence: confident segments with timestamps
  /// stitch to WER 0 without the final pass, saving the full-recording
  /// upload; uncertain segments still fall back to the full pass.
  public static var `default`: ChunkedFinalPassPolicy { .onUncertainty }

  /// Tolerant config parsing: hyphen/underscore/case variants plus "auto"
  /// as an alias for the default. Unknown values return nil (caller keeps
  /// the current value or reports an invalid value).
  public init?(configString raw: String) {
    let normalized =
      raw.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
      .replacingOccurrences(of: "_", with: "-")
    switch normalized {
    case "always": self = .always
    case "on-uncertainty", "onuncertainty", "auto", "uncertainty":
      self = .onUncertainty
    case "never", "off", "none": self = .never
    default: return nil
    }
  }
}

/// Why the pipeline did or did not run the final full-recording pass.
public enum ChunkedFinalReason: String, Equatable, Codable {
  /// No segments: empty recording, transcribing silence is pointless.
  case emptyRecording
  /// One segment already covered the whole recording.
  case singleSegment
  /// Policy `always` requested the final pass.
  case policyAlways
  /// Policy `never` skipped the final pass (segments succeeded).
  case policyNever
  /// All segments looked acceptable, final pass skipped.
  case confidentSkip
  /// A segment returned empty text after finalization.
  case uncertainEmptySegment
  /// A segment with glued overlap had no word timestamps to verify the seam.
  case uncertainMissingTimestamps
}

/// Per-segment quality signal used to decide whether reconciliation is needed.
public struct ChunkedSegmentReport: Equatable, Codable {
  public var index: Int
  /// Finalized segment text was empty (nothing useful recognized).
  public var isEmpty: Bool
  /// Provider returned word timestamps for this segment.
  public var hasTimestamps: Bool
  /// Actually glued overlap for this segment, seconds (0 for the first).
  public var overlapSeconds: TimeInterval

  public init(index: Int, isEmpty: Bool, hasTimestamps: Bool, overlapSeconds: TimeInterval) {
    self.index = index
    self.isEmpty = isEmpty
    self.hasTimestamps = hasTimestamps
    self.overlapSeconds = overlapSeconds
  }

  /// True when this segment alone justifies a reconciling final pass:
  /// empty text, or an unverifiable seam (overlap without timestamps).
  public var isUncertain: Bool {
    if isEmpty { return true }
    if overlapSeconds > 0, !hasTimestamps { return true }
    return false
  }

  /// Reason the final pass would run because of this segment.
  public var uncertainReason: ChunkedFinalReason? {
    if isEmpty { return .uncertainEmptySegment }
    if overlapSeconds > 0, !hasTimestamps { return .uncertainMissingTimestamps }
    return nil
  }
}

public enum ChunkedFinalDecision {
  /// Decide whether the final full-recording pass should run.
  /// - single-segment and empty recordings never run it (also under `always`:
  ///   the single request already covered the whole recording).
  /// - `always` runs it for every multi-segment recording.
  /// - `never` skips it for successful segments (error recovery is decided
  ///   by the caller, not here).
  /// - `onUncertainty` runs it only when at least one segment is uncertain.
  public static func shouldRunFinalPass(
    segmentCount: Int,
    reports: [ChunkedSegmentReport],
    policy: ChunkedFinalPassPolicy
  ) -> (run: Bool, reason: ChunkedFinalReason, uncertainIndices: [Int]) {
    guard segmentCount > 0 else {
      return (false, .emptyRecording, [])
    }
    guard segmentCount > 1 else {
      return (false, .singleSegment, [])
    }
    switch policy {
    case .always:
      let uncertain = reports.filter(\.isUncertain).map(\.index)
      return (true, .policyAlways, uncertain)
    case .never:
      return (false, .policyNever, reports.filter(\.isUncertain).map(\.index))
    case .onUncertainty:
      let uncertain = reports.filter(\.isUncertain)
      guard let first = uncertain.first, let reason = first.uncertainReason else {
        return (false, .confidentSkip, [])
      }
      return (true, reason, uncertain.map(\.index))
    }
  }
}
