// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VoiceInput",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "VoiceInputCore", targets: ["VoiceInputCore"]),
        .library(name: "VoiceInputLocal", targets: ["VoiceInputLocal"]),
        .executable(name: "voice-eval", targets: ["voice-eval"]),
        .executable(name: "judge-eval", targets: ["judge-eval"]),
        .executable(name: "source-eval", targets: ["source-eval"]),
    ],
    dependencies: [
        // 通信しないことは 1.1.1 の中身（トークナイザーの探し方と取得への切り替え、download と modelFolder の扱い、
        // 保存の形、detectLangauge）に頼っている。上げるときは、取得に行く道がないかを確かめ直す。
        // Xcode のビルドは Package.resolved を見ないので、版を固定する。
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.1"),
    ],
    targets: [
        .target(name: "VoiceInputCore"),
        // WhisperKit に依存する部分はここだけに置く（VoiceInputCore は依存なしのまま）
        .target(
            name: "VoiceInputLocal",
            dependencies: ["VoiceInputCore", .product(name: "WhisperKit", package: "WhisperKit")]
        ),
        .executableTarget(name: "voice-eval", dependencies: ["VoiceInputCore", "VoiceInputLocal"]),
        // 端末内AIの「普通の言葉か」の判定精度を測る
        .executableTarget(name: "judge-eval", dependencies: ["VoiceInputCore"]),
        // 端末内AIで置き換え元を探す方式の精度を測る
        .executableTarget(name: "source-eval", dependencies: ["VoiceInputCore"]),
        .testTarget(
            name: "VoiceInputCoreTests",
            dependencies: ["VoiceInputCore"],
            resources: [.copy("Fixtures")]
        ),
        // モデルを使わずに確かめられる部分だけを試す
        .testTarget(name: "VoiceInputLocalTests", dependencies: ["VoiceInputLocal"]),
    ]
)
