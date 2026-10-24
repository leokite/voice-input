import Testing
@testable import VoiceInputCore

@Suite struct RealtimeChunkerTests {
    @Test func emitsOnPunctuation() {
        var c = RealtimeChunker()
        #expect(c.append("これは", at: 0) == nil)
        #expect(c.append("テスト。", at: 0.1) == "これはテスト。")
    }

    @Test func emitsAfterGap() {
        var c = RealtimeChunker()
        #expect(c.append("hello", at: 0) == nil)
        #expect(c.tick(at: 0.4) == nil)
        #expect(c.tick(at: 0.5) == "hello")
    }

    @Test func flushReturnsRemainderOnce() {
        var c = RealtimeChunker()
        _ = c.append("残り", at: 0)
        #expect(c.flush() == "残り")
        #expect(c.flush() == nil)
    }

    @Test func trailingWhitespaceAfterPunctuationStillEmitsUntrimmed() {
        var c = RealtimeChunker()
        #expect(c.append("テスト。 ", at: 0) == "テスト。 ")
        #expect(c.flush() == nil)
    }

    @Test func emptyAppendAndEmptyTickEmitNothing() {
        var c = RealtimeChunker()
        #expect(c.append("", at: 0) == nil)
        #expect(c.tick(at: 10) == nil)
        _ = c.append("a", at: 1)
        #expect(c.append("", at: 5) == nil)
        #expect(c.tick(at: 1.5) == "a")
    }
}
