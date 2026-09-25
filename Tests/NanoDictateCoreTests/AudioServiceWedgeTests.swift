import Foundation
import AVFoundation
import AudioEngineGuard
@testable import NanoDictateCore

/// Branches around engine hangs (regression of replaceEngineAfterWedge fix):
///   • hung engine.start() holds ONLY its own queue — engine swap is
///     synchronous, fresh engine gets its own queue, next start passes
///     without waiting for the blocked one;
///   • input-node setup failure (NSException under ObjC gateway) — terminal
///     error with engine teardown and successful retry;
///   • converter not created (AVAudioFormat() → nil from
///     AVAudioConverter(from:to:)) — .unsupportedFormat BEFORE tap install and
///     WITHOUT teardown; retry after format 'fix' succeeds;
///   • stale start unblocks AFTER swap (generation race) — .failure
///     (.engineSuperseded), new session untouched, old engine torn down;
///   • stale start unblock WITH engine.start() failure after swap —
///     .failure(start failure), new session alive, only its own engine torn down;
///   • start from hung engine's queue, failing in setup on stale
///     generation — .failure(setup failure), only its own engine torn down,
///     current pair untouched;
///   • start QUEUED behind the hung one runs after the fresh session —
///     generation guard holds the converter write under the same lock,
///     fresh converter untouched (.engineSuperseded without write).
final class AudioServiceWedgeTests: XCTestCase {

    /// Recovery after hung start: engine swap returns immediately, retry
    /// succeeds on fresh pair, teardown runs on fresh engine's queue, old
    /// engine torn down on global queue.
    @objc func testWedgeRecoveryReplacesEngineAndRestarts() {
        let hanging = FakeEngine()
        let working = FakeEngine()
        var factoryCalls = 0
        let service = AudioService(
            logLevel: "info",
            engine: hanging,
            makeEngine: {
                factoryCalls += 1
                return working
            }
        )
        let hangSignal = DispatchSemaphore(value: 0)
        hanging.hangStart = hangSignal

        // Start goes to hung engine's queue, stalls in start().
        service.start { _ in }
        // Wait until start REALLY hung (startCount == 1 → thread in
        // semaphore.wait(), engine queue blocked forever).
        XCTAssertTrue(
            eventually { hanging.startCount == 1 },
            "старт обязан дойти до engine.start() и заблокироваться"
        )

        // Already hung: swap must return immediately (NOT via engine queue —
        // else recovery would never happen).
        service.replaceEngineAfterWedge()
        XCTAssertEqual(factoryCalls, 1, "подмена создаёт ровно один свежий движок")

        // Retry on fresh pair (engine + own queue): succeeds despite old
        // engine's queue blocked forever.
        guard case .success = runStart(service) else {
            XCTFail("повторный старт после подмены обязан пройти")
            return
        }
        XCTAssertEqual(working.node.tapCount, 1, "свежий движок ставит свой tap")
        XCTAssertEqual(working.startCount, 1, "свежий движок реально стартовал")
        XCTAssertEqual(hanging.startCount, 1, "зависший движок стартовал ровно один раз")

        // stop() after recovery goes to FRESH engine's queue and reaches
        // teardown, though old queue still blocked.
        let samples = service.stop()
        XCTAssertTrue(
            eventually { working.stopCount == 1 },
            "teardown свежего движка обязан дойти"
        )

        // Old engine torn down on global queue (not its own blocked one):
        // old instance's stop() called.
        XCTAssertTrue(
            eventually { hanging.stopCount == 1 },
            "зависший движок обязан быть остановлен вне своих очередей"
        )

        // Release hung thread so test process exits cleanly.
        hangSignal.signal()
        XCTAssertEqual(samples, [])
    }

