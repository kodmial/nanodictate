import Foundation
import AVFoundation
@testable import NanoDictateCore

/// Тесты MicAccessRequester — проверяемый в мини-XCTest (без аудио-железа и TCC,
/// именно для этого координатор вынесен из Agent в Core).
/// Покрывают целиком «цикл запроса с защитами»:
///   • authorized/denied/restricted — синхронный исход без системного запроса;
///   • granted/denied в ответ на системный диалог — исход на главной очереди;
///   • сторож: колбэк не пришёл за timeout → .timedOut (не вечное ожидание),
///     таймаут учтён в штормовой политике;
///   • ПОЗДНИЙ granted после таймаута отбрасывается по сессионному токену:
///     ни второго исхода, ни сброса штормового счётчика (регрессия фикса);
///   • повторный запрос, пока диалог висит, не открывает второй диалог;
///   • анти-шторм: после 3 таймаутов в окне 6 ч запрос не открывается вовсе.
final class MicAccessRequesterTests: XCTestCase {

    /// Управляемый «системный запрос»: диалог не открывает, колбэк держит до
    /// команды теста (respond/промолчать). callCount — сколько раз запрос
    /// реально стартовал.
    private final class RequestStub {
        private(set) var callCount = 0
        private(set) var lastCompletion: ((Bool) -> Void)?

        func asRequestAccess() -> MicAccessRequester.RequestAccess {
            { [weak self] completion in
                self?.callCount += 1
                self?.lastCompletion = completion
            }
        }
    }

    private func makeRequester(
        status: @escaping MicAccessRequester.StatusProvider,
        stub: RequestStub,
        policyFile: URL,
        timeout: TimeInterval = 0.2
    ) -> MicAccessRequester {
        MicAccessRequester(
            status: status,
            requestAccess: stub.asRequestAccess(),
            policy: MicRequestPolicy(fileURL: policyFile),
            timeout: timeout
        )
    }

    /// Ждёт ровно один исход (completion координатора — РОВНО один раз).
    private func waitForOutcome(
        _ requester: MicAccessRequester,
        timeout: TimeInterval = 2
    ) -> (MicAccessRequester.Outcome, [MicAccessRequester.Outcome]) {
        let done = expectation(description: "mic access outcome")
        var outcomes: [MicAccessRequester.Outcome] = []
        requester.requestIfNeeded { outcome in
            outcomes.append(outcome)
            if outcomes.count == 1 { done.fulfill() }
        }
        wait(for: [done], timeout: timeout)
        return (outcomes.first ?? .denied, outcomes)
    }

    // MARK: - Статус уже известен (без системного запроса)

    @objc func testAuthorizedGrantsImmediately() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("requester-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let stub = RequestStub()
        let requester = makeRequester(status: { .authorized }, stub: stub, policyFile: file)

        var outcomes: [MicAccessRequester.Outcome] = []
        requester.requestIfNeeded { outcomes.append($0) }

        // Синхронно, без wait: статус уже известен — системного запроса нет.
        XCTAssertEqual(outcomes, [.granted])
        XCTAssertEqual(stub.callCount, 0, "системный диалог не открывается при выданном доступе")
        XCTAssertFalse(requester.isInFlight)
    }

