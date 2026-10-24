import Foundation

/// Soniox リアルタイム WebSocket の最初に送る設定 JSON。
public struct SonioxConfig: Encodable, Equatable, Sendable {
    public struct ContextEntry: Encodable, Equatable, Sendable {
        public let key: String
        public let value: String
    }

    public struct Context: Encodable, Equatable, Sendable {
        public let general: [ContextEntry]
        public let terms: [String]
    }

    public let model = "stt-rt-v5"
    public let audioFormat = "pcm_s16le"
    public let sampleRate = 16000
    public let numChannels = 1
    public let languageHints: [String]
    public let enableEndpointDetection = false
    public let context: Context

    public init(languageHints: [String], terms: [String]) {
        self.languageHints = languageHints
        self.context = Context(
            general: [ContextEntry(key: "domain", value: "ソフトウェア開発")],
            terms: terms
        )
    }

    enum CodingKeys: String, CodingKey {
        case model
        case audioFormat = "audio_format"
        case sampleRate = "sample_rate"
        case numChannels = "num_channels"
        case languageHints = "language_hints"
        case enableEndpointDetection = "enable_endpoint_detection"
        case context
    }
}

public struct SonioxToken: Decodable, Equatable, Sendable {
    public let text: String
    public let isFinal: Bool

    public init(text: String, isFinal: Bool) {
        self.text = text
        self.isFinal = isFinal
    }

    enum CodingKeys: String, CodingKey {
        case text
        case isFinal = "is_final"
    }
}

public struct SonioxResponse: Decodable, Equatable, Sendable {
    public let tokens: [SonioxToken]
    public let finished: Bool
    public let errorCode: String?
    public let errorMessage: String?

    public init(tokens: [SonioxToken], finished: Bool, errorCode: String?, errorMessage: String?) {
        self.tokens = tokens
        self.finished = finished
        self.errorCode = errorCode
        self.errorMessage = errorMessage
    }

    enum CodingKeys: String, CodingKey {
        case tokens
        case finished
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try c.decodeIfPresent([SonioxToken].self, forKey: .tokens) ?? []
        finished = try c.decodeIfPresent(Bool.self, forKey: .finished) ?? false
        errorMessage = try c.decodeIfPresent(String.self, forKey: .errorMessage)
        if let s = try? c.decodeIfPresent(String.self, forKey: .errorCode) {
            errorCode = s
        } else if let n = try? c.decodeIfPresent(Int.self, forKey: .errorCode) {
            errorCode = String(n)
        } else {
            errorCode = nil
        }
    }
}
