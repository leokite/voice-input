import Foundation
import Testing
@testable import VoiceInputCore

private struct JudgeError: Error {}

/// 答えを決めておける偽物の AI。`hang` なら答えを返さずに待ち続ける。
private struct FakeJudge: CorrectionJudge {
    var source: String? = nil
    var common: Set<String> = []
    var fails = false
    var hang = false

    func locateSource(of word: String, in sentence: String) async throws -> String? {
        try await wait()
        return source
    }

    func isCommonWord(_ word: String) async throws -> Bool {
        try await wait()
        return common.contains(word)
    }

    private func wait() async throws {
        if hang { try await Task.sleep(for: .seconds(3600)) }
        if fails { throw JudgeError() }
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

    @Test func unresolvedPieceUsesJudgeLocatedSource() async throws {
        var g = Glossary.empty
        _ = await registrar(FakeJudge(source: "どうか")).register(candidates(unresolved: ["Docker"]), into: &g)
        #expect(g.replacements.map { "\($0.from)→\($0.to)" } == ["どうか→Docker"])
    }

    @Test func judgeSourceNotInSentenceFallsBackToHintOnly() async throws {
        var g = Glossary.empty
        _ = await registrar(FakeJudge(source: "ドッカー")).register(candidates(unresolved: ["Docker"]), into: &g)
        #expect(g.replacements.isEmpty)
        #expect(g.terms.map(\.text) == ["Docker"])
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
        _ = await registrar(FakeJudge(source: "どうか", fails: true)).register(
            candidates(unresolved: ["Docker"]), into: &g)
        #expect(g.replacements.isEmpty)
        #expect(g.terms.map(\.text) == ["Docker"])
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
}