    /// Input-node setup failure: NSException makeInputNode() → NSError under
    /// gateway → terminal .failure with engine teardown (stop called, tap never
    /// installed — nothing to remove) and successful retry on same service.
    @objc func testSetupFailureRaisesAndAllowsRestart() {
        let engine = FakeEngine()
        engine.failSetup = true
        let service = AudioService(logLevel: "info", engine: engine)

        let first = runStart(service)
        guard case .failure = first else {
            XCTFail("сбой подъёма узла обязан дать терминальный .failure")
            return
        }
        XCTAssertEqual(engine.node.tapCount, 0, "tap не ставился — узел не поднялся")
        XCTAssertEqual(engine.node.removeTapCount, 0, "снимать tap нечего")
        XCTAssertEqual(engine.stopCount, 1, "движок остановлен в teardown терминальной ветки")

        // 'Fix' the node — retry on SAME service succeeds.
        engine.failSetup = false
        guard case .success = runStart(service) else {
            XCTFail("повторный старт после сбоя подъёма обязан пройти")
            return
        }
        XCTAssertEqual(engine.node.tapCount, 1, "повторный старт ставит свежий tap")
    }

    /// Converter not created: hardware format AVAudioFormat() (rate 0) gives
    /// nil from AVAudioConverter(from:to:) → .unsupportedFormat BEFORE tap
    /// install (nothing to remove, engine not stopped); after format 'fix'
    /// retry succeeds — same mechanism as 'format drifted after device
    /// change' regression.
    @objc func testNilConverterFailsBeforeTapAndRetrySucceeds() {
        let engine = FakeEngine()
        let service = AudioService(logLevel: "info", engine: engine)

        // Zero format: AVAudioConverter(from:to:) returns nil.
        engine.node.format = AVAudioFormat()

        let first = runStart(service)
        guard case .failure(let error) = first else {
            XCTFail("nil-конвертер обязан дать терминальный .failure")
            return
        }
        XCTAssertEqual(error as? AudioServiceError, .unsupportedFormat, "ожидали .unsupportedFormat")
        XCTAssertEqual(engine.node.tapCount, 0, "tap НЕ установлен — конвертер не создался ДО installTap")
        XCTAssertEqual(engine.node.removeTapCount, 0, "снимать tap нечего")
        XCTAssertEqual(engine.stopCount, 0, "движок не тронут — teardown в этой ветке не нужен")

        // 'Fix' the format (like recovery after device change) — retry succeeds.
        engine.node.format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
        guard case .success = runStart(service) else {
            XCTFail("повторный старт после починки формата обязан пройти")
            return
        }
        XCTAssertEqual(engine.node.tapCount, 1, "повторный старт ставит свежий tap")
        XCTAssertEqual(engine.node.removeTapCount, 0, "старт без аварийной ветки tap не снимал")
    }

