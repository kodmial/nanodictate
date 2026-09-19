// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "NanoDictate",
    platforms: [
        .macOS(.v12),
    ],
    products: [
        .library(name: "NanoDictateCore", targets: ["NanoDictateCore"]),
        .executable(name: "NanoDictateAgent", targets: ["NanoDictateAgent"]),
        .executable(name: "nanodictate", targets: ["nanodictate"]),
    ],
    // Линтеры/форматтеры подключены только как command-плагины: их вербы
    // вызываются явно (`swift package plugin …`) в CI, но НЕ запускаются
    // автоматически при `swift build`. Иначе замечание линтера ломало бы
    // сборку и, вместе с ней, деплой через MCP.
    dependencies: [
        // SwiftFormat < 0.56.2 не публикует продукт-плагин.
        .package(url: "https://github.com/nicklockwood/SwiftFormat", from: "0.56.2"),
        // SwiftLint < 0.55.0 публикует только build-tool-плагин, который
        // запускается на каждой сборке; command-плагин (верб `swiftlint`)
        // появился в 0.55.0. Это первый релиз с нужной нам командой.
        .package(url: "https://github.com/realm/SwiftLint", from: "0.55.0"),
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
            dependencies: ["AudioEngineGuard"],
            plugins: [
                .plugin(name: "SwiftFormatPlugin", package: "SwiftFormat"),
                .plugin(name: "SwiftLintCommandPlugin", package: "SwiftLint"),
            ]
        ),
        .executableTarget(
            name: "NanoDictateAgent",
            dependencies: ["NanoDictateCore"],
            plugins: [
                .plugin(name: "SwiftFormatPlugin", package: "SwiftFormat"),
                .plugin(name: "SwiftLintCommandPlugin", package: "SwiftLint"),
            ]
        ),
        .executableTarget(
            name: "nanodictate",
            dependencies: ["NanoDictateCore"],
            plugins: [
                .plugin(name: "SwiftFormatPlugin", package: "SwiftFormat"),
                .plugin(name: "SwiftLintCommandPlugin", package: "SwiftLint"),
            ]
        ),
        // Компактный раннер тестов: на этой машине нет Xcode / XCTest.framework,
        // поэтому `swift test` физически не работает ("XCTest not available").
        // Исполняемый таргет прогоняет те же проверки и завершается с ненулевым
        // кодом при первом упавшем тесте: `swift run NanoDictateCoreTests`.
        .executableTarget(
            name: "NanoDictateCoreTests",
            dependencies: ["NanoDictateCore", "AudioEngineGuard"],
            path: "Tests/NanoDictateCoreTests"
        ),
    ]
)
