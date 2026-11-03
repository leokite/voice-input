import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple の端末内AI（Foundation Models）で、置き換え元を探す。オフラインでも使えるようにするための試作。
/// 文字は Mac の外に出ない。まだアプリには組み込んでいない（`source-eval` で精度を測る段階）。
public enum OnDeviceSourceLocator {
    public enum Strategy: String, Sendable, CaseIterable {
        /// 文から置き換え元を自由に抜き出させる。
        case free
        /// 読みの近い順に並べた候補（文の一部）から選ばせる。
        case choose
        /// 読みの近さで見つかればそれを答え、見つからなければ snapped で AI に聞く。
        case hybrid
        /// AI を使わず、読みがいちばん近い候補をそのまま答える（基準線）。
        case phonetic
        /// free の答えを、候補の区切りに合わせる（はみ出しや断片は直すか捨てる）。
        case snapped
    }

    public static func make(strategy: Strategy) -> SourceLocator? {
        if strategy == .phonetic { return PhoneticLocator() }
        #if canImport(FoundationModels)
        if #available(macOS 26, *), case .available = OnDeviceJudge.make().availability {
            return Impl(strategy: strategy)
        }
        #endif
        return nil
    }

    static let particles: Set<Character> = ["は", "が", "を", "の", "に", "で", "と", "へ", "も", "や"]
    static let maxRunsInCandidate = 3
    static let endings = ["でした", "ました", "です", "ます"]

    struct PhoneticLocator: SourceLocator {
        func locate(word: String, in sentence: String) async throws -> String? {
            guard let best = OnDeviceSourceLocator.candidates(word: word, in: sentence, limit: 1).first,
                  Phonetic.distance(word, best) <= Phonetic.maxDistance else { return nil }
            return best
        }
    }

    private enum Script { case hiragana, katakana, latin, kanji, other }

    private static func script(of c: Character) -> Script {
        guard let v = c.unicodeScalars.first?.value else { return .other }
        switch v {
        case 0x3041...0x309F: return .hiragana
        case 0x30A0...0x30FF where v != 0x30FB: return .katakana
        case 0x4E00...0x9FFF, 0x3400...0x4DBF: return .kanji
        default:
            if c.isASCII && (c.isLetter || c.isNumber || "-_+#".contains(c)) { return .latin }
            return .other
        }
    }

    /// 文字種（ひらがな、カタカナ、英数字、漢字）が変わるところで区切った連なり。長音記号は前の文字と同じ連なりにする。
    static func runs(_ sentence: String) -> [Range<Int>] {
        let chars = Array(sentence)
        var result: [Range<Int>] = []
        var start = 0
        var current: Script?
        for (i, c) in chars.enumerated() {
            var kind = script(of: c)
            if c == "ー", let current { kind = current }
            if kind != current {
                if let current, current != .other { result.append(start..<i) }
                start = i
                current = kind
            }
        }
        if let current, current != .other { result.append(start..<chars.count) }
        return result
    }

    /// 文の一部の候補すべて（並べ替え前）。文字種の連なりを 1〜3 個つなげたもの。
    /// ひらがなの連なりの端にある助詞（「ぱいそんで」の「で」）を外したものも候補にする。
    static func allCandidates(in sentence: String) -> [String] {
        let chars = Array(sentence)
        let runs = runs(sentence)
        var seen = Set<String>()
        var result: [String] = []
        func add(_ piece: String) {
            let t = piece.trimmingCharacters(in: CharacterSet.whitespaces.union(.punctuationCharacters))
            guard t.count >= 2 || (t.count == 1 && script(of: t.first!) != .hiragana) else { return }
            if seen.insert(t).inserted { result.append(t) }
        }
        for start in runs.indices {
            for end in start..<min(runs.count, start + maxRunsInCandidate) {
                let range = runs[start].lowerBound..<runs[end].upperBound
                let piece = chars[range]
                add(String(piece))
                // 端の助詞を外した形。
                var lo = piece.startIndex, hi = piece.endIndex
                if script(of: chars[runs[start].lowerBound]) == .hiragana, particles.contains(piece[lo]) { lo += 1 }
                if script(of: chars[runs[end].upperBound - 1]) == .hiragana, hi - 1 > lo, particles.contains(piece[hi - 1]) { hi -= 1 }
                if (lo, hi) != (piece.startIndex, piece.endIndex) { add(String(piece[lo..<hi])) }
                // 語尾（です・ます）も外した形。
                let inner = String(piece[lo..<hi])
                if let e = endings.first(where: { inner.hasSuffix($0) && inner.count > $0.count }) {
                    add(String(inner.dropLast(e.count)))
                }
            }
        }
        return result
    }

    /// word と読みが近い順に並べた候補。
    public static func candidates(word: String, in sentence: String, limit: Int = 6) -> [String] {
        allCandidates(in: sentence)
            .filter { $0.count <= word.count * 3 + 4 }
            .map { ($0, Phonetic.distance(word, $0)) }
            .sorted { $0.1 < $1.1 }
            .prefix(limit).map(\.0)
    }

    /// 自由に抜き出した答えを、候補の区切りに合わせる。候補そのものならそのまま、候補の一部なら含む最も短い候補に直す。
    /// どの候補にも合わなければ nil。
    public static func snap(_ answer: String, in sentence: String) -> String? {
        let all = allCandidates(in: sentence)
        if all.contains(answer) { return answer }
        guard answer.count >= 2 else { return nil }
        return all.filter { $0.contains(answer) }.min { $0.count < $1.count }
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
struct SourceAnswer {
    @Guide(description: "文からそのまま抜き出した、聞き間違えられた部分。見つからなければ空文字")
    var source: String
}

@available(macOS 26, *)
@Generable
struct SourceChoice {
    @Guide(description: "選んだ候補の番号。どれも当てはまらなければ -1")
    var index: Int
}

@available(macOS 26, *)
extension OnDeviceSourceLocator {
    struct Impl: SourceLocator {
        let strategy: Strategy

        func locate(word: String, in sentence: String) async throws -> String? {
            switch strategy {
            case .free: try await free(word, sentence)
            case .snapped:
                try await free(word, sentence).flatMap { OnDeviceSourceLocator.snap($0, in: sentence) }
            case .choose: try await choose(word, sentence)
            case .phonetic: nil
            case .hybrid:
                if let hit = try await PhoneticLocator().locate(word: word, in: sentence) { hit } else {
                    try await free(word, sentence).flatMap { OnDeviceSourceLocator.snap($0, in: sentence) }
                }
            }
        }

        private func free(_ word: String, _ sentence: String) async throws -> String? {
            let session = LanguageModelSession(instructions: """
                音声認識の結果（文）の一部を、ユーザーが正しい語に直した。\
                文の中で、その語を聞き間違えて書き起こされた部分を、文からそのまま抜き出す。\
                読み（発音）が正しい語に近い部分を選ぶ。助詞などの前後の語は含めない。正しい語そのものは答えない。\
                見つからなければ空文字にする。\
                例: 文「どうかコンテナを再起動」、正しい語「Docker」→「どうか」。
                """)
            let r = try await session.respond(to: "文: \(sentence)\n正しい語: \(word)", generating: SourceAnswer.self)
            let s = r.content.source.trimmingCharacters(in: .whitespacesAndNewlines)
            return s.isEmpty ? nil : s
        }

        private func choose(_ word: String, _ sentence: String) async throws -> String? {
            let options = OnDeviceSourceLocator.candidates(word: word, in: sentence)
            guard !options.isEmpty else { return nil }
            let session = LanguageModelSession(instructions: """
                音声認識の結果（文）の一部を、ユーザーが正しい語に直した。\
                候補の中から、正しい語を聞き間違えて書き起こされた部分を 1 つ選び、その番号を答える。\
                読み（発音）が正しい語に近いものを選ぶ。どれも当てはまらなければ -1 にする。\
                例: 文「どうかコンテナを再起動」、正しい語「Docker」、候補 0:どうか 1:コンテナ 2:再起動 → 0。
                """)
            let list = options.enumerated().map { "\($0.offset): \($0.element)" }.joined(separator: "\n")
            let r = try await session.respond(to: "文: \(sentence)\n正しい語: \(word)\n候補:\n\(list)",
                                              generating: SourceChoice.self)
            guard options.indices.contains(r.content.index) else { return nil }
            return options[r.content.index]
        }
    }
}
#endif
