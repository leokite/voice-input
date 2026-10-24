import Foundation
import Testing
@testable import VoiceInputCore

private let env = ProcessInfo.processInfo.environment

@Suite("SonioxLive")
struct SonioxLiveTests {
    @Test(.enabled(if: env["SONIOX_API_KEY"] != nil))
    func liveTranscribesFixture() async throws {
        let key = try #require(env["SONIOX_API_KEY"])
        let url = try #require(Bundle.module.url(forResource: "hello-ja", withExtension: "pcm", subdirectory: "Fixtures"))
        let pcm = try Data(contentsOf: url)

        let session = SonioxWebSocketSession(apiKey: key)
        try await session.start(config: SonioxConfig(languageHints: ["ja", "en"], terms: []))
        let stream = session.responses

        var offset = 0
        while offset < pcm.count {
            let end = min(offset + 3200, pcm.count)
            try await session.sendAudio(pcm.subdata(in: offset..<end))
            offset = end
        }
        try await session.finalize()

        var assembler = TranscriptAssembler()
        for try await response in stream {
            if assembler.ingest(response).reachedFin { break }
        }
        await session.finish()
        #expect(assembler.finalText.contains("テスト"))
    }

    @Test(.enabled(if: env["SONIOX_API_KEY"] != nil || env["SONIOX_LIVE_TESTS"] == "1"))
    func liveBadKeyThrowsUnauthenticated() async throws {
        let session = SonioxWebSocketSession(apiKey: "invalid")
        let stream = session.responses
        var thrown: Error?
        do {
            try await session.start(config: SonioxConfig(languageHints: ["ja"], terms: []))
            try? await session.sendAudio(Data(count: 3200))
            for try await _ in stream {}
        } catch {
            thrown = error
        }
        await session.finish()
        #expect(thrown as? SonioxError == .unauthenticated)
    }
}

@Suite("SonioxSessionLifecycle")
struct SonioxSessionLifecycleTests {
    @Test func finishDuringPendingConnectionEndsStreamPromptly() async throws {
        // 到達不能なエンドポイントでも finish() がハングせず、ストリームが終わること。
        let session = SonioxWebSocketSession(apiKey: "x", url: URL(string: "ws://10.255.255.1:81/")!)
        let stream = session.responses
        let started = ContinuousClock.now
        Task { try? await session.start(config: SonioxConfig(languageHints: ["ja"], terms: [])) }
        try await Task.sleep(for: .milliseconds(200))
        await session.finish()
        for try await _ in stream {}
        #expect(ContinuousClock.now - started < .seconds(5))
    }
}
