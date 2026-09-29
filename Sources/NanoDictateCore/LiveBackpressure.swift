import Foundation

// MARK: - Backpressure and coalescing for the non-streaming live path
//
// Non-streaming providers transcribe live speech segments serially. When
// segment production outruns STT completion the pending queue grows and the
// user waits long after stopping. The 60-second recording cap bounds memory
// but not tail latency.
//
// This file makes the live path explicitly backpressured:
// - queued audio duration/age and active request state are tracked,
// - the pending queue is bounded by policy,
// - adjacent not-yet-sent segments are coalesced into fewer requests when STT
//   falls behind, without dropping voiced samples,
// - ordering and transcript context (prompt chaining) are preserved,
// - cancellation is deterministic and leaves no orphan work or blocked worker.
//
// The scheduler is an actor (structured concurrency). It never blocks a GCD
// worker on a semaphore.

/// Bounded queue policy for the non-streaming live path.
///
/// The bound limits outstanding *requests*, not voiced audio: when the bound
/// is exceeded, pending segments are merged (concatenated), never dropped.
/// Queued audio itself stays bounded by the 60-second recording cap upstream.
public struct LiveBackpressurePolicy: Equatable {
    /// Maximum pending (not-yet-started) batches before coalescing kicks in.
    /// The in-flight request is not counted.
    public var maxPendingBatches: Int
    /// Maximum queued (pending, not in-flight) audio duration before
    /// coalescing kicks in.
    public var maxQueuedSeconds: Double
    /// Sample rate used for duration accounting.
    public var sampleRate: Int

    public init(maxPendingBatches: Int = 2, maxQueuedSeconds: Double = 9.0, sampleRate: Int = 16000) {
        self.maxPendingBatches = maxPendingBatches
        self.maxQueuedSeconds = maxQueuedSeconds
        self.sampleRate = sampleRate
    }

    /// Maximum queued samples derived from `maxQueuedSeconds`.
    public var maxQueuedSamples: Int {
        max(1, Int((maxQueuedSeconds * Double(sampleRate)).rounded()))
    }

    /// Default policy: at most 2 pending batches / 9 seconds of queued audio.
    /// With ~3 s live chunks this means coalescing starts once STT lags by
    /// roughly three chunks; steady state is at most one in-flight request
    /// plus one coalesced pending batch, so stop-to-final latency is bounded
    /// by ~2 STT calls instead of growing linearly with segment count.
    public static let `default` = LiveBackpressurePolicy()
}

/// One coalesced unit handed to STT: concatenation of one or more adjacent
/// live segments in delivery order.
public struct LiveSegmentBatch: Equatable {
    /// Concatenated PCM samples of all source segments, in order. Never empty.
    public var samples: [Int16]
    /// True when the last source segment was the stop tail.
    public var isTail: Bool
    /// How many delivered segments were merged into this batch.
    public var sourceSegmentCount: Int
    /// Enqueue time of the oldest source segment (for age accounting).
    public var enqueuedAt: Date

    public init(samples: [Int16], isTail: Bool, sourceSegmentCount: Int, enqueuedAt: Date) {
        self.samples = samples
        self.isTail = isTail
        self.sourceSegmentCount = sourceSegmentCount
        self.enqueuedAt = enqueuedAt
    }
}

/// Pure coalescing helper: merges adjacent pending batches into one while
/// preserving sample order and the tail flag. No samples are dropped.
public enum LiveSegmentCoalescer {
    /// Concatenates `batches` (must be non-empty, already in order) into a
    /// single batch. The result carries all samples, `isTail` of the last
    /// batch, the summed source count and the oldest enqueue time.
    public static func coalesce(_ batches: [LiveSegmentBatch]) -> LiveSegmentBatch {
        precondition(!batches.isEmpty, "coalesce requires at least one batch")
        if batches.count == 1 { return batches[0] }
        var samples: [Int16] = []
        samples.reserveCapacity(batches.reduce(0) { $0 + $1.samples.count })
        for batch in batches {
            samples.append(contentsOf: batch.samples)
        }
        return LiveSegmentBatch(
            samples: samples,
            isTail: batches.last!.isTail,
            sourceSegmentCount: batches.reduce(0) { $0 + $1.sourceSegmentCount },
            enqueuedAt: batches.map(\.enqueuedAt).min()!
        )
    }
}

