import Foundation

/// リアルタイム挿入モードで、確定テキストをためて句読点または無音の間で区切って返す。
public struct RealtimeChunker: Sendable {
    private let gap: TimeInterval
    private var buffer = ""
    private var lastAppend: TimeInterval = 0

    private static let punctuation: Set<Character> = ["。", "、", "！", "？", ".", ",", "!", "?"]

    public init(gap: TimeInterval = 0.5) {
        self.gap = gap
    }

    public mutating func append(_ finalText: String, at t: TimeInterval) -> String? {
        guard !finalText.isEmpty else { return nil }
        buffer += finalText
        lastAppend = t
        guard let last = buffer.last(where: { !$0.isWhitespace }),
              Self.punctuation.contains(last) else { return nil }
        return flush()
    }

    public mutating func tick(at t: TimeInterval) -> String? {
        guard !buffer.isEmpty, t - lastAppend >= gap else { return nil }
        return flush()
    }

    public mutating func flush() -> String? {
        guard !buffer.isEmpty else { return nil }
        defer { buffer = "" }
        return buffer
    }
}
