// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceInput",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VoiceInputCore", targets: ["VoiceInputCore"]),
        .executable(name: "voice-eval", targets: ["voice-eval"]),
    ],
    targets: [
        .target(name: "VoiceInputCore"),
        .executableTarget(name: "voice-eval", dependencies: ["VoiceInputCore"]),
        .testTarget(
            name: "VoiceInputCoreTests",
            dependencies: ["VoiceInputCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