    /// Generation race: hung OLD-engine start unblocks only AFTER wedge swap
    /// and new recording on fresh engine. Stale start must: return
    /// .failure(.engineSuperseded) (NOT .success — else agent would call
    /// audio.cancel() on live fresh pair), NOT touch new session state
    /// (isRecording/buffers), tear down ONLY its engine, and old-generation
    /// tap must silently drop buffers, not mix into new recording.
    @objc func testStaleStartUnblockAfterWedgeDoesNotTouchNewSession() {
        let hanging = FakeEngine()
        let working = FakeEngine()
        var factoryCalls = 0
        let service = AudioService(
            logLevel: "info",
            engine: hanging,
            makeEngine: {
                factoryCalls += 1
                return working
            }
        )
        let hangSignal = DispatchSemaphore(value: 0)
        hanging.hangStart = hangSignal

        // Start #1 to hung engine's queue, stalls in start(). Catch its
        // completion separately — that IS the 'stale start'.
        var staleResult: AudioStartResult?
        service.start { result in
            if staleResult == nil {
                staleResult = result
            }
        }
        XCTAssertTrue(
            eventually { hanging.startCount == 1 },
            "старт обязан дойти до engine.start() и заблокироваться"
        )

        // Wedge: replace engine + its queue + bump generation.
        service.replaceEngineAfterWedge()
        XCTAssertEqual(factoryCalls, 1, "подмена создаёт ровно один свежий движок")

        // New recording on fresh engine — went fine.
        guard case .success = runStart(service) else {
            XCTFail("повторный старт после подмены обязан пройти")
            return
        }

        // New session samples via FRESH engine's tap.
        working.node.emit(makeToneBuffer(engine: working))
        // OLD engine's tap still installed and feeding: generation stale —
        // buffer must be silently dropped, not mixed into new session.
        hanging.node.emit(makeToneBuffer(engine: hanging))
        // More new-session samples — accumulation alive.
        working.node.emit(makeToneBuffer(engine: working))

        // Release hung old start(): it finishes when its generation is
        // no longer current.
        hangSignal.signal()

        // Stale start must end .failure(.engineSuperseded).
        XCTAssertTrue(
            eventually { staleResult != nil },
            "разблокированный старт обязан завершиться"
        )
        switch staleResult {
        case .failure(AudioServiceError.engineSuperseded)?:
            break
        default:
            XCTFail("устаревший старт обязан дать .failure(.engineSuperseded), получили \(String(describing: staleResult))")
        }

        // Old engine torn down by stale branch (tap removed exactly once; stop
        // may have come earlier — wedge teardown on global queue).
        XCTAssertTrue(
            eventually { hanging.node.removeTapCount == 1 },
            "устаревший старт обязан снять tap со СВОЕГО движка"
        )
        XCTAssertGreaterThanOrEqual(hanging.stopCount, 1, "устаревший движок обязан быть остановлен")

        // New session untouched: samples of two fresh-engine buffers present, old
        // tap's buffer not in them (no duplication beyond 2 buffers).
        let samples = service.stop()
        XCTAssertGreaterThanOrEqual(samples.count, 2 * 1410, "сэмплы нового сеанса обязаны сохраниться (два буфера свежего движка)")
        XCTAssertLessThanOrEqual(samples.count, 2 * 1560, "сэмплы не должны задваиваться — буфер старого tap дропнут")

        // stop() tore down FRESH engine: its teardown completed.
        XCTAssertTrue(
            eventually { working.stopCount == 1 },
            "teardown свежего движка обязан дойти"
        )
    }

