import Foundation
@testable import NanoDictateCore

// MARK: - Backpressure and coalescing for the non-streaming live path
//
// Covers the issue acceptance criteria with an injectable (mock, optionally
// slow) transcriber:
// - faster-than-realtime: no coalescing, order and prompt context preserved,
// - slower-than-realtime: pending batch count bounded, request count drops,
//   no voiced samples lost, tail flag preserved,
// - cancellation: no orphan work, pending cleared, pump exits deterministically.

final class LiveBackpressureTests: XCTestCase {

    private func segment(_ value: Int16, count: Int) -> [Int16] {
        [Int16](repeating: value, count: count)
    }

    private func runAsync<T>(_ body: @escaping () async throws -> T) throws -> T {
        let box = ResultBox<T>()
        let expect = expectation(description: "runAsync")
        Task {
            do { box.value = try await body() }
            catch { box.error = error }
            expect.fulfill()
        }
        wait(for: [expect], timeout: 15.0)
        if let error = box.error { throw error }
        return box.value!
    }

    private final class ResultBox<T> {
        var value: T?
        var error: Error?
    }

    // MARK: - Faster than realtime: no coalescing, order preserved

    @objc func testFasterThanRealtime_NoCoalescing_OrderPreserved() throws {
        try runAsync {
            let scheduler = LiveSegmentScheduler(
                policy: LiveBackpressurePolicy(maxPendingBatches: 10, maxQueuedSeconds: 60.0))
            await scheduler.enqueue(samples: self.segment(1, count: 1600), isTail: false)
            await scheduler.enqueue(samples: self.segment(2, count: 1600), isTail: false)
            await scheduler.enqueue(samples: self.segment(3, count: 1600), isTail: false)
            let pending = await scheduler.pendingBatchCount
            XCTAssertEqual(pending, 3, "fast path must not coalesce below the bound")

            var seenPrompts: [String?] = []
            var inserted: [String] = []
            let stt: ChunkedPipeline.STTHandler = { _, _, prompt in
                seenPrompts.append(prompt)
                return ChunkedPipeline.SttResult(text: "word\(seenPrompts.count)")
            }
            let batches = await scheduler.run(stt: stt) { transcribed in
                inserted.append(transcribed.insertText)
            }
            XCTAssertEqual(batches.count, 3)
            XCTAssertEqual(inserted.count, 3)
            // Ordering: first batch has no prompt, later batches chain context
            // (TextRefinement.finalize capitalizes, so prompts carry "WordN.").
            XCTAssertNil(seenPrompts[0])
            XCTAssertTrue((seenPrompts[1] ?? "").contains("Word1"), "second prompt chains first text")
            XCTAssertTrue((seenPrompts[2] ?? "").contains("Word1"))
            XCTAssertTrue((seenPrompts[2] ?? "").contains("Word2"))
            let started = await scheduler.totalStartedRequests
            XCTAssertEqual(started, 3, "fast path keeps one request per segment")
            let coalesced = await scheduler.totalCoalescedBatches
            XCTAssertEqual(coalesced, 0)
        }
    }

    // MARK: - Slower than realtime: bounded queue, fewer requests, no loss

