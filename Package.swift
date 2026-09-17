// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "NanoDictate",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .library(name: "NanoDictateCore", targets: ["NanoDictateCore"]),
        .executable(name: "NanoDictateAgent", targets: ["NanoDictateAgent"]),
        .executable(name: "nanodictate", targets: ["nanodictate"])
    ],
    targets: [
        // ObjC-шлюз NSException AVFAudio: SPM 5.7 не допускает подмешивание
        // ObjC в Swift-таргеты, поэтому шлюз живёт отдельным clang-таргетом.
        .target(
            name: "AudioEngineGuard",
            publicHeadersPath: "include"
        ),
        .target(
            name: "NanoDictateCore",
            dependencies: ["AudioEngineGuard"]
        ),
        .executableTarget(
            name: "NanoDictateAgent",
            dependencies: ["NanoDictateCore"]
        ),
        .executableTarget(
            name: "nanodictate",
            dependencies: ["NanoDictateCore"]
        ),
        // Компактный раннер тестов: на этой машине нет Xcode / XCTest.framework,
        // поэтому `swift test` физически не работает ("XCTest not available").
        // Исполняемый таргет прогоняет те же проверки и завершается с ненулевым
        // кодом при первом упавшем тесте: `swift run NanoDictateCoreTests`.
        .executableTarget(
            name: "NanoDictateCoreTests",
            dependencies: ["NanoDictateCore", "AudioEngineGuard"],
            path: "Tests/NanoDictateCoreTests"
        )
    ]
)