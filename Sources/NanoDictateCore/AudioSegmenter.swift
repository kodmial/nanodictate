import Foundation

// MARK: - VAD segmentation (stepwise dictation)

// Pure audio split by voice pauses with adaptive speech detection (issue #21).
// No I/O: works on RMS timeline or Int16 PCM samples.
// Params: pause >= 0.8-1.5 s (default 1.0) — boundary; minSegment ~3 s
// (tiny clips not cut); maxSegment 45 s (hard cap); overlap 1 s — last
// second of PREVIOUS SPEECH BODY glued to next segment start (not pause
// silence: pause longer than overlap drops out of both segments entirely)
// so boundary words get context.

public struct AudioSegmenterConfig: Equatable {
  /// Continuous pause length after which we cut.
  public var pauseDuration: TimeInterval
  /// Minimum segment length; shorter not cut (none — segment longer).
  public var minSegment: TimeInterval
  /// Hard max segment length; cut always on reaching it.
  public var maxSegment: TimeInterval
  /// Previous segment tail glued to next start.
  public var overlap: TimeInterval
  /// Legacy fixed RMS "silence" threshold (linear 0...1). Kept for config
  /// compatibility; adaptive detection (issue #21) drives decisions by
  /// default — see `useAdaptiveVAD`. Set `useAdaptiveVAD = false` to restore
  /// the old fixed-threshold behavior.
  public var silenceRMS: Float
  /// Adaptive speech detection on/off. Default true: noise-floor estimate
  /// from the timeline plus hysteresis replaces the single fixed threshold,
  /// so quiet speech below the old -50 dBFS boundary still counts as speech
  /// while steady noise above it does not latch as speech.
  public var useAdaptiveVAD: Bool
  /// Adaptive margins/clamps (enter above floor, hysteresis, absolute bounds).
  public var vadConfig: AdaptiveVADConfig

  public init(
    pauseDuration: TimeInterval = 1.0,
    minSegment: TimeInterval = 3.0,
    maxSegment: TimeInterval = 45.0,
    overlap: TimeInterval = 1.0,
    silenceRMS: Float = AudioMetrics.nearSilenceThreshold,
    useAdaptiveVAD: Bool = true,
    vadConfig: AdaptiveVADConfig = .defaults
  ) {
    self.pauseDuration = pauseDuration
    self.minSegment = minSegment
    self.maxSegment = maxSegment
    self.overlap = overlap
    self.silenceRMS = silenceRMS
    self.useAdaptiveVAD = useAdaptiveVAD
    self.vadConfig = vadConfig
  }

  public static let defaults = AudioSegmenterConfig()
}

/// One recognized chunk: segment body plus glued overlap.
public struct AudioSegment: Equatable {
  /// Body start (no overlap) from recording start, seconds.
  public let start: TimeInterval
  /// Body end (no overlap) from recording start, seconds.
  public let end: TimeInterval
  /// PCM samples: body + last `overlap` seconds of previous body (or whole
  /// previous if shorter). First segment — no overlap.
  public let samples: [Int16]
  /// ACTUALLY glued overlap of previous body, seconds. Always 0 for first;
  /// later — `min(configured overlap, previous body length)` in samples →
  /// seconds. dedupeOverlap cuts duplicates EXACTLY by this (not by
  /// `config.overlap`, which exceeds real glued tail when previous segment short).
  public let overlapSeconds: TimeInterval

  public init(
    start: TimeInterval, end: TimeInterval, samples: [Int16], overlapSeconds: TimeInterval = 0
  ) {
    self.start = start
    self.end = end
    self.samples = samples
    self.overlapSeconds = overlapSeconds
  }
}

/// Range-based segment metadata: references the original bounded recording
/// buffer via sample ranges instead of owned PCM. The caller keeps the source
/// `[Int16]` alive for the plan lifetime; PCM is materialized on demand per
/// segment (overlap + body) only when bytes are needed for a request.
/// Mirrors `BatchBodySpec` naming (`bodyRange`/`overlapRange`) so the two
/// paths do not introduce competing buffer abstractions.
public struct AudioSegmentSpec: Equatable {
  /// 0-based segment index.
  public let index: Int
  /// Body start (no overlap) from recording start, seconds.
  public let start: TimeInterval
  /// Body end (no overlap) from recording start, seconds.
  public let end: TimeInterval
  /// Body sample range into the source buffer (0-based, end-exclusive).
  public let bodyRange: Range<Int>
  /// Overlap sample range (tail of previous body); nil for the first segment.
  public let overlapRange: Range<Int>?
  /// Actually glued overlap seconds (0 for first segment).
  public let overlapSeconds: TimeInterval

