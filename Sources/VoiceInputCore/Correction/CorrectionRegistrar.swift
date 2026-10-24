import Foundation

/// 直しの判断を任せる AI。
public protocol CorrectionJudge: Sendable {
    /// 日常的に使われる普通の言葉なら true。
    func isCommonWord(_ word: String) async throws -> Bool
}

/// 置き換え元を探してもらう外部の AI。読みの近さで見つからなかった語にだけ使う。
public protocol SourceLocator: Sendable {
    /// sentence の中で、word に直されたと考えられる部分をそのまま返す。見つからなければ nil。
    func locate(word: String, in sentence: String) async throws -> String?
}

/// 履歴の文と選んだ文字列を丸ごと渡して、「置き換え元 → 正しい語」の組み合わせを取り出してもらう外部の AI。
public protocol CorrectionExtractor: Sendable {
    func extract(sentence: String, selection: String) async throws -> [CorrectionPair]
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
    private let locator: SourceLocator?
    private let extractor: CorrectionExtractor?
    private let timeout: Duration
    private let locatorTimeout: Duration
    private let sleep: @Sendable (Duration) async -> Void

    public init(judge: CorrectionJudge?, locator: SourceLocator? = nil, extractor: CorrectionExtractor? = nil,
                timeout: Duration = .milliseconds(1500), locatorTimeout: Duration = defaultLocatorTimeout,
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) }) {
        self.judge = judge
        self.locator = locator
        self.extractor = extractor
        self.timeout = timeout
        self.locatorTimeout = locatorTimeout
        self.sleep = sleep
    }

    /// OpenAI を待つ時間。登録は文字起こしとは別の操作で、多少遅くても困らないので長めにとる。
    public static let defaultLocatorTimeout: Duration = .seconds(5)

    /// OpenAI に聞けなかった理由。ユーザーが異変に気づけるよう、表示に添える。
    public enum LocatorIssue: Equatable, Sendable {
        case timedOut(Duration)
        case failed

        var reason: String {
            switch self {
            case .timedOut(let d):
                let c = d.components
                let seconds = Double(c.seconds) + Double(c.attoseconds) / 1e18
                return "OpenAI の応答が \(String(format: "%g", seconds)) 秒を超えたため"
            case .failed:
                return "OpenAI に接続できなかったため"
            }
        }
    }

    /// 判断の結果。
    public struct Outcome: Equatable, Sendable {
        public var decisions: [Decision]
        public var locatorIssue: LocatorIssue?

        /// 何も登録できなかったときに出す文言。OpenAI に聞けなかったときだけ。
        public var locatorProblem: String? {
            locatorIssue.map { "\($0.reason)、登録できませんでした" }
        }
    }

    /// 用語集に足すかどうかの判断。置き換えにするか（replace）、認識のヒントだけにするか。
    public struct Decision: Equatable, Sendable {
        public var pair: CorrectionPair
        public var replace: Bool
    }

    /// AI に聞いて、候補ごとの判断を決める。用語集には触らない。
    /// AI への質問は並べて行う（全体でも待ち時間はおよそ timeout まで）。
    public func decide(_ c: CorrectionCandidates) async -> Outcome {
        var c = c
        var issue: LocatorIssue?
        // 外部の AI があれば、まず組み合わせを丸ごと取り出してもらう。使えるものがあれば、プログラムの結果より優先する。
        if let extractor, !c.selection.isEmpty {
            switch await extract(extractor, c.sentence, c.selection) {
            case .pairs(let pairs):
                let usable = Array(pairs.filter {
                    !$0.from.isEmpty && !$0.to.isEmpty && $0.from != $0.to
                        && c.sentence.contains($0.from) && c.selection.contains($0.to)
                }.prefix(3))
                if !usable.isEmpty {
                    c.pairs = usable
                    c.unresolved = []
                }
            case .timedOut:
                issue = .timedOut(locatorTimeout)
            case .failed:
                issue = .failed
            }
        }

        var located: [CorrectionPair] = []
        var hintsOnly: [String] = []
        // 置き換え元が決まっていない語は、外部の AI があれば聞く。答えが履歴の文にあるときだけ使う。
        // 見つからなければ、認識のヒントとしてだけ登録する。
        for word in c.unresolved.filter(Self.isWorthAsTerm) {
            // 組み合わせの取り出しで、すでに時間切れやエラーになっていれば、もう待たない。
            guard let locator, issue == nil else {
                hintsOnly.append(word)
                continue
            }
            switch await locate(locator, word, c.sentence) {
            case .answer(let source?) where !source.isEmpty && source != word && c.sentence.contains(source):
                located.append(CorrectionPair(from: source, to: word))
            case .answer:
                hintsOnly.append(word)
            case .timedOut:
                issue = .timedOut(locatorTimeout)
                hintsOnly.append(word)
            case .failed:
                if issue == nil { issue = .failed }
                hintsOnly.append(word)
            }
        }
        let pairs = (c.pairs + located).filter(Self.isWorthRegistering)
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
        let decisions = pairs.enumerated().map { Decision(pair: $0.element, replace: replaceable.contains($0.offset)) }
            + hintsOnly.map { Decision(pair: CorrectionPair(from: "", to: $0), replace: false) }
        return Outcome(decisions: decisions, locatorIssue: issue)
    }

    /// 判断を用語集に足す。足したものがなければ nil。表示には、実際に足したものだけを数える。
    public static func apply(_ outcome: Outcome, to glossary: inout Glossary) -> Registration? {
        let decisions = outcome.decisions
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
        let note = outcome.locatorIssue.map { "（\($0.reason)、ヒントだけ登録しました）" } ?? ""
        return Registration(addedTerms: addedTerms, addedReplacementIDs: addedIDs, message: message + note)
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

    private enum LocateResult: Sendable {
        case answer(String?)
        case timedOut
        case failed
    }

    private enum ExtractResult: Sendable {
        case pairs([CorrectionPair])
        case timedOut
        case failed
    }

    private func extract(_ extractor: CorrectionExtractor, _ sentence: String, _ selection: String) async -> ExtractResult {
        let sleep = sleep
        let timeout = locatorTimeout
        return await withTaskGroup(of: ExtractResult.self) { group in
            group.addTask {
                do { return .pairs(try await extractor.extract(sentence: sentence, selection: selection)) } catch {
                    return .failed
                }
            }
            group.addTask {
                await sleep(timeout)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }

    /// OpenAI に聞く。時間切れとエラーを分けて返す。
    private func locate(_ locator: SourceLocator, _ word: String, _ sentence: String) async -> LocateResult {
        let sleep = sleep
        let timeout = locatorTimeout
        return await withTaskGroup(of: LocateResult.self) { group in
            group.addTask {
                do { return .answer(try await locator.locate(word: word, in: sentence)) } catch { return .failed }
            }
            group.addTask {
                await sleep(timeout)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
    }

    /// AI に聞く。AI がない、時間切れ、エラーのときは nil。
    fileprivate func ask<T: Sendable>(_ op: @escaping @Sendable (CorrectionJudge) async throws -> T) async -> T? {
        guard let judge else { return nil }
        return await bounded(timeout) { try await op(judge) }
    }

    /// timeout までに終わらなければ nil。エラーのときも nil。
    private func bounded<T: Sendable>(_ timeout: Duration, _ op: @escaping @Sendable () async throws -> T) async -> T? {
        let sleep = sleep
        return await withTaskGroup(of: T?.self) { group in
            group.addTask { try? await op() }
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
