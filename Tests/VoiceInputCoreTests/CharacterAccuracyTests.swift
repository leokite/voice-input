import Testing
@testable import VoiceInputCore

@Suite("CharacterAccuracy")
struct CharacterAccuracyTests {
    @Test func identicalIsOne() {
        #expect(CharacterAccuracy.score(expected: "GitHub に push", actual: "github に push。") == 1.0)
    }

    @Test func oneCharWrongOutOfTen() {
        let s = CharacterAccuracy.score(expected: "あいうえおかきくけこ", actual: "あいうえおかきくけさ")
        #expect(abs(s - 0.9) < 1e-9)
    }

    @Test func clampsAtZero() {
        #expect(CharacterAccuracy.score(expected: "あ", actual: "いろはにほへとちりぬるを") == 0.0)
    }
}
