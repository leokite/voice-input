import Testing
@testable import VoiceInputCore

@Suite struct TranscriptAssemblerTests {
    private func response(_ tokens: [(String, Bool)]) -> SonioxResponse {
        SonioxResponse(tokens: tokens.map { SonioxToken(text: $0.0, isFinal: $0.1) },
                       finished: false, errorCode: nil, errorMessage: nil)
    }

    @Test func assemblerAppendsFinalsReplacesPartials() {
        var a = TranscriptAssembler()
        let u1 = a.ingest(response([("こん", true), ("にち", false)]))
        #expect(u1.newFinalText == "こん")
        #expect(u1.partialText == "にち")
        let u2 = a.ingest(response([("にちは", true), ("。", false)]))
        #expect(a.finalText == "こんにちは")
        #expect(u2.newFinalText == "にちは")
        #expect(u2.partialText == "。")
        #expect(u2.reachedFin == false)
    }

    @Test func assemblerKeepsLeadingSpaces() {
        var a = TranscriptAssembler()
        _ = a.ingest(response([("Hello", true)]))
        _ = a.ingest(response([(" world", true)]))
        #expect(a.finalText == "Hello world")
    }

    @Test func assemblerStripsFinMarker() {
        var a = TranscriptAssembler()
        let u = a.ingest(response([("こん", true), ("<fin>", true)]))
        #expect(u.reachedFin == true)
        #expect(u.newFinalText == "こん")
        #expect(a.finalText == "こん")
    }

    @Test func assemblerStripsEndMarker() {
        var a = TranscriptAssembler()
        let u = a.ingest(response([("あ", true), ("<end>", true)]))
        #expect(u.reachedFin == false)
        #expect(a.finalText == "あ")
    }
}
