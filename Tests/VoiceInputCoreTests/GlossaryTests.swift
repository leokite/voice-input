import Foundation
import Testing
@testable import VoiceInputCore

struct GlossaryTests {
    @Test func addCorrectionAddsReplacementAndTerm() {
        var g = Glossary.empty
        g.addCorrection(from: "ぎっとはぶ", to: "GitHub")
        #expect(g.replacements.count == 1)
        #expect(g.terms.map(\.text) == ["GitHub"])
    }

    @Test func addCorrectionOverwritesSameFrom() {
        var g = Glossary.empty
        g.addCorrection(from: "ぎっとはぶ", to: "Github")
        g.addCorrection(from: "ぎっとはぶ", to: "GitHub")
        #expect(g.replacements.count == 1)
        #expect(g.replacements[0].to == "GitHub")
    }

    @Test func contextTermsDedupesAndPrefersRecent() {
        var g = Glossary.empty
        g.addTerm("Old")
        g.addTerm("Never")
        g.addTerm("New")
        g.addTerm("New")
        g.addCorrection(from: "ぎっとはぶ", to: "Old")
        g.markUsed(["Old"], at: Date(timeIntervalSince1970: 100))
        g.markUsed(["New"], at: Date(timeIntervalSince1970: 200))
        let result = g.contextTerms()
        #expect(result.terms == ["New", "Old", "Never"])
        #expect(result.truncated == false)
    }

    @Test func contextTermsRespectsBudget() {
        var g = Glossary.empty
        for i in 0..<100 {
            g.addTerm(String(format: "%03d", i) + String(repeating: "x", count: 97))
        }
        let result = g.contextTerms(budgetChars: 1000)
        #expect(result.terms.reduce(0) { $0 + $1.count } <= 1000)
        #expect(result.terms.count == 10)
        #expect(result.truncated)
    }

    @Test func glossaryRoundTripsJSON() throws {
        var g = Glossary.empty
        g.addCorrection(from: "ぎっとはぶ", to: "GitHub")
        g.addTerm("Kubernetes")
        g.markUsed(["GitHub"], at: Date(timeIntervalSince1970: 1_000))
        let data = try JSONEncoder().encode(g)
        #expect(try JSONDecoder().decode(Glossary.self, from: data) == g)
    }
}
