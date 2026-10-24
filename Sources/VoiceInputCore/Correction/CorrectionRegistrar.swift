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

    /// 登録するものがなければ nil。
    public func register(_ c: CorrectionCandidates, into glossary: inout Glossary) async -> Registration? {
        // 置き換え元が決まっていない語は、認識のヒントとしてだけ登録する。
        let pairs = c.pairs.filter(Self.isWorthRegistering)
        let hintsOnly = c.unresolved.filter { !Self.isBlank($0) }

        let before = glossary
        var registered: [(pair: CorrectionPair, replacement: Bool)] = []
        for pair in pairs {
            let common = await ask { judge in try await judge.isCommonWord(pair.from) } ?? true
            if common {
                glossary.addTerm(pair.to)
            } else {
                glossary.addCorrection(from: pair.from, to: pair.to)
            }
            registered.append((pair, !common))
        }
        for word in hintsOnly {
            glossary.addTerm(word)
            registered.append((CorrectionPair(from: "", to: word), false))
        }

        let oldTerms = Set(before.terms.map(\.text))
        let oldIDs = Set(before.replacements.map(\.id))
        let addedTerms = glossary.terms.map(\.text).filter { !oldTerms.contains($0) }
        let addedIDs = glossary.replacements.map(\.id).filter { !oldIDs.contains($0) }
        guard !addedTerms.isEmpty || !addedIDs.isEmpty, let first = registered.first else { return nil }

        let message: String
        if registered.count > 1 {
            message = "\(first.pair.to) ほか \(registered.count - 1) 件を登録しました"
        } else if first.replacement {
            message = "\(first.pair.from) → \(first.pair.to) を登録しました"
        } else {
            message = "\(first.pair.to) を登録しました"
        }
        return Registration(addedTerms: addedTerms, addedReplacementIDs: addedIDs, message: message)
    }

    /// その登録で足したもののうち、まだ残っているものだけを消す。
    public static func undo(_ r: Registration, in glossary: inout Glossary) {
        let ids = Set(r.addedReplacementIDs)
        let terms = Set(r.addedTerms)
        glossary.replacements.removeAll { ids.contains($0.id) }
        glossary.terms.removeAll { terms.contains($0.text) }
    }

    /// AI に聞く。AI がない、時間切れ、エラーのときは nil。
    private func ask<T: Sendable>(_ op: @escaping @Sendable (CorrectionJudge) async throws -> T) async -> T? {
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

    static func isWorthRegistering(_ p: CorrectionPair) -> Bool {
        !p.from.isEmpty && p.from != p.to && !isBlank(p.to) && !(p.from.count <= 1 && p.to.count <= 1)
    }

    /// 空白と句読点だけなら true。
    static func isBlank(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.punctuationCharacters.contains($0)
        }
    }
}
