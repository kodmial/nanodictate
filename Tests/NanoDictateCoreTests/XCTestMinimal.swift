import Foundation
import ObjectiveC

// MARK: - Минимальная замена XCTest (нет Xcode на этой машине)
//
// CommandLineTools lacks XCTest.framework, so `swift test` fails; this shim
// mirrors the XCTest API. Runner (main.swift) finds XCTestCase subclasses via
// ObjC runtime, calls each test* selector, exits nonzero on first failure.

/// Bool flag over DispatchSemaphore: semaphore waits raced here — fulfill()
/// fired yet wait still timed out.
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
    /// Failures of current test; runner resets before each test.
    public static var currentFailures: [String] = []

    public required override init() {
        super.init()
    }

    // @objc: runner calls by selector; subclass overrides inherit objc visibility.
    @objc public func setUp() {}
    @objc public func tearDown() {}

    public func expectation(description: String) -> XCTestExpectation {
        return XCTestExpectation()
    }

    /// Spins RunLoop, not usleep: main-actor Task (runAsync) must run to fulfill().
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