import Foundation
import AVFoundation
import AudioEngineGuard
@testable import NanoDictateCore

/// Тесты live-VAD в AudioService (живая пошаговая диктовка, task #112).
/// Железа нет — фейковый движок (тот же паттерн, что AudioServiceLifecycleTests).
///
/// Проверяется:
///   • пауза ≥ pauseDuration закрывает уттеренс — сегмент отдаётся КОПИЕЙ,
///     общий буфер записи не трогается (stop() вернёт ВСЮ запись);
///   • короткая пауза — внутренний пробел, уттеренс живёт;
///   • stop() отдаёт «хвост» незакрытого уттеренса (isTail == true), и только
///     если речь реально шла; cancel() не отдаёт ничего;
///   • принудительный стоп по лимиту: «хвост» доставляется ДО колбэка лимита;
///   • VAD сбрасывается между сегментами одного сеанса и между сеансами.
///
/// Pre-/post-roll (задача #139):
///   • pre-roll 0.5 c: тишина перед первым словом не срезается; отступ НЕ
///     заезжает в уже доставленный сегмент (клампится liveLastCutIndex);
///   • пост-ролл 0.25 c: к последней речи добавляется тишина без раздувания
///     паузой и без выхода за конец записи; «хвост» stop() — БЕЗ пост-ролла;
///   • граничная пауза: ровно на livePauseSamples уттеренс закрывается; чуть
///     меньше — продолжается, новая речь его продлевает (второго уттеренса не
///     открывается); ПОСЛЕ закрытия новая речь открывает НОВЫЙ уттеренс —
///     вторая порция доставляется отдельным сегментом (живая диктовка).
///
/// Замечание о буферных счётчиках: после скачка амплитуды 0.2 → 0.001
/// пересэмплер (AVAudioConverter) «звенит» — первый буфер тишины после речи
/// имеет RMS ≈ 0.013 > порога 0.00316 и уходит в речевую ветку. Поэтому
/// закрывающая пауза «начинается» со ВТОРОГО буфера тишины: 4 чистых буфера
/// дают накопление 3×1486 ≈ 4458 ≥ 3200. В проде это добавляет к паузе одну
/// задержку буфера (~90 мс) — несущественно; тесты закладывают запас.
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

        /// Эмитирует один буфер из tap-колбэка (в проде это делает аудио-поток).
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

    /// Сервис live-VAD с настраиваемой паузой закрытия: тестовый буфер
    /// 4096 фр. @44.1 кГц ≈ 1486 сэмплов @16 кГц; пауза 0.2 c = порог 3200
    /// сэмплов (накрывается тремя чистыми буферами тишины). Пауза 1.0 c =
    /// порог 16000 сэмплов — больше пост-ролла (4000), нужна для проверки
    /// точной границы пост-ролла без клампинга концом буфера. `autoStop` —
    /// конфигурация автоостановки по тишине (по умолчанию `.defaults`).
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

    /// Константный буфер: RMS = |amplitude|. Речь — 0.2 (» порог 0.00316),
    /// тишина — 0.001 (« порог).
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

    /// Первый сэмпл с |амплитудой| ≥ threshold — для калибровки pre-roll-отступа
    /// по фактическому (а не предполагаемому) числу сэмплов в буфере.
    private func firstLoudIndex(_ samples: [Int16], threshold: Int = 1000) -> Int? {
        samples.firstIndex { abs(Int($0)) >= threshold }
    }

    /// Ищет сдвиг окна записи, при котором оно в среднем равно сегменту:
    /// максимизирует долю сэмплов, сошедшихся по знаку с речью (амплитуда 6553)
    /// и с тишиной (32) одновременно — нормировка на максимум в окне делает
    /// критерий устойчивым к ±джиттеру тайминга VAD (единицы сэмплов).
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

    /// Речь 2 буфера → пауза 6 буферов (≥ pauseDuration с учётом «звонящего»
    /// первого буфера тишины): ровно один сегмент, границы = речевые сэмплы
    /// (без тишины паузы). Сегмент — КОПИЯ: общий буфер не тронут, stop()
    /// возвращает всю запись, префикс которой равен сегменту, а хвост — тишина.
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
        // 2 буфера речи + звонящий первый буфер тишины (~3 × 1486) + пост-ролл
        // 0.25 c (4000 сэмплов) — хвост последнего слова не срезается. Пост-ролл
        // меньше остатка паузы (кламп концом буфера здесь не задевается), поэтому
        // сегмент — префикс записи, а не вся запись.
        XCTAssertTrue(seg.count > 2600, "сегмент = речевой блок")
        XCTAssertTrue(seg.count > 7800, "пост-ролл 0.25 c тишины добавлен к речи")
        XCTAssertTrue(seg.count < 9100, "сегмент не раздувается всей паузой (> пост-ролла)")

        // stop(): вся запись (речь + пауза) цела, префикс = сегмент.
        let samples = service.stop()
        XCTAssertTrue(samples.count > seg.count, "stop() отдаёт всю запись, сегмент — её префикс")
        XCTAssertEqual(Array(samples.prefix(seg.count)), seg, "речевые сэмплы в общем буфере не пострадали")
        let tailPart = samples.dropFirst(seg.count)
        XCTAssertTrue(tailPart.allSatisfy { abs(Int($0)) < 100 }, "хвост записи — тишина паузы")
    }

    /// Пауза короче pauseDuration — внутренний пробел: уттеренс не рвётся,
    /// «вздох» между фразами не тайкнет сегмент. Речь 2 → пауза 2 →
    /// речь 2 → пауза 6: ОДИН сегмент (речь + внутренний пробел), хвоста нет.
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
        emit(engine, amplitude: 0.001, count: 2)  // < pauseDuration — внутренний пробел
        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 6)  // ≥ pauseDuration — закрывает

        XCTAssertEqual(box.deliveries.count, 1, "внутренний пробел не рвёт уттеренс")
        XCTAssertFalse(box.deliveries[0].isTail)
        let seg = box.deliveries[0].samples
        // 4 буфера речи + «звон» пересэмплера (~3–6 × 1486) + пост-ролл 4000.
        // Обе порции речи — ОДИН сегмент (иначе было бы 2 доставки), длинная
        // завершающая пауза в сегмент целиком не попадает (пост-ролл обрезан).
        // Фактический замер на звоне: 15882 (вариант со звенящим закрытием) и
        // 14396 (вариант с чистой тишиной) — диапазон накрывает оба.
        XCTAssertTrue(seg.count > 13900, "сегмент включает и речь после пробела, и пост-ролл")
        XCTAssertTrue(seg.count < 17000, "сегмент не включает длинную паузу")

        // Уттеренс уже закрыт длинной паузой — при стопе «хвоста» нет.
        _ = service.stop()
        XCTAssertEqual(box.deliveries.count, 1)
    }

    // MARK: - «Хвост» stop() и cancel()

    /// Незакрытый уттеренс при stop() доставляется как последний сегмент
    /// (isTail == true) — сэмплы без хвостовой тишины. Тишина без речи
    /// «хвоста» не даёт.
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

        // Новый сеанс, только тишина: уттеренс не начинался — «хвост» не
        // доставляется (бесполезный STT-запрос пустоты не отправляется).
        guard runStart(service) else {
            XCTFail("повторный старт должен пройти", file: #file, line: #line)
            return
        }
        emit(engine, amplitude: 0.001, count: 3)
        _ = service.stop()
        XCTAssertEqual(box.deliveries.count, 1, "тишина без речи не даёт ни сегмента, ни хвоста")
    }

    /// Esc (cancel()): данные отбрасываются целиком — ни сегмента, ни хвоста,
    /// даже если речь шла (и уттеренс был открыт).
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

    /// Непрерывная речь до жёсткого лимита объёма (960 000 сэмплов): «хвост»
    /// (isTail == true) доставляется ДО колбэка onRecordingLimitReached —
    /// клиент успевает поставить его в очередь распознавания раньше финализации.
    @objc func testLimitStopDeliversTailBeforeLimitCallback() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine)
        // Единый журнал событий: порядок «хвост → лимит» критичен для живой
        // диктовки (серийный исполнитель Agent'а обязан увидеть хвост первым).
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

        // ~1486 сэмплов на буфер: 650 буферов гарантированно переходят порог
        // 960 000 (последний буфер обрезается лимитом; elapsed ≪ 60 с).
        emit(engine, amplitude: 0.2, count: 650)
        wait(for: [limitDone], timeout: 5)

        XCTAssertEqual(events, ["tail", "limit"], "хвост обязан встать в очередь до финализации записи")
    }

    // MARK: - Принудительный стоп по непрерывной тишине (автоостановка ~3 c)

    /// Непрерывная тишина ≥ 3 c в активной записи останавливает её тем же
    /// путём, что лимит: onAutoStop вызывается на главной очереди с собранными
    /// сэмплами. Кадр: буфер 4096 фр. @44.1 кГц ≈ 1486 сэмплов @16 кГц ≈ 0.093 c;
    /// порог 3.0 c накрывается ~33 тихими буферами (~3.1 c).
    ///
    /// Вход FakeEngine — буферы КОНСТАНТНОЙ амплитуды 0.001 (≪ порога 0.00316):
    /// микрофонного «звона» тут нет. Единственная оговорка — ресэмплер
    /// AVAudioConverter после скачка амплитуды 0.2 → 0.001 может «звенеть»
    /// первый конвертированный буфер (RMS ≈ 0.013 > порога) — тогда он
    /// уходит в речевую ветку и не накапливается (примечание в шапке файла).
    /// 45 буферов тишины (≈ 4.2 c) дают большой запас поверх ~33 в любом
    /// случае: срабатывание не зависит от этой детали.
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

        // Речь 2 буфера → тишина 45 буферов (~4 c): автоостановка срабатывает
        // на ~33-м чистом тихом буфере; оставшиеся буферы отбрасываются
        // early-выходом (autoStopScheduled). Элapsed ≪ 60 c — лимит не мешает.
        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 45)
        wait(for: [autoStopDone], timeout: 5)

        XCTAssertTrue(autoStopSamples.count > 2000, "в onAutoStop приходят собранные сэмплы записи, а не пусто")
        XCTAssertTrue(autoStopSamples.count <= 47 * 1486 + 4096, "снимок не раздут: буферы после срабатывания не дописываются")
        // 3 секунды тишины полностью «съедают» уттеренс закрытием по паузе
        // live-VAD (0.2 c у хелпера; в проде — 1.0 c): к моменту автоостановки
        // открытого уттеренса нет — хвост не доставляется, это правильное
        // поведение (см. handleAutoStop: в live-диктовке финальный проход
        // работает по снимку, хвост не участвует).
        XCTAssertEqual(tailDeliveries, 0, "при автоостановке открытого уттеренса быть не может: речь была >3 c назад")
        XCTAssertGreaterThanOrEqual(segmentDeliveries, 1, "уттеренс закрыт live-VAD по паузе ещё ДО автоостановки")
    }

    /// Пауза короче 3 c запись НЕ останавливает: тишина в 6 буферов (~0.5 c)
    /// не добирает порог, после неё продолжается речь, и только явный stop()
    /// завершает запись со ВСЕМ собранным (включая речь ПОСЛЕ паузы) — фича
    /// не рвёт запись на задумчивой паузе внутри диктовки.
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

        // Речь 2 → пауза 6 буферов (~0.5 c тишины; если первый после скачка
        // амплитуды «звенит» на ресэмплере — ~0.46 c, всё равно ≪ 3 c)
        // → снова речь 2.
        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 6)
        emit(engine, amplitude: 0.2, count: 2)
        // Явный стоп: не даёт дождаться никакой автоостановки — всё синхронно.
        let samples = service.stop()

        XCTAssertFalse(autoStopFired, "короткая пауза (< 3 c) не останавливает запись")
        // Хвост покрывает обе порции речи (пауза 0.5 c < pause 1.0 c — один
        // уттеренс, с pre-roll / пост-роллом в границах).
        XCTAssertEqual(tails.count, 1, "стоп отдаёт один незакрытый уттеренс")
        XCTAssertTrue(tails[0].count > 5000, "уттеренс включает речь ПОСЛЕ паузы")
        XCTAssertTrue(samples.count > 4000, "stop возвращает всю запись (речь + пауза)")
    }

    /// Рубильник: конфиг с enabled == false не останавливает запись даже после
    /// тишины ~4.2 c (45 буферов) — запись живёт до явного стопа. Спасательный
    /// люк для шумного окружения/длинных диктовок; дефолт не меняется
    /// (ср. testContinuousSilenceTriggersAutoStop с конфигом по умолчанию).
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

        // Речь 2 буфера → тишина 45 буферов (~4.2 c): при выключенной фиче
        // тишина НЕ завершает запись — итог подводит явный stop().
        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 45)
        let samples = service.stop()

        XCTAssertFalse(autoStopFired, "выключенная фича не останавливает запись по тишине")
        // Тишина 4.2 c ≫ пауза live-VAD 0.2 c — уттеренс закрылся обычным путём
        // сегментации (это работает независимо от автоостановки).
        XCTAssertGreaterThanOrEqual(segmentDeliveries, 1, "уттеренс закрыт live-VAD по паузе ещё до stop")
        // Полная запись 47 буферов ≈ 69839 сэмплов: ресэмплер AVAudioConverter
        // жертвует ~3 сэмпла на priming, поэтому строгая граница «47 × 1486»
        // (69842) физически недостижима. Нижняя граница «47 × 1480» с запасом
        // на джиттер конвертера доказывает, что в снимок вошли ВСЕ 47 буферов
        // (~4.4 c) — никакая автоостановка запись не обрезала.
        XCTAssertTrue(samples.count >= 47 * 1480, "stop возвращает всю запись, включая длинную тишину: \(samples.count)")
    }

    // MARK: - Сброс VAD между сегментами и между сеансами

    /// Два уттеренса в одном сеансе: после доставки сегмента VAD сбрасывается —
    /// второй сегмент начинается со своего речевого блока (не срастается со
    /// старым). Новый сеанс тоже стартует с чистых границ.
    @objc func testVADResetsAfterDeliveryAndAcrossCycles() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        // Сеанс 1: уттеренс 1 (речь 2 → пауза 6), уттеренс 2 (речь 2 → пауза 6).
        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 6)
        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 6)

        XCTAssertEqual(box.deliveries.count, 2, "два уттеренса — два сегмента")
        XCTAssertFalse(box.deliveries[0].isTail)
        XCTAssertFalse(box.deliveries[1].isTail)
        // Второй сегмент — ровно свой речевой блок (2 буфера + звон), не
        // сросшийся с первым уттеренсом (иначе был бы на тысячи сэмплов длиннее).
        let second = box.deliveries[1].samples
        // Речевой блок (~3 × 1486) + пост-ролл 4000. Граница между сегментами
        // держится ровно на liveLastCutIndex (конец пост-ролла первого сегмента),
        // поэтому второй сегмент не срастается ни с первым уттеренсом, ни с
        // тишиной паузы.
        XCTAssertTrue(second.count > 10000, "второй сегмент = свой речевой блок + пост-ролл")
        XCTAssertTrue(second.count < 13000, "второй сегмент не тащит первый уттеренс")
        let first = box.deliveries[0].samples
        XCTAssertTrue(first.count > 7500, "первый сегмент тоже самодостаточен (речь + пост-ролл)")
        XCTAssertTrue(first.count < 9100, "первый сегмент не раздувается паузой")

        // Уттеренс 2 закрыт паузой — стоп без «хвоста».
        _ = service.stop()
        XCTAssertEqual(box.deliveries.count, 2)

        // Сеанс 2: новый старт — границы чистые, «хвост» ровно одного буфера.
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

    /// Pre-roll: уттеренс начинается НЕ с первого речевого буфера, а на
    /// 0.5 c (8000 сэмплов) раньше. Тишины перед речью больше pre-roll
    /// (10 буферов ≈ 14860 > 8000) — отступ полный и не клампится нулём
    /// записи: сегмент стартует ровно за 8000 сэмплов до атаки первого
    /// слова и открывается этими 0.5 c чистой тишины.
    /// Порог firstLoudIndex — 3000 (амплитуда слова 6553), но НЕ 1000:
    /// с порогом 1000 калибровка ловит «звон» первого речевого
    /// буфера (амплитуда 32) на границе с тишиной и ошибается на блок.
    @objc func testPreRollCapturesHalfSecondOfSilenceBeforeFirstWord() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        emit(engine, amplitude: 0.001, count: 10)  // тишина до речи (> pre-roll 8000)
        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 6)   // закрывает уттеренс

        XCTAssertEqual(box.deliveries.count, 1)
        XCTAssertFalse(box.deliveries[0].isTail)
        let seg = box.deliveries[0].samples
        let samples = service.stop()

        // Калибровка по фактическому буферу: атака речи = первый сэмпл ≥ 3000
        // («звон» тишины — 32 — порог не проходит). Отступа тишины 14860 ≫ 8000,
        // поэтому pre-roll полный и клампится только нулём записи.
        guard let firstLoud = firstLoudIndex(samples, threshold: 3000) else {
            XCTFail("в записи должна быть речь", file: #file, line: #line)
            return
        }
        XCTAssertTrue(firstLoud > 8000 + 1486,
            "тишины перед речью хватает на полный pre-roll с запасом на блок")
        let expectedStart = max(0, firstLoud - 8000)
        XCTAssertTrue(expectedStart > 0, "pre-roll реально ушёл в тишину, а не начался с нуля записи")

        // Граница среза записи и граница, по которой VAD режет сегмент, могут
        // расходиться на единицы сэмплов (тайминг VAD в буферных индексах vs
        // сплошной счётчик записи) — поэтому сегмент проверяем по содержимому:
        // он должен быть окном записи вблизи expectedStart, а не точным срезом.
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

    /// Закрытие РОВНО на границе: накопление тишины 2×1486 = 2972 < 3200 —
    /// уттеренс жив; следующий же буфер доводит до 4458 ≥ 3200 — закрытие
    /// происходит ровно в этом блоке (аналог «±1 сэмпл» при крупности 1486).
    @objc func testPauseClosesExactlyAtThresholdBoundaryBlock() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        // Звонящий первый буфер тишины + 2 чистых = 2972 < 3200: не закрыт.
        emit(engine, amplitude: 0.2, count: 2)
        emit(engine, amplitude: 0.001, count: 3)
        XCTAssertEqual(box.deliveries.count, 0, "накопленная пауза < livePauseSamples — не закрыт")

        // Ещё один чистый буфер: 4458 ≥ 3200 — закрытие РОВНО в этом блоке.
        emit(engine, amplitude: 0.001, count: 1)
        XCTAssertEqual(box.deliveries.count, 1, "следующий блок тишины закрыл уттеренс сразу")
        XCTAssertFalse(box.deliveries[0].isTail)
    }

    /// Пауза «чуть меньше» порога НЕ закрывает уттеренс: новая речь после неё
    /// продолжает ТОТ ЖЕ уттеренс (единый сегмент на обе порции), второй
    /// уттеренс внутри одного живого не открывается.
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
        emit(engine, amplitude: 0.001, count: 3)  // 2972 < 3200 — НЕ закрывает
        XCTAssertEqual(box.deliveries.count, 0, "пауза чуть меньше порога — уттеренс продолжается")

        emit(engine, amplitude: 0.2, count: 2)    // речь продлевает уттеренс
        XCTAssertEqual(box.deliveries.count, 0, "новая речь внутри уттеренса — второй НЕ открывается")

        emit(engine, amplitude: 0.001, count: 6)  // закрывает
        XCTAssertEqual(box.deliveries.count, 1, "обе порции речи — один сегмент")
        let seg = box.deliveries[0].samples
        // Две порции речи (≈6×1486) + пост-ролл 4000. Диапазон 13900…17000
        // накрывает обе реализации звона закрывающей паузы (замеры 14396 и
        // 15882) и гарантирует, что продление речи учтено: без второй порции
        // сюда не дотянуться (≈8452 уже с пост-роллом).
        XCTAssertTrue(seg.count > 13900, "сегмент включает речь и ПОСЛЕ внутренней паузы")
        XCTAssertTrue(seg.count < 17000, "сегмент не включает длинную паузу")

        _ = service.stop()
        XCTAssertEqual(box.deliveries.count, 1, "уттеренс закрыт паузой — хвоста при стопе нет")
    }

    // MARK: - Ключевой сценарий живой диктовки: «и-и-и чуть-чуть ещё сказал»

    /// ПОСЛЕ закрытия (пауза ≥ порога) новая речь открывает НОВЫЙ уттеренс —
    /// вторая порция доставляется ОТДЕЛЬНЫМ сегментом, а не теряется и не
    /// сливается с первой (регресс: «сказал чуть-чуть ещё — и ничего»).
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

        emit(engine, amplitude: 0.2, count: 2)    // «чуть-чуть ещё» ПОСЛЕ закрытия
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

        // Оба сегмента закрыты паузами — стоп не даёт ни «хвоста», ни дублей.
        _ = service.stop()
        XCTAssertEqual(box.deliveries.count, 2)
    }

    /// Pre-roll не заезжает в уже доставленный сегмент: второй уттеренс после
    /// длинной паузы начинается РОВНО на liveLastCutIndex (конец пост-ролла
    /// первого), а не на sampleStart − 8000. Без клампа вторая порция началась
    /// бы на ~2,4k сэмплов раньше и задублировала доставленное аудио: проверка
    /// непрерывности по полной записи (без разрыва и наложения) это ловит.
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

    /// Точная граница пост-ролла: пауза закрытия 1.0 c (порог 16000) больше
    /// пост-ролла (4000), клампинг концом буфера не вмешивается — сегмент
    /// заканчивается ровно через 4000 сэмплов тишины после последней речи.
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
        emit(engine, amplitude: 0.001, count: 15)  // ≈ 22290 > порог 16000 — закрывает

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

    /// Границы сегмента не выходят за запись: live-сегмент — префикс записи,
    /// «хвост» стопа продолжает запись ровно со среза. Речь, дошедшая до самого
    /// конца буфера записи, уходит в «хвост» целиком (без обрезки и без
    /// пост-ролла сверх конца).
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
        emit(engine, amplitude: 0.001, count: 6)   // закрывает сегмент 1
        emit(engine, amplitude: 0.2, count: 2)     // речь до самого конца записи
        let samples = service.stop()               // стоп на открытом уттеренсе

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

    /// Пост-ролл применяется ТОЛЬКО к live-закрытию; «хвост» stop() режется по
    /// последней речи (сэмплы тишины паузы и пост-ролла в него не попадают).
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
        emit(engine, amplitude: 0.001, count: 2)  // пауза НЕ закрыла: стоп на открытом уттеренсе
        let samples = service.stop()

        XCTAssertEqual(box.deliveries.count, 1)
        XCTAssertTrue(box.deliveries[0].isTail, "незакрытый уттеренс — «хвост» stop()")
        let tail = box.deliveries[0].samples
        // Речь + звонящий буфер тишины (~3×1486). Примени пост-ролл — было бы
        // ≥5944 (весь буфер) — диапазон это ловит.
        XCTAssertTrue(tail.count > 4200 && tail.count < 4900, "«хвост» без пост-ролла")
        XCTAssertEqual(tail, Array(samples.prefix(tail.count)), "«хвост» — префикс записи")
        XCTAssertTrue(tail.count < samples.count, "тишина паузы (и пост-ролл) в «хвост» не попала")
    }

    // MARK: - Сброс liveLastCutIndex между сеансами

    /// Pre-roll-кламп liveLastCutIndex живёт ТОЛЬКО внутри сеанса: новый сеанс
    /// начинает с чистых границ. Если бы срез не сбрасывался между сеансами,
    /// «хвост» второго сеанса зажался бы старым срезом за концом буфера и вышел
    /// бы пустым (потеря первой реплики).
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
        emit(engine, amplitude: 0.001, count: 6)   // сегмент доставлен → liveLastCutIndex = пост-ролл
        XCTAssertEqual(box.deliveries.count, 1)
        _ = service.stop()                          // уттеренс закрыт паузой — «хвоста» нет

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

    /// Непрерывная речь длиннее окна (35 буферов × 1486 ≈ 52010 ≥ 48000) +
    /// микро-пауза (4 буфера тишины → с учётом звонящего первого буфера
    /// накопленные 3×1486 = 4458 ≥ 4000) → чанк доставляется РОВНО один, ДО
    /// полной паузы 1 c (4458 ≪ 16000): текст выводится, пока человек говорит.
    /// Пауза 1.0 c выбрана, чтобы полная пауза НЕ сработала раньше чанка
    /// (для дефолтной 0.2 c порог 3200 меньше микро-паузы 4000 — чанк не был
    /// бы различим от обычного закрытия).
    @objc func testContinuousSpeechDeliversChunkOnMicroPause() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine, pause: 1.0)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        emit(engine, amplitude: 0.2, count: 35)      // речь ≈ 52010 ≥ окно 48000
        emit(engine, amplitude: 0.001, count: 4)     // микро-пауза 4458 ≥ 4000

        XCTAssertEqual(box.deliveries.count, 1, "чанк доставлен на микро-паузе — ДО полной паузы 1 c")
        XCTAssertFalse(box.deliveries[0].isTail, "чанк из середины речи — не хвост")
        let seg = box.deliveries[0].samples
        // Речевой блок (35 речь + звонящий буфер тишины = 36×1486 ≈ 53496) +
        // пост-ролл 4000 ≈ 57496. Диапазон 55000…60000 не дотягивается ни без
        // пост-ролла, ни при затягивании чанка всей паузой.
        XCTAssertTrue(seg.count > 55000 && seg.count < 60000, "чанк = речь + пост-ролл 0.25 c")
        guard let attack = firstLoudIndex(seg, threshold: 3000) else {
            XCTFail("в чанке должна быть речь", file: #file, line: #line)
            return
        }
        XCTAssertTrue(attack < 100, "чанк начинается с речи — атака не срезана")
        XCTAssertTrue(seg.suffix(4000).allSatisfy { abs(Int($0)) < 100 },
            "пост-ролл 0.25 c тишины сохранён в конце чанка")
        // Чанк вырезан на микро-паузе → VAD сброшен, при стопе «хвоста» нет.
        _ = service.stop()
        XCTAssertEqual(box.deliveries.count, 1)
    }

    /// Речь КОРОЧЕ окна (10 буферов ≈ 14860 < 48000): микро-пауза 4458 ≥ 4000
    /// НЕ режет — уттеренс живёт, последующая речь продлевает ТОТ ЖЕ уттеренс
    /// (аналог testShortInternalPauseKeepsUtteranceAlive: межсловный пробел не
    /// тайкает сегмент). Закрывает только полная пауза 1 c — единый сегмент
    /// на обе порции речи.
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
        emit(engine, amplitude: 0.001, count: 4)     // микро-пауза, но речь < окна
        XCTAssertEqual(box.deliveries.count, 0, "речь < окна — микро-пауза НЕ режет")

        emit(engine, amplitude: 0.2, count: 3)       // речь продлевает ТОТ ЖЕ уттеренс
        XCTAssertEqual(box.deliveries.count, 0, "новой речи внутри живого уттеренса — второй не открывается")

        emit(engine, amplitude: 0.001, count: 12)    // ≈ 16346 ≥ 16000 — полная пауза закрывает
        XCTAssertEqual(box.deliveries.count, 1, "обе порции речи закрыты ОДНИМ сегментом")
        XCTAssertFalse(box.deliveries[0].isTail)
        let seg = box.deliveries[0].samples
        // Речь (10 + звон + 3 = 14×1486 ≈ 20804) + внутренняя пауза (4×1486)
        // + пост-ролл 4000 ≈ 30748. Диапазон 28000…33000 гарантирует, что ОБЕ
        // порции речи в сегменте (только вторая порция — ~8452, не дотянуться).
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

    /// Граница окна РОВНО: 31 буфер × 1486 = 46066 (+ звон первого буфера
    /// тишины 1486 = 47552) < 48000 — микро-пауза НЕ режет, уттеренс живёт;
    /// следующий буфер речи доводит накопление до 49038 ≥ 48000 — ближайшая
    /// микро-пауза режет чанк. Обе стороны границы «48000 ± буфер» в одном
    /// тесте: ниже — молчание, от пересечения — доставка.
    @objc func testChunkBoundaryExactlyAtWindow() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine, pause: 1.0)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        // 31 буфер речи = 46066, + звон = 47552 < 48000: до окна не дотянулись.
        emit(engine, amplitude: 0.2, count: 31)
        emit(engine, amplitude: 0.001, count: 4)     // микро-пауза 4458 ≥ 4000
        XCTAssertEqual(box.deliveries.count, 0, "накопленная речь чуть ниже окна — микро-пауза не режет")

        // +1 буфер речи: 49038 ≥ 48000 — окно пересечено, микро-пауза режет.
        emit(engine, amplitude: 0.2, count: 1)
        emit(engine, amplitude: 0.001, count: 4)
        XCTAssertEqual(box.deliveries.count, 1, "речь пересекла окно — ближайшая микро-пауза режет чанк")
        XCTAssertFalse(box.deliveries[0].isTail)
        let seg = box.deliveries[0].samples
        // Речь от старта (31 + звон + 1 = 33×1486 ≈ 49038; со звоном второго
        // блока тишины — 34×1486 ≈ 50524) + пост-ролл 4000. Замеры 57496…58982
        // (две реализации звона закрывающего блока): диапазон накрывает оба.
        XCTAssertTrue(seg.count > 56000 && seg.count < 62000, "чанк = вся речь от старта + пост-ролл 0.25 c")
        XCTAssertTrue(seg.contains { abs(Int($0)) >= 3000 }, "чанк содержит речь от начала записи")

        _ = service.stop()
        XCTAssertEqual(box.deliveries.count, 1)
    }

    /// После чанка новый речевой блок стартует РОВНО со среза первого чанка
    /// (liveLastCutIndex = конец пост-ролла): «хвост» стопа продолжает запись
    /// без наложения на уже доставленный чанк и без потери — ровно та же
    /// проверка непрерывности, что testPreRollDoesNotOverlapPreviouslyDeliveredSegment,
    /// но для чанка на микро-паузе.
    @objc func testChunkAfterDeliveryNextSpeechNoOverlap() {
        let engine = FakeEngine()
        let service = makeLiveService(engine: engine, pause: 1.0)
        let box = DeliveryBox()
        service.onSpeechSegment = { s, t in box.add(s, isTail: t) }

        guard runStart(service) else {
            XCTFail("старт должен пройти", file: #file, line: #line)
            return
        }

        emit(engine, amplitude: 0.2, count: 35)      // чанк 1 ≈ 57496 (см. первый тест)
        emit(engine, amplitude: 0.001, count: 4)     // микро-пауза — чанк доставлен
        XCTAssertEqual(box.deliveries.count, 1, "чанк 1 доставлен на микро-паузе")

        emit(engine, amplitude: 0.2, count: 2)       // «ещё сказал» после чанка
        let samples = service.stop()                 // стоп на открытом уттеренсе — «хвост»

        XCTAssertEqual(box.deliveries.count, 2, "чанк 1 + «хвост» стопа")
        XCTAssertFalse(box.deliveries[0].isTail)
        XCTAssertTrue(box.deliveries[1].isTail)
        let seg1 = box.deliveries[0].samples
        let tail = box.deliveries[1].samples

        // Непрерывность по полной записи: хвост начинается РОВНО со среза
        // чанка (конец пост-ролла), а не раньше (ранее — наложение/дубль) и
        // не позже (ранее доставленное не теряется).
        XCTAssertEqual(seg1, Array(samples.prefix(seg1.count)), "чанк 1 — префикс записи")
        XCTAssertEqual(tail, Array(samples.dropFirst(seg1.count)), "«хвост» продолжает запись со среза чанка — без наложения")
        XCTAssertEqual(seg1.count + tail.count, samples.count, "чанк + «хвост» = вся запись, без потерь")
        XCTAssertTrue(seg1.count > 55000 && seg1.count < 60000, "чанк 1 не раздут")
        XCTAssertTrue(tail.count > 3000 && tail.count < 3900, "«хвост» = 2 буфера речи + pre-roll-отступ от среза")
        XCTAssertTrue(tail.contains { abs(Int($0)) >= 3000 }, "доречь после чанка ушла в «хвост» целиком")
    }
}