import Foundation
import AVFoundation
import AudioEngineGuard
@testable import NanoDictateCore

/// Live-VAD tests of AudioService (task #112). Fake engine, no hardware
/// (same pattern as AudioServiceLifecycleTests).
///
/// Checks:
///   • pause ≥ pauseDuration closes utterance — segment delivered as COPY,
///     shared record untouched (stop() returns WHOLE record);
///   • short pause — inner gap, utterance stays alive;
///   • stop() delivers tail of unclosed utterance (isTail == true) only when
///     speech ran; cancel() delivers nothing;
///   • limit stop: tail delivered BEFORE limit callback;
///   • VAD resets between segments of one session and between sessions.
///
/// Pre-/post-roll (task #139):
///   • pre-roll 0.5 s: silence before first word kept; offset does NOT eat
///     into delivered segment (clamped at liveLastCutIndex);
///   • post-roll 0.25 s: silence added to last speech without pause bloat and
///     past record end; stop() tail — NO post-roll;
///   • boundary pause: exactly livePauseSamples closes utterance; slightly
///     less keeps it, later speech extends it (no second utterance opens);
///     AFTER close new speech opens NEW utterance — second portion delivered
///     as separate segment (live dictation).
///
/// Buffer counters: after amplitude jump 0.2 → 0.001 resampler
/// (AVAudioConverter) "rings" — first silence buffer after speech has
/// RMS ≈ 0.013 > 0.00316 and goes to speech branch. Closing pause "starts"
/// at SECOND silence buffer: 4 clean buffers accumulate 3×1486 ≈ 4458 ≥ 3200.
/// In prod adds one buffer delay (~90 ms) — negligible; tests reserve margin.
final class AudioServiceVADTests: XCTestCase {

    // MARK: - Фейковый движок

    private final class FakeInputNode: AudioInputNodeLike {
        let format: AVAudioFormat
        var tapBlock: AVAudioNodeTapBlock?

        init(sampleRate: Double = 44100) {
            format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        }

        func outputFormat(forBus bus: AVAudioNodeBus) -> AVAudioFormat { format }

        func installTap(
            onBus bus: AVAudioNodeBus,
            bufferSize: AVAudioFrameCount,
            format: AVAudioFormat?,
            block tapBlock: @escaping AVAudioNodeTapBlock
        ) {
            self.tapBlock = tapBlock
        }

        func removeTap(onBus bus: AVAudioNodeBus) {}

        /// Emits one buffer via tap callback (prod audio thread does this).
        func emit(_ buffer: AVAudioPCMBuffer) {
            tapBlock?(buffer, AVAudioTime())
        }
    }

    private final class FakeEngine: AudioEngineLike {
        let node = FakeInputNode()

        func makeInputNode() -> AudioInputNodeLike { node }
        func prepare() {}
        func start() throws {}
        func stop() {}
    }

    // MARK: - Доставки

    private final class DeliveryBox {
        private(set) var deliveries: [(samples: [Int16], isTail: Bool)] = []
        func add(_ samples: [Int16], isTail: Bool) { deliveries.append((samples, isTail)) }
    }

    // MARK: - Helpers

    /// Live-VAD service with configurable close pause: test buffer 4096 fr
    /// @44.1 kHz ≈ 1486 samples @16 kHz; pause 0.2 s = threshold 3200 samples
    /// (covered by three clean silence buffers). Pause 1.0 s = threshold 16000
    /// — above post-roll (4000), needed for exact post-roll edge without
    /// buffer-end clamp. `autoStop` — silence auto-stop config (default
    /// `.defaults`).
    private func makeLiveService(
        engine: FakeEngine,
        pause: TimeInterval = 0.2,
        autoStop: AutoStopConfig = .defaults
    ) -> AudioService {
        var config = AudioSegmenterConfig.defaults
        config.pauseDuration = pause
        return AudioService(logLevel: "info", engine: engine, segmenterConfig: config, autoStopConfig: autoStop)
    }

