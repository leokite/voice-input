import Foundation

/// 端末内の文字起こし。`pcm` は 16kHz、モノラル、s16le。
public protocol LocalTranscriber: Sendable {
    func transcribe(pcm: Data, languageHints: [String], terms: [String]) async throws -> String
}

public struct LocalTranscriptionError: Error, Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }
}
