import Foundation
import Testing
@testable import VoiceInputCore

@Suite struct CorrectionMatcherTests {
    let now = Date(timeIntervalSince1970: 1_000_000)

    func entry(_ text: String, secondsAgo: TimeInterval = 10) -> HistoryEntry {
        HistoryEntry(date: now.addingTimeInterval(-secondsAgo), text: text, rawText: text,
                     duration: 1, inserted: true)
    }

    @Test func internalEditBecomesPair() throws {
        let e = entry("main ブランチにマージする前に CI が通るか確認します。")
        let c = try #require(CorrectionMatcher.match(
            selection: "マージする前に GitHub Actions が通るか", history: [e], now: now))
        #expect(c.pairs == [CorrectionPair(from: "CI", to: "GitHub Actions")])
        #expect(c.unresolved == [])
        #expect(c.entryID == e.id)
    }

    @Test func editAtSelectionEdgeUsesSoundAlikeSource() throws {
        let e = entry("今日はどうかコンテナを再起動してからAPIを確認します。")
        let c = try #require(CorrectionMatcher.match(
            selection: "Dockerコンテナを再起動", history: [e], now: now))
        #expect(c.pairs == [CorrectionPair(from: "どうか", to: "Docker")])
        #expect(c.unresolved == [])
        #expect(c.sentence == e.text)
    }

    @Test func editAtSelectionEdgeWithoutSoundAlikeStaysUnresolved() throws {
        let e = entry("コンテナを再起動してからAPIを確認します。")
        let c = try #require(CorrectionMatcher.match(
            selection: "Dockerコンテナを再起動", history: [e], now: now))
        #expect(c.pairs == [])
        #expect(c.unresolved == ["Docker"])
    }

    @Test func trailingEditUsesSoundAlikeSource() throws {
        let e = entry("新しい機能をぎっとはぶにプッシュしました。")
        let c = try #require(CorrectionMatcher.match(
            selection: "新しい機能をGitHub", history: [e], now: now))
        #expect(c.pairs == [CorrectionPair(from: "ぎっとはぶ", to: "GitHub")])
    }

    @Test func wordOnlySelectionUsesNewestEntry() throws {
        let older = entry("キューバーニーツへのデプロイに失敗したのでログを調べます。", secondsAgo: 60)
        let newer = entry("キューバーニーツのクラスタを確認します。", secondsAgo: 10)
        let c = try #require(CorrectionMatcher.match(
            selection: "Kubernetes", history: [newer, older], now: now))
        #expect(c.unresolved == ["Kubernetes"])
        #expect(c.pairs == [])
        #expect(c.sentence == newer.text)
    }

    @Test func unchangedSelectionReturnsNil() {
        let e = entry("どうかコンテナを再起動してからAPIを確認します。")
        #expect(CorrectionMatcher.match(selection: "コンテナを再起動", history: [e], now: now) == nil)
    }

    @Test func unrelatedSelectionReturnsNil() {
        let e = entry("どうかコンテナを再起動してからAPIを確認します。")
        #expect(CorrectionMatcher.match(
            selection: "今日の天気は晴れです。明日は雨が降るでしょう。週末は出かける予定です。", history: [e], now: now) == nil)
    }

    @Test func ignoresEntriesOlderThanWindowAndBeyondFive() {
        let old = entry("どうかコンテナを再起動してから", secondsAgo: 11 * 60)
        #expect(CorrectionMatcher.match(selection: "Dockerコンテナを再起動", history: [old], now: now) == nil)

        let fillers = (0..<5).map { entry("天気の話です。\($0)", secondsAgo: TimeInterval($0 + 1)) }
        let sixth = entry("どうかコンテナを再起動してから", secondsAgo: 30)
        let c = CorrectionMatcher.match(selection: "Dockerコンテナを再起動してから",
                                        history: fillers + [sixth], now: now)
        #expect(c?.entryID != sixth.id)
        #expect(c == nil || c?.pairs.isEmpty == true)
    }

    @Test func tooManyEditsReturnsNil() {
        let e = entry("あいうえおかきくけこさしすせそたちつてと")
        #expect(CorrectionMatcher.match(
            selection: "あいXえおかきYけこさしZせそたちWてと", history: [e], now: now) == nil)
    }

    @Test func mixedJapaneseEnglish() throws {
        let e = entry("この PR を merge して")
        let c = try #require(CorrectionMatcher.match(selection: "この PR を marge して", history: [e], now: now))
        // 英字の並びは 1 つの語として比べる。
        #expect(c.pairs == [CorrectionPair(from: "merge", to: "marge")])
    }

    // 最終レビューの指摘（C1）: 語の境目をまたぐ断片を置き換え元にしない。
    @Test func soundAlikeSourceRespectsWordBoundaries() throws {
        let e = entry("これはリアでアプリを作ります。")
        let c = try #require(CorrectionMatcher.match(selection: "Reactでアプリを作り", history: [e], now: now))
        #expect(!c.pairs.contains { $0.from.contains("は") })
        let figma = try #require(CorrectionMatcher.match(
            selection: "Figmaのデザイン", history: [entry("今日はぐまのデザインを見ます。")], now: now))
        #expect(!figma.pairs.contains { $0.from.contains("は") })
    }

    // 最終レビューの指摘（I2）: 前後が短い選択も、前後を含めた選択として扱う。
    @Test func shortContextSelectionUsesContextPath() throws {
        let c = try #require(CorrectionMatcher.match(
            selection: "Reactで作る", history: [entry("リアクトで作るアプリです。")], now: now))
        #expect(c.pairs == [CorrectionPair(from: "リアクト", to: "React")])
        let k = try #require(CorrectionMatcher.match(
            selection: "Kubernetesのクラスタ", history: [entry("あのキューバーニーツのクラスタを確認します。")], now: now))
        #expect(k.pairs == [CorrectionPair(from: "キューバーニーツ", to: "Kubernetes")])
    }

    // 最終レビューの指摘（I7）: 端の句読点を落とす。
    @Test func trimsPunctuationAtSelectionEdges() throws {
        let c = try #require(CorrectionMatcher.match(
            selection: "、Dockerコンテナを再起動", history: [entry("どうかコンテナを再起動してから")], now: now))
        #expect(c.pairs == [CorrectionPair(from: "どうか", to: "Docker")])
    }

    // 語のかたまりで比べ、1 つの直しを割らない（GPT-6、Luna → gpt-6-luna）。
    @Test func wholeLatinWordEditIsOnePair() throws {
        let e = entry("OpenAIのAPIで使うモデルは、GPT-6、Lunaだと思いますが。")
        let c = try #require(CorrectionMatcher.match(
            selection: "モデルは、gpt-6-lunaだと思いますが", history: [e], now: now))
        #expect(c.pairs == [CorrectionPair(from: "GPT-6、Luna", to: "gpt-6-luna")])
        #expect(c.unresolved == [])
        #expect(c.selection == "モデルは、gpt-6-lunaだと思いますが")
    }

    // 英字の語だけを選んだときは、文中に散らばった文字に一致させない。
    @Test func latinWordOnlySelectionIsUnresolved() throws {
        let e = entry("OpenAIのAPIで使うモデルは、GPT-6、Lunaだと思いますが。")
        let c = try #require(CorrectionMatcher.match(selection: "gpt-6-luna", history: [e], now: now))
        #expect(c.pairs == [])
        #expect(c.unresolved == ["gpt-6-luna"])
    }

    // 大文字と小文字だけの直しも、直しとして扱う。
    @Test func caseOnlyEditIsAPair() throws {
        let e = entry("Githubにプッシュしました。")
        let c = try #require(CorrectionMatcher.match(selection: "GitHubにプッシュ", history: [e], now: now))
        #expect(c.pairs == [CorrectionPair(from: "Github", to: "GitHub")])
    }
}
