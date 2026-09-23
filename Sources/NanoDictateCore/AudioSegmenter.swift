import Foundation

// MARK: - VAD-сегментация записи (пошаговая диктовка)

//
// Pure audio split by voice pauses (RMS threshold, as in
// AudioMetrics.nearSilenceThreshold). No I/O: works on RMS timeline
// (AudioService.rmsHistory representation) or Int16 PCM samples.
// Params: pause ≥ 0.8–1.5 s (default 1.0) — boundary; minSegment ~3 s
// (tiny clips not cut); maxSegment 45 s (hard cap); overlap 1 s — last
// second of PREVIOUS SPEECH BODY glued to next segment start (not pause
// silence: pause longer than overlap drops out of both segments entirely)
// so boundary words get context.

public struct AudioSegmenterConfig: Equatable {
  /// Continuous pause length (RMS below threshold) after which we cut.
  public var pauseDuration: TimeInterval
  /// Minimum segment length; shorter not cut (none — segment longer).
  public var minSegment: TimeInterval
  /// Hard max segment length; cut always on reaching it.
  public var maxSegment: TimeInterval
  /// Previous segment tail glued to next start.
  public var overlap: TimeInterval
  /// RMS "silence" threshold (linear 0...1) — reuse AudioMetrics.
  public var silenceRMS: Float

  public init(
    pauseDuration: TimeInterval = 1.0,
    minSegment: TimeInterval = 3.0,
    maxSegment: TimeInterval = 45.0,
    overlap: TimeInterval = 1.0,
    silenceRMS: Float = AudioMetrics.nearSilenceThreshold
  ) {
    self.pauseDuration = pauseDuration
    self.minSegment = minSegment
    self.maxSegment = maxSegment
    self.overlap = overlap
    self.silenceRMS = silenceRMS
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

public enum AudioSegmenter {
  /// Sample-work window duration: 85 ms at 16 kHz = 1360 samples
  /// (like AudioService.rmsHistory RMS buffers).
  public static let defaultWindowDuration: TimeInterval = 0.085

  // MARK: - Разбиение по RMS-таймлайну

  /// Split RMS timeline (one value per window) into segment window ranges.
  ///
  /// Guarantees:
  /// - boundary only after continuous pause length ≥ `pauseDuration`;
  /// - segment shorter than `minSegment` not cut (glued to next);
  /// - `maxSegment` reached → forced boundary (even mid-speech — hard cap);
  /// - junction silence enters no segment (cut at pause edges);
  /// - output segments cover recording with no gaps and no overlaps.
  static func splitRanges(
    rms: [Float],
    windowDuration: TimeInterval,
    config: AudioSegmenterConfig = .defaults
  ) -> [Range<Int>] {
    guard !rms.isEmpty else { return [] }
    let pauseWindows = max(1, Int(round(config.pauseDuration / windowDuration)))

    var segments: [Range<Int>] = []
    var segStart = 0
    var silenceStart: Int?

    for i in 0..<rms.count {
      // Hard cap: cut on reaching max length.
      let segmentDuration = TimeInterval(i - segStart + 1) * windowDuration
      if segmentDuration >= config.maxSegment {
        appendSegmentIfHasSpeech(
          rms: rms, range: segStart..<(i + 1), threshold: config.silenceRMS, to: &segments)
        segStart = i + 1
        silenceStart = nil
        continue
      }

      if rms[i] < config.silenceRMS {
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
      }
    }
    appendTrailingSegment(
      rms: rms, segStart: segStart, windowDuration: windowDuration, config: config, to: &segments)
    return segments
  }

  /// Append range to segments only if it has speech (not silence).
  private static func appendSegmentIfHasSpeech(
    rms: [Float],
    range: Range<Int>,
    threshold: Float,
    to segments: inout [Range<Int>]
  ) {
    if (rms[range].max() ?? 0) >= threshold {
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
    to segments: inout [Range<Int>]
  ) {
    guard segStart < rms.count, (rms[segStart..<rms.count].max() ?? 0) >= config.silenceRMS else {
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

  // MARK: - Разбиение по сэмплам

  /// Split Int16 PCM samples (16 kHz) into segments with overlap.
  /// Samples treated as continuous from recording start.
  public static func segments(
    samples: [Int16],
    sampleRate: Int = 16000,
    config: AudioSegmenterConfig = .defaults
  ) -> [AudioSegment] {
    let windowSize = max(1, Int((defaultWindowDuration * Double(sampleRate)).rounded()))
    var rms: [Float] = []
    var cursor = 0
    while cursor < samples.count {
      let chunk = Array(samples[cursor..<min(cursor + windowSize, samples.count)])
      rms.append(AudioMetrics.rms(samples: chunk))
      cursor += windowSize
    }
    let ranges = splitRanges(rms: rms, windowDuration: defaultWindowDuration, config: config)
    guard !ranges.isEmpty else { return [] }

    let overlapCount = min(
      max(0, Int((config.overlap * Double(sampleRate)).rounded())),
      samples.count
    )

    var result: [AudioSegment] = []
    for (index, range) in ranges.enumerated() {
      let bodyStart = range.lowerBound * windowSize
      let bodyEnd = min(range.upperBound * windowSize, samples.count)
      let body = Array(samples[bodyStart..<bodyEnd])

      var segSamples = body
      var overlapSeconds: TimeInterval = 0
      if index > 0 {
        // Overlap taken from previous segment's BODY TAIL (speech),
        // not region near bodyStart (may be pause silence).
        let prevEnd = min(ranges[index - 1].upperBound * windowSize, samples.count)
        let overlapFrom = max(0, prevEnd - overlapCount)
        segSamples = Array(samples[overlapFrom..<prevEnd]) + body
        // Actually glued min(overlapCount, prevEnd) samples —
        // short previous body caps configured overlap.
        overlapSeconds = TimeInterval(prevEnd - overlapFrom) / Double(sampleRate)
      }

      result.append(
        AudioSegment(
          start: TimeInterval(bodyStart) / Double(sampleRate),
          end: TimeInterval(bodyEnd) / Double(sampleRate),
          samples: segSamples,
          overlapSeconds: overlapSeconds
        ))
    }
    return result
  }
}
