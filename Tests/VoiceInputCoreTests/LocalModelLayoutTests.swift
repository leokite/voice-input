import Foundation
import Testing
@testable import VoiceInputCore

@Suite struct LocalModelLayoutTests {
    private func makeBase() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalModelLayoutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func touch(_ url: URL, directory: Bool) throws {
        if directory {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
    }

    private func installModel(base: URL, skipping skipped: String? = nil) throws {
        let folder = LocalModelLayout.modelFolder(base: base)
        for name in [
            "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc",
            "TextDecoderContextPrefill.mlmodelc",
        ]
        where name != skipped {
            let dir = folder.appendingPathComponent(name)
            try touch(dir.appendingPathComponent("coremldata.bin"), directory: false)
            try touch(dir.appendingPathComponent("weights/weight.bin"), directory: false)
        }
        try touch(folder.appendingPathComponent("config.json"), directory: false)
    }

    private func installTokenizer(base: URL) throws {
        let folder = LocalModelLayout.tokenizerFolder(base: base)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for name in ["tokenizer.json", "tokenizer_config.json"] {
            try Data(#"{"version":"1.0"}"#.utf8).write(to: folder.appendingPathComponent(name))
        }
    }

    private func complete(_ base: URL) throws {
        try installModel(base: base)
        try installTokenizer(base: base)
    }

    @Test func pathsMatchLayout() {
        let support = URL(fileURLWithPath: "/tmp/support", isDirectory: true)
        let base = LocalModelLayout.downloadBase(supportDirectory: support)
        #expect(base.path == "/tmp/support/Models")
        #expect(LocalModelLayout.modelFolder(base: base).path
            == "/tmp/support/Models/models/argmaxinc/whisperkit-coreml/openai_whisper-large-v3-v20240930_turbo")
        #expect(LocalModelLayout.tokenizerFolder(base: base).path
            == "/tmp/support/Models/models/openai/whisper-large-v3")
    }

    @Test func emptyDirectoryIsNotInstalled() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(!LocalModelLayout.isInstalled(base: base))
    }

    @Test func modelWithoutTokenizerIsNotInstalled() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try installModel(base: base)
        #expect(!LocalModelLayout.isInstalled(base: base))
    }

    @Test func modelMissingEncoderIsNotInstalled() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try installModel(base: base, skipping: "AudioEncoder.mlmodelc")
        try installTokenizer(base: base)
        #expect(!LocalModelLayout.isInstalled(base: base))
    }

    @Test func completeLayoutIsInstalled() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try installModel(base: base)
        try installTokenizer(base: base)
        #expect(LocalModelLayout.isInstalled(base: base))
    }

    @Test func emptyMlmodelcDirectoryIsNotInstalled() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try complete(base)
        let dir = LocalModelLayout.modelFolder(base: base).appendingPathComponent("TextDecoder.mlmodelc")
        try FileManager.default.removeItem(at: dir)
        try touch(dir, directory: true)
        #expect(!LocalModelLayout.isInstalled(base: base))
    }

    @Test func mlmodelcMissingWeightsIsNotInstalled() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try complete(base)
        let weights = LocalModelLayout.modelFolder(base: base)
            .appendingPathComponent("AudioEncoder.mlmodelc/weights/weight.bin")
        try FileManager.default.removeItem(at: weights)
        #expect(!LocalModelLayout.isInstalled(base: base))
    }

    @Test func zeroByteTokenizerIsNotInstalled() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try complete(base)
        let file = LocalModelLayout.tokenizerFolder(base: base).appendingPathComponent("tokenizer.json")
        try Data().write(to: file)
        #expect(!LocalModelLayout.isInstalled(base: base))
    }

    @Test func zeroByteConfigIsNotInstalled() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try complete(base)
        try Data().write(to: LocalModelLayout.modelFolder(base: base).appendingPathComponent("config.json"))
        #expect(!LocalModelLayout.isInstalled(base: base))
    }

    @Test func fileWhereDirectoryExpectedIsNotInstalled() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try complete(base)
        let dir = LocalModelLayout.modelFolder(base: base).appendingPathComponent("MelSpectrogram.mlmodelc")
        try FileManager.default.removeItem(at: dir)
        try Data("x".utf8).write(to: dir)
        #expect(!LocalModelLayout.isInstalled(base: base))
    }

    @Test func contextPrefillMissingWeightsIsNotInstalled() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try complete(base)
        let weights = LocalModelLayout.modelFolder(base: base)
            .appendingPathComponent("TextDecoderContextPrefill.mlmodelc/weights/weight.bin")
        try FileManager.default.removeItem(at: weights)
        #expect(!LocalModelLayout.isInstalled(base: base))
    }

    @Test func missingTokenizerConfigIsNotInstalled() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try complete(base)
        try FileManager.default.removeItem(
            at: LocalModelLayout.tokenizerFolder(base: base).appendingPathComponent("tokenizer_config.json"))
        #expect(!LocalModelLayout.isInstalled(base: base))
    }

    @Test func validTokenizerFilesPass() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try complete(base)
        #expect(LocalModelLayout.tokenizerFilesAreValid(base: base))
    }

    @Test(arguments: ["tokenizer.json", "tokenizer_config.json"])
    func truncatedTokenizerFileIsInvalid(name: String) throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try complete(base)
        let file = LocalModelLayout.tokenizerFolder(base: base).appendingPathComponent(name)
        try Data(#"{"version":"1."#.utf8).write(to: file)
        #expect(!LocalModelLayout.tokenizerFilesAreValid(base: base))
    }

    @Test func emptyTokenizerFileIsInvalid() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try complete(base)
        try Data().write(to: LocalModelLayout.tokenizerFolder(base: base).appendingPathComponent("tokenizer.json"))
        #expect(!LocalModelLayout.tokenizerFilesAreValid(base: base))
    }

    @Test func nonObjectTokenizerFileIsInvalid() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try complete(base)
        try Data("[1, 2]".utf8)
            .write(to: LocalModelLayout.tokenizerFolder(base: base).appendingPathComponent("tokenizer_config.json"))
        #expect(!LocalModelLayout.tokenizerFilesAreValid(base: base))
    }

    @Test func missingTokenizerIsInvalid() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        try installModel(base: base)
        #expect(!LocalModelLayout.tokenizerFilesAreValid(base: base))
    }

    @Test func leftoverFilesAreDetected() throws {
        let base = try makeBase()
        defer { try? FileManager.default.removeItem(at: base) }
        #expect(!LocalModelLayout.hasFiles(base: base))
        try touch(LocalModelLayout.modelFolder(base: base).appendingPathComponent("config.json"), directory: false)
        #expect(LocalModelLayout.hasFiles(base: base))
    }
}
