import Foundation

public enum CharacterAccuracy {
    private static let ignored: Set<Character> = Set("。、，．！？,.!?")

    /// 空白と句読点を消し、英字を小文字にする。
    public static func normalize(_ s: String) -> String {
        String(s.lowercased().filter { !$0.isWhitespace && !ignored.contains($0) })
    }

    /// 1 − (文字単位の編集距離 ÷ 期待する文の文字数) を 0〜1 に収める。
    public static func score(expected: String, actual: String) -> Double {
        let e = Array(normalize(expected))
        let a = Array(normalize(actual))
        if e.isEmpty { return a.isEmpty ? 1.0 : 0.0 }
        let distance = levenshtein(e, a)
        return min(1.0, max(0.0, 1.0 - Double(distance) / Double(e.count)))
    }

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