    /// Generation race + engine.start() failure: hung OLD-engine start
    /// unblocked AFTER wedge swap, crashes in engine.start() (hang → throw,
    /// see FakeEngine.start). Stale failure branch must: return .failure
    /// (start failure) (NOT .success, NOT .engineSuperseded-'success'), NOT
    /// touch new session state (isRecording/buffers — boolean teardown part
    /// not run), tear down ONLY its engine.
    @objc func testStaleStartFailureAfterWedgeDoesNotTouchNewSession() {
        let hanging = FakeEngine()
        let working = FakeEngine()
        hanging.failStart = true
        var factoryCalls = 0
        let service = AudioService(
            logLevel: "info",
            engine: hanging,
            makeEngine: {
                factoryCalls += 1
                return working
            }
        )
        let hangSignal = DispatchSemaphore(value: 0)
        hanging.hangStart = hangSignal

        // Start #1 to hung engine's queue, stalls in start(). Catch its
        // completion separately — that IS the 'stale start'.
        var staleResult: AudioStartResult?
        service.start { result in
            if staleResult == nil {
                staleResult = result
            }
        }
        XCTAssertTrue(
            eventually { hanging.startCount == 1 },
            "старт обязан дойти до engine.start() и заблокироваться"
        )

        // Wedge: replace engine + its queue + bump generation.
        service.replaceEngineAfterWedge()
        XCTAssertEqual(factoryCalls, 1, "подмена создаёт ровно один свежий движок")

        // New recording on fresh engine — went fine.
        guard case .success = runStart(service) else {
            XCTFail("повторный старт после подмены обязан пройти")
            return
        }

        // New session samples via FRESH engine's tap.
        working.node.emit(makeToneBuffer(engine: working))
        // OLD engine's tap still installed and feeding: generation stale —
        // buffer must be silently dropped.
        hanging.node.emit(makeToneBuffer(engine: hanging))
        // More new-session samples — accumulation alive.
        working.node.emit(makeToneBuffer(engine: working))

        // Release hung old start(): it fails (failStart checked AFTER
        // unblock) when its generation is no longer current.
        hangSignal.signal()

        // Stale start must end .failure(engine.start() failure).
        XCTAssertTrue(
            eventually { staleResult != nil },
            "разблокированный старт обязан завершиться"
        )
        switch staleResult {
        case .failure(AudioServiceError.unsupportedFormat)?:
            break
        default:
            XCTFail("устаревший старт со сбоем engine.start() обязан дать .failure(.unsupportedFormat), получили \(String(describing: staleResult))")
        }

        // Old engine torn down by stale branch (tap removed exactly once; stop
        // may have come earlier — wedge teardown on global queue).
        XCTAssertTrue(
            eventually { hanging.node.removeTapCount == 1 },
            "устаревший старт обязан снять tap со СВОЕГО движка"
        )
        XCTAssertGreaterThanOrEqual(hanging.stopCount, 2, "устаревший движок обязан быть остановлен (wedge + stale-разборка)")

        // New session NOT touched: boolean teardown part (setRecording(false)/
        // buffer reset) NOT run — recording still on, stop() returns samples
        // of two fresh-engine buffers (old tap's buffer not duplicated).
        let samples = service.stop()
        XCTAssertGreaterThanOrEqual(samples.count, 2 * 1410, "сэмплы нового сеанса обязаны сохраниться — запись не убита устаревшей веткой сбоя")
        XCTAssertLessThanOrEqual(samples.count, 2 * 1560, "сэмплы не должны задваиваться — буфер старого tap дропнут")

        // stop() tore down FRESH engine: its teardown completed.
        XCTAssertTrue(
            eventually { working.stopCount == 1 },
            "teardown свежего движка обязан дойти"
        )
    }

