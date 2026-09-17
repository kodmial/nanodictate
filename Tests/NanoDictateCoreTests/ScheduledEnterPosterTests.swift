import Foundation
@testable import NanoDictateCore

/// Отмена УЖЕ запланированного синтетического Enter (замечание #2 ревью):
/// Esc после вставки текста (латч уже снят, пост висит в очереди на ~250 мс)
/// должен отменять срабатывание. Планирование инкапсулировано в
/// ScheduledEnterPoster — здесь latency-тесты отмены и срабатывания.
final class ScheduledEnterPosterTests: XCTestCase {

    /// Ждёт до `timeout` секунд, пока `condition` не станет true (крутит main
    /// run loop — как прод: asyncAfter/тап живут на нём).
    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Отмена: после cancelScheduled() действие НЕ выполняется даже по
    /// истечении паузы (Esc после Enter-останова не даёт постикнуть Enter).
    @objc func testCancelPreventsScheduledAction() {
        let poster = ScheduledEnterPoster()
        poster.delay = 0.05
        var fired = 0
        poster.action = { fired += 1 }

        poster.schedule()
        poster.cancelScheduled()

        waitFor(timeout: 0.4) { fired > 0 }
        XCTAssertEqual(fired, 0, "отменённый пост не должен сработать через паузу")
    }

    /// Без отмены действие срабатывает ровно один раз после паузы.
    @objc func testActionFiresOnceAfterDelay() {
        let poster = ScheduledEnterPoster()
        poster.delay = 0.05
        var fired = 0
        poster.action = { fired += 1 }

        poster.schedule()

        waitFor(timeout: 0.4) { fired >= 1 }
        XCTAssertEqual(fired, 1)
    }

    /// Перепланирование отменяет предыдущее: сработать может только последний
    /// schedule (в латче Enter всегда ровно один, повторы не инкрементируют).
    @objc func testRescheduleReplacesPrevious() {
        let poster = ScheduledEnterPoster()
        poster.delay = 0.05
        var fired = 0
        poster.action = { fired += 1 }

        poster.schedule()
        poster.schedule()

        waitFor(timeout: 0.4) { fired >= 1 }
        XCTAssertEqual(fired, 1)
    }

    /// Отмена без планирования и повторная отмена — идемпотентный no-op.
    @objc func testCancelWithoutScheduleIsNoop() {
        let poster = ScheduledEnterPoster()
        poster.cancelScheduled()
        poster.cancelScheduled()
        poster.delay = 0.05
        var fired = 0
        poster.action = { fired += 1 }
        poster.schedule()
        waitFor(timeout: 0.4) { fired >= 1 }
        XCTAssertEqual(fired, 1)
    }

    /// После отмены можно планировать заново (новый цикл записи → новый Enter).
    @objc func testScheduleWorksAgainAfterCancel() {
        let poster = ScheduledEnterPoster()
        poster.delay = 0.05
        var fired = 0
        poster.action = { fired += 1 }

        poster.schedule()
        poster.cancelScheduled()
        poster.schedule()

        waitFor(timeout: 0.4) { fired >= 1 }
        XCTAssertEqual(fired, 1)
    }
}