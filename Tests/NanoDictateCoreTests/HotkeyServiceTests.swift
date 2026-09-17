import Foundation
@testable import NanoDictateCore

final class HotkeyServiceTests: XCTestCase {

    // MARK: - DoubleAltDetector

    @objc func testTwoTapsWithinIntervalIsDoubleTap() {
        var detector = DoubleAltDetector(maxInterval: 0.4)
        XCTAssertFalse(detector.registerTap(at: 1.0))
        XCTAssertTrue(detector.registerTap(at: 1.25)) // 0.25s < 0.4s
    }

    @objc func testTwoTapsWithLargerIntervalIsNotDoubleTap() {
        var detector = DoubleAltDetector(maxInterval: 0.4)
        XCTAssertFalse(detector.registerTap(at: 1.0))
        XCTAssertFalse(detector.registerTap(at: 1.5)) // 0.5s > 0.4s
    }

    @objc func testSingleTapIsNeverDoubleTap() {
        var detector = DoubleAltDetector(maxInterval: 0.4)
        XCTAssertFalse(detector.registerTap(at: 1.0))
    }

    @objc func testThreeFastTapsDetectPairAndReset() {
        var detector = DoubleAltDetector(maxInterval: 0.4)
        XCTAssertFalse(detector.registerTap(at: 1.0))
        // Второй тап в пределах интервала — двойной тап...
        XCTAssertTrue(detector.registerTap(at: 1.1))
        // ...а после срабатывания детектор сброшен: третий тап начинает новое окно.
        XCTAssertFalse(detector.registerTap(at: 1.2))
        // Четвёртый в пределах окна от третьего — снова двойной тап (доказательство сброса).
        XCTAssertTrue(detector.registerTap(at: 1.25))
    }

    @objc func testDetectorIsResetAfterDoubleTap() {
        var detector = DoubleAltDetector(maxInterval: 0.4)
        XCTAssertFalse(detector.registerTap(at: 0.0))
        XCTAssertTrue(detector.registerTap(at: 0.1))
        detector.reset()
        XCTAssertFalse(detector.registerTap(at: 0.2)) // после reset — одиночное нажатие
    }

    @objc func testTapExactlyAtIntervalBoundaryIsDoubleTap() {
        var detector = DoubleAltDetector(maxInterval: 0.4)
        XCTAssertFalse(detector.registerTap(at: 5.0))
        XCTAssertTrue(detector.registerTap(at: 5.4)) // ровно maxInterval
    }

    // MARK: - HotkeyService public API (конструктор не бросает, свойства доступны)

    @objc func testDefaultMaxInterval() {
        let service = HotkeyService()
        XCTAssertEqual(service.doubleTapMaxInterval, 0.4)
    }

    @objc func testCustomMaxInterval() {
        let service = HotkeyService(doubleTapMaxInterval: 1.0)
        XCTAssertEqual(service.doubleTapMaxInterval, 1.0)
    }
}