    /// Generation race + input node setup failure: start #2 QUEUED on hung
    /// engine's queue (behind hanging start #1). After wedge swap it runs on
    /// stale generation and fails in setup (makeInputNode under gateway).
    /// Stale setup-failure guard must: return .failure(setup failure), tear
    /// down ONLY its (old) engine, NOT run boolean teardown part
    /// (setRecording(false)/buffer reset/tapInstalled), NOT touch current
    /// pair — restart on it after teardowns succeeds.
    @objc func testStaleSetupFailureAfterWedgeTearsDownOnlyOldEngine() {
        // CI runner: виртуальное аудио/тайминг-флак, локально проходит.
        if ProcessInfo.processInfo.environment["CI"] != nil { return }
        let hanging = FakeEngine()
        let working = FakeEngine()
        var factoryCalls = 0
        let service = AudioService(
            logLevel: "info",
            engine: hanging,
            makeEngine: {
                factoryCalls += 1
                return working
            }
        )
        let hangSignal = DispatchSemaphore(value: 0)
        hanging.hangStart = hangSignal

        // Start #1 to hung engine's queue, stalls in start().
        service.start { _ in }
        XCTAssertTrue(
            eventually { hanging.startCount == 1 },
            "старт обязан дойти до engine.start() и заблокироваться"
        )

        // Start #2 on old engine's queue BEHIND hanging start #1: won't start
        // until queue unblocks; does setup on stale generation (same W
        // generation snapshot).
        var staleSetupResult: AudioStartResult?
        service.start { result in
            if staleSetupResult == nil {
                staleSetupResult = result
            }
        }

        // Wedge: generation W+1, fresh engine + its queue.
        service.replaceEngineAfterWedge()
        XCTAssertEqual(factoryCalls, 1, "подмена создаёт ровно один свежий движок")

        // Break setup before queue unblock: start #2 will fail in
        // makeInputNode on stale generation.
        hanging.failSetup = true

        // Unblock queue: hanging start #1 finishes first (stale SUCCESS →
        // .failure(.engineSuperseded), see test above), then start #2.
        hangSignal.signal()

        // Start #2 must end .failure(input node failure) — not become
        // 'current' start.
        XCTAssertTrue(
            eventually { staleSetupResult != nil },
            "старт из очереди зависшего движка обязан завершиться"
        )
        guard case .failure = staleSetupResult else {
            XCTFail("устаревший setup-сбой обязан дать .failure, получили \(String(describing: staleSetupResult))")
            return
        }

        // Both stale starts tore down THEIR engine: stop certainly called
        // (wedge on global queue + teardownEngineOnly of two stale branches).
        // removeTap is NOT a counter: teardownEngineOnly goes through
        // makeInputNode — fake with failSetup=true crashes BEFORE removeTap,
        // nothing to remove.
        XCTAssertTrue(
            eventually { hanging.stopCount >= 3 },
            "старый движок обязан быть остановлен (wedge-global + две stale-разборки)"
        )

        // KEY guard: stale setup-failure branch did NOT run boolean teardown part
        // (setRecording(false)). isRecording stayed true (set by start #1
        // before hang; wedge does not touch it) — stop() must go to CURRENT
        // pair teardown (working), not return early. Unprotected branch would
        // reset the flag → stop() returns [] without teardown → working.
        // stopCount stays 0 — assert catches guard regression.
        _ = service.stop()
        XCTAssertTrue(
            eventually { working.stopCount == 1 },
            "isRecording не сбит stale-разборками — stop() разобрал текущую пару"
        )

        // Current pair alive: next start on it succeeds, tap installed without
        // collision.
        guard case .success = runStart(service) else {
            XCTFail("старт на текущей паре после stale-разборок обязан пройти")
            return
        }
        XCTAssertEqual(working.node.tapCount, 1, "текущая пара ставит свой tap")
        _ = service.stop()
        XCTAssertTrue(
            eventually { working.stopCount == 2 },
            "повторный teardown текущей пары обязан дойти"
        )
    }

