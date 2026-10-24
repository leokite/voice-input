import Foundation
import Testing
@testable import VoiceInputCore

private struct JudgeError: Error {}

/// 答えを決めておける偽物の AI。`hang` なら答えを返さずに待ち続ける。
private struct FakeJudge: CorrectionJudge {
    var common: Set<String> = []
    var fails = false
    var hang = false

    func isCommonWord(_ word: String) async throws -> Bool {
        try await wait()
        return common.contains(word)
    }

    private func wait() async throws {
        if hang { try await Task.sleep(for: .seconds(3600)) }
        if fails { throw JudgeError() }
    }
}

/// 答えを決めておける偽物の外部AI。
private struct FakeLocator: SourceLocator {
    var source: String?
    var hang = false
    func locate(word: String, in sentence: String) async throws -> String? {
        if hang { try await Task.sleep(for: .seconds(3600)) }
        return source
    }
}

@Suite struct CorrectionRegistrarTests {
    let id = UUID()

    func candidates(pairs: [CorrectionPair] = [], unresolved: [String] = [],
                    sentence: String = "どうかコンテナを再起動") -> CorrectionCandidates {
        CorrectionCandidates(entryID: id, sentence: sentence, pairs: pairs, unresolved: unresolved)
    }

    func registrar(_ judge: CorrectionJudge?, timeout: Duration = .milliseconds(1500)) -> CorrectionRegistrar {
        CorrectionRegistrar(judge: judge, timeout: timeout)
    }

