import Foundation

public enum GroupMeans {
    public struct Entry: Equatable, Sendable {
        public let group: String
        public let mean: Double
    }

    /// グループごとの平均。順番は最初に出た順。group が nil のケースは数えない。
    public static func compute(scores: [Double], groups: [String?]) -> [Entry] {
        var order: [String] = []
        var sums: [String: (sum: Double, count: Int)] = [:]
        for (score, group) in zip(scores, groups) {
            guard let group else { continue }
            if sums[group] == nil { order.append(group) }
            let cur = sums[group] ?? (0, 0)
            sums[group] = (cur.sum + score, cur.count + 1)
        }
        return order.map { Entry(group: $0, mean: sums[$0]!.sum / Double(sums[$0]!.count)) }
    }
}