/// Serial backpressured scheduler for non-streaming live STT.
///
/// Usage: producers call `enqueue(samples:isTail:)` from any context; a single
/// consumer pumps `dequeue()` / `markCompleted(...)` (or the convenience
/// `run(stt:insert:)`) strictly in order. While a request is in flight, newly
/// enqueued segments accumulate in `pending`; once the pending depth exceeds
/// the policy, all pending batches merge into one. Ordering is preserved
/// because batches only ever merge with their immediate neighbours and the
/// in-flight batch is never touched.
///
/// Transcript context is preserved by the consumer: each dequeued batch is
/// transcribed with the accumulated prompt, exactly like
/// `ChunkedPipeline.recognizeSegment` with a running index.
public actor LiveSegmentScheduler {
    /// Result of one transcribed batch, in dequeue order.
    public struct TranscribedBatch: Equatable {
        public let batch: LiveSegmentBatch
        /// Text prepared for insertion (leading-space rule applied).
        public let insertText: String
        /// Clean text appended to prompt context.
        public let promptText: String
        public let index: Int
    }

    private let policy: LiveBackpressurePolicy
    private var pending: [LiveSegmentBatch] = []
    private var inFlight = false
    private var cancelled = false

    // Transcript accumulation (prompt chaining), owned by the scheduler so a
    // coalesced batch still carries the full prior context in order.
    private var insertedText = ""
    private var promptParts: [String] = []
    private var nextIndex = 0

    // Accounting.
    private var enqueuedSegments = 0
    private var enqueuedSamples = 0
    private var startedRequests = 0
    private var coalescedBatches = 0
    private var completedRequests = 0

    public init(policy: LiveBackpressurePolicy = .default) {
        self.policy = policy
    }

    /// Queue a delivered live segment. Empty segments are ignored (VAD never
    /// delivers voiced audio as empty; keeping them would create pointless STT
    /// requests). When the pending depth exceeds the policy, all pending
    /// batches merge into one — no voiced samples are lost.
    public func enqueue(samples: [Int16], isTail: Bool) {
        guard !cancelled, !samples.isEmpty else { return }
        enqueuedSegments += 1
        enqueuedSamples += samples.count
        pending.append(LiveSegmentBatch(
            samples: samples,
            isTail: isTail,
            sourceSegmentCount: 1,
            enqueuedAt: Date()
        ))
        coalesceIfNeeded()
    }

    /// Number of pending (not-yet-started) batches.
    public var pendingBatchCount: Int { pending.count }

    /// Queued (pending) sample count.
    public var queuedSampleCount: Int { pending.reduce(0) { $0 + $1.samples.count } }

    /// Queued (pending) audio duration in seconds.
    public var queuedDuration: TimeInterval {
        Double(queuedSampleCount) / Double(policy.sampleRate)
    }

    /// Age of the oldest pending batch, or zero when empty.
    public var oldestQueuedAge: TimeInterval {
        guard let oldest = pending.map(\.enqueuedAt).min() else { return 0 }
        return max(0, Date().timeIntervalSince(oldest))
    }

    /// Whether an STT request is currently running.
    public var isBusy: Bool { inFlight }

    /// Total delivered segments accepted (excluding empties and post-cancel).
    public var totalEnqueuedSegments: Int { enqueuedSegments }

    /// Total delivered samples accepted.
    public var totalEnqueuedSamples: Int { enqueuedSamples }

    /// STT requests started.
    public var totalStartedRequests: Int { startedRequests }

    /// STT requests completed (success or failure).
    public var totalCompletedRequests: Int { completedRequests }

    /// How many batches were absorbed by coalescing.
    public var totalCoalescedBatches: Int { coalescedBatches }

    /// Accumulated inserted text (prompt/diff base), in order.
    public var currentInsertedText: String { insertedText }

    /// Number of batches transcribed so far (coalesced counts as one).
    public var transcribedBatchCount: Int { nextIndex }

    /// Take the next batch for transcription, marking the scheduler busy.
    /// Returns nil when empty, busy, or cancelled. The in-flight batch is
    /// never merged by later enqueues.
    public func dequeue() -> LiveSegmentBatch? {
        guard !cancelled, !inFlight, !pending.isEmpty else { return nil }
        inFlight = true
        startedRequests += 1
        return pending.removeFirst()
    }

    /// Report completion of the in-flight batch after a successful STT call.
    /// Accumulates prompt context in dequeue order.
    public func markCompleted(insertText: String, promptText: String) {
        guard inFlight else { return }
        inFlight = false
        completedRequests += 1
        insertedText += insertText
        promptParts.append(promptText)
        nextIndex += 1
    }

    /// Report completion of the in-flight batch after a failed STT call.
    /// Prompt context is untouched; ordering still advances deterministically.
    public func markFailed() {
        guard inFlight else { return }
        inFlight = false
        completedRequests += 1
        nextIndex += 1
    }

    /// Current prompt for the next STT call (nil when no context yet).
    public var currentPrompt: String? {
        promptParts.isEmpty ? nil : ChunkedPipeline.truncatedPrompt(promptParts)
    }

    /// Deterministic stop: drops all pending batches, clears the busy flag
    /// handling, and blocks future enqueue/dequeue. An in-flight STT call
    /// should be abandoned by the consumer via task cancellation; the
    /// scheduler itself holds no GCD worker and leaves no orphan work.
    public func cancel() {
        cancelled = true
        pending.removeAll()
        inFlight = false
    }

    /// Whether `cancel()` was called.
    public var isCancelled: Bool { cancelled }

    /// Serial pump: dequeues batches in order and transcribes each via
    /// `ChunkedPipeline.recognizeSegment` with running prompt context.
    /// `stt` may be deliberately slow in tests to simulate STT falling behind
    /// audio production. `insert` receives each batch text synchronously in
    /// order. Stops on cancellation or task cancellation; failures are
    /// reported through `onSegmentError` without breaking the order.
    /// Returns transcribed batches in order.
    @discardableResult
    public func run(
        stt: ChunkedPipeline.STTHandler,
        insert: ((TranscribedBatch) -> Void)? = nil,
        onSegmentError: ((LiveSegmentBatch, Error) -> Void)? = nil
    ) async -> [TranscribedBatch] {
        var out: [TranscribedBatch] = []
        while !cancelled, !Task.isCancelled {
            guard let batch = dequeue() else {
                // Idle and nothing pending: yield once. When producers only
                // call enqueue from other tasks, the actor mailbox wakes us;
                // a short sleep avoids a hot spin while still reacting fast.
                // The loop exits as soon as cancel() lands or the caller
                // cancels the pump task.
                if pending.isEmpty, !inFlight { break }
                try? await Task.sleep(nanoseconds: 5_000_000)
                continue
            }
            let index = nextIndex
            let prompt = currentPrompt
            do {
                let result = try await ChunkedPipeline.recognizeSegment(
                    samples: batch.samples,
                    index: index,
                    insertedText: insertedText,
                    prompt: prompt,
                    stt: stt,
                    filename: "live-segment-\(index + 1).wav"
                )
                markCompleted(insertText: result.insertText, promptText: result.promptText)
                let transcribed = TranscribedBatch(
                    batch: batch, insertText: result.insertText,
                    promptText: result.promptText, index: index
                )
                out.append(transcribed)
                insert?(transcribed)
            } catch {
                markFailed()
                onSegmentError?(batch, error)
            }
        }
        return out
    }

    // MARK: - Private

    private func coalesceIfNeeded() {
        let overCount = pending.count > policy.maxPendingBatches
        let overDuration = queuedSampleCount > policy.maxQueuedSamples
        guard overCount || overDuration, pending.count > 1 else { return }
        let absorbed = pending.count - 1
        pending = [LiveSegmentCoalescer.coalesce(pending)]
        coalescedBatches += absorbed
    }
}
