// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "AltDictation",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "DictationCore", targets: ["DictationCore"]),
        .executable(name: "DictatorAgent", targets: ["DictatorAgent"]),
        .executable(name: "dictatorctl", targets: ["dictatorctl"])
    ],
    targets: [
        // ObjC-шлюз NSException AVFAudio: SPM 5.7 не допускает подмешивание
        // ObjC в Swift-таргеты, поэтому шлюз живёт отдельным clang-таргетом.
        .target(
            name: "AudioEngineGuard",
            publicHeadersPath: "include"
        ),
        .target(
            name: "DictationCore",
            dependencies: ["AudioEngineGuard"]
        ),
        .executableTarget(
            name: "DictatorAgent",
            dependencies: ["DictationCore"]
        ),
        .executableTarget(
            name: "dictatorctl",
            dependencies: ["DictationCore"]
        ),
        // Компактный раннер тестов: на этой машине нет Xcode / XCTest.framework,
        // поэтому `swift test` физически не работает ("XCTest not available").
        // Исполняемый таргет прогоняет те же проверки и завершается с ненулевым
        // кодом при первом упавшем тесте: `swift run DictationCoreTests`.
        .executableTarget(
            name: "DictationCoreTests",
            dependencies: ["DictationCore", "AudioEngineGuard"],
            path: "Tests/DictationCoreTests"
        )
    ]
)