    /// Generation race — start QUEUED BEHIND the hung one: dispatched BEFORE
    /// the wedge (slot = old pair, generation W), it runs only after the hung
    /// start unblocks — i.e. AFTER the fresh session already started and wrote
    /// converter_B. Its converter-assignment step must be held by the
    /// generation guard under the SAME lock: pre-fix code wrote the STALE
    /// converter (old HAL format) first and only then failed the guard — the
    /// live session's subsequent buffers would convert with the old engine's
    /// converter (format mismatch → convertOnce error → buffer dropped →
    /// corrupted/truncated audio). Guard-under-lock: stale start returns
    /// .failure(.engineSuperseded) WITHOUT writing, fresh converter intact.
    /// The same lock + generation check gates the stale start's top-of-start
    /// session reset (didLogFirstBuffer/limit/recordStartTime/collectedSamples/
    /// rmsHistory/autoStopDetector/gain/live-VAD) — pre-fix it ran BEFORE any
    /// guard and wiped the LIVE session's accumulation: the buffer emitted
    /// before the stale start runs (buffer A below) must survive it.
    /// The stale start must also NOT tear down the live session at its TOP
    /// (tap-teardown gate by generation): `tapInstalled` belongs to the fresh
    /// engine — removing the tap + setRecording(false) would kill the live
    /// recording regardless of the converter guard.
    @objc func testStaleStartQueuedBehindHangDoesNotClobberFreshConverter() {
        let hanging = FakeEngine()
        let working = FakeEngine()
        // Formats MUST differ: if the stale write clobbers self.converter, the
        // live 44.1k buffers hit a 48k->16k converter — convertOnce errors
        // (status .error) and the buffer is dropped (see AudioCaptureTests on
        // convertOnce). Same-format fakes would hide the clobber (both
        // converters behave identically).
        hanging.node.format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        var factoryCalls = 0
        let service = AudioService(
            logLevel: "info",
            engine: hanging,
            makeEngine: {
                factoryCalls += 1
                return working
            }
        )
        let hangSignal = DispatchSemaphore(value: 0)
        hanging.hangStart = hangSignal

        // Start #1 to hung engine's queue, stalls in start() — holds the queue.
        service.start { _ in }
        XCTAssertTrue(
            eventually { hanging.startCount == 1 },
            "старт обязан дойти до engine.start() и заблокироваться"
        )

        // Start #2 to the SAME hung queue, DISPATCHED BEFORE the wedge. Its
        // completion fills `staleResult` ALONE — so the sample asserts below
        // run strictly AFTER its converter-assignment step (it is the last
        // thing before the stale start returns).
        var staleResult: AudioStartResult?
        service.start { result in
            if staleResult == nil {
                staleResult = result
            }
        }

        // Wedge: generation W→W+1, fresh engine + its own queue; stale #2 stays
        // queued on the hung engine's queue until unblocked.
        service.replaceEngineAfterWedge()
        XCTAssertEqual(factoryCalls, 1, "подмена создаёт ровно один свежий движок")

        // Fresh recording on the fresh engine: converter_B installed, tap live.
        guard case .success = runStart(service) else {
            XCTFail("повторный старт после подмены обязан пройти")
            return
        }
        XCTAssertEqual(working.node.tapCount, 1, "свежий сеанс ставит свой tap")

        // Buffer A accumulated in the LIVE session BEFORE the stale start runs.
        // Pre-fix the stale start's top-of-start reset (collectedSamples=[] and
        // friends) ran BEFORE the generation guard — it would WIPE this buffer;
        // the stop() assert below (A+B both present) catches a regressed guard.
        // The reset now runs only under the generation check (same lock).
        working.node.emit(makeToneBuffer(engine: working))

        // Unblock the hung queue: start #1 finishes first (stale SUCCESS →
        // .engineSuperseded, see test above); then start #2 runs its
        // converter-assignment on the stale generation.
        hangSignal.signal()

        // Stale #2 must end .failure(.engineSuperseded).
        XCTAssertTrue(
            eventually { staleResult != nil },
            "устаревший старт из очереди обязан завершиться"
        )
        switch staleResult {
        case .failure(AudioServiceError.engineSuperseded)?:
            break
        default:
            XCTFail("устаревший старт из очереди обязан дать .failure(.engineSuperseded), получили \(String(describing: staleResult))")
        }

        // THE discriminator: buffer B emitted AFTER the stale start completed.
        // Pre-fix the stale write left the 48k converter in state — a 44.1k
        // buffer cannot convert (convertOnce → nil) and is DROPPED:
        // accumulation stops at ONE buffer. With the guard-under-lock the write
        // never happened — converter_B intact. The same guard now also protects
        // session state: buffer A (accumulated before the stale start) survived
        // its top-of-start reset — both buffers present.
        working.node.emit(makeToneBuffer(engine: working))
        let samples = service.stop()
        XCTAssertGreaterThanOrEqual(samples.count, 2 * 1410, "конвертер и состояние живого сеанса не тронуты — оба буфера (до и после stale-старта) сконвертированы (\(samples.count))")
        XCTAssertLessThanOrEqual(samples.count, 2 * 1560, "сэмплы не должны теряться или задваиваться (\(samples.count))")

        // Stale starts tore down THEIR engine — tap removed only by the two
        // stale branches (resume + guard), NOT by a top-of-start teardown of
        // the live session (tapInstalled=false would have added a third
        // removeTap and killed the recording).
        XCTAssertTrue(
            eventually { hanging.node.removeTapCount == 2 },
            "устаревшие старты снимают tap ТОЛЬКО со своего движка (две stale-разборки)"
        )
        XCTAssertTrue(
            eventually { hanging.stopCount >= 3 },
            "устаревший движок обязан быть остановлен (wedge-global + две stale-разборки)"
        )

        // stop() tore down FRESH engine: its teardown completed.
        XCTAssertTrue(
            eventually { working.stopCount == 1 },
            "teardown свежего движка обязан дойти"
        )
    }