    @objc func testSlowerThanRealtime_CoalescesPending_NoSamplesLost() throws {
        try runAsync {
            let scheduler = LiveSegmentScheduler(
                policy: LiveBackpressurePolicy(maxPendingBatches: 2, maxQueuedSeconds: 9.0))
            // Enqueue 6 segments with no consumer running: coalescing applies
            // synchronously inside the actor on every enqueue.
            for i in 0..<6 {
                await scheduler.enqueue(samples: self.segment(Int16(i + 1), count: 1600), isTail: false)
                let pending = await scheduler.pendingBatchCount
                XCTAssertLessThanOrEqual(pending, 2, "pending batch count stays bounded")
            }
            let pending = await scheduler.pendingBatchCount
            XCTAssertLessThanOrEqual(pending, 2)
            let coalesced = await scheduler.totalCoalescedBatches
            XCTAssertGreaterThan(coalesced, 0, "slow production must merge pending batches")
            let enqueued = await scheduler.totalEnqueuedSamples
            XCTAssertEqual(enqueued, 6 * 1600)

            var calls = 0
            let stt: ChunkedPipeline.STTHandler = { _, _, _ in
                calls += 1
                return ChunkedPipeline.SttResult(text: "text")
            }
            let batches = await scheduler.run(stt: stt)
            XCTAssertLessThan(calls, 6, "request count decreases when STT falls behind")
            let delivered = batches.reduce(0) { $0 + $1.batch.samples.count }
            XCTAssertEqual(delivered, 6 * 1600, "no voiced samples lost when coalescing")
            let sources = batches.reduce(0) { $0 + $1.batch.sourceSegmentCount }
            XCTAssertEqual(sources, 6, "source segment accounting covers every delivery")
            // Order within the coalesced batch: sample values ascend 1..6.
            let all = batches.flatMap { $0.batch.samples }
            XCTAssertEqual(all.count, 6 * 1600)
            for (i, block) in all.chunked(size: 1600).enumerated() {
                XCTAssertTrue(block.allSatisfy { $0 == Int16(i + 1) }, "block \(i) out of order")
            }
        }
    }

    @objc func testSlowerThanRealtime_ConcurrentProductionWhileBusy() throws {
        try runAsync {
            let scheduler = LiveSegmentScheduler(
                policy: LiveBackpressurePolicy(maxPendingBatches: 2, maxQueuedSeconds: 9.0))
            await scheduler.enqueue(samples: self.segment(1, count: 1600), isTail: false)
            var calls = 0
            let slowSTT: ChunkedPipeline.STTHandler = { _, _, _ in
                calls += 1
                try? await Task.sleep(nanoseconds: 200_000_000)
                return ChunkedPipeline.SttResult(text: "slow\(calls)")
            }
            // Pump starts while the first request is slow; production
            // continues behind it and must coalesce instead of piling up.
            let pump = Task { await scheduler.run(stt: slowSTT) }
            // Give the pump a moment to dequeue and go in-flight.
            try? await Task.sleep(nanoseconds: 20_000_000)
            for i in 2...7 {
                await scheduler.enqueue(samples: self.segment(Int16(i), count: 800), isTail: false)
            }
            let midPending = await scheduler.pendingBatchCount
            XCTAssertLessThanOrEqual(midPending, 2, "queue stays bounded while STT is busy")
            let batches = await pump.value
            let totalSamples = batches.reduce(0) { $0 + $1.batch.samples.count }
            XCTAssertEqual(totalSamples, 1600 + 6 * 800, "all voiced audio transcribed")
            XCTAssertLessThan(calls, 7, "fewer requests than delivered segments")
            let busy = await scheduler.isBusy
            XCTAssertFalse(busy, "no request left running after drain")
        }
    }

    @objc func testCoalescing_PreservesTailFlag() throws {
        try runAsync {
            let scheduler = LiveSegmentScheduler(
                policy: LiveBackpressurePolicy(maxPendingBatches: 1, maxQueuedSeconds: 0.01))
            await scheduler.enqueue(samples: self.segment(1, count: 160), isTail: false)
            await scheduler.enqueue(samples: self.segment(2, count: 160), isTail: false)
            await scheduler.enqueue(samples: self.segment(3, count: 160), isTail: true)
            let pending = await scheduler.pendingBatchCount
            XCTAssertEqual(pending, 1, "over-bound pending merges into a single batch")
            let stt: ChunkedPipeline.STTHandler = { _, _, _ in ChunkedPipeline.SttResult(text: "x") }
            let batches = await scheduler.run(stt: stt)
            XCTAssertEqual(batches.count, 1)
            XCTAssertTrue(batches[0].batch.isTail, "merged batch keeps the tail flag")
            XCTAssertEqual(batches[0].batch.sourceSegmentCount, 3)
        }
    }

