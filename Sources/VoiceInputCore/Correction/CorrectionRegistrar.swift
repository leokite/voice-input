import Foundation

/// 直しの判断を任せる AI。
public protocol CorrectionJudge: Sendable {
    /// 日常的に使われる普通の言葉なら true。
    func isCommonWord(_ word: String) async throws -> Bool
}

/// 1 回の登録で用語集に足したもの。取り消しに使う。
public struct Registration: Equatable, Sendable {
    public var addedTerms: [String]
    public var addedReplacementIDs: [UUID]
    public var message: String
}

/// 直しの候補を、用語集に登録する規則。
public struct CorrectionRegistrar: Sendable {
    private let judge: CorrectionJudge?
    private let timeout: Duration
    private let sleep: @Sendable (Duration) async -> Void

    public init(judge: CorrectionJudge?, timeout: Duration = .milliseconds(1500),
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.judge = judge
        self.timeout = timeout
        self.sleep = sleep
    }

    /// 用語集に足すかどうかの判断。置き換えにするか（replace）、認識のヒントだけにするか。
    public struct Decision: Equatable, Sendable {
        public var pair: CorrectionPair
        public var replace: Bool
    }

    /// AI に聞いて、候補ごとの判断を決める。用語集には触らない。
    /// AI への質問は並べて行う（全体でも待ち時間はおよそ timeout まで）。
    public func decide(_ c: CorrectionCandidates) async -> [Decision] {
        let pairs = c.pairs.filter(Self.isWorthRegistering)
        // 置き換え元が決まっていない語は、認識のヒントとしてだけ登録する。
        let hintsOnly = c.unresolved.filter(Self.isWorthAsTerm)
        let replaceable = await withTaskGroup(of: (Int, Bool).self) { group in
            for (index, pair) in pairs.enumerated() where pair.from.count >= Self.minReplacementSource {
                group.addTask {
                    let common = await self.ask { judge in try await judge.isCommonWord(pair.from) } ?? true
                    return (index, !common)
                }
            }
            var result = Set<Int>()
            for await (index, replace) in group where replace { result.insert(index) }
            return result
        }
        return pairs.enumerated().map { Decision(pair: $0.element, replace: replaceable.contains($0.offset)) }
            + hintsOnly.map { Decision(pair: CorrectionPair(from: "", to: $0), replace: false) }
    }

    /// 判断を用語集に足す。足したものがなければ nil。表示には、実際に足したものだけを数える。
    public static func apply(_ decisions: [Decision], to glossary: inout Glossary) -> Registration? {
        let before = glossary
        var added: [Decision] = []
        for d in decisions {
            let termsBefore = glossary.terms.count
            let replacementsBefore = glossary.replacements.count
            if d.replace {
                glossary.addCorrection(from: d.pair.from, to: d.pair.to)
            } else {
                glossary.addTerm(d.pair.to)
            }
            let addedReplacement = glossary.replacements.count > replacementsBefore
            if glossary.terms.count > termsBefore || addedReplacement {
                added.append(Decision(pair: d.pair, replace: addedReplacement))
            }
        }
        let oldTerms = Set(before.terms.map(\.text))
        let oldIDs = Set(before.replacements.map(\.id))
        let addedTerms = glossary.terms.map(\.text).filter { !oldTerms.contains($0) }
        let addedIDs = glossary.replacements.map(\.id).filter { !oldIDs.contains($0) }
        guard let first = added.first else { return nil }

        let message: String
        if added.count > 1 {
            message = "\(first.pair.to) ほか \(added.count - 1) 件を登録しました"
        } else if first.replace {
            message = "\(first.pair.from) → \(first.pair.to) を登録しました"
        } else {
            message = "\(first.pair.to) を登録しました"
        }
        return Registration(addedTerms: addedTerms, addedReplacementIDs: addedIDs, message: message)
    }

    /// 判断して、そのまま用語集に足す。登録するものがなければ nil。
    public func register(_ c: CorrectionCandidates, into glossary: inout Glossary) async -> Registration? {
        Self.apply(await decide(c), to: &glossary)
    }

    /// その登録で足したもののうち、まだ残っているものだけを消す。
    public static func undo(_ r: Registration, in glossary: inout Glossary) {
        let ids = Set(r.addedReplacementIDs)
        let terms = Set(r.addedTerms)
        glossary.replacements.removeAll { ids.contains($0.id) }
        glossary.terms.removeAll { terms.contains($0.text) }
    }

    /// AI に聞く。AI がない、時間切れ、エラーのときは nil。
    fileprivate func ask<T: Sendable>(_ op: @escaping @Sendable (CorrectionJudge) async throws -> T) async -> T? {
        guard let judge else { return nil }
        let timeout = timeout
        let sleep = sleep
        return await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await op(judge) }
            group.addTask {
                await sleep(timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// これより短い置き換え元は、別の語の一部（「リア」と「リアル」など）を書き換えてしまうので、置き換えにしない。
    static let minReplacementSource = 3

    static func isWorthRegistering(_ p: CorrectionPair) -> Bool {
        !p.from.isEmpty && p.from != p.to && isWorthAsTerm(p.to) && !(p.from.count <= 1 && p.to.count <= 1)
    }

    /// 用語にする価値がある語か。空白や句読点だけ、1 文字、ひらがなだけ（語尾の直しなど）、
    /// 漢字と英字が混ざったもの（選択が音声入力の外まで広がったもの）は用語にしない。
    static func isWorthAsTerm(_ s: String) -> Bool {
        guard !isBlank(s), s.count > 1 else { return false }
        let scalars = s.unicodeScalars
        if scalars.allSatisfy({ (0x3040...0x309F).contains($0.value) }) { return false }
        let hasLatin = scalars.contains { $0.isASCII && $0.properties.isAlphabetic }
        let hasKanji = scalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        return !(hasLatin && hasKanji)
    }

    /// 空白と句読点だけなら true。
    static func isBlank(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.punctuationCharacters.contains($0)
        }
    }
}
