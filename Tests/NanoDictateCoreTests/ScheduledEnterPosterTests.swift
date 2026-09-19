import Foundation
@testable import NanoDictateCore

/// Cancels an already-scheduled synthetic Enter (замечание #2 ревью): Esc after insert
/// must not let the ~250 ms pending post fire. Latency tests live here.
final class ScheduledEnterPosterTests: XCTestCase {

    /// Spins main run loop until `condition` is true or `timeout` (asyncAfter/tap live there).
    private func waitFor(timeout: TimeInterval, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline && !condition() {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
    }

    /// Canceled action never fires, even after the delay (Esc after Enter-stop must not post).
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

    @objc func testActionFiresOnceAfterDelay() {
        let poster = ScheduledEnterPoster()
        poster.delay = 0.05
        var fired = 0
        poster.action = { fired += 1 }

        poster.schedule()

        waitFor(timeout: 0.4) { fired >= 1 }
        XCTAssertEqual(fired, 1)
    }

    /// Reschedule replaces the previous one: only the last schedule fires (latch holds one Enter).
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

    /// Can reschedule after cancel (new recording cycle needs a new Enter).
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