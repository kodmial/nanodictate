import Foundation
@testable import NanoDictateCore

/// Анти-штормовый сторож TCC-запросов микрофона (MicRequestPolicy).
/// Порог: 3 таймаута в окне 6 ч → запрос блокируется; recordGranted сбрасывает
/// счётчик; окно протухает по времени; повреждённый/отсутствующий файл
/// состояния = свежее состояние; состояние персистентно между инстансами.
/// Все тесты пишут во ВРЕМЕННЫЙ файл (никогда не трогают реальный
/// Application Support пользователя).
final class MicRequestPolicyTests: XCTestCase {

    /// Временный URL файла состояния, уникальный на тест (между записями
    /// разных тестов нет конфликтов, тестовое состояние не липнет к агенту).
    private func tempStateURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mic-request-policy-\(UUID().uuidString).json")
    }

    /// Стабильное «сейчас» для детерминизма (окно 6 ч = 21 600 с).
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// До порога новые запросы разрешены: 0, 1 и 2 таймаута в окне.
    @objc func testAllowBelowThreshold() {
        var policy = MicRequestPolicy(fileURL: tempStateURL())
        XCTAssertTrue(policy.allowRequest(now: t0))
        policy.recordTimeout(now: t0)
        XCTAssertTrue(policy.allowRequest(now: t0.addingTimeInterval(1)))
        policy.recordTimeout(now: t0.addingTimeInterval(1))
        XCTAssertTrue(policy.allowRequest(now: t0.addingTimeInterval(2)))
    }

    /// На пороге и выше (3+ таймаутов в окне) запрос блокируется,
    /// пока горит окно.
    @objc func testBlockAtAndAfterThreeTimeouts() {
        var policy = MicRequestPolicy(fileURL: tempStateURL())
        for i in 0..<3 {
            policy.recordTimeout(now: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertFalse(policy.allowRequest(now: t0.addingTimeInterval(5)))
        // 4-й таймаут не «починит» ситуацию — все ещё в окне.
        policy.recordTimeout(now: t0.addingTimeInterval(5))
        XCTAssertFalse(policy.allowRequest(now: t0.addingTimeInterval(6)))
    }

    /// recordGranted сбрасывает счётчик: блокировавший шторм снимается
    /// полностью, следующий запрос разрешён.
    @objc func testRecordGrantedResets() {
        var policy = MicRequestPolicy(fileURL: tempStateURL())
        for i in 0..<3 {
            policy.recordTimeout(now: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertFalse(policy.allowRequest(now: t0.addingTimeInterval(5)))
        policy.recordGranted(now: t0.addingTimeInterval(5))
        XCTAssertTrue(policy.allowRequest(now: t0.addingTimeInterval(6)))
    }

    /// Окно протухает по времени: ровно на границе 6 ч старый таймаут выпадает
    /// из подсчёта (сброс «по времени»); за секунду до границы — ещё блокирует.
    @objc func testWindowExpiryReallows() {
        var policy = MicRequestPolicy(fileURL: tempStateURL())
        for i in 0..<3 {
            policy.recordTimeout(now: t0.addingTimeInterval(Double(i)))
        }
        let justBefore = t0.addingTimeInterval(MicRequestPolicy.windowDuration - 1)
        XCTAssertFalse(policy.allowRequest(now: justBefore))
        let onBoundary = t0.addingTimeInterval(MicRequestPolicy.windowDuration)
        XCTAssertTrue(policy.allowRequest(now: onBoundary))
    }

    /// Повреждённый JSON в файле состояния трактуется как свежее состояние:
    /// сторож не ломается мусором и снова разрешает запросы.
    @objc func testCorruptStateFileIsFresh() throws {
        let url = tempStateURL()
        try "не json {{{".data(using: .utf8)!.write(to: url)
        let policy = MicRequestPolicy(fileURL: url)
        XCTAssertTrue(policy.allowRequest(now: t0))
    }

    /// Отсутствующий файл состояния — тоже свежее состояние.
    @objc func testMissingStateFileIsFresh() {
        let policy = MicRequestPolicy(fileURL: tempStateURL())
        XCTAssertTrue(policy.allowRequest(now: t0))
    }

    /// Состояние персистентно между инстансами: второй инстанс, открывший тот
    /// же файл, видит те же таймауты (перезапуск агента не снимает шторм).
    @objc func testPersistenceAcrossInstances() {
        let url = tempStateURL()
        var first = MicRequestPolicy(fileURL: url)
        for i in 0..<3 {
            first.recordTimeout(now: t0.addingTimeInterval(Double(i)))
        }
        let second = MicRequestPolicy(fileURL: url)
        XCTAssertFalse(second.allowRequest(now: t0.addingTimeInterval(10)))
        // И recordGranted тоже персистится: грант в одном инстансе снимает
        // шторм и в новом (проблема решена — счётчик больше не блокирует).
        var third = MicRequestPolicy(fileURL: url)
        third.recordGranted(now: t0.addingTimeInterval(10))
        let fourth = MicRequestPolicy(fileURL: url)
        XCTAssertTrue(fourth.allowRequest(now: t0.addingTimeInterval(11)))
    }
}