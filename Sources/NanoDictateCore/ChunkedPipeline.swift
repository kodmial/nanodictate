import Foundation

// MARK: - Пошаговая (чанковая) диктовка

//
// Progressive dictation: VAD-segment → transcribe each (prompt = prior text)
// → incremental insert → final pass over WHOLE WAV (one request) → word diff
// → replace changed range (single undoable action).
//
// Pure pipeline: STT + insert injected via closures — tests use mocks, no
// network/CGEvent; agent passes real Transcriber/Inserter.

public struct ChunkedPipeline {
  // MARK: - Инъекции (моки в тестах)

  /// Transcribe WAV → text + word timestamps (if provider returned).
  /// `prompt` — prior segments context; `filename` — debug only.
  public typealias STTHandler = (_ wav: Data, _ filename: String, _ prompt: String?) async throws ->
    SttResult
  /// One keyboard action over active app.
  public typealias InsertHandler = (Operation) -> Void
  /// Pipeline phase for overlay ("Recognizing… (part N)", "Finalizing…").
  public typealias PhaseHandler = (Phase) -> Void

  /// Segment transcription result: text + timestamps (empty = text only,
  /// provider gave no timestamps).
  public struct SttResult: Equatable {
    public let text: String
    public let words: [TimedWord]

    public init(text: String, words: [TimedWord] = []) {
      self.text = text
      self.words = words
    }
  }

  /// Current pipeline step (fired before it runs). Indices 0-based.
  public enum Phase: Equatable {
    case segment(Int)
    case finalizing
  }

  public enum Operation: Equatable {
    /// Insert recognized segment at end (incremental).
    case appendSegment(index: Int, text: String)
    /// Final pass: replace tail, single action (`old` under backspace,
    /// `new` typed).
    case replaceTail(old: String, new: String)
  }

  /// Run outcome: inserted text, final pass done, text changed?
  public struct Outcome: Equatable {
    public let segmentCount: Int
    /// Final text (chunks after diff).
    public let insertedText: String
    /// Final pass executed.
    public let finalized: Bool
    /// Final pass changed inserted text (diff not empty).
    public let finalChanged: Bool

    public init(segmentCount: Int, insertedText: String, finalized: Bool, finalChanged: Bool) {
      self.segmentCount = segmentCount
      self.insertedText = insertedText
      self.finalized = finalized
      self.finalChanged = finalChanged
    }
  }

  public let sampleRate: Int
  public let segmenterConfig: AudioSegmenterConfig

  public init(sampleRate: Int = 16000, segmenterConfig: AudioSegmenterConfig = .defaults) {
    self.sampleRate = sampleRate
    self.segmenterConfig = segmenterConfig
  }

  // MARK: - Хелперы

  /// STT prompt limited: OpenAI ~224 tokens (~600-700 Cyrillic chars). Cut
  /// FROM TAIL — recent segments matter (speech continuation). Trim first
  /// (cut) word to boundary — prompt must not start mid-word. ≤ maxLength.
  public static func truncatedPrompt(_ parts: [String], maxLength: Int = 600) -> String {
    guard !parts.isEmpty else { return "" }
    let joined = parts.joined(separator: " ")
    guard joined.count > maxLength else { return joined }
    let tail = String(joined.suffix(maxLength))
    // Cut first word: drop it up to first space.
    if let firstSpace = tail.firstIndex(of: " ") {
      return String(tail[tail.index(after: firstSpace)...])
    }
    return tail
  }

  /// Overlap join: STT re-transcribes prior segment tail. Drop words ended
  /// inside overlap by timestamps (`end <= overlapSeconds`), cut tail by
  /// CHAR offset (raw slice — internal punctuation intact). No timestamps —
  /// text untouched: final word-diff pass cleans duplicates (corrupt/empty
  /// `words` does NOT break pipeline).
  public static func dedupeOverlap(text: String, words: [TimedWord], overlapSeconds: TimeInterval)
    -> String
  {  // swiftlint:disable:this opening_brace
    guard overlapSeconds > 0, !words.isEmpty else { return text }
    let overlapWordCount = words.prefix { $0.end <= overlapSeconds }.count
    guard overlapWordCount > 0 else { return text }
    let tail = WordDiff.tailAfterWords(overlapWordCount, in: text)
    return String(tail.drop { $0.isWhitespace })
  }

  // MARK: - Отдельные шаги конвейера (reuse live-диктовкой)

  /// Single segmentation entry for the legacy chunked path: computed once per
  /// recording for the pipeline policy. Returns range-based specs; PCM stays
  /// in the source buffer until per-segment encode.
  public func plan(samples: [Int16]) -> [AudioSegmentSpec] {
    AudioSegmenter.plan(samples: samples, sampleRate: sampleRate, config: segmenterConfig)
  }

  /// STT request count for an already-computed plan (segments + final pass).
  /// Never reruns segmentation to estimate limits.
  public static func requestCount(for plan: [AudioSegmentSpec]) -> Int {
    AudioSegmenter.requestCount(for: plan)
  }

  /// Recognize ONE speech segment from already-encoded WAV bytes.
  /// Shared core for slice and pre-materialized callers; overlap dedup and
  /// separator semantics are identical.
  public static func recognizeWAV(
    _ bytes: Data,
    index: Int,
    insertedText: String,
    prompt: String?,
    stt: STTHandler,
    filename: String = "segment.wav",
    overlap: TimeInterval = 0
  ) async throws -> (insertText: String, promptText: String) {
    let result = try await stt(bytes, filename, prompt)
    // Segment head (i>0): AudioSegmenter glues overlap — prior segment
    // tail. STT may duplicate seam word: drop overlap words by timestamps;
    // no timestamps — leave as is, final pass cleans.
    let raw = Self.dedupeOverlap(text: result.text, words: result.words, overlapSeconds: overlap)
    let text = TextRefinement.finalize(raw)
    var insertText = text
    // F2: space between segments, else adjacent chunk words merge. Empty or
    // whitespace-only final text inserts NO stray space (finalize already
    // trimmed; live path handleLiveSegment consumes insertText as is).
    if index > 0, !insertedText.isEmpty, !insertedText.hasSuffix(" "), !text.isEmpty {
      insertText = " " + text
    }
    return (insertText, text)
  }

