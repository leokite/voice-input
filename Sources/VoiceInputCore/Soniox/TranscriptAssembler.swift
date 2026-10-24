import Foundation

public struct AssemblerUpdate: Equatable, Sendable {
    public var newFinalText: String
    public var partialText: String
    public var reachedFin: Bool
}

/// Soniox の確定トークンを連結し、仮トークンは毎回置き換える。
public struct TranscriptAssembler: Sendable {
    public private(set) var finalText: String = ""

    public init() {}

    public mutating func ingest(_ r: SonioxResponse) -> AssemblerUpdate {
        var newFinal = ""
        var partial = ""
        var reachedFin = false
        for token in r.tokens {
            if token.isFinal {
                if token.text == "<fin>" { reachedFin = true; continue }
                if token.text == "<end>" { continue }
                newFinal += token.text
            } else {
                partial += token.text
            }
        }
        finalText += newFinal
        return AssemblerUpdate(newFinalText: newFinal, partialText: partial, reachedFin: reachedFin)
    }
}
