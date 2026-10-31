import Testing
@testable import VoiceInputCore

@Suite struct LanguageChoiceTests {
    @Test func noHintsReturnsNil() {
        #expect(LanguageChoice.pick(hints: [], probabilities: ["en": -0.1]) == nil)
    }

    @Test func singleHintIsUsed() {
        #expect(LanguageChoice.pick(hints: ["ja"], probabilities: ["en": -0.1]) == "ja")
    }

    @Test func multipleHintsPickMostLikely() {
        #expect(LanguageChoice.pick(hints: ["ja", "en"], probabilities: ["en": -0.1, "ja": -2.0]) == "en")
    }

    @Test func hintMissingFromProbabilitiesIsSkipped() {
        #expect(LanguageChoice.pick(hints: ["ja", "en"], probabilities: ["en": -5.0]) == "en")
    }

    @Test func noProbabilitiesFallsBackToFirstHint() {
        #expect(LanguageChoice.pick(hints: ["ja", "en"], probabilities: [:]) == "ja")
    }

    @Test func nanProbabilityNeverWins() {
        #expect(LanguageChoice.pick(hints: ["ja", "en"], probabilities: ["ja": .nan, "en": -3.0]) == "en")
        #expect(LanguageChoice.pick(hints: ["ja", "en"], probabilities: ["ja": -3.0, "en": .nan]) == "ja")
    }
}