  public init(
    index: Int,
    start: TimeInterval,
    end: TimeInterval,
    bodyRange: Range<Int>,
    overlapRange: Range<Int>?,
    overlapSeconds: TimeInterval = 0
  ) {
    self.index = index
    self.start = start
    self.end = end
    self.bodyRange = bodyRange
    self.overlapRange = overlapRange
    self.overlapSeconds = overlapSeconds
  }

  /// Materialize PCM for this segment only: overlap tail + body.
  /// Bounds are clamped to `source.count`; out-of-range specs yield the
  /// intersecting part (empty when disjoint).
  public func samples(from source: [Int16]) -> [Int16] {
    let total = source.count
    let bodyLow = max(0, min(total, bodyRange.lowerBound))
    let bodyHigh = max(0, min(total, bodyRange.upperBound))
    guard bodyLow < bodyHigh else {
      if let overlap = overlapRange {
        let low = max(0, min(total, overlap.lowerBound))
        let high = max(0, min(total, overlap.upperBound))
        guard low < high else { return [] }
        return Array(source[low..<high])
      }
      return []
    }
    if let overlap = overlapRange {
      let low = max(0, min(total, overlap.lowerBound))
      let high = max(0, min(total, overlap.upperBound))
      if low < high {
        var out: [Int16] = []
        out.reserveCapacity((high - low) + (bodyHigh - bodyLow))
        out.append(contentsOf: source[low..<high])
        out.append(contentsOf: source[bodyLow..<bodyHigh])
        return out
      }
    }
    return Array(source[bodyLow..<bodyHigh])
  }
}

public enum AudioSegmenter {
  /// Sample-work window duration: 85 ms at 16 kHz = 1360 samples
  /// (like AudioService.rmsHistory RMS buffers).
  public static let defaultWindowDuration: TimeInterval = 0.085

  // MARK: - RMS timeline split

  /// Split RMS timeline (one value per window) into segment window ranges.
  ///
  /// Guarantees:
  /// - boundary only after continuous pause length >= `pauseDuration`;
  /// - segment shorter than `minSegment` not cut (glued to next);
  /// - `maxSegment` reached -> forced boundary (even mid-speech — hard cap);
  /// - junction silence enters no segment (cut at pause edges);
  /// - output segments cover recording with no gaps and no overlaps.
  ///
  /// Speech classification is adaptive by default (issue #21): the noise floor
  /// is estimated from the timeline (low percentile, capped) and hysteresis
  /// (enter above floor, exit below enter) replaces the single fixed
  /// threshold. Set `config.useAdaptiveVAD = false` for legacy fixed behavior.
  static func splitRanges(
    rms: [Float],
    windowDuration: TimeInterval,
    config: AudioSegmenterConfig = .defaults
  ) -> [Range<Int>] {
    guard !rms.isEmpty else { return [] }
    let pauseWindows = max(1, Int(round(config.pauseDuration / windowDuration)))
    let (enter, exit) = thresholds(rms: rms, config: config)

    var segments: [Range<Int>] = []
    var segStart = 0
    var silenceStart: Int?
    // Hysteresis state: inSpeech starts false; enter needs >= enter, exit
    // needs < exit. Between thresholds state holds (no chatter).
    var inSpeech = false
    // Per-segment speech presence from the hysteresis classifier. Forced-cut
    // and trailing decisions use this state so voiceless timelines never emit
    // a segment merely because a sample crossed the lower exit threshold.
    var hasSpeechInSegment = false

    func isSpeech(_ value: Float) -> Bool {
      if inSpeech {
        if value < exit { inSpeech = false }
      } else {
        if value >= enter { inSpeech = true }
      }
      return inSpeech
    }

    for i in 0..<rms.count {
      let speech = isSpeech(rms[i])
      if speech {
        hasSpeechInSegment = true
      }

      // Hard cap: cut on reaching max length.
      let segmentDuration = TimeInterval(i - segStart + 1) * windowDuration
      if segmentDuration >= config.maxSegment {
        appendSegmentIfHasSpeech(
          range: segStart..<(i + 1), hasSpeech: hasSpeechInSegment, to: &segments)
        segStart = i + 1
        silenceStart = nil
        hasSpeechInSegment = false
        continue
      }

      if !speech {
        if silenceStart == nil {
          silenceStart = i
        }
        continue
      }

      if let pauseStart = silenceStart {
        silenceStart = nil
        let sustained = (i - pauseStart) >= pauseWindows
        guard sustained else { continue }
        // Pause edge closes previous segment; pause itself unowned.
        let boundary = pauseStart - 1
        guard boundary >= segStart else { continue }
        let duration = TimeInterval(boundary - segStart + 1) * windowDuration
        guard duration >= config.minSegment else { continue }
        segments.append(segStart..<(boundary + 1))
        segStart = i
        // New segment starts on the current speech sample.
        hasSpeechInSegment = true
      }
    }
    appendTrailingSegment(
      rms: rms, segStart: segStart, windowDuration: windowDuration, config: config,
      hasSpeech: hasSpeechInSegment, to: &segments)
    return segments
  }

