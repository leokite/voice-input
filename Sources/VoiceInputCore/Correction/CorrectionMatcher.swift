import Foundation

/// 履歴の文字列（from）を、ユーザーが選んだ文字列（to）に直した組み合わせ。
public struct CorrectionPair: Equatable, Hashable, Sendable {
    public var from: String
    public var to: String

    public init(from: String, to: String) {
        self.from = from
        self.to = to
    }
}

/// 選択と履歴を比べた結果。
public struct CorrectionCandidates: Equatable, Sendable {
    public var entryID: UUID
    /// 比べた履歴の `text`。
    public var sentence: String
    /// 置き換え元までプログラムで決まった組み合わせ。
    public var pairs: [CorrectionPair]
    /// 置き換え元を決められなかった、選択側の語（読みの近い部分がない端の直しや、単語だけの選択）。
    public var unresolved: [String]

    public init(entryID: UUID, sentence: String, pairs: [CorrectionPair], unresolved: [String]) {
        self.entryID = entryID
        self.sentence = sentence
        self.pairs = pairs
        self.unresolved = unresolved
    }
}

/// ユーザーが選んだ文字列と最近の音声入力の履歴を比べて、直した箇所を取り出す。
public enum CorrectionMatcher {
    static let similarityThreshold = 0.4
    /// 共通の文字が、これだけ続けて一致していれば、全体の割合が低くても前後を含めた選択とみなす
    /// （「Reactで作る」のように、直した語が長く、前後が短い選択のため）。
    static let minAnchorRun = 3
    static let maxEdits = 3
    static let maxEditLength = 30
    static let maxWordLength = 30

    public static func match(selection: String, history: [HistoryEntry], now: Date,
                             maxEntries: Int = 5, window: TimeInterval = 600) -> CorrectionCandidates? {
        let trimmed = selection.trimmingCharacters(in: Self.edgeJunk)
        guard !trimmed.isEmpty else { return nil }
        let entries = history
            .filter { now.timeIntervalSince($0.date) <= window }
            .sorted { $0.date > $1.date }
            .prefix(maxEntries)
        guard let newest = entries.first else { return nil }
        if entries.contains(where: { $0.text.contains(trimmed) }) { return nil }

        let sel = Array(trimmed)
        var best: (entry: HistoryEntry, ratio: Double, table: LCSTable)?
        for entry in entries {
            let table = LCSTable(Array(entry.text), sel)
            let ratio = Double(table.length) / Double(sel.count)
            guard ratio >= similarityThreshold || table.longestRun() >= minAnchorRun else { continue }
            if best == nil || ratio > best!.ratio { best = (entry, ratio, table) }
        }

        if let best {
            let (pairs, unresolved) = edits(best.table)
            let count = pairs.count + unresolved.count
            let tooLong = pairs.contains { $0.from.count > maxEditLength || $0.to.count > maxEditLength }
                || unresolved.contains { $0.count > maxEditLength }
            guard count > 0, count <= maxEdits, !tooLong else { return nil }
            return CorrectionCandidates(entryID: best.entry.id, sentence: best.entry.text,
                                        pairs: pairs, unresolved: unresolved)
        }

        guard sel.count <= maxWordLength else { return nil }
        return CorrectionCandidates(entryID: newest.id, sentence: newest.text, pairs: [], unresolved: [trimmed])
    }

    /// 端から落とす空白と句読点。
    static let edgeJunk = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

    /// 対応をたどって差分を取り出す。両側が一致に挟まれた差分は組み合わせにする。
    /// 選択の端の差分は、読みの近い置き換え元が見つかれば組み合わせに、見つからなければ未解決にする。
    /// 空白だけの一致を挟んだ差分は 1 つにまとめる（"CI" → "GitHub Actions" のような語の直しを分けないため）。
    static func edits(_ t: LCSTable) -> (pairs: [CorrectionPair], unresolved: [String]) {
        let matches = t.alignment()
        guard let first = matches.first, let last = matches.last else { return ([], []) }

        var unresolved: [String] = []
        var edgePairs: [CorrectionPair] = []
        // 選択の端の直しは、履歴でその手前（後ろ）にある部分から、読みが近いものを置き換え元にする。
        let leading = String(t.b[0..<first.j]).trimmingCharacters(in: edgeJunk)
        if !leading.isEmpty {
            if let source = Phonetic.bestSuffix(of: String(t.a[0..<first.i]), soundingLike: leading) {
                edgePairs.append(CorrectionPair(from: source, to: leading))
            } else {
                unresolved.append(leading)
            }
        }

        // 一致の連続（run）と、その間の差分（gap）に分ける。
        struct Gap { var from: String; var to: String; var runBefore: String }
        var gaps: [Gap] = []
        var run = String(t.a[first.i])
        for (prev, next) in zip(matches, matches.dropFirst()) {
            let from = String(t.a[(prev.i + 1)..<next.i])
            let to = String(t.b[(prev.j + 1)..<next.j])
            if from.isEmpty && to.isEmpty {
                run.append(t.a[next.i])
            } else {
                gaps.append(Gap(from: from, to: to, runBefore: run))
                run = String(t.a[next.i])
            }
        }

        var merged: [CorrectionPair] = []
        for (index, gap) in gaps.enumerated() {
            if index > 0, gap.runBefore.allSatisfy(\.isWhitespace), var previous = merged.popLast() {
                previous.from += gap.runBefore + gap.from
                previous.to += gap.runBefore + gap.to
                merged.append(previous)
            } else {
                merged.append(CorrectionPair(from: gap.from, to: gap.to))
            }
        }
        let pairs = merged.map {
            CorrectionPair(from: $0.from.trimmingCharacters(in: edgeJunk),
                           to: $0.to.trimmingCharacters(in: edgeJunk))
        }

        let trailing = String(t.b[(last.j + 1)...]).trimmingCharacters(in: edgeJunk)
        if !trailing.isEmpty {
            if let source = Phonetic.bestPrefix(of: String(t.a[(last.i + 1)...]), soundingLike: trailing) {
                edgePairs.append(CorrectionPair(from: source, to: trailing))
            } else {
                unresolved.append(trailing)
            }
        }
        return (edgePairs.prefix(1) + pairs + edgePairs.dropFirst(), unresolved)
    }
}

/// 2 つの文字列の最長共通部分列（文字単位）。`dp[i][j]` は a[i...] と b[j...] の LCS の長さ。
struct LCSTable {
    let a: [Character]
    let b: [Character]
    private let dp: [[Int]]

    init(_ a: [Character], _ b: [Character]) {
        self.a = a
        self.b = b
        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
            }
        }
        self.dp = dp
    }

    var length: Int { dp[0][0] }

    /// 対応の中で、両側で続けて一致している文字の最長の長さ。
    func longestRun() -> Int {
        var longest = 0, current = 0
        var previous: (i: Int, j: Int)?
        for m in alignment() {
            if let p = previous, m.i == p.i + 1, m.j == p.j + 1 { current += 1 } else { current = 1 }
            longest = max(longest, current)
            previous = m
        }
        return longest
    }

    /// 一致した文字の位置（a の i、b の j）を前から順に返す。
    func alignment() -> [(i: Int, j: Int)] {
        var result: [(i: Int, j: Int)] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] && dp[i][j] == dp[i + 1][j + 1] + 1 {
                result.append((i, j))
                i += 1
                j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        return result
    }
}
