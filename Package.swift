// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceInput",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VoiceInputCore", targets: ["VoiceInputCore"]),
        .library(name: "VoiceInputLocal", targets: ["VoiceInputLocal"]),
        .executable(name: "voice-eval", targets: ["voice-eval"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "1.1.1"),
    ],
    targets: [
        .target(name: "VoiceInputCore"),
        // WhisperKit に依存する部分はここだけに置く（VoiceInputCore は依存なしのまま）
        .target(
            name: "VoiceInputLocal",
            dependencies: ["VoiceInputCore", .product(name: "WhisperKit", package: "WhisperKit")]
        ),
        .executableTarget(name: "voice-eval", dependencies: ["VoiceInputCore", "VoiceInputLocal"]),
        .testTarget(
            name: "VoiceInputCoreTests",
            dependencies: ["VoiceInputCore"],
            resources: [.copy("Fixtures")]
        ),
        // モデルを使わずに確かめられる部分だけを試す
        .testTarget(name: "VoiceInputLocalTests", dependencies: ["VoiceInputLocal"]),
    ]
)