    @objc func testQueuedAge_Tracked() throws {
        try runAsync {
            let scheduler = LiveSegmentScheduler(policy: .default)
            let empty = await scheduler.oldestQueuedAge
            XCTAssertEqual(empty, 0)
            await scheduler.enqueue(samples: self.segment(1, count: 160), isTail: false)
            // Small sleep so the age is observable but still tiny.
            try? await Task.sleep(nanoseconds: 20_000_000)
            let age = await scheduler.oldestQueuedAge
            XCTAssertGreaterThan(age, 0)
            XCTAssertLessThan(age, 5.0, "age tracks wall time of oldest pending batch")
        }
    }

    // MARK: - Cancellation: deterministic, no orphan work

    @objc func testCancel_ClearsPending_BlocksNewWork() throws {
        try runAsync {
            let scheduler = LiveSegmentScheduler(policy: .default)
            await scheduler.enqueue(samples: self.segment(1, count: 1600), isTail: false)
            await scheduler.enqueue(samples: self.segment(2, count: 1600), isTail: false)
            await scheduler.cancel()
            let cancelled = await scheduler.isCancelled
            XCTAssertTrue(cancelled)
            let pending = await scheduler.pendingBatchCount
            XCTAssertEqual(pending, 0, "cancel drops pending batches")
            let dequeued = await scheduler.dequeue()
            XCTAssertNil(dequeued, "nothing dequeues after cancel")
            // Post-cancel deliveries are ignored.
            await scheduler.enqueue(samples: self.segment(9, count: 1600), isTail: false)
            let afterEnqueue = await scheduler.pendingBatchCount
            XCTAssertEqual(afterEnqueue, 0)
            let enqueued = await scheduler.totalEnqueuedSegments
            XCTAssertEqual(enqueued, 2, "post-cancel delivery not accepted")
            var calls = 0
            let stt: ChunkedPipeline.STTHandler = { _, _, _ in
                calls += 1
                return ChunkedPipeline.SttResult(text: "x")
            }
            let batches = await scheduler.run(stt: stt)
            XCTAssertTrue(batches.isEmpty)
            XCTAssertEqual(calls, 0, "cancelled pump issues no STT requests")
            let busy = await scheduler.isBusy
            XCTAssertFalse(busy, "no worker left blocked after cancel")
        }
    }

    @objc func testCancel_MidFlight_DropsRemaining() throws {
        try runAsync {
            let scheduler = LiveSegmentScheduler(
                policy: LiveBackpressurePolicy(maxPendingBatches: 10, maxQueuedSeconds: 60.0))
            await scheduler.enqueue(samples: self.segment(1, count: 1600), isTail: false)
            await scheduler.enqueue(samples: self.segment(2, count: 1600), isTail: false)
            // Dequeue one (in-flight), then cancel: remaining pending is dropped.
            let first = await scheduler.dequeue()
            XCTAssertNotNil(first)
            await scheduler.cancel()
            let pending = await scheduler.pendingBatchCount
            XCTAssertEqual(pending, 0)
            let busy = await scheduler.isBusy
            XCTAssertFalse(busy, "cancel releases the busy flag deterministically")
        }
    }

    @objc func testEmptySegments_Ignored() throws {
        try runAsync {
            let scheduler = LiveSegmentScheduler(policy: .default)
            await scheduler.enqueue(samples: [], isTail: false)
            let pending = await scheduler.pendingBatchCount
            XCTAssertEqual(pending, 0, "empty segments create no work")
            let enqueued = await scheduler.totalEnqueuedSegments
            XCTAssertEqual(enqueued, 0)
        }
    }
}

// MARK: - Helpers

private extension Array {
    func chunked(size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var out: [[Element]] = []
        var i = 0
        while i < count {
            out.append(Array(self[i..<Swift.min(i + size, count)]))
            i += size
        }
        return out
    }
}
