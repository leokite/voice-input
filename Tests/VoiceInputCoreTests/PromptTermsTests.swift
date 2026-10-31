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

    @Test func neverSkipsAheadToLaterTerms() {
        #expect(PromptTerms.build(from: ["a", "bbbbbbbb", "c"], maxChars: 6) == "a")
    }

    @Test func exactLimitIsKept() {
        #expect(PromptTerms.build(from: ["A", "B"], maxChars: 4) == "A, B")
        #expect(PromptTerms.build(from: ["A", "B"], maxChars: 3) == "A")
    }

    @Test func firstTermLongerThanBudgetGivesEmpty() {
        #expect(PromptTerms.build(from: ["abcdef", "g"], maxChars: 5) == "")
    }

    @Test func emptyTermsAreIgnored() {
        #expect(PromptTerms.build(from: ["", "A", "", "B", ""]) == "A, B")
    }
}
