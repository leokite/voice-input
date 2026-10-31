import Testing
@testable import VoiceInputCore

@Suite struct PromptTermsTests {
    @Test func joinsInGivenOrder() {
        #expect(PromptTerms.build(from: ["A", "B"]) == "A, B")
    }

    @Test func stopsBeforeExceedingBudget() {
        #expect(PromptTerms.build(from: ["abc", "de", "f"], maxChars: 5) == "abc")
    }

    @Test func emptyTermsGiveEmptyPrompt() {
        #expect(PromptTerms.build(from: []) == "")
    }
}