  /// Adaptive thresholds (enter/exit) from the RMS timeline, or legacy fixed
  /// pair when `useAdaptiveVAD` is false. Deterministic, no I/O.
  static func thresholds(
    rms: [Float],
    config: AudioSegmenterConfig
  ) -> (enter: Float, exit: Float) {
    guard config.useAdaptiveVAD else {
      return (config.silenceRMS, config.silenceRMS)
    }
    // Noise floor: low percentile of the timeline (robust to speech outliers),
    // capped so all-loud timelines still read as speech and very quiet
    // timelines stay sensitive. Absolute clamp keeps digital zeros sane.
    let sorted = rms.sorted()
    let idx = min(sorted.count - 1, Int(Double(sorted.count) * 0.2))
    let low = sorted.isEmpty ? config.silenceRMS : sorted[max(0, idx)]
    let floor = min(max(low, 0.0001), 0.01)
    let floorDb = AudioMetrics.dbfs(floor)
    var enterDb = floorDb + config.vadConfig.enterMarginDb
    enterDb = min(max(enterDb, config.vadConfig.minEnterDb), config.vadConfig.maxEnterDb)
    let exitDb = enterDb - config.vadConfig.hysteresisDb
    let enter = min(max(powf(10, enterDb / 20), 0.00001), 1)
    let exit = min(max(powf(10, exitDb / 20), 0.00001), 1)
    return (enter, exit)
  }

  /// Append range to segments only if it has speech (not silence).
  private static func appendSegmentIfHasSpeech(
    range: Range<Int>,
    hasSpeech: Bool,
    to segments: inout [Range<Int>]
  ) {
    if hasSpeech {
      segments.append(range)
    }
  }

  /// Handle recording tail after last boundary: fully silent tail (and whole
  /// voiceless recording) not added — silence would make "empty" segment and
  /// extra STT request. Tail shorter than minSegment glued to previous segment,
  /// if combined length ≤ maxSegment.
  private static func appendTrailingSegment(
    rms: [Float],
    segStart: Int,
    windowDuration: TimeInterval,
    config: AudioSegmenterConfig,
    hasSpeech: Bool,
    to segments: inout [Range<Int>]
  ) {
    guard segStart < rms.count, hasSpeech else {
      return
    }
    let trail = segStart..<rms.count
    let trailSeconds = TimeInterval(trail.count) * windowDuration
    if trailSeconds < config.minSegment,
      let last = segments.last,
      TimeInterval(rms.count - last.lowerBound) * windowDuration <= config.maxSegment
    {  // swiftlint:disable:this opening_brace
      segments[segments.count - 1] = last.lowerBound..<rms.count
    } else {
      segments.append(trail)
    }
  }

  // MARK: - Single-pass segmentation (range-based)

  /// RMS timeline over PCM without per-window Array copies: windows are
  /// scanned in place via the source buffer. Single pass, no PCM retained.
  public static func rmsTimeline(
    samples: [Int16],
    sampleRate: Int = 16000
  ) -> [Float] {
    let windowSize = max(1, Int((defaultWindowDuration * Double(sampleRate)).rounded()))
    guard !samples.isEmpty else { return [] }
    let windowCount = (samples.count + windowSize - 1) / windowSize
    var rms: [Float] = []
    rms.reserveCapacity(windowCount)
    samples.withUnsafeBufferPointer { buffer in
      guard let base = buffer.baseAddress else { return }
      var cursor = 0
      while cursor < buffer.count {
        let length = min(windowSize, buffer.count - cursor)
        let window = UnsafeBufferPointer(start: base.advanced(by: cursor), count: length)
        rms.append(AudioMetrics.rms(buffer: window))
        cursor += windowSize
      }
    }
    return rms
  }

