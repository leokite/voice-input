import Testing
@testable import VoiceInputCore

@Suite struct PhoneticTests {
    @Test(arguments: [
        ("今日はどうか", "Docker", "どうか"),
        ("キューバーニーツ", "Kubernetes", "キューバーニーツ"),
        ("このピーアール", "PR", "ピーアール"),
        ("ここでぎっとはぶ", "GitHub", "ぎっとはぶ"),
        ("明日のミーティング", "meeting", "ミーティング"),
        ("メイン", "main", "メイン"),
    ])
    func findsSoundAlikeSuffix(context: String, word: String, expected: String) {
        #expect(Phonetic.bestSuffix(of: context, soundingLike: word) == expected)
    }

    @Test func rejectsUnrelatedSuffix() {
        #expect(Phonetic.bestSuffix(of: "昨日の", soundingLike: "Kubernetes") == nil)
        #expect(Phonetic.bestSuffix(of: "この", soundingLike: "PR") == nil)
    }

    @Test func findsSoundAlikePrefix() {
        #expect(Phonetic.bestPrefix(of: "ぎっとはぶにプッシュしました。", soundingLike: "GitHub") == "ぎっとはぶ")
    }

    @Test func readingFoldsLongVowelMarks() {
        #expect(Phonetic.reading("ミーティング") == "mitingu")
    }
}
