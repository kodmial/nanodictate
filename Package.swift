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
        .target(
            name: "DictationCore",
            dependencies: []
        ),
        .executableTarget(
            name: "DictatorAgent",
            dependencies: ["DictationCore"]
        ),
        .executableTarget(
            name: "dictatorctl",
            dependencies: ["DictationCore"]
        ),
        .testTarget(
            name: "DictationCoreTests",
            dependencies: ["DictationCore"]
        )
    ]
)