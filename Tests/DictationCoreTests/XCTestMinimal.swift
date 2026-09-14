import Foundation
import ObjectiveC

// MARK: - Минимальная замена XCTest (нет Xcode на этой машине)
//
// `swift test` не работает: в CommandLineTools нет XCTest.framework
// ("XCTest not available"). Чтобы тесты реально выполнялись, предоставляем
// компактный XCTest-совместимый API: тот же `XCTestCase`, те же
// `XCTAssert*`-функции. Раннер (см. main.swift) находит все подклассы
// `XCTestCase` через ObjC-runtime, вызывает каждый `test*`-метод по
// селектору и завершает процесс с ненулевым кодом при первом провале.

/// Примитив асинхронного ожидания: тест создаёт expectation, async-задача
/// вызывает fulfill(), а `wait(for:timeout:)` блокирует до сброса флага.
///
/// Флаг (а не DispatchSemaphore) выбран намеренно: семафорные ожидания здесь
/// показали гонки (fulfill() вызывается, но wait всё равно уходит в таймаут),
/// а флаг с NSLock не «поедается» при чтении, как се‥мафорный wait(.now()).
public class XCTestExpectation: NSObject {
    private let lock = NSLock()
    private var _fulfilled = false
    public override init() { super.init() }

    public var isFulfilled: Bool {
        lock.lock(); defer { lock.unlock() }
        return _fulfilled
    }

    @objc public func fulfill() {
        lock.lock(); defer { lock.unlock() }
        _fulfilled = true
    }
}

public class XCTestCase: NSObject {
    /// Неудачи текущего теста; раннер сбрасывает перед каждым тестом.
    public static var currentFailures: [String] = []

    public required override init() {
        super.init()
    }

    // @objc — раннер вызывает setUp/tearDown по селектору (см. main.swift),
    // а override в подклассах наследует objc-доступность.
    @objc public func setUp() {}
    @objc public func tearDown() {}

    /// Создаёт ожидание (API-совместимо с XCTest).
    public func expectation(description: String) -> XCTestExpectation {
        return XCTestExpectation()
    }

    /// Блокирует поток до выполнения всех ожиданий либо до `timeout`.
    /// Крутит RunLoop (а не usleep), чтобы `Task` на главном акторе —
    /// как в TranscriberTests.runAsync — мог выполниться и позвать fulfill().
    public func wait(for expectations: [XCTestExpectation], timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while !expectations.allSatisfy({ $0.isFulfilled }) {
            if Date() >= deadline { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        if !expectations.allSatisfy({ $0.isFulfilled }) {
            XCTestCase.recordFailure(
                "wait(for:timeout:) — ожидания не выполнены за \(timeout)c",
                file: #file, line: #line
            )
        }
    }

    /// Регистрирует неудачу (вызывается из XCTAssert*-функций).
    public static func recordFailure(_ message: String, file: StaticString, line: UInt) {
        currentFailures.append("\(file):\(line): \(message)")
    }
}

// MARK: - Assert-функции

public func XCTFail(_ message: String = "", file: StaticString = #file, line: UInt = #line) {
    XCTestCase.recordFailure("XCTFail: \(message)", file: file, line: line)
}

public func XCTAssertTrue(
    _ expression: @autoclosure () -> Bool,
    _ message: String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    if !expression() {
        XCTestCase.recordFailure("XCTAssertTrue failed: \(message)", file: file, line: line)
    }
}

public func XCTAssertFalse(
    _ expression: @autoclosure () -> Bool,
    _ message: String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    if expression() {
        XCTestCase.recordFailure("XCTAssertFalse failed: \(message)", file: file, line: line)
    }
}

public func XCTAssertEqual<T: Equatable>(
    _ a: @autoclosure () -> T,
    _ b: @autoclosure () -> T,
    _ message: String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    let (va, vb) = (a(), b())
    if va != vb {
        XCTestCase.recordFailure(
            "XCTAssertEqual failed: \(String(describing: va)) != \(String(describing: vb)) \(message)",
            file: file, line: line
        )
    }
}

public func XCTAssertEqual<T: FloatingPoint>(
    _ a: @autoclosure () -> T,
    _ b: @autoclosure () -> T,
    accuracy: T,
    _ message: String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    let (va, vb) = (a(), b())
    if abs(va - vb) > accuracy {
        XCTestCase.recordFailure(
            "XCTAssertEqual failed: \(String(describing: va)) != \(String(describing: vb)) (accuracy \(accuracy)) \(message)",
            file: file, line: line
        )
    }
}

public func XCTAssertGreaterThanOrEqual<T: Comparable>(
    _ a: @autoclosure () -> T,
    _ b: @autoclosure () -> T,
    _ message: String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    let (va, vb) = (a(), b())
    if !(va >= vb) {
        XCTestCase.recordFailure(
            "XCTAssertGreaterThanOrEqual failed: \(va) < \(vb) \(message)", file: file, line: line
        )
    }
}

public func XCTAssertGreaterThanOrEqual<T: FloatingPoint>(
    _ a: @autoclosure () -> T,
    _ b: @autoclosure () -> T,
    accuracy: T,
    _ message: String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    let (va, vb) = (a(), b())
    if va + accuracy < vb {
        XCTestCase.recordFailure(
            "XCTAssertGreaterThanOrEqual failed: \(va) < \(vb) (accuracy \(accuracy)) \(message)",
            file: file, line: line
        )
    }
}

public func XCTAssertLessThanOrEqual<T: Comparable>(
    _ a: @autoclosure () -> T,
    _ b: @autoclosure () -> T,
    _ message: String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    let (va, vb) = (a(), b())
    if !(va <= vb) {
        XCTestCase.recordFailure(
            "XCTAssertLessThanOrEqual failed: \(va) > \(vb) \(message)", file: file, line: line
        )
    }
}

public func XCTAssertNil(
    _ a: @autoclosure () -> Any?,
    _ message: String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    if let value = a() {
        XCTestCase.recordFailure("XCTAssertNil failed: \(value) \(message)", file: file, line: line)
    }
}

public func XCTAssertNotNil(
    _ a: @autoclosure () -> Any?,
    _ message: String = "",
    file: StaticString = #file,
    line: UInt = #line
) {
    if a() == nil {
        XCTestCase.recordFailure("XCTAssertNotNil failed: nil \(message)", file: file, line: line)
    }
}

/// Проверяет, что выражение бросает ошибку. `errorHandler` вызывается,
/// если ошибка действительно была.
public func XCTAssertThrowsError<T>(
    _ expression: @autoclosure () throws -> T,
    _ message: String = "",
    file: StaticString = #file,
    line: UInt = #line,
    _ errorHandler: (Error) -> Void
) {
    do {
        _ = try expression()
        XCTestCase.recordFailure("XCTAssertThrowsError failed: no error thrown \(message)", file: file, line: line)
    } catch {
        errorHandler(error)
    }
}