  /// Compute segmentation once per recording for a given policy.
  /// Returns lightweight specs referencing the source buffer; PCM is NOT
  /// copied here. Materialize per segment via `AudioSegmentSpec.samples(from:)`
  /// or `WAVEncoder.encodeSegment` only when bytes are needed for a request.
  public static func plan(
    samples: [Int16],
    sampleRate: Int = 16000,
    config: AudioSegmenterConfig = .defaults
  ) -> [AudioSegmentSpec] {
    let windowSize = max(1, Int((defaultWindowDuration * Double(sampleRate)).rounded()))
    let rms = rmsTimeline(samples: samples, sampleRate: sampleRate)
    let ranges = splitRanges(rms: rms, windowDuration: defaultWindowDuration, config: config)
    guard !ranges.isEmpty else { return [] }

    let overlapCount = min(
      max(0, Int((config.overlap * Double(sampleRate)).rounded())),
      samples.count
    )

    var result: [AudioSegmentSpec] = []
    result.reserveCapacity(ranges.count)
    for (index, range) in ranges.enumerated() {
      let bodyStart = range.lowerBound * windowSize
      let bodyEnd = min(range.upperBound * windowSize, samples.count)
      var overlapRange: Range<Int>?
      var overlapSeconds: TimeInterval = 0
      if index > 0 {
        // Overlap taken from previous segment's BODY TAIL (speech),
        // not region near bodyStart (may be pause silence).
        let prevEnd = min(ranges[index - 1].upperBound * windowSize, samples.count)
        let overlapFrom = max(0, prevEnd - overlapCount)
        if overlapFrom < prevEnd {
          overlapRange = overlapFrom..<prevEnd
        }
        // Actually glued min(overlapCount, prevEnd) samples —
        // short previous body caps configured overlap.
        overlapSeconds = TimeInterval(prevEnd - overlapFrom) / Double(sampleRate)
      }
      result.append(
        AudioSegmentSpec(
          index: index,
          start: TimeInterval(bodyStart) / Double(sampleRate),
          end: TimeInterval(bodyEnd) / Double(sampleRate),
          bodyRange: bodyStart..<bodyEnd,
          overlapRange: overlapRange,
          overlapSeconds: overlapSeconds
        ))
    }
    return result
  }

  /// STT request count for a computed plan: one request per segment plus one
  /// final whole-recording pass when more than one segment exists. A single
  /// segment (or empty plan) needs no final pass; empty plan needs no request
  /// at all. Use this on an already-computed plan — never rerun segmentation
  /// solely to estimate watchdog limits.
  public static func requestCount(for plan: [AudioSegmentSpec]) -> Int {
    switch plan.count {
    case 0:
      return 0
    case 1:
      return 1
    default:
      return plan.count + 1
    }
  }

  /// Watchdog request estimate preserving the legacy agent formula
  /// (`segments.count <= 1 ? 1 : count + 1`): an empty recording still arms a
  /// single-request timeout. Prefer `requestCount(for:)` for pipeline logic.
  public static func watchdogRequestCount(for plan: [AudioSegmentSpec]) -> Int {
    plan.count <= 1 ? 1 : plan.count + 1
  }

  // MARK: - Разбиение по сэмплам (legacy owned-PCM wrapper)

  /// Split Int16 PCM samples (16 kHz) into segments with overlap.
  /// Samples treated as continuous from recording start.
  /// Legacy owned-PCM wrapper over `plan(samples:)`: boundaries are computed
  /// once via the single-pass plan, then each segment materializes its own
  /// PCM. New code should use `plan` + on-demand materialization instead.
  public static func segments(
    samples: [Int16],
    sampleRate: Int = 16000,
    config: AudioSegmenterConfig = .defaults
  ) -> [AudioSegment] {
    let specs = plan(samples: samples, sampleRate: sampleRate, config: config)
    return specs.map { spec in
      AudioSegment(
        start: spec.start,
        end: spec.end,
        samples: spec.samples(from: samples),
        overlapSeconds: spec.overlapSeconds
      )
    }
  }
}