    @Test func nonCommonSourceRegistersReplacementAndTerm() async throws {
        var g = Glossary.empty
        let r = try #require(await registrar(FakeJudge()).register(
            candidates(pairs: [CorrectionPair(from: "キューバーニーツ", to: "Kubernetes")]), into: &g))
        #expect(g.replacements.map(\.from) == ["キューバーニーツ"])
        #expect(g.terms.map(\.text) == ["Kubernetes"])
        #expect(r.message == "キューバーニーツ → Kubernetes を登録しました")
    }

    @Test func commonSourceRegistersHintOnly() async throws {
        var g = Glossary.empty
        let r = try #require(await registrar(FakeJudge(common: ["どうか"])).register(
            candidates(pairs: [CorrectionPair(from: "どうか", to: "Docker")]), into: &g))
        #expect(g.replacements.isEmpty)
        #expect(g.terms.map(\.text) == ["Docker"])
        #expect(r.message == "Docker を登録しました")
    }

    @Test func unresolvedIsAlwaysHintOnly() async throws {
        var g = Glossary.empty
        let r = try #require(await registrar(FakeJudge()).register(candidates(unresolved: ["Docker"]), into: &g))
        #expect(g.replacements.isEmpty)
        #expect(g.terms.map(\.text) == ["Docker"])
        #expect(r.message == "Docker を登録しました")
    }

    @Test func noJudgeMeansHintOnly() async throws {
        var g = Glossary.empty
        _ = await registrar(nil).register(
            candidates(pairs: [CorrectionPair(from: "キューバーニーツ", to: "Kubernetes")]), into: &g)
        #expect(g.replacements.isEmpty)
        #expect(g.terms.map(\.text) == ["Kubernetes"])
    }

    @Test func judgeTimeoutMeansHintOnly() async throws {
        var g = Glossary.empty
        _ = await registrar(FakeJudge(hang: true), timeout: .milliseconds(50)).register(
            candidates(pairs: [CorrectionPair(from: "キューバーニーツ", to: "Kubernetes")]), into: &g)
        #expect(g.replacements.isEmpty)
        #expect(g.terms.map(\.text) == ["Kubernetes"])
    }

    @Test func judgeErrorMeansHintOnly() async throws {
        var g = Glossary.empty
        _ = await registrar(FakeJudge(fails: true)).register(
            candidates(pairs: [CorrectionPair(from: "キューバーニーツ", to: "Kubernetes")]), into: &g)
        #expect(g.replacements.isEmpty)
        #expect(g.terms.map(\.text) == ["Kubernetes"])
    }

    @Test func discardsTrivialPairs() async {
        var g = Glossary.empty
        let trivial = [("e", "a"), ("の", "へ"), ("x", "x"), ("", "A"), ("A", "、")]
            .map { CorrectionPair(from: $0.0, to: $0.1) }
        let r = await registrar(FakeJudge()).register(candidates(pairs: trivial), into: &g)
        #expect(r == nil)
        #expect(g == .empty)
    }

    @Test func multiplePairsMessage() async throws {
        var g = Glossary.empty
        let r = try #require(await registrar(FakeJudge()).register(candidates(pairs: [
            CorrectionPair(from: "キューバーニーツ", to: "Kubernetes"),
            CorrectionPair(from: "ぎっとはぶ", to: "GitHub"),
        ]), into: &g))
        #expect(r.message == "Kubernetes ほか 1 件を登録しました")
    }

    @Test func existingTermIsNotReportedOrUndone() async throws {
        var g = Glossary.empty
        g.addTerm("Docker")
        let r = try #require(await registrar(nil).register(
            candidates(pairs: [CorrectionPair(from: "どうか", to: "Docker"),
                               CorrectionPair(from: "ぎっとはぶ", to: "GitHub")]), into: &g))
        #expect(r.addedTerms == ["GitHub"])
        CorrectionRegistrar.undo(r, in: &g)
        #expect(g.terms.map(\.text) == ["Docker"])
    }

    @Test func undoRemovesOnlyWhatRemains() async throws {
        var g = Glossary.empty
        let r = try #require(await registrar(FakeJudge()).register(
            candidates(pairs: [CorrectionPair(from: "キューバーニーツ", to: "Kubernetes")]), into: &g))
        g.terms.removeAll { $0.text == "Kubernetes" }
        CorrectionRegistrar.undo(r, in: &g)
        #expect(g == .empty)
    }

    // 最終レビューの指摘（C1）: 2 文字以下の置き換え元は、別の文の一部を書き換えるので置き換えにしない。
    @Test func shortSourceRegistersHintOnly() async throws {
        var g = Glossary.empty
        _ = await registrar(FakeJudge()).register(
            candidates(pairs: [CorrectionPair(from: "リア", to: "React")]), into: &g)
        #expect(g.replacements.isEmpty)
        #expect(g.terms.map(\.text) == ["React"])
    }

    // 最終レビューの指摘（I5）: 表示には、実際に足したものだけを数える。
    @Test func messageCountsOnlyAddedEntries() async throws {
        var g = Glossary.empty
        g.addTerm("Docker")
        let r = try #require(await registrar(nil).register(
            candidates(pairs: [CorrectionPair(from: "どうか", to: "Docker"),
                               CorrectionPair(from: "ぎっとはぶ", to: "GitHub")]), into: &g))
        #expect(r.message == "GitHub を登録しました")
    }

    // 最終レビューの指摘（I6）: AI を待つ間に変わった用語集にも、判断の結果を正しく足せる。
    @Test func decisionsApplyToGlossaryChangedDuringWait() async throws {
        let decisions = await registrar(FakeJudge()).decide(
            candidates(pairs: [CorrectionPair(from: "キューバーニーツ", to: "Kubernetes")]))
        var g = Glossary.empty
        g.addTerm("Swift")
        let r = try #require(CorrectionRegistrar.apply(decisions, to: &g))
        #expect(g.terms.map(\.text) == ["Swift", "Kubernetes"])
        #expect(r.addedTerms == ["Kubernetes"])
    }

    // 最終レビューの指摘（I7）: ひらがなだけ、1 文字、漢字と英字の混ざった語はヒントにしない。
    @Test func junkHintsAreDropped() async {
        var g = Glossary.empty
        let r = await registrar(nil).register(
            candidates(pairs: [CorrectionPair(from: "してから", to: "しました")],
                       unresolved: ["ました", "X", "明日Docker"]), into: &g)
        #expect(r == nil)
        #expect(g == .empty)
    }

    // 外部AI: 単語だけの選択でも、置き換え元を見つけられる。
    @Test func locatorResolvesUnresolvedWord() async throws {
        var g = Glossary.empty
        let r = CorrectionRegistrar(judge: FakeJudge(), locator: FakeLocator(source: "どうか"))
        _ = await r.register(candidates(unresolved: ["Docker"]), into: &g)
        #expect(g.replacements.map { "\($0.from)→\($0.to)" } == ["どうか→Docker"])
    }

    @Test func locatorAnswerNotInSentenceIsIgnored() async throws {
        var g = Glossary.empty
        let r = CorrectionRegistrar(judge: FakeJudge(), locator: FakeLocator(source: "ドッカー"))
        _ = await r.register(candidates(unresolved: ["Docker"]), into: &g)
        #expect(g.replacements.isEmpty)
        #expect(g.terms.map(\.text) == ["Docker"])
    }

    @Test func locatorTimeoutFallsBackToHint() async throws {
        var g = Glossary.empty
        let r = CorrectionRegistrar(judge: FakeJudge(), locator: FakeLocator(hang: true),
                                    locatorTimeout: .milliseconds(50))
        _ = await r.register(candidates(unresolved: ["Docker"]), into: &g)
        #expect(g.replacements.isEmpty)
        #expect(g.terms.map(\.text) == ["Docker"])
    }
}
