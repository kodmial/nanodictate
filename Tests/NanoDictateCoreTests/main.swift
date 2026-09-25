import Foundation
import ObjectiveC

// Test-process marker (RuntimeEnvironment.isTestRun): gates SysSounds, overlay, prod agent.log.
setenv("NANODICTATE_TESTS", "1", 1)

// MARK: - Раннер тестов (мини-XCTest без Xcode)
// Suites explicit (objc_copyClassList clumsy in Swift); any failure → non-zero exit + names.
// Run: `swift run NanoDictateCoreTests`.

// Swift-методы `@objc func testX() throws` выставляются рантайму как селектор
// `<testX>AndReturnError:` с сигнатурой `(BOOL)AndReturnError:(NSError **)err`.
// Голый perform(selector) не передаёт NSError**, и метод на выходе пишет ошибку
// через мусорный указатель → SIGBUS (KERN_PROTECTION_FAILURE, CI run 35815418862).
// Поэтому throws-тесты вызываем напрямую через IMP с настоящим holder'ом ошибки.
typealias NoArgFn = @convention(c) (AnyObject, Selector) -> Void
typealias WithErrorFn = @convention(c) (AnyObject, Selector, AutoreleasingUnsafeMutablePointer<NSError?>?) -> Bool

let suites: [XCTestCase.Type] = [
    HotkeyServiceTests.self,
    InputGainTests.self,
    AudioMetricsTests.self,
    AudioCaptureTests.self,
    AudioServiceLifecycleTests.self,
    AudioServiceWedgeTests.self,
    AudioServiceVADTests.self,
    AudioServiceAuditFixTests.self,
    LoggerTests.self,
    ConfigTests.self,
    ConfigMaskingTests.self,
    ProviderTests.self,
    RecognitionLabelTests.self,
    RetryProviderTests.self,
    ClipboardInsertTests.self,
    ReviewGateTests.self,
    RetryInsertionGateTests.self,
    AgentStatusTests.self,
    VersionTests.self,
    MicErrorCooldownTests.self,
    MicRequestPolicyTests.self,
    MicAccessRequesterTests.self,
    SysSoundsTests.self,
    SysSoundsUXTests.self,
    InserterTests.self,
    WAVEncoderTests.self,
    RecordingLimitTests.self,
    SilenceAutoStopTests.self,
    TranscriberTests.self,
    STTAdapterTests.self,
    CookieRelayProviderTests.self,
    DebugDumpTests.self,
    EnterSendLatchTests.self,
    ScheduledEnterPosterTests.self,
    OverlayControllerTests.self,
    OverlayLifecycleTests.self,
    NanoDictateFlowTests.self,
    AudioSegmenterTests.self,
    WordDiffTests.self,
    ChunkedPipelineTests.self,
    LiveSegmentFailureTests.self,
    LiveOrchestrationBranchTests.self,
    OverlayLevelTests.self,
    RoutingRoleTests.self,
    BatchSegmenterTests.self,
    BatchTextJoinerTests.self,
    BatchTranscriberTests.self,
    BatchLongFormTests.self,
    WAVDecoderTests.self,
    AgentPlistTests.self,
]

var passed = 0
var failed: [String] = []

for cls in suites {
    var methodCount: UInt32 = 0
    guard let methods = class_copyMethodList(cls, &methodCount) else { continue }
    defer { free(methods) }

    var testSelectors: [Selector] = []
    for m in 0..<Int(methodCount) {
        let name = String(cString: sel_getName(method_getName(methods[m])))
        if name.hasPrefix("test") {
            testSelectors.append(method_getName(methods[m]))
        }
    }
    // Deterministic order (class_copyMethodList is unsorted).
    testSelectors.sort { String(describing: $0) < String(describing: $1) }

    guard !testSelectors.isEmpty else { continue }

    let suiteName = String(describing: cls).split(separator: ".").last.map(String.init) ?? String(describing: cls)
    print("Suite: \(suiteName) (\(testSelectors.count) тестов)")

    for selector in testSelectors {
        XCTestCase.currentFailures = []
        let instance = cls.init()

        print("  TEST: \(suiteName).\(selector)")
        fflush(stdout)

        _ = instance.perform(Selector(("setUp")))
        if String(cString: sel_getName(selector)).hasSuffix("AndReturnError:") {
            // @objc throws: вызываем IMP с валидным NSError* holder'ом.
            guard let imp = class_getMethodImplementation(cls, selector) else { continue }
            let fn = unsafeBitCast(imp, to: WithErrorFn.self)
            var err: NSError?
            withUnsafeMutablePointer(to: &err) { ptr in
                let holder = AutoreleasingUnsafeMutablePointer<NSError?>(ptr)
                _ = fn(instance, selector, holder)
            }
            if let err {
                XCTestCase.currentFailures.append("test threw: \(String(reflecting: err))")
            }
        } else {
            // Non-throwing: вызов без out-param, как раньше.
            guard let imp = class_getMethodImplementation(cls, selector) else { continue }
            let fn = unsafeBitCast(imp, to: NoArgFn.self)
            fn(instance, selector)
        }
        _ = instance.perform(Selector(("tearDown")))

        let failures = XCTestCase.currentFailures
        if failures.isEmpty {
            passed += 1
        } else {
            failed.append("\(suiteName).\(selector)")
            for f in failures {
                print("  [FAIL] \(f)")
            }
        }
    }
}

print("\nИТОГ: \(passed) passed, \(failed.count) failed")
if !failed.isEmpty {
    print("Упавшие тесты:")
    for name in failed { print("  - \(name)") }
    exit(1)
}
exit(0)