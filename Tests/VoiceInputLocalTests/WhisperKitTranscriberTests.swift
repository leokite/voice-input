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
}

@MainActor
@Suite struct LocalModelManagerTests {
    @Test func deleteRemovesOnlyModelsFolder() throws {
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
        try manager.delete()

        #expect(!FileManager.default.fileExists(atPath: base.appendingPathComponent("models").path))
        #expect(FileManager.default.fileExists(atPath: other.path))
        #expect(manager.status == .notInstalled)
    }

    @Test func deleteWithoutModelsSucceeds() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalModelManagerTests-\(UUID().uuidString)", isDirectory: true)
        let manager = LocalModelManager(base: base)
        try manager.delete()
        #expect(manager.status == .notInstalled)
    }
}
