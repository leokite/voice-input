import Foundation

public struct Term: Codable, Equatable, Hashable, Sendable {
    public var text: String
    public var lastUsed: Date?

    public init(text: String, lastUsed: Date? = nil) {
        self.text = text
        self.lastUsed = lastUsed
    }
}

public struct Replacement: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var from: String
    public var to: String
    public var lastUsed: Date?

    public init(id: UUID = UUID(), from: String, to: String, lastUsed: Date? = nil) {
        self.id = id
        self.from = from
        self.to = to
        self.lastUsed = lastUsed
    }
}

public struct Glossary: Codable, Equatable, Sendable {
    public var terms: [Term]
    public var replacements: [Replacement]

    public static let empty = Glossary(terms: [], replacements: [])

    public init(terms: [Term] = [], replacements: [Replacement] = []) {
        self.terms = terms
        self.replacements = replacements
    }

    public mutating func addTerm(_ text: String) {
        guard !text.isEmpty, !terms.contains(where: { $0.text == text }) else { return }
        terms.append(Term(text: text))
    }

    public mutating func addCorrection(from: String, to: String) {
        if let index = replacements.firstIndex(where: { $0.from == from }) {
            replacements[index].to = to
        } else {
            replacements.append(Replacement(from: from, to: to))
        }
        addTerm(to)
    }

    public mutating func markUsed(_ texts: Set<String>, at date: Date) {
        for i in terms.indices where texts.contains(terms[i].text) {
            terms[i].lastUsed = date
        }
        for i in replacements.indices where texts.contains(replacements[i].to) {
            replacements[i].lastUsed = date
        }
    }

    public func contextTerms(budgetChars: Int = 9000) -> (terms: [String], truncated: Bool) {
        var latest: [String: Date?] = [:]
        var order: [String] = []
        let entries = terms.map { ($0.text, $0.lastUsed) } + replacements.map { ($0.to, $0.lastUsed) }
        for (text, used) in entries where !text.isEmpty {
            if let existing = latest[text] {
                if let used, existing.map({ used > $0 }) ?? true { latest[text] = used }
            } else {
                latest[text] = used
                order.append(text)
            }
        }
        let indexed = order.enumerated().sorted { a, b in
            let da = latest[a.element] ?? nil
            let db = latest[b.element] ?? nil
            switch (da, db) {
            case let (x?, y?) where x != y: return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            default: return a.offset < b.offset
            }
        }
        var result: [String] = []
        var total = 0
        for (_, text) in indexed {
            if total + text.count > budgetChars { return (result, true) }
            total += text.count
            result.append(text)
        }
        return (result, false)
    }
}
