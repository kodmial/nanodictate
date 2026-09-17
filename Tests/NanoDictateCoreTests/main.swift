import Foundation
import ObjectiveC

// Тестовый раннер: помечаем процесс как тестовый (setenv — не аргумент CLI).
// На этом признаке (RuntimeEnvironment.isTestRun) гейтятся реальные эффекты,
// которые тревожат пользователя при прогонах тестов: системные звуки SysSounds
// не играют, панель оверлея не выводится на экран, Logger не пишет в боевой
// ~/Library/Logs/NanoDictate/agent.log (пишет в /tmp/nanodictate-tests/agent.log).
setenv("NANODICTATE_TESTS", "1", 1)

// MARK: - Раннер тестов (мини-XCTest без Xcode)
//
// Все suite-классы перечислены явно (objc_copyClassList неудобен из Swift).
// Для класса берётся список test*-методов через class_copyMethodList, каждый
// вызывается по селектору; ассерты копятся в XCTestCase.currentFailures.
// Итог: ненулевой exit-код при любом провале + печать имён упавших тестов.
// Запуск: `swift run NanoDictateCoreTests`.

let suites: [XCTestCase.Type] = [
    HotkeyServiceTests.self,
    InputGainTests.self,
    AudioMetricsTests.self,
    AudioCaptureTests.self,
    AudioServiceLifecycleTests.self,
    AudioServiceVADTests.self,
    LoggerTests.self,
    ConfigTests.self,
    ProviderTests.self,
    RecognitionLabelTests.self,
    RetryProviderTests.self,
    ClipboardInsertTests.self,
    ReviewGateTests.self,
    AgentStatusTests.self,
    MicErrorCooldownTests.self,
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
    // Детерминированный порядок (class_copyMethodList не сортирован).
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
        _ = instance.perform(selector)
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