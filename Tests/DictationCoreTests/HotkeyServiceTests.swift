import XCTest
@testable import DictationCore

final class HotkeyServiceTests: XCTestCase {

    // MARK: - DoubleAltDetector

    func testTwoTapsWithinIntervalIsDoubleTap() {
        var detector = DoubleAltDetector(maxInterval: 0.4)
        XCTAssertFalse(detector.registerTap(at: 1.0))
        XCTAssertTrue(detector.registerTap(at: 1.25)) // 0.25s < 0.4s
    }

    func testTwoTapsWithLargerIntervalIsNotDoubleTap() {
        var detector = DoubleAltDetector(maxInterval: 0.4)
        XCTAssertFalse(detector.registerTap(at: 1.0))
        XCTAssertFalse(detector.registerTap(at: 1.5)) // 0.5s > 0.4s
    }

    func testSingleTapIsNeverDoubleTap() {
        var detector = DoubleAltDetector(maxInterval: 0.4)
        XCTAssertFalse(detector.registerTap(at: 1.0))
    }

    func testThreeFastTapsDetectPairAndReset() {
        var detector = DoubleAltDetector(maxInterval: 0.4)
        XCTAssertFalse(detector.registerTap(at: 1.0))
        // Второй тап в пределах интервала — двойной тап...
        XCTAssertTrue(detector.registerTap(at: 1.1))
        // ...а после срабатывания детектор сброшен: третий тап начинает новое окно.
        XCTAssertFalse(detector.registerTap(at: 1.2))
        // Четвёртый в пределах окна от третьего — снова двойной тап (доказательство сброса).
        XCTAssertTrue(detector.registerTap(at: 1.25))
    }

    func testDetectorIsResetAfterDoubleTap() {
        var detector = DoubleAltDetector(maxInterval: 0.4)
        XCTAssertFalse(detector.registerTap(at: 0.0))
        XCTAssertTrue(detector.registerTap(at: 0.1))
        detector.reset()
        XCTAssertFalse(detector.registerTap(at: 0.2)) // после reset — одиночное нажатие
    }

    func testTapExactlyAtIntervalBoundaryIsDoubleTap() {
        var detector = DoubleAltDetector(maxInterval: 0.4)
        XCTAssertFalse(detector.registerTap(at: 5.0))
        XCTAssertTrue(detector.registerTap(at: 5.4)) // ровно maxInterval
    }

    // MARK: - HotkeyService public API (конструктор не бросает, свойства доступны)

    func testDefaultMaxInterval() {
        let service = HotkeyService()
        XCTAssertEqual(service.doubleTapMaxInterval, 0.4)
    }

    func testCustomMaxInterval() {
        let service = HotkeyService(doubleTapMaxInterval: 1.0)
        XCTAssertEqual(service.doubleTapMaxInterval, 1.0)
    }
}