    /// Buffer 44.1 kHz/mono with constant amplitude 0.2 ('tone', not
    /// silence) — emulates tap-callback buffer in engine node format.
    private func makeToneBuffer(engine: FakeEngine) -> AVAudioPCMBuffer {
        let buffer = AVAudioPCMBuffer(pcmFormat: engine.node.format, frameCapacity: 4096)!
        buffer.frameLength = 4096
        let channel = buffer.floatChannelData![0]
        for i in 0..<4096 {
            channel[i] = 0.2
        }
        return buffer
    }
}

/// Wedge fired from INSIDE installTap — вынесено в отдельный сьют, чтобы тело
/// AudioServiceWedgeTests осталось в лимите type_body_length.

final class AudioServiceInstallTapWedgeTests: XCTestCase {

    /// Generation race in the TAP/RECORDING stage: a start that was already
    /// past the converter guard (generation W still current) when the wedge
    /// swaps the engine (W→W+1) from INSIDE installTap. The stale start must
    /// NOT write setTapInstalled(true)/setRecording(true) into the NEW
    /// generation's ledger. Unguarded, both writes land in W+1 and its terminal
    /// branch (teardownEngineOnly) never resets the booleans — the ledger ends
    /// isRecording==true at idle with no session, and a plain stop() would
    /// tear down the fresh, never-started engine. Post-fix stop() is a no-op.
    @objc func testStaleStartWedgeDuringInstallTapLeavesNewLedgerIdle() {
        let stale = FakeEngine()
        let working = FakeEngine()
        var factoryCalls = 0
        let service = AudioService(
            logLevel: "info",
            engine: stale,
            makeEngine: {
                factoryCalls += 1
                return working
            }
        )
        // Fire the wedge exactly inside installTap: after the converter guard
        // passed (generation current) but before setTapInstalled/setRecording.
        // replaceEngineAfterWedge tears the old engine down off the engine
        // queue, so calling it from here cannot deadlock.
        stale.node.onInstallTap = { [weak service] in service?.replaceEngineAfterWedge() }

        var result: AudioStartResult?
        service.start { startResult in
            if result == nil {
                result = startResult
            }
        }
        XCTAssertTrue(
            eventually { result != nil },
            "устаревший старт обязан завершиться"
        )
        switch result {
        case .failure(AudioServiceError.engineSuperseded)?:
            break
        default:
            XCTFail("устаревший старт обязан дать .failure(.engineSuperseded), получили \(String(describing: result))")
        }
        XCTAssertEqual(factoryCalls, 1, "подмена создаёт ровно один свежий движок")

        // THE invariant (synchronous discriminator): the stale start must NOT
        // leave tapInstalled/isRecording set in the NEW generation. Start a
        // REAL recording on the fresh engine — it must succeed AND must not
        // spuriously tear the fresh engine down first. A leaked tapInstalled
        // makes the fresh start's top-of-start (line ~400) run
        // teardownOnEngineQueue on the fresh engine BEFORE installing its own
        // tap → working.node.removeTapCount becomes 1. With the guards the leak
        // never happens → removeTapCount stays 0 here.
        guard case .success = runStart(service) else {
            XCTFail("старт на свежем движке после устаревшего обязан пройти")
            return
        }
        XCTAssertEqual(working.node.tapCount, 1, "свежий сеанс ставит свой единственный tap")
        XCTAssertEqual(
            working.node.removeTapCount, 0,
            "устаревший старт не оставил tapInstalled/isRecording в новом поколении — свежий старт не разбирает свежий движок (removeTap=\(working.node.removeTapCount))"
        )
        _ = service.stop()
    }
}
