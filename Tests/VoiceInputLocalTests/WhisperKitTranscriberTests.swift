import Foundation
import Testing
import VoiceInputCore
@testable import VoiceInputLocal

@Suite struct WhisperKitTranscriberTests {
    @Test func noLanguageLetsWhisperDetect() {
        let options = WhisperKitTranscriber.decodingOptions(language: nil, promptTokens: [])
        #expect(options.language == nil)
        #expect(options.detectLanguage)
        #expect(options.promptTokens == nil)
    }

    @Test func fixedLanguageSkipsDetection() {
        let options = WhisperKitTranscriber.decodingOptions(language: "ja", promptTokens: [])
        #expect(options.language == "ja")
        #expect(!options.detectLanguage)
        #expect(options.temperature == 0)
        #expect(options.skipSpecialTokens)
    }

    @Test func promptTokensUsePrefill() {
        let options = WhisperKitTranscriber.decodingOptions(language: "en", promptTokens: [10, 20])
        #expect(options.promptTokens == [10, 20])
        #expect(options.usePrefillPrompt)
    }

    @Test func samplesAreScaledFromInt16() {
        let pcm = Data([0x00, 0x80, 0xFF, 0x7F, 0x00, 0x00])
        #expect(WhisperKitTranscriber.samples(from: pcm) == [-1, Float(32767) / 32768, 0])
    }

    @Test func missingModelFailsWithoutLoading() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperKitTranscriberTests-\(UUID().uuidString)", isDirectory: true)
        let transcriber = WhisperKitTranscriber(base: base)
        await #expect(throws: LocalTranscriptionError.self) {
            try await transcriber.transcribe(pcm: Data(count: 3200), languageHints: ["ja"], terms: [])
        }
    }

    // 読めないトークナイザーで WhisperKit を作ると取得しに行くので、作る前に断る（ここで WhisperKit を作れば通信が起こりうる）
    @Test func brokenTokenizerFailsBeforeCreatingWhisperKit() async throws {
        let base = try ModelFixture.makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try ModelFixture.install(base: base, tokenizerConfig: "not json")
        #expect(LocalModelLayout.isInstalled(base: base))
        let transcriber = WhisperKitTranscriber(base: base)
        await #expect(throws: LocalTranscriptionError(message: "ローカルのモデルが導入されていないか、壊れています")) {
            try await transcriber.transcribe(pcm: Data(count: 3200), languageHints: ["ja"], terms: [])
        }
    }
}

/// モデルを使わずに、導入済みの形だけを temp に作る
enum ModelFixture {
    static func makeBase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("VoiceInputLocalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func install(base: URL, tokenizerConfig: String = #"{"version":"1.0"}"#) throws {
        let model = LocalModelLayout.modelFolder(base: base)
        var files: [(URL, String)] = [(model.appendingPathComponent("config.json"), "{}")]
        for name in ["AudioEncoder", "TextDecoder", "MelSpectrogram", "TextDecoderContextPrefill"] {
            let dir = model.appendingPathComponent("\(name).mlmodelc")
            files.append((dir.appendingPathComponent("coremldata.bin"), "x"))
            files.append((dir.appendingPathComponent("weights/weight.bin"), "x"))
        }
        let tokenizer = LocalModelLayout.tokenizerFolder(base: base)
        files.append((tokenizer.appendingPathComponent("tokenizer.json"), #"{"version":"1.0"}"#))
        files.append((tokenizer.appendingPathComponent("tokenizer_config.json"), tokenizerConfig))
        for (url, text) in files {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
    }
}

@MainActor
@Suite struct LocalModelManagerTests {
    @Test func deleteRemovesOnlyModelsFolder() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalModelManagerTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let model = LocalModelLayout.modelFolder(base: base).appendingPathComponent("config.json")
        let tokenizer = LocalModelLayout.tokenizerFolder(base: base).appendingPathComponent("tokenizer.json")
        let other = base.appendingPathComponent("keep.txt")
        for file in [model, tokenizer, other] {
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: file)
        }

        let manager = LocalModelManager(base: base)
        try await manager.delete()

        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("models").path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(manager.status == .notInstalled)
    }

    @Test func deleteWithoutModelsSucceeds() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalModelManagerTests-\(UUID().uuidString)", isDirectory: true)
        let manager = LocalModelManager(base: base)
        try await manager.delete()
        #expect(manager.status == .notInstalled)
    }

    @Test func installedModelIsReady() throws {
        let base = try ModelFixture.makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try ModelFixture.install(base: base)
        #expect(LocalModelManager(base: base).status == .ready)
    }

    @Test func brokenTokenizerIsNotReady() throws {
        let base = try ModelFixture.makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try ModelFixture.install(base: base, tokenizerConfig: "not json")
        let manager = LocalModelManager(base: base)
        guard case .failed = manager.status else {
            Issue.record("\(manager.status)")
            return
        }
        manager.refresh()
        #expect(manager.status != .ready)
    }

    @Test func loadFailureStaysVisibleUntilDeleted() async throws {
        let base = try ModelFixture.makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try ModelFixture.install(base: base)
        let manager = LocalModelManager(base: base)
        manager.loadFailed("メモリが足りません")
        guard case .failed(let reason) = manager.status else {
            Issue.record("\(manager.status)")
            return
        }
        #expect(reason.contains("メモリが足りません"))
        // 設定画面を開いたときの見直しで消さない
        manager.refresh()
        #expect(manager.status == .failed(reason))
        try await manager.delete()
        #expect(manager.status == .notInstalled)
        #expect(!LocalModelLayout.hasFiles(base: base))
    }

    @Test func loadFailureIsIgnoredUnlessReady() {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalModelManagerTests-\(UUID().uuidString)", isDirectory: true)
        let manager = LocalModelManager(base: base)
        // 削除の後に届いた読み込みの失敗で、未導入を失敗に変えない
        manager.loadFailed("x")
        #expect(manager.status == .notInstalled)
    }
}