    private func runStart(_ service: AudioService) -> Bool {
        let done = expectation(description: "audio start")
        var ok = false
        service.start { r in
            if case .success = r { ok = true }
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return ok
    }

    /// Constant buffer: RMS = |amplitude|. Speech 0.2 (> threshold 0.00316),
    /// silence 0.001 (<).
    private func makeBuffer(engine: FakeEngine, amplitude: Float) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.node.format, frameCapacity: 4096)!
        buffer.frameLength = 4096
        let channel = buffer.floatChannelData![0]
        for i in 0..<4096 { channel[i] = amplitude }
        return buffer
    }

    private func emit(_ engine: FakeEngine, amplitude: Float, count: Int) {
        for _ in 0..<count {
            engine.node.emit(makeBuffer(engine: engine, amplitude: amplitude))
        }
    }

    /// First sample with |amp| ≥ threshold — calibrates pre-roll offset by
    /// actual (not assumed) buffer sample count.
    private func firstLoudIndex(_ samples: [Int16], threshold: Int = 1000) -> Int? {
        samples.firstIndex { abs(Int($0)) >= threshold }
    }

    /// Finds record window shift where it matches segment on average:
    /// maximizes sample share agreeing with speech (amp 6553) and silence (32)
    /// at once — max normalization in window keeps criterion robust to VAD
    /// timing jitter (few samples).
    private func bestWindowOffset(record: [Int16], start: Int, window seg: [Int16], search: Int) -> Int? {
        guard start >= 0, start + seg.count + search <= record.count else { return nil }
        var best: (offset: Int, score: Float) = (0, -1)
        for offset in -search...search {
            if start + offset < 0 || start + offset + seg.count > record.count { continue }
            var norm: Float = 0
            var score: Float = 0
            for i in 0..<seg.count {
                let r = abs(Int(record[start + offset + i]))
                let s = abs(Int(seg[i]))
                let m = Float(max(r, s))
                if m == 0 { continue }
                norm += 1
                if (r >= 3000) == (s >= 3000) { score += 1 }
            }
            guard norm > 0 else { continue }
            let ratio = score / norm
            if ratio > best.score { best = (offset, ratio) }
        }
        return best.offset
    }

    // MARK: - Пауза закрывает уттеренс; сегмент — копия

    /// Speech 2 buffers → pause 6 (≥ pauseDuration, counting ringing first
    /// silence buffer): exactly one segment, bounds = speech samples (no pause
    /// silence). Segment — COPY: shared record untouched, stop() returns whole
    /// record, prefix equal to segment, tail silence.
    @objc func testPauseClosesUtteranceAndDeliversCopy() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 6)

        XCTAssertEqual(box.deliveries.count, 1, "одна пауза — один сегмент")
        XCTAssertFalse(box.deliveries[0].isTail, "сегмент из середины записи — не хвост")
        let seg = box.deliveries[0].samples
        // 2 speech buffers + ringing first silence buffer (~3 × 1486) +
        // post-roll 0.25 s (4000 samples) — tail of last word not cut.
        // Post-roll < pause remainder (no buffer-end clamp here), so segment
        // is prefix of record, not whole record.
        XCTAssertTrue(seg.count > 2600, "сегмент = речевой блок")
        XCTAssertTrue(seg.count > 7800, "пост-ролл 0.25 c тишины добавлен к речи")
        XCTAssertTrue(seg.count < 9100, "сегмент не раздувается всей паузой (> пост-ролла)")

        // stop(): whole record intact, prefix = segment (asserts below).
        let samples = service.stop()
        XCTAssertTrue(samples.count > seg.count, "stop() отдаёт всю запись, сегмент — её префикс")
        XCTAssertEqual(Array(samples.prefix(seg.count)), seg, "речевые сэмплы в общем буфере не пострадали")
        let tailPart = samples.dropFirst(seg.count)
        XCTAssertTrue(tailPart.allSatisfy { abs(Int($0)) < 100 }, "хвост записи — тишина паузы")
    }

    /// Pause shorter than pauseDuration — inner gap: utterance not broken,
    /// sigh between phrases does not tick segment. Speech 2 → pause 2 →
    /// speech 2 → pause 6: ONE segment (speech + inner gap), no tail.
    @objc func testShortInternalPauseKeepsUtteranceAlive() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 2)  // < pauseDuration — inner gap
        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 6)  // ≥ pauseDuration — closes

        XCTAssertEqual(box.deliveries.count, 1, "внутренний пробел не рвёт уттеренс")
        XCTAssertFalse(box.deliveries[0].isTail)
        let seg = box.deliveries[0].samples
        // 4 speech buffers + resampler ring (~3–6 × 1486) + post-roll 4000.
        // Both speech portions — ONE segment (else 2 deliveries), long final
        // pause not into segment (post-roll cut). Measured: 15882 (ringing
        // close) and 14396 (clean silence) — range covers both.
        XCTAssertTrue(seg.count > 13900, "сегмент включает и речь после пробела, и пост-ролл")
        XCTAssertTrue(seg.count < 17000, "сегмент не включает длинную паузу")

        // Utterance already closed by long pause — stop yields no tail.
        _ = service.stop()
        XCTAssertEqual(box.deliveries.count, 1)
    }

    // MARK: - «Хвост» stop() и cancel()

    /// Unclosed utterance delivered by stop() as last segment (isTail == true)
    /// — samples without trailing silence. Silence without speech gives no
    /// tail.
    @objc func testStopDeliversTailOnlyWhenSpeechWasInProgress() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        emit(engine, amplitude: 0.2, count: 2)
        let samples = service.stop()

        XCTAssertEqual(box.deliveries.count, 1)
        XCTAssertTrue(box.deliveries[0].isTail, "незакрытый уттеренс — хвост stop()")
        let tail = box.deliveries[0].samples
        XCTAssertEqual(tail.count, samples.count, "паузы не было — хвост = вся запись")

        // New session, silence only: no utterance — no tail delivered
        // (useless STT request of void is not sent).
        guard runStart(service) else {
            XCTFail("повторный старт должен пройти", file: #file, line: #line)
            return
        }
        emit(engine, amplitude: 0.001, count: 3)
        _ = service.stop()
        XCTAssertEqual(box.deliveries.count, 1, "тишина без речи не даёт ни сегмента, ни хвоста")
    }

    /// Esc (cancel()): data dropped whole — no segment, no tail, even if
    /// speech ran (utterance was open).
    @objc func testCancelDeliversNothing() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        emit(engine, amplitude: 0.2, count: 2)
        service.cancel()
        XCTAssertEqual(box.deliveries.count, 0, "отмена отбрасывает открытый уттеренс")
    }

    // MARK: - Принудительный стоп по лимиту

    /// Continuous speech to hard volume limit (960 000 samples): tail
    /// (isTail == true) delivered BEFORE onRecordingLimitReached callback —
    /// client queues it for recognition before finalization.
    @objc func testLimitStopDeliversTailBeforeLimitCallback() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine)
        // Single event log: order "tail → limit" critical for live dictation
        // (Agent's serial executor must see tail first).
        var events: [String] = []
        service.onSpeechSegment = { _, _ in events.append("tail") }
        let limitDone = expectation(description: "limit reached")
        service.onRecordingLimitReached = { _ in
            events.append("limit")
            limitDone.fulfill()
        }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        // ~1486 samples per buffer: 650 buffers certainly cross threshold
        // 960 000 (last buffer cut by limit; elapsed ≪ 60 s).
        emit(engine, amplitude: 0.2, count: 650)
        wait(for: [limitDone], timeout: 5)

        XCTAssertEqual(events, ["tail", "limit"], "хвост обязан встать в очередь до финализации записи")
    }

    // MARK: - Принудительный стоп по непрерывной тишине (автоостановка ~3 c)

    /// Continuous silence ≥ 3 s in active record stops it same way as limit:
    /// onAutoStop on main queue with collected samples. Frame: buffer 4096 fr
    /// @44.1 kHz ≈ 1486 samples @16 kHz ≈ 0.093 s.
    ///
    /// Auto-stop model (hysteresis + grace + gate): amplitude 0.001 ≪ silence
    /// threshold 0.00126 (−58 dBFS) — clean quiet buffers; amplitude 0.2 ≥
    /// speech threshold 0.00562 (−45 dBFS). Min speech run ≥ 0.3 s ≈ 4 speech
    /// buffers (take 6 for margin). Then silence: grace 2.0 s skips buffers
    /// started before grace end (elapsed < 2 s), i.e. first ~16 quiet buffers;
    /// rest accumulate, reach 3.0 s at ~49th quiet buffer (60 buffers =
    /// ~5.6 s — margin for resampler ring after amplitude jump, see header).
    @objc func testContinuousSilenceTriggersAutoStop() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine)
        var autoStopSamples: [Int16] = []
        var segmentDeliveries = 0
        var tailDeliveries = 0
        service.onSpeechSegment = { _, isTail in
            if isTail { tailDeliveries += 1 } else { segmentDeliveries += 1 }
        }
        let autoStopDone = expectation(description: "auto-stop by silence")
        service.onAutoStop = { samples in
            autoStopSamples = samples
            autoStopDone.fulfill()
        }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        // Speech 6 buffers (~0.6 s; speech gate latched) → silence 60 buffers
        // (~5.6 s): auto-stop fires ~55th buffer (after grace window and 3.0 s
        // silence); remaining buffers dropped by early exit (autoStopScheduled).
        // Elapsed ≪ 60 s — limit does not interfere.
        emit(engine, amplitude: 0.2, count: 6)
        emit(engine, amplitude: 0.001, count: 60)
        wait(for: [autoStopDone], timeout: 5)

        XCTAssertTrue(autoStopSamples.count > 2000, "в onAutoStop приходят собранные сэмплы записи, а не пусто")
        XCTAssertTrue(autoStopSamples.count <= 66 * 1486 + 4096, "снимок не раздут: буферы после срабатывания не дописываются")
        // 3 s silence fully "eats" utterance by live-VAD pause close (0.2 s helper;
        // prod 1.0 s): no open utterance at auto-stop — no tail delivered,
        // correct behavior (see handleAutoStop: in live dictation final pass
        // works on snapshot, tail unused).
        XCTAssertEqual(tailDeliveries, 0, "при автоостановке открытого уттеренса быть не может: речь была >3 c назад")
        XCTAssertGreaterThanOrEqual(segmentDeliveries, 1, "уттеренс закрыт live-VAD по паузе ещё ДО автоостановки")
    }

    /// Pause shorter than 3 s does NOT stop: silence of 6 buffers (~0.5 s) stays
    /// below threshold and lies fully inside grace window 2.0 s (no
    /// accumulation at all), speech resumes after, and only explicit stop()
    /// ends record with EVERYTHING collected (including speech AFTER pause) —
    /// feature does not cut record on thoughtful pause inside dictation.
    @objc func testShortSilenceDoesNotStopRecording() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine, pause: 1.0)
        var autoStopFired = false
        service.onAutoStop = { _ in autoStopFired = true }
        var tails: [[Int16]] = []
        service.onSpeechSegment = { samples, isTail in
            if isTail { tails.append(samples) }
        }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        // Speech 2 → pause 6 buffers (~0.5 s silence; if first post-jump buffer
        // rings on resampler — ~0.46 s, still ≪ 3 s) → speech 2 again.
        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 6)
        emit(engine, amplitude: 0.2, count: 2)
        // Explicit stop: no auto-stop wait — all synchronous.
        let samples = service.stop()

        XCTAssertFalse(autoStopFired, "короткая пауза (< 3 c) не останавливает запись")
        // Tail covers both speech portions: pause 0.5 s < pause 1.0 s — one
        // utterance, pre-/post-roll within bounds.
        XCTAssertEqual(tails.count, 1, "стоп отдаёт один незакрытый уттеренс")
        XCTAssertTrue(tails[0].count > 5000, "уттеренс включает речь ПОСЛЕ паузы")
        XCTAssertTrue(samples.count > 4000, "stop возвращает всю запись (речь + пауза)")
    }

    /// Master switch: config with enabled == false does not stop record even
    /// after silence ~4.2 s (45 buffers) — record lives to explicit stop.
    /// Escape hatch for noisy env/long dictations; default unchanged
    /// (cf. testContinuousSilenceTriggersAutoStop with default config).
    @objc func testDisabledAutoStopDoesNotFire() {
        let engine = FakeEngine()
        var disabledConfig = AutoStopConfig.defaults
        disabledConfig.enabled = false
        let service = makeLiveService(engine: engine, autoStop: disabledConfig)
        var autoStopFired = false
        service.onAutoStop = { _ in autoStopFired = true }
        var segmentDeliveries = 0
        service.onSpeechSegment = { _, isTail in
            if !isTail { segmentDeliveries += 1 }
        }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        // Speech 2 buffers → silence 45 buffers (~4.2 s): feature off — silence
        // does NOT end record, explicit stop() sums up.
        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 45)
        let samples = service.stop()

        XCTAssertFalse(autoStopFired, "выключенная фича не останавливает запись по тишине")
        // Silence 4.2 s ≫ live-VAD pause 0.2 s — utterance closed by normal
        // segmentation (works regardless of auto-stop).
        XCTAssertGreaterThanOrEqual(segmentDeliveries, 1, "уттеренс закрыт live-VAD по паузе ещё до stop")
        // Whole record 47 buffers ≈ 69839 samples: AVAudioConverter gives up ~3
        // samples to priming, strict edge "47 × 1486" (69842) physically
        // unreachable. Lower edge "47 × 1480" with margin for converter
        // jitter proves snapshot holds ALL 47 buffers (~4.4 s) — no auto-stop
        // cut the record.
        XCTAssertTrue(samples.count >= 47 * 1480, "stop возвращает всю запись, включая длинную тишину: \(samples.count)")
    }

    // MARK: - Сброс VAD между сегментами и между сеансами

    /// Two utterances in one session: after segment delivery VAD resets —
    /// second segment starts at its own speech block (not merged with old).
    /// New session also starts with clean bounds.
    @objc func testVADResetsAfterDeliveryAndAcrossCycles() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        // Session 1: utterance 1 (speech 2 → pause 6), utterance 2 (speech 2 → pause 6).
        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 6)
        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 6)

        XCTAssertEqual(box.deliveries.count, 2, "два уттеренса — два сегмента")
        XCTAssertFalse(box.deliveries[0].isTail)
        XCTAssertFalse(box.deliveries[1].isTail)
        // Second segment — exactly its own speech block (2 buffers + ring), not
        // merged with first utterance (would be thousands of samples longer).
        let second = box.deliveries[1].samples
        // Speech block (~3 × 1486) + post-roll 4000. Segment boundary sits exactly
        // at liveLastCutIndex (end of first segment post-roll), so second
        // segment merges with neither first utterance nor pause silence.
        XCTAssertTrue(second.count > 10000, "второй сегмент = свой речевой блок + пост-ролл")
        XCTAssertTrue(second.count < 13000, "второй сегмент не тащит первый уттеренс")
        let first = box.deliveries[0].samples
        XCTAssertTrue(first.count > 7500, "первый сегмент тоже самодостаточен (речь + пост-ролл)")
        XCTAssertTrue(first.count < 9100, "первый сегмент не раздувается паузой")

        // Utterance 2 closed by pause — stop without tail.
        _ = service.stop()
        XCTAssertEqual(box.deliveries.count, 2)

        // Session 2: fresh start — clean bounds, tail of exactly one buffer.
        guard runStart(service) else {
            XCTFail("повторный старт должен пройти", file: #file, line: #line)
            return
        }
        emit(engine, amplitude: 0.2, count: 1)
        _ = service.stop()

        XCTAssertEqual(box.deliveries.count, 3)
        XCTAssertTrue(box.deliveries[2].isTail, "хвост нового сеанса")
        let newTail = box.deliveries[2].samples
        XCTAssertTrue(newTail.count > 1300, "хвост = один буфер речи")
        XCTAssertTrue(newTail.count < 1700, "хвост не подтянул сэмплы прошлого сеанса")
    }

    // MARK: - Pre-roll 0.5 c: атака первого слова не срезается

    /// Pre-roll: utterance starts NOT at first speech buffer but 0.5 s
    /// (8000 samples) earlier. Silence before speech > pre-roll (10 buffers ≈
    /// 14860 > 8000) — offset full, not clamped to record start: segment
    /// starts exactly 8000 samples before first word attack, opens with these
    /// 0.5 s of clean silence.
    /// firstLoudIndex threshold 3000 (word amp 6553), NOT 1000: with 1000
    /// calibration catches first speech buffer "ring" (amp 32) at silence
    /// edge and misses by a block.
    @objc func testPreRollCapturesHalfSecondOfSilenceBeforeFirstWord() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        emit(engine, amplitude: 0.001, count: 10)  // silence before speech (> pre-roll 8000)
        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 6)   // closes utterance

        XCTAssertEqual(box.deliveries.count, 1)
        XCTAssertFalse(box.deliveries[0].isTail)
        let seg = box.deliveries[0].samples
        let samples = service.stop()

        // Calibration by actual buffer: speech attack = first sample ≥ 3000
        // (silence "ring" 32 does not pass). Silence lead 14860 ≫ 8000, so
        // pre-roll full, clamped only by record start.
        guard let firstLoud = firstLoudIndex(samples, threshold: 3000) else {
            XCTFail("в записи должна быть речь", file: #file, line: #line)
            return
        }
        XCTAssertTrue(firstLoud > 8000 + 1486,
            "тишины перед речью хватает на полный pre-roll с запасом на блок")
        let expectedStart = max(0, firstLoud - 8000)
        XCTAssertTrue(expectedStart > 0, "pre-roll реально ушёл в тишину, а не начался с нуля записи")

        // Record cut edge and VAD segment cut edge may differ by few samples (VAD
        // timing in buffer indices vs continuous record counter) — check
        // segment by content: window of record near expectedStart, not exact
        // slice.
        XCTAssertTrue(seg.count > 15500 && seg.count < 17500, "тишина pre-roll + речь + пост-ролл")
        guard let segAttack = firstLoudIndex(seg, threshold: 3000) else {
            XCTFail("в сегменте должна быть речь", file: #file, line: #line)
            return
        }
        XCTAssertTrue(segAttack > 6900 && segAttack < 8600,
            "атака первого слова — внутри сегмента, не срезана и не у края")
        XCTAssertTrue(
            Array(seg[0..<(segAttack > 8000 ? 8000 : segAttack)]).allSatisfy { abs(Int($0)) < 100 },
            "первые 0.5 c сегмента — чистая тишина до атаки первого слова"
        )
        if let offset = bestWindowOffset(record: samples, start: expectedStart, window: seg, search: 12) {
            XCTAssertTrue(abs(offset) <= 12,
                "сегмент — окно записи вблизи expectedStart (джиттер тайминга в пределе)")
        } else {
            XCTFail("сегмент не ложится на окно записи", file: #file, line: #line)
        }
        XCTAssertTrue(expectedStart + seg.count < samples.count,
            "пост-ролл закончился раньше конца записи, пауза продолжается")
    }

    // MARK: - Граничная пауза: ровно на livePauseSamples / чуть меньше

    /// Close EXACTLY at boundary: silence accumulation 2×1486 = 2972 < 3200 —
    /// utterance alive; next buffer reaches 4458 ≥ 3200 — close happens
    /// exactly in that block (analog of "±1 sample" at 1486 granularity).
    @objc func testPauseClosesExactlyAtThresholdBoundaryBlock() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        // Ringing first silence buffer + 2 clean = 2972 < 3200: not closed.
        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 3)
        XCTAssertEqual(box.deliveries.count, 0, "накопленная пауза < livePauseSamples — не закрыт")

        // One more clean buffer: 4458 ≥ 3200 — closes exactly in this block.
        emit(engine, amplitude: 0.001, count: 1)
        XCTAssertEqual(box.deliveries.count, 1, "следующий блок тишины закрыл уттеренс сразу")
        XCTAssertFalse(box.deliveries[0].isTail)
    }

    /// Pause "just below" threshold does NOT close: new speech after it
    /// continues SAME utterance (single segment for both portions); second
    /// utterance inside one live not opened.
    @objc func testPauseJustBelowThresholdKeepsUtteranceAndSpeechExtendsIt() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 3)  // 2972 < 3200 — does not close
        XCTAssertEqual(box.deliveries.count, 0, "пауза чуть меньше порога — уттеренс продолжается")

        emit(engine, amplitude: 0.2, count: 2)    // speech extends utterance
        XCTAssertEqual(box.deliveries.count, 0, "новая речь внутри уттеренса — второй НЕ открывается")

        emit(engine, amplitude: 0.001, count: 6)  // closes
        XCTAssertEqual(box.deliveries.count, 1, "обе порции речи — один сегмент")
        let seg = box.deliveries[0].samples
        // Two speech portions (≈6×1486) + post-roll 4000. Range 13900…17000 covers
        // both ring implementations of closing pause (14396, 15882) and
        // guarantees extension counted: second portion alone ≈8452 with
        // post-roll — unreachable.
        XCTAssertTrue(seg.count > 13900, "сегмент включает речь и ПОСЛЕ внутренней паузы")
        XCTAssertTrue(seg.count < 17000, "сегмент не включает длинную паузу")

        _ = service.stop()
        XCTAssertEqual(box.deliveries.count, 1, "уттеренс закрыт паузой — хвоста при стопе нет")
    }

    // MARK: - Ключевой сценарий живой диктовки: «и-и-и чуть-чуть ещё сказал»

    /// AFTER closing (pause ≥ threshold) new speech opens NEW utterance —
    /// second portion delivered as SEPARATE segment, not lost, not merged
    /// (regression: "said a bit more — and nothing").
    @objc func testAfterLongPauseNewSpeechDeliversSeparateSegment() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 6)
        XCTAssertEqual(box.deliveries.count, 1, "первая порция доставлена")

        emit(engine, amplitude: 0.2, count: 2)    // "a bit more" AFTER closing
        emit(engine, amplitude: 0.001, count: 6)
        XCTAssertEqual(box.deliveries.count, 2, "вторая порция доставлена ОТДЕЛЬНЫМ сегментом")

        XCTAssertFalse(box.deliveries[0].isTail)
        XCTAssertFalse(box.deliveries[1].isTail)
        let seg1 = box.deliveries[0].samples
        let seg2 = box.deliveries[1].samples
        XCTAssertTrue(seg1.count > 7500 && seg1.count < 9100, "сегмент 1: речь + пост-ролл 0.25 c (count=\(seg1.count))")
        XCTAssertTrue(seg2.count > 10000 && seg2.count < 13000,
            "сегмент 2: свою речь + пост-ролл (замер 11889 с полным звоном)")
        XCTAssertTrue(seg2.contains { abs(Int($0)) >= 3000 },
            "вторая порция содержит реальную речь — не потеряна (жалоба «ничего не происходило»)")

        // Both segments closed by pauses — stop gives no tail, no duplicates.
        _ = service.stop()
        XCTAssertEqual(box.deliveries.count, 2)
    }

    /// Pre-roll does not eat into delivered segment: second utterance after long
    /// pause starts EXACTLY at liveLastCutIndex (end of first post-roll), not
    /// at sampleStart − 8000. Without clamp second portion would start ~2.4k
    /// samples earlier and duplicate delivered audio: continuity check over
    /// whole record (no gap, no overlap) catches it.
    @objc func testPreRollDoesNotOverlapPreviouslyDeliveredSegment() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 6)
        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 6)

        XCTAssertEqual(box.deliveries.count, 2)
        let seg1 = box.deliveries[0].samples
        let seg2 = box.deliveries[1].samples
        let samples = service.stop()

        XCTAssertEqual(seg1, Array(samples.prefix(seg1.count)), "сегмент 1 — префикс записи")
        XCTAssertEqual(
            seg2, Array(samples.dropFirst(seg1.count).prefix(seg2.count)),
            "сегмент 2 продолжает запись ровно со среза: без наложения и потери"
        )
        XCTAssertTrue(seg1.count > 7500 && seg1.count < 9100, "сегмент 1 не раздут")
        XCTAssertTrue(seg2.count > 10000 && seg2.count < 13000, "сегмент 2 не раздут")
    }

    // MARK: - Post-roll 0.25 c: точная граница и конец буфера

    /// Exact post-roll edge: closing pause 1.0 s (threshold 16000) > post-roll
    /// (4000), buffer-end clamp does not interfere — segment ends exactly
    /// through 4000 samples of silence after last speech.
    @objc func testPostRollAddsExactlyQuarterSecondOfSilence() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine, pause: 1.0)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 15)  // ≈ 22290 > 16000 — closes

        XCTAssertEqual(box.deliveries.count, 1)
        let seg = box.deliveries[0].samples
        let samples = service.stop()

        XCTAssertTrue(seg.count > 8000 && seg.count < 9000, "речь (~3×1486) + пост-ролл 4000")
        XCTAssertTrue(seg.suffix(4000).allSatisfy { abs(Int($0)) < 100 },
            "после последней речи в сегменте ровно 0.25 c тишины")
        XCTAssertTrue(samples.count - seg.count > 10000,
            "пост-ролл НЕ проглотил паузу: остаток паузы остался в записи, а не в сегменте")
        XCTAssertEqual(seg, Array(samples.prefix(seg.count)), "сегмент — префикс записи, без хвостовой паузы")
    }

    /// Segment bounds never exceed record: live segment — prefix of record,
    /// stop tail continues record exactly at cut. Speech reaching record end
    /// goes to tail whole (no cut, no post-roll beyond end).
    @objc func testDeliveredSegmentsStayWithinRecordBounds() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 6)   // closes segment 1
        emit(engine, amplitude: 0.2, count: 2)     // speech to record end
        let samples = service.stop()               // stop on open utterance

        XCTAssertEqual(box.deliveries.count, 2, "сегмент 1 (live) + «хвост» 2 (стоп)")
        let seg1 = box.deliveries[0].samples
        let tail = box.deliveries[1].samples
        XCTAssertFalse(box.deliveries[0].isTail)
        XCTAssertTrue(box.deliveries[1].isTail)

        XCTAssertEqual(seg1, Array(samples.prefix(seg1.count)), "live-сегмент не вышел за конец записи")
        XCTAssertEqual(tail, Array(samples.dropFirst(seg1.count)), "«хвост» продолжает запись со среза")
        XCTAssertEqual(seg1.count + tail.count, samples.count, "live-сегмент + «хвост» = вся запись, без потерь")
        XCTAssertTrue(tail.contains { abs(Int($0)) >= 3000 }, "доречь ушла в «хвост» целиком")
    }

    // MARK: - «Хвост» stop() без пост-ролла

    /// Post-roll applied ONLY to live close; stop() tail cut at last speech
    /// (pause silence and post-roll samples do not get in).
    @objc func testTailHasNoPostRoll() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 2)  // pause did NOT close: stop on open utterance
        let samples = service.stop()

        XCTAssertEqual(box.deliveries.count, 1)
        XCTAssertTrue(box.deliveries[0].isTail, "незакрытый уттеренс — «хвост» stop()")
        let tail = box.deliveries[0].samples
        // Speech + ringing silence buffer (~3×1486). Apply post-roll — would be
        // ≥5944 (whole buffer) — range catches it.
        XCTAssertTrue(tail.count > 4200 && tail.count < 4900, "«хвост» без пост-ролла")
        XCTAssertEqual(tail, Array(samples.prefix(tail.count)), "«хвост» — префикс записи")
        XCTAssertTrue(tail.count < samples.count, "тишина паузы (и пост-ролл) в «хвост» не попала")
    }

    // MARK: - Сброс liveLastCutIndex между сеансами

    /// liveLastCutIndex pre-roll clamp lives ONLY inside session: new session
    /// starts with clean bounds. If cut were kept across sessions, second
    /// session tail would be clamped by old cut past buffer end and come out
    /// empty (first reply lost).
    @objc func testLiveLastCutIndexResetsOnNewRecording() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 6)   // segment delivered → liveLastCutIndex = post-roll
        XCTAssertEqual(box.deliveries.count, 1)
        _ = service.stop()                          // closed by pause — no tail

        guard runStart(service) else {
            XCTFail("повторный старт должен пройти", file: #file, line: #line)
            return
        }
        emit(engine, amplitude: 0.2, count: 2)
        let samples2 = service.stop()

        XCTAssertEqual(box.deliveries.count, 2, "сеанс 2 доставил свой «хвост»")
        XCTAssertTrue(box.deliveries[1].isTail)
        let tail = box.deliveries[1].samples
        XCTAssertTrue(tail.count > 2600 && tail.count < 3400, "«хвост» — свой речевой блок")
        XCTAssertEqual(tail, samples2, "«хвост» начинается с нуля записи сеанса — старый срез сброшен")
    }

    // MARK: - Чанки при непрерывной речи (task #142)

    /// Continuous speech longer than window (35 buffers × 1486 ≈ 52010 ≥ 48000)
    /// + micro-pause (4 silence buffers → with ringing first buffer
    /// accumulated 3×1486 = 4458 ≥ 4000) → chunk delivered EXACTLY one, before
    /// full 1 s pause: text shown while person talks. Pause 1.0 s chosen so
    /// full pause does NOT fire before chunk (for default 0.2 s threshold 3200
    /// < micro-pause 4000 — chunk indistinguishable from normal close).
    @objc func testContinuousSpeechDeliversChunkOnMicroPause() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine, pause: 1.0)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        emit(engine, amplitude: 0.2, count: 35)      // speech ≈ 52010 ≥ window 48000
        emit(engine, amplitude: 0.001, count: 4)     // micro-pause 4458 ≥ 4000

        XCTAssertEqual(box.deliveries.count, 1, "чанк доставлен на микро-паузе — ДО полной паузы 1 c")
        XCTAssertFalse(box.deliveries[0].isTail, "чанк из середины речи — не хвост")
        let seg = box.deliveries[0].samples
        // Speech block (35 speech + ringing silence buffer = 36×1486 ≈ 53496) +
        // post-roll 4000 ≈ 57496. Range 55000…60000 unreachable without
        // post-roll or with chunk stretched by whole pause.
        XCTAssertTrue(seg.count > 55000 && seg.count < 60000, "чанк = речь + пост-ролл 0.25 c")
        guard let attack = firstLoudIndex(seg, threshold: 3000) else {
            XCTFail("в чанке должна быть речь", file: #file, line: #line)
            return
        }
        XCTAssertTrue(attack < 100, "чанк начинается с речи — атака не срезана")
        XCTAssertTrue(seg.suffix(4000).allSatisfy { abs(Int($0)) < 100 },
            "пост-ролл 0.25 c тишины сохранён в конце чанка")
        // Chunk cut on micro-pause → VAD reset, stop gives no tail.
        _ = service.stop()
        XCTAssertEqual(box.deliveries.count, 1)
    }

    /// Speech SHORTER than window (10 buffers ≈ 14860 < 48000): micro-pause
    /// 4458 ≥ 4000 does NOT cut — utterance lives, later speech extends SAME
    /// utterance (cf. testShortInternalPauseKeepsUtteranceAlive: word-gap does
    /// not tick segment). Only full 1 s pause closes — one segment over both
    /// speech portions.
    @objc func testShortSpeechMicroPauseDoesNotDeliver() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine, pause: 1.0)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        emit(engine, amplitude: 0.2, count: 10)
        emit(engine, amplitude: 0.001, count: 4)     // micro-pause, but speech < window
        XCTAssertEqual(box.deliveries.count, 0, "речь < окна — микро-пауза НЕ режет")

        emit(engine, amplitude: 0.2, count: 3)       // speech extends SAME utterance
        XCTAssertEqual(box.deliveries.count, 0, "новой речи внутри живого уттеренса — второй не открывается")

        emit(engine, amplitude: 0.001, count: 12)    // ≈ 16346 ≥ 16000 — full pause closes
        XCTAssertEqual(box.deliveries.count, 1, "обе порции речи закрыты ОДНИМ сегментом")
        XCTAssertFalse(box.deliveries[0].isTail)
        let seg = box.deliveries[0].samples
        // Speech (10 + ring + 3 = 14×1486 ≈ 20804) + inner pause (4×1486) +
        // post-roll 4000 ≈ 30748. Range 28000…33000 guarantees BOTH speech
        // portions in segment (only second portion — ~8452, unreachable).
        XCTAssertTrue(seg.count > 28000 && seg.count < 33000, "обе порции речи — один сегмент")
        guard let attack = firstLoudIndex(seg, threshold: 3000) else {
            XCTFail("в сегменте должна быть речь", file: #file, line: #line)
            return
        }
        XCTAssertTrue(attack < 100, "первая порция речи не потеряна — сегмент начинается с неё")
        XCTAssertTrue(seg[20000...].contains { abs(Int($0)) >= 3000 },
            "вторая порция речи после микро-паузы тоже внутри сегмента")

        _ = service.stop()
        XCTAssertEqual(box.deliveries.count, 1, "уттеренс закрыт полной паузой — хвоста нет")
    }

    /// Window edge EXACTLY: 31 buffers × 1486 = 46066 (+ ringing first silence
    /// buffer 1486 = 47552) < 48000 — micro-pause does NOT cut, utterance
    /// lives; next speech buffer reaches 49038 ≥ 48000 — nearest micro-pause
    /// cuts chunk. Both sides of "48000 ± buffer" in one test: below —
    /// silence, crossing — delivery.
    @objc func testChunkBoundaryExactlyAtWindow() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine, pause: 1.0)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        // 31 speech buffers = 46066, + ring = 47552 < 48000: below window.
        emit(engine, amplitude: 0.2, count: 31)
        emit(engine, amplitude: 0.001, count: 4)     // micro-pause 4458 ≥ 4000
        XCTAssertEqual(box.deliveries.count, 0, "накопленная речь чуть ниже окна — микро-пауза не режет")

        // +1 speech buffer: 49038 ≥ 48000 — window crossed, micro-pause cuts.
        emit(engine, amplitude: 0.2, count: 1)
        emit(engine, amplitude: 0.001, count: 4)
        XCTAssertEqual(box.deliveries.count, 1, "речь пересекла окно — ближайшая микро-пауза режет чанк")
        XCTAssertFalse(box.deliveries[0].isTail)
        let seg = box.deliveries[0].samples
        // Speech from start (31 + ring + 1 = 33×1486 ≈ 49038; with second silence
        // block ring — 34×1486 ≈ 50524) + post-roll 4000. Measured 57496…
        // 58982 (two ring implementations of closing block): range covers both.
        XCTAssertTrue(seg.count > 56000 && seg.count < 62000, "чанк = вся речь от старта + пост-ролл 0.25 c")
        XCTAssertTrue(seg.contains { abs(Int($0)) >= 3000 }, "чанк содержит речь от начала записи")

        _ = service.stop()
        XCTAssertEqual(box.deliveries.count, 1)
    }

    /// After chunk new speech block starts EXACTLY at first chunk cut
    /// (liveLastCutIndex = post-roll end): stop tail continues record with no
    /// overlap onto delivered chunk and no loss — same continuity check as
    /// testPreRollDoesNotOverlapPreviouslyDeliveredSegment, but for
    /// micro-pause chunk.
    @objc func testChunkAfterDeliveryNextSpeechNoOverlap() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine, pause: 1.0)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        emit(engine, amplitude: 0.2, count: 35)      // chunk 1 ≈ 57496 (see first test)
        emit(engine, amplitude: 0.001, count: 4)     // micro-pause — chunk delivered
        XCTAssertEqual(box.deliveries.count, 1, "чанк 1 доставлен на микро-паузе")

        emit(engine, amplitude: 0.2, count: 2)       // "said more" after chunk
        let samples = service.stop()                 // stop on open utterance — tail

        XCTAssertEqual(box.deliveries.count, 2, "чанк 1 + «хвост» стопа")
        XCTAssertFalse(box.deliveries[0].isTail)
        XCTAssertTrue(box.deliveries[1].isTail)
        let seg1 = box.deliveries[0].samples
        let tail = box.deliveries[1].samples

        // Continuity over whole record: tail starts EXACTLY at chunk cut (post-roll
        // end), not earlier (earlier — overlap/duplicate) and not later
        // (earlier delivered not lost).
        XCTAssertEqual(seg1, Array(samples.prefix(seg1.count)), "чанк 1 — префикс записи")
        XCTAssertEqual(tail, Array(samples.dropFirst(seg1.count)), "«хвост» продолжает запись со среза чанка — без наложения")
        XCTAssertEqual(seg1.count + tail.count, samples.count, "чанк + «хвост» = вся запись, без потерь")
        XCTAssertTrue(seg1.count > 55000 && seg1.count < 60000, "чанк 1 не раздут")
        XCTAssertTrue(tail.count > 3000 && tail.count < 3900, "«хвост» = 2 буфера речи + pre-roll-отступ от среза")
        XCTAssertTrue(tail.contains { abs(Int($0)) >= 3000 }, "доречь после чанка ушла в «хвост» целиком")
    }
}