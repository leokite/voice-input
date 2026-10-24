import Foundation

/// 読み（ローマ字）の近さで、誤認識された部分を探す。
/// 例:「Docker」に直した選択の手前にある「今日はどうか」から、読みが近い「どうか」を見つける。
public enum Phonetic {
    /// これより遠い候補は使わない（0 が同じ読み、1 がまったく違う読み）。
    public static let maxDistance = 0.6
    /// 拗音・促音・長音の記号から始まる候補は、語の途中から切り出したものなので候補にしない。
    private static let nonInitial = Set("ゃゅょぁぃぅぇぉっゎャュョァィゥェォッヮー")
    /// 促音で終わる候補は、語の途中で切ったものなので候補にしない。
    private static let nonFinal = Set("っッ")

    /// 読みのローマ字。漢字は日本語の読みに、かなはまとめてローマ字に（促音を正しく扱うため）、英字は小文字にする。
    /// 長音記号などの補助記号は落とす。
    public static func reading(_ s: String) -> String {
        let cf = s as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cf))
        let tokenizer = CFStringTokenizerCreate(nil, cf, range, kCFStringTokenizerUnitWord,
                                                Locale(identifier: "ja") as CFLocale)
        var mixed = ""
        var cursor = 0
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            mixed += (s as NSString).substring(with: NSRange(location: cursor, length: r.location - cursor))
            let token = (s as NSString).substring(with: NSRange(location: r.location, length: r.length))
            if token.unicodeScalars.contains(where: isKanji),
               let latin = CFStringTokenizerCopyCurrentTokenAttribute(
                   tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String {
                mixed += latin
            } else {
                mixed += token
            }
            cursor = r.location + r.length
        }
        mixed += (s as NSString).substring(from: cursor)
        let latin = NSMutableString(string: mixed)
        CFStringTransform(latin, nil, kCFStringTransformToLatin, false)
        return (latin as String).folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .filter { $0.isASCII && $0.isLetter }
    }

    private static func isKanji(_ u: Unicode.Scalar) -> Bool {
        (0x4E00...0x9FFF).contains(u.value) || (0x3400...0x4DBF).contains(u.value)
    }

    /// 読みの編集距離を、長い方の長さで割ったもの。
    public static func distance(_ a: String, _ b: String) -> Double {
        let x = Array(reading(a)), y = Array(reading(b))
        guard !x.isEmpty || !y.isEmpty else { return 0 }
        return Double(editDistance(x, y)) / Double(max(x.count, y.count))
    }

    /// 語の区切りに使う助詞。候補の端がこれだと、語の途中から切り出したことになる。
    private static let particles: Set<String> = ["は", "が", "を", "の", "に", "で", "と", "へ", "も", "や"]

    /// context の末尾の部分のうち、word と読みがいちばん近いもの。maxDistance より遠ければ nil。
    /// 候補は語の区切りから始まるものだけにし、助詞から始まるものは除く（「これはリア」の「れはリア」などを選ばない）。
    public static func bestSuffix(of context: String, soundingLike word: String) -> String? {
        let chars = Array(context)
        let tokens = wordTokens(context)
        let candidates = tokens.indices.compactMap { index -> String? in
            let start = tokens[index].lowerBound
            guard chars.count - start <= word.count * 2 + 4 else { return nil }
            let first = String(chars[tokens[index]])
            guard !particles.contains(first), let head = chars[start...].first, !nonInitial.contains(head) else {
                return nil
            }
            return String(chars[start...])
        }
        return best(candidates, word)
    }

    /// context の先頭の部分のうち、word と読みがいちばん近いもの。maxDistance より遠ければ nil。
    /// 候補は語の区切りで終わるものだけにし、助詞で終わるものは除く。
    public static func bestPrefix(of context: String, soundingLike word: String) -> String? {
        let chars = Array(context)
        guard let head = chars.first, !nonInitial.contains(head) else { return nil }
        let tokens = wordTokens(context)
        let candidates = tokens.indices.compactMap { index -> String? in
            let end = tokens[index].upperBound
            guard end <= word.count * 2 + 4 else { return nil }
            guard !particles.contains(String(chars[tokens[index]])) else { return nil }
            return String(chars[..<end])
        }
        return best(candidates, word)
    }

    /// 語の区切り（文字の位置の範囲）。
    static func wordTokens(_ s: String) -> [Range<Int>] {
        let cf = s as CFString
        let tokenizer = CFStringTokenizerCreate(nil, cf, CFRange(location: 0, length: CFStringGetLength(cf)),
                                                kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale)
        var result: [Range<Int>] = []
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let lower = String.Index(utf16Offset: r.location, in: s)
            let upper = String.Index(utf16Offset: r.location + r.length, in: s)
            let start = s.distance(from: s.startIndex, to: lower)
            result.append(start..<(start + s.distance(from: lower, to: upper)))
        }
        return result
    }

    private static func best(_ candidates: [String], _ word: String) -> String? {
        var best: (piece: String, d: Double)?
        for piece in candidates where !piece.trimmingCharacters(in: .whitespaces).isEmpty
            && !nonFinal.contains(piece.last!) {
            let d = distance(word, piece)
            if best == nil || d < best!.d { best = (piece, d) }
        }
        guard let best, best.d <= maxDistance else { return nil }
        return best.piece.trimmingCharacters(in: .whitespaces)
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1,
                                 previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
