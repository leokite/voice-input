import Testing
@testable import VoiceInputCore

struct FillerRemoverTests {
    static let cases: [(String, String)] = [
        ("えー、これはテストです。", "これはテストです。"),
        ("これはえーと、テストです。", "これはテストです。"),
        ("えーーと、はい", "はい"),
        ("あーー、そうですね", "そうですね"),
        ("うーん。難しい", "難しい"),
        ("あの件ですが", "あの件ですが"),
        ("Um, I think so.", "I think so."),
        ("I uh think so", "I think so"),
        ("This is a hummer", "This is a hummer"),
        ("この PR を merge して", "この PR を merge して"),
        ("えー", ""),
        ("えー、うーん。", ""),
    ]

    @Test(arguments: cases)
    func cleansText(input: String, expected: String) {
        let remover = FillerRemover(fillers: FillerRemover.defaultFillers)
        #expect(remover.clean(input) == expected)
    }

    @Test func defaultFillersMatchConstraints() {
        #expect(FillerRemover.defaultFillers == [
            "えー", "えーと", "えっと", "あー", "あのー", "うーん", "んー",
            "um", "uh", "uhm", "er", "erm", "hmm",
        ])
    }
}
