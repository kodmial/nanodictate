import Foundation
@testable import NanoDictateCore

/// Латч «ровно один синтетический Enter после вставки» (фича «Enter стопит
/// запись»): arm — поставить (Enter в .recording), consume — вытащить один
/// раз (точка постинга), cancel — погасить без постинга (Esc / пустой
/// результат / ошибка STT).
final class EnterSendLatchTests: XCTestCase {

    @objc func testArmThenConsumeReturnsTrueOnce() {
        let latch = EnterSendLatch()
        latch.arm()
        XCTAssertTrue(latch.isPending)
        XCTAssertTrue(latch.consume()) // ровно один Enter
        XCTAssertFalse(latch.isPending)
        XCTAssertFalse(latch.consume()) // повторный consume пуст
    }

    /// Повторный Enter (несколько нажатий во время записи) не инкрементирует
    /// латч: consume отдаёт ровно один Enter.
    @objc func testRepeatedArmStillSingleConsume() {
        let latch = EnterSendLatch()
        latch.arm()
        latch.arm()
        latch.arm()
        XCTAssertTrue(latch.consume())
        XCTAssertFalse(latch.consume())
    }

    @objc func testConsumeWithoutArmIsFalse() {
        let latch = EnterSendLatch()
        XCTAssertFalse(latch.isPending)
        XCTAssertFalse(latch.consume())
    }

    /// cancel (Esc во время распознавания / пустой результат / ошибка) —
    /// синтетический Enter не постится.
    @objc func testCancelClearsPending() {
        let latch = EnterSendLatch()
        latch.arm()
        latch.cancel()
        XCTAssertFalse(latch.isPending)
        XCTAssertFalse(latch.consume())
    }

    @objc func testCancelIsIdempotent() {
        let latch = EnterSendLatch()
        latch.cancel()
        latch.cancel()
        XCTAssertFalse(latch.isPending)
        XCTAssertFalse(latch.consume())
    }

    /// После cancel латч можно поставить заново (новый цикл Enter-останова).
    @objc func testArmAfterCancelWorksAgain() {
        let latch = EnterSendLatch()
        latch.arm()
        latch.cancel()
        latch.arm()
        XCTAssertTrue(latch.consume())
        XCTAssertFalse(latch.consume())
    }

    /// Арм и консьюм не зависят от порядка вызовов: после успешного consume
    /// латч мёртв, пока не поставлен заново.
    @objc func testConsumeIsOneShotAcrossCycles() {
        let latch = EnterSendLatch()
        latch.arm()
        _ = latch.consume()
        _ = latch.consume()
        latch.arm()
        XCTAssertTrue(latch.consume())
        XCTAssertFalse(latch.consume())
    }
}