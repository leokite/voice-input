import Testing
@testable import VoiceInputCore

struct TextPipelineTests {
    private let fillers = FillerRemover(fillers: FillerRemover.defaultFillers)

    @Test func pipelineRemovesFillersThenReplaces() {
        var g = Glossary.empty
        g.addCorrection(from: "ぎっとはぶ", to: "GitHub")
        let out = TextPipeline(fillers: fillers, glossary: g).process("えー、ぎっとはぶに push して")
        #expect(out.text == "GitHubに push して")
        #expect(out.usedTerms == ["GitHub"])
    }

    @Test func pipelineReportsPlainTermUsage() {
        var g = Glossary.empty
        g.addTerm("Kubernetes")
        let out = TextPipeline(fillers: fillers, glossary: g).process("Kubernetes を使う")
        #expect(out.usedTerms == ["Kubernetes"])
    }
}