    @objc func testDeniedAndRestrictedFailImmediately() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("requester-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        for status in [AVAuthorizationStatus.denied, .restricted] {
            let stub = RequestStub()
            let requester = makeRequester(status: { status }, stub: stub, policyFile: file)
            var outcomes: [MicAccessRequester.Outcome] = []
            requester.requestIfNeeded { outcomes.append($0) }
            XCTAssertEqual(outcomes, [.denied], "статус \(status) → .denied")
            XCTAssertEqual(stub.callCount, 0)
        }
    }

    // MARK: - Ответ системного диалога (в срок)

    @objc func testPromptGrantSucceedsAndResetsStormCounter() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("requester-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        // Два таймаута в прошлом (штормовой счётчик на 2 из 3 — запрос
        // доступа ещё разрешён)…
        var policy = MicRequestPolicy(fileURL: file)
        for _ in 0..<(MicRequestPolicy.maxTimeoutsInWindow - 1) {
            policy.recordTimeout(now: Date())
        }
        XCTAssertTrue(MicRequestPolicy(fileURL: file).allowRequest(now: Date()), "2 таймаута — ещё до порога")

        // …и НОРМАЛЬНЫЙ granted в ответ на запрос: шторм снимается.
        let stub = RequestStub()
        let requester = makeRequester(status: { .notDetermined }, stub: stub, policyFile: file)

        let done = expectation(description: "granted outcome")
        var outcomes: [MicAccessRequester.Outcome] = []
        requester.requestIfNeeded { outcome in
            outcomes.append(outcome)
            if outcomes.count == 1 { done.fulfill() }
        }
        XCTAssertEqual(stub.callCount, 1, "системный запрос открыт ровно один раз")
        // Диалог отвечает granted в срок (сторож 0.2 с не успевает)…
        stub.lastCompletion?(true)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(outcomes, [.granted])
        XCTAssertTrue(
            eventually { requester.isInFlight == false },
            "после granted флаг «в полёте» снят"
        )
        // Грант получен — счётчик таймаутов сброшен.
        XCTAssertTrue(
            MicRequestPolicy(fileURL: file).allowRequest(now: Date()),
            "granted в срок обязан сбросить штормовой счётчик"
        )
    }

    @objc func testPromptDenyFails() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("requester-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let stub = RequestStub()
        let requester = makeRequester(status: { .notDetermined }, stub: stub, policyFile: file)

        requester.requestIfNeeded { _ in }
        stub.lastCompletion?(false)
        // Ответ переводится на main (async): дождаться, пока первый запрос
        // завершится и снимет флаг — иначе повторный вызов уйдёт в
        // guard isInFlight (диалог №2 не откроется, исхода не будет).
        XCTAssertTrue(
            eventually { requester.isInFlight == false },
            "первый запрос обязан завершиться до повторного"
        )

        let done = expectation(description: "denied outcome")
        var outcomes: [MicAccessRequester.Outcome] = []
        requester.requestIfNeeded { outcome in
            outcomes.append(outcome)
            done.fulfill()
        }
        // Следующий Alt+Alt открывает НОВЫЙ диалог; ответ deny → .denied.
        stub.lastCompletion?(false)
        wait(for: [done], timeout: 2)
        XCTAssertEqual(outcomes, [.denied])
    }

    // MARK: - Сторож таймаута

    @objc func testTimeoutFiresWhenNoResponse() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("requester-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }

        // Два таймаута уже в окне (штормовой счётчик на 2 из 3): третий,
        // который запишет сторож, обязан перевалить лимит. Так assert
        // allowRequest(file) внизу доказывает, что таймаут РЕАЛЬНО записан.
        var seed = MicRequestPolicy(fileURL: file)
        seed.recordTimeout(now: Date())
        seed.recordTimeout(now: Date())
        XCTAssertTrue(MicRequestPolicy(fileURL: file).allowRequest(now: Date()), "2 таймаута — ещё до порога")

        let stub = RequestStub()
        // Сторож короткий (0.2 c) — тест не ждёт 10 c прода.
        let requester = makeRequester(status: { .notDetermined }, stub: stub, policyFile: file, timeout: 0.2)

        let (outcome, _) = waitForOutcome(requester)
        XCTAssertEqual(outcome, .timedOut, "молчащий диалог обязан дать .timedOut")
        XCTAssertEqual(stub.callCount, 1, "запрос стартовал один раз")
        XCTAssertFalse(requester.isInFlight, "после таймаута флаг «в полёте» снят")
        // Третий таймаут сторожа (на фоне двух посеянных) перевалил порог:
        // свежий инстанс политики из того же файла запрос больше не разрешает.
        XCTAssertFalse(
            MicRequestPolicy(fileURL: file).allowRequest(now: Date()),
            "таймаут записан в штормовой счётчик (2+1 на пределе)"
        )
    }

    /// Поздний granted после таймаута — ровно та регрессия, ради которой в
    /// стороже СМЕНА токена, а не только снятие флага: ответ, пришедший после
    /// показанной ошибки, не даёт второго исхода (запись не начнётся) и не
    /// сбрасывает штормовой счётчик (запрос считался таймаутом).
    @objc func testLateGrantAfterTimeoutIsDropped() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("requester-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let stub = RequestStub()
        // Стартовая политика пустая: три молчащих диалога САМИ доведут счётчик
        // до предела (после 3-го таймаута четвёртый запрос блокируется).
        let requester = makeRequester(status: { .notDetermined }, stub: stub, policyFile: file, timeout: 0.15)

        // Три таймаута подряд: каждый цикл — новый запрос, ответа нет.
        var lastCycleOutcomes: [MicAccessRequester.Outcome] = []
        for _ in 0..<3 {
            let (outcome, outcomes) = waitForOutcome(requester)
            XCTAssertEqual(outcome, .timedOut)
            lastCycleOutcomes = outcomes
        }
        // Четвёртый запрос — анти-шторм (счётчик на пределе): системный
        // диалог не открывается вовсе, исход единственный.
        let (suppressedOutcome, suppressedOutcomes) = waitForOutcome(requester)
        XCTAssertEqual(suppressedOutcome, .suppressedByPolicy)
        XCTAssertEqual(suppressedOutcomes, [.suppressedByPolicy], "анти-шторм: один исход, диалог не открывался")

        // Последний РЕАЛЬНЫЙ диалог (третьего цикла) отвечает granted — НО
        // уже после того, как сторож сработал и сменил сессию.
        stub.lastCompletion?(true)
        // Ответа, который начал бы запись, нет: у последнего реального цикла
        // по-прежнему ровно один исход (.timedOut). drainEngineQueue прогоняет
        // run loop — неотброшенный granted уже успел бы долететь.
        drainEngineQueue()
        XCTAssertEqual(
            lastCycleOutcomes,
            [.timedOut],
            "поздний granted не даёт второго исхода (запись не начнётся)"
        )
        // Штормовой счётчик НЕ сброшен поздним granted: запрос остаётся
        // заблокированным (fresh policy читает состояние из файла).
        XCTAssertFalse(
            MicRequestPolicy(fileURL: file).allowRequest(now: Date()),
            "поздний granted не должен сбрасывать штормовой счётчик"
        )
    }

    /// Повторный запрос, пока системный диалог висит, не открывает второй
    /// диалог и не даёт второго исхода.
    @objc func testDuplicateWhileInFlightIsIgnored() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("requester-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let stub = RequestStub()
        let requester = makeRequester(status: { .notDetermined }, stub: stub, policyFile: file, timeout: 0.5)

        var outcomes: [MicAccessRequester.Outcome] = []
        requester.requestIfNeeded { outcomes.append($0) }
        XCTAssertEqual(stub.callCount, 1, "первый запрос стартует")

        // Второй Alt+Alt в полёте: ни исхода, ни второго системного запроса.
        requester.requestIfNeeded { outcomes.append($0) }
        XCTAssertEqual(stub.callCount, 1, "второй запрос не открывает второй диалог")
        XCTAssertEqual(outcomes, [], "повторный вызов в полёте не даёт исхода")

        // Ответ на ПЕРВЫЙ запрос — ровно один исход.
        stub.lastCompletion?(true)
        XCTAssertTrue(
            eventually(timeout: 1.0, { outcomes == [.granted] }),
            "исход первого запроса приходит ровно один раз: \(outcomes)"
        )
    }

    // MARK: - Анти-шторм

    @objc func testSuppressedAfterTimeoutLimit() {
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("requester-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let stub = RequestStub()
        var policy = MicRequestPolicy(fileURL: file)
        for _ in 0..<MicRequestPolicy.maxTimeoutsInWindow {
            policy.recordTimeout(now: Date())
        }

        let requester = makeRequester(status: { .notDetermined }, stub: stub, policyFile: file, timeout: 0.2)
        let (outcome, _) = waitForOutcome(requester)
        XCTAssertEqual(outcome, .suppressedByPolicy, "лимит таймаутов → запрос не открывается вовсе")
        XCTAssertEqual(stub.callCount, 0, "системный диалог НЕ открывается под анти-штормом")
        XCTAssertFalse(requester.isInFlight)
    }
}