  /// Recognize ONE speech segment: WAV → STT (prompt = prior context) →
  /// finalize. Returns text FOR INSERT (space-prefixed for i>0) and clean
  /// text for prompt accumulation. Legacy owned-PCM entry; the pipeline run
  /// path encodes directly from source ranges via `recognizeWAV`.
  public static func recognizeSegment(
    samples: [Int16],
    index: Int,
    sampleRate: Int = 16000,
    insertedText: String,
    prompt: String?,
    stt: STTHandler,
    filename: String = "segment.wav",
    overlap: TimeInterval = 0
  ) async throws -> (insertText: String, promptText: String) {
    let bytes = WAVEncoder.encode(samples: samples, sampleRate: sampleRate)
    return try await recognizeWAV(
      bytes,
      index: index,
      insertedText: insertedText,
      prompt: prompt,
      stt: stt,
      filename: filename,
      overlap: overlap
    )
  }

  /// Final pass over WHOLE WAV: one STT request (no prompt), word diff with
  /// inserted → replace changed range in ONE action. `changed == false` —
  /// final text equals inserted, no edit.
  public static func finalize(
    samples: [Int16],
    sampleRate: Int = 16000,
    insertedText: String,
    stt: STTHandler,
    insert: InsertHandler,
    onFinalizing: (() -> Void)? = nil
  ) async throws -> (finalText: String, changed: Bool) {
    onFinalizing?()
    let finalWAV = WAVEncoder.encode(samples: samples, sampleRate: sampleRate)
    let finalResult = try await stt(finalWAV, "final.wav", nil)
    let finalText = TextRefinement.finalize(finalResult.text)

    guard let change = WordDiff.change(old: insertedText, new: finalText) else {
      return (finalText, false)
    }
    insert(.replaceTail(old: change.tailOld, new: change.tailNew))
    return (finalText, true)
  }

  // MARK: - Прогон (single-pass, lazy materialization)

  /// Run with segmentation computed once inside: single RMS scan via
  /// `AudioSegmenter.plan`, then per-segment WAV encode straight from the
  /// source buffer. Only the segment being sent is materialized.
  public func run(
    samples: [Int16],
    stt: STTHandler,
    insert: InsertHandler,
    onPhase: PhaseHandler? = nil
  ) async throws -> Outcome {
    let specs = AudioSegmenter.plan(
      samples: samples, sampleRate: sampleRate, config: segmenterConfig
    )
    return try await run(
      samples: samples, plannedSegments: specs, stt: stt, insert: insert, onPhase: onPhase)
  }

  /// Run with a precomputed plan (e.g. already built for watchdog limits):
  /// segmentation is NOT rerun. Specs must come from the same `samples` and
  /// policy; ordering and overlap semantics are identical to `run(samples:)`.
  public func run(
    samples: [Int16],
    plannedSegments: [AudioSegmentSpec],
    stt: STTHandler,
    insert: InsertHandler,
    onPhase: PhaseHandler? = nil
  ) async throws -> Outcome {
    let segments = plannedSegments

    // Empty recording (no segments) — empty insert, no final pass:
    // transcribing silence pointless and costly.
    guard !segments.isEmpty else {
      return Outcome(segmentCount: 0, insertedText: "", finalized: false, finalChanged: false)
    }

    var insertedText = ""
    var promptParts: [String] = []

    for spec in segments {
      let index = spec.index
      onPhase?(.segment(index))
      // Materialize/encode only the segment being sent: overlap tail + body
      // straight from the source buffer, no retained per-segment PCM arrays.
      let bytes = WAVEncoder.encodeSegment(
        source: samples,
        bodyRange: spec.bodyRange,
        overlapRange: spec.overlapRange,
        sampleRate: sampleRate
      )
      let result = try await Self.recognizeWAV(
        bytes,
        index: index,
        insertedText: insertedText,
        prompt: promptParts.isEmpty ? nil : Self.truncatedPrompt(promptParts),
        stt: stt,
        filename: "segment-\(index + 1).wav",
        // ACTUAL glued overlap (min(config.overlap, prior segment body)),
        // not config: overlap > minSegment would cut new segment words.
        overlap: spec.overlapSeconds
      )
      insert(.appendSegment(index: index, text: result.insertText))
      insertedText += result.insertText
      // Prompt gets clean text, no leading space.
      promptParts.append(result.promptText)
    }

    // Single segment = whole recording: final pass pointless, double
    // request only costs.
    guard segments.count > 1 else {
      return Outcome(
        segmentCount: 1, insertedText: insertedText, finalized: false, finalChanged: false)
    }

    // Final pass: whole WAV one request (full context), word diff → replace
    // tail in ONE action (backspace + type).
    let result = try await Self.finalize(
      samples: samples,
      sampleRate: sampleRate,
      insertedText: insertedText,
      stt: stt,
      insert: insert
    ) { onPhase?(.finalizing) }
    guard result.changed else {
      // Final text matches inserted — nothing to touch.
      return Outcome(
        segmentCount: segments.count,
        insertedText: insertedText,
        finalized: true,
        finalChanged: false)
    }
    return Outcome(
      segmentCount: segments.count,
      insertedText: result.finalText,
      finalized: true,
      finalChanged: true
    )
  }
}
