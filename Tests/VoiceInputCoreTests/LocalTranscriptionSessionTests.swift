import Foundation
import Testing
@testable import VoiceInputCore

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.withLock { value } }
    func increment() { lock.withLock { value += 1 } }
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct LocalTranscriptionSessionTests {
    private func makeHarness(_ transcriber: FakeLocalTranscriber) -> Harness {
        let h = Harness(sessions: SingleSessionFactory(LocalTranscriptionSession(transcriber: transcriber)))
        h.settings.engine = .local
        return h
    }

    @Test func transcribesBufferedAudioAfterStop() async {
        let transcriber = FakeLocalTranscriber()
        transcriber.result = .success("こんにちは")
        let h = makeHarness(transcriber)
        h.confirm()
        h.audio.emit(loudPCM(), rms: 0.2)
        h.audio.emit(loudPCM(), rms: 0.2)
        await h.stop()
        await h.controller.waitUntilIdle()
        #expect(h.inserter.inserted == ["こんにちは"])
        #expect(transcriber.calls.count == 1)
        #expect(transcriber.calls.first?.pcm.count == 6400)
        #expect(transcriber.calls.first?.hints == h.settings.languageHints)
        #expect(h.history.count == 1)
        #expect(transcriber.calls.first?.terms == [])
    }

    @Test func unexpectedTranscriberErrorShowsTranscriptionError() async {
        struct Raw: Error {}
        let transcriber = FakeLocalTranscriber()
        transcriber.result = .failure(Raw())
        let h = makeHarness(transcriber)
        h.confirm()
        h.audio.emit(loudPCM(), rms: 0.2)
        await h.stop()
        await h.controller.waitUntilIdle()
        #expect(h.errors == [.transcription])
        #expect(h.states.contains(.error("文字起こしに失敗しました")))
    }

    @Test func recognitionOutlastingTimeoutShowsTranscriptionError() async {
        let session = LocalTranscriptionSession(transcriber: HangingTranscriber())
        let h = Harness(sessions: SingleSessionFactory(session))
        h.settings.engine = .local
        h.confirm()
        h.audio.emit(loudPCM(), rms: 0.2)
        await h.stop()
        // 音声が届いて待ち時間が確定するまで待つ。
        while session.finalizeTimeout == .seconds(15) { await Task.yield() }
        let timeout = session.finalizeTimeout
        await h.clock.waitForSleeper(timeout)
        h.clock.advance(by: timeout)
        await h.controller.waitUntilIdle()
        #expect(h.errors == [.transcription])
        #expect(h.inserter.inserted.isEmpty)
        #expect(h.history.isEmpty)
    }

    @Test func neverLoudRecordingIsNotTranscribed() async {
        let transcriber = FakeLocalTranscriber()
        transcriber.result = .success("幻聴")
        let h = makeHarness(transcriber)
        h.confirm()
        h.audio.emit(silentPCM(), rms: 0)
        h.audio.emit(silentPCM(), rms: 0)
        await h.stop()
        await h.controller.waitUntilIdle()
        #expect(transcriber.calls.isEmpty)
        #expect(h.inserter.inserted.isEmpty)
        #expect(h.history.isEmpty)
        #expect(h.errors.isEmpty)
        #expect(h.states.last == .idle)
    }

    @Test func transcriberFailureShowsTranscriptionError() async {
        let transcriber = FakeLocalTranscriber()
        transcriber.result = .failure(LocalTranscriptionError(message: "モデルが読めません"))
        let h = makeHarness(transcriber)
        h.confirm()
        h.audio.emit(loudPCM(), rms: 0.2)
        await h.stop()
        await h.controller.waitUntilIdle()
        #expect(h.errors == [.transcription])
        #expect(h.inserter.inserted.isEmpty)
        #expect(h.history.isEmpty)
        #expect(h.states.contains(.error("文字起こしに失敗しました")))
    }

    @Test func localEngineInsertsInOneBatch() async {
        let h = Harness()
        h.settings.insertionMode = .realtime
        h.settings.engine = .local
        h.confirm()
        h.session.push(.final("一つ目。"))
        h.session.push(.final("二つ目。"))
        await h.stop()
        await h.respondFinAndWait()
        #expect(h.inserter.inserted == ["一つ目。二つ目。"])
    }

    @Test func localEngineNeverBuildsSonioxSession() {
        let sonioxCalls = Counter()
        let localCalls = Counter()
        let transcriber = FakeLocalTranscriber()
        let engine = Counter()  // 0 = local, 1 = soniox
        let factory = EngineSessionFactory(
            settings: {
                var s = AppSettings.default
                s.engine = engine.count == 0 ? .local : .soniox
                return s
            },
            soniox: {
                sonioxCalls.increment()
                return LocalTranscriptionSession(transcriber: transcriber)
            },
            local: {
                localCalls.increment()
                return LocalTranscriptionSession(transcriber: transcriber)
            }
        )
        _ = factory.makeSession()
        #expect(sonioxCalls.count == 0)
        #expect(localCalls.count == 1)
        engine.increment()
        _ = factory.makeSession()
        #expect(sonioxCalls.count == 1)
        #expect(localCalls.count == 1)
    }

    @Test func finalizeTimeoutGrowsWithAudio() async throws {
        let session = LocalTranscriptionSession(transcriber: FakeLocalTranscriber())
        #expect(session.finalizeTimeout == .seconds(15))
        try await session.sendAudio(Data(count: 320_000))
        #expect(session.finalizeTimeout == .seconds(45))
    }
}

/// 取り消されるまで終わらない。
private struct HangingTranscriber: LocalTranscriber {
    func transcribe(pcm: Data, languageHints: [String], terms: [String]) async throws -> String {
        try await Task.sleep(for: .seconds(3600))
        return ""
    }
}

/// 毎回同じセッションを返す。
private final class SingleSessionFactory: TranscriptionSessionFactory, @unchecked Sendable {
    private let session: TranscriptionSession
    init(_ session: TranscriptionSession) { self.session = session }
    func makeSession() -> TranscriptionSession { session }
}
