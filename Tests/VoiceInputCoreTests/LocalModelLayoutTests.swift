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
        for name in ["AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc"]
        where name != skipped {
            try touch(folder.appendingPathComponent(name), directory: true)
        }
        try touch(folder.appendingPathComponent("config.json"), directory: false)
    }

    private func installTokenizer(base: URL) throws {
        try touch(
            LocalModelLayout.tokenizerFolder(base: base).appendingPathComponent("tokenizer.json"),
            directory: false)
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
}
