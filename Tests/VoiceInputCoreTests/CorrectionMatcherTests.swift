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

    @Test func editAtSelectionEdgeBecomesUnresolved() throws {
        let e = entry("どうかコンテナを再起動してからAPIを確認します。")
        let c = try #require(CorrectionMatcher.match(
            selection: "Dockerコンテナを再起動", history: [e], now: now))
        #expect(c.pairs == [])
        #expect(c.unresolved == ["Docker"])
        #expect(c.sentence == e.text)
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
        #expect(c.pairs == [CorrectionPair(from: "e", to: "a")])
    }
}
