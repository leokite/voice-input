import Foundation

public struct HistoryEntry: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var date: Date
    public var text: String
    public var rawText: String
    public var duration: TimeInterval
    public var inserted: Bool

    public init(id: UUID = UUID(), date: Date, text: String, rawText: String,
                duration: TimeInterval, inserted: Bool) {
        self.id = id
        self.date = date
        self.text = text
        self.rawText = rawText
        self.duration = duration
        self.inserted = inserted
    }
}

public struct History: Codable, Equatable, Sendable {
    public var entries: [HistoryEntry]

    public init(entries: [HistoryEntry] = []) {
        self.entries = entries
    }

    /// Inserts the entry newest-first and drops the oldest beyond `limit`.
    public mutating func add(_ e: HistoryEntry, limit: Int) {
        entries.insert(e, at: 0)
        if entries.count > limit {
            entries.removeLast(entries.count - max(limit, 0))
        }
    }
}
