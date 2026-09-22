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
    // Линтеры не живут в SPM-графе: свежие релизы SwiftLint требуют
    // tools-version 5.9, локальный тулчейн — 5.7; резолвинг зависимостей
    // падает. Линтеры работают как внешние бинари: pre-commit хук (.githooks)
    // и отдельные шаги CI.
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
    ]
)
