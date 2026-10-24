import Foundation

public struct ProcessedText: Equatable, Sendable {
    public var text: String
    public var usedTerms: Set<String>

    public init(text: String, usedTerms: Set<String>) {
        self.text = text
        self.usedTerms = usedTerms
    }
}

public struct TextPipeline: Sendable {
    private let fillers: FillerRemover
    private let glossary: Glossary

    public init(fillers: FillerRemover, glossary: Glossary) {
        self.fillers = fillers
        self.glossary = glossary
    }

    public func process(_ raw: String) -> ProcessedText {
        var text = fillers.clean(raw)
        let ordered = glossary.replacements
            .filter { !$0.from.isEmpty }
            .sorted { $0.from.count > $1.from.count }
        for r in ordered {
            text = text.replacingOccurrences(of: r.from, with: r.to)
        }
        let candidates = Set(glossary.terms.map(\.text) + glossary.replacements.map(\.to))
        let used = candidates.filter { !$0.isEmpty && text.contains($0) }
        return ProcessedText(text: text, usedTerms: used)
    }
}
