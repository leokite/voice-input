import Foundation
import Testing
@testable import VoiceInputCore

@MainActor final class Harness {
    let clock = TestClock()
    let audio = FakeAudio()
    let factory: FakeFactory
    let inserter = FakeInserter()
    let frontmost = FakeFrontmost()
    var settings = AppSettings.default
    var glossary = Glossary.empty
    private(set) var history: [HistoryEntry] = []
    private(set) var termsUsed: [Set<String>] = []
    private(set) var autoStops = 0
    private(set) var states: [SessionState] = [] {
        didSet { resumeStateWaiters() }
    }
    private var stateWaiters: [(state: SessionState, from: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private(set) var controller: SessionController!

    init() {
        factory = FakeFactory(clock: clock)
        let clock = clock
        controller = SessionController(
            audio: audio,
            sessions: factory,
            inserter: inserter,
            frontmost: frontmost,
            settings: { [unowned self] in self.settings },
            glossary: { [unowned self] in self.glossary },
            onHistory: { [unowned self] in self.history.append($0) },
            onTermsUsed: { [unowned self] in self.termsUsed.append($0) },
            now: { clock.now },
            sleep: { await clock.sleep(for: $0) }
        )
        controller.onStateChange = { [unowned self] in self.states.append($0) }
        controller.onAutoStop = { [unowned self] in self.autoStops += 1 }
    }

    var session: FakeSession { factory.sessions[factory.sessions.count - 1] }

    func confirm() {
        controller.handle(.beginBuffering)
        controller.handle(.confirm(.toggle))
    }

    /// `.stop` を送り、200ms の追加取り込みが終わってマイクが止まる（processing になる）まで進める。
    func stop() async {
        let mark = states.count
        controller.handle(.stop)
        await clock.waitForSleeper(.milliseconds(200))
        clock.advance(by: .milliseconds(200))
        await waitForState(.processing, from: mark)
    }

    /// finalize が送られたら `<fin>` を返し、セッションの終了を待つ。
    func respondFinAndWait() async {
        await session.waitFor("finalize")
        session.push(.fin)
        await controller.waitUntilIdle()
    }

    /// `from` 番目以降の状態変化に `state` が現れるまで待つ。
    func waitForState(_ state: SessionState, from: Int = 0) async {
        if states[min(from, states.count)...].contains(state) { return }
        await withCheckedContinuation { stateWaiters.append((state, from, $0)) }
    }

    private func resumeStateWaiters() {
        let matches = { (w: (state: SessionState, from: Int, continuation: CheckedContinuation<Void, Never>)) in
            self.states[min(w.from, self.states.count)...].contains(w.state)
        }
        let ready = stateWaiters.filter(matches)
        stateWaiters.removeAll(where: matches)
        ready.forEach { $0.continuation.resume() }
    }
}

@MainActor @Suite(.timeLimit(.minutes(1)))
struct SessionControllerTests {
    @Test func cancelNeverOpensSession() async {
        let h = Harness()
        h.controller.handle(.beginBuffering)
        #expect(h.audio.started)
        h.audio.emit(Data("A".utf8), rms: 0.5)
        h.controller.handle(.cancel)
        await h.controller.waitUntilIdle()
        #expect(h.factory.sessions.isEmpty)
        #expect(h.audio.stopped)
        #expect(h.states.isEmpty)
    }

    @Test func shortUtteranceBeforeConnectFlushesBufferFirst() async {
        let h = Harness()
        h.factory.startDelay = .seconds(1)
        h.controller.handle(.beginBuffering)
        h.audio.emit(Data("A".utf8), rms: 0.5)
        h.audio.emit(Data("B".utf8), rms: 0.5)
        h.controller.handle(.confirm(.toggle))
        await h.clock.waitForSleeper(.seconds(1))
        await h.stop()
        #expect(h.audio.stopped)
        #expect(h.session.log.isEmpty)
        h.clock.advance(by: .seconds(1))
        await h.respondFinAndWait()
        #expect(h.session.log == ["audio:A", "audio:B", "finalize", "finish"])
    }

    @Test func batchInsertsProcessedTextWhenSameApp() async {
        let h = Harness()
        h.glossary.addCorrection(from: "ぎっとはぶ", to: "GitHub")
        h.confirm()
        h.session.push(.final("えー、ぎっとはぶです"))
        await h.stop()
        await h.respondFinAndWait()
        #expect(h.session.config?.context.terms == ["GitHub"])
        #expect(h.inserter.inserted == ["GitHubです"])
        #expect(h.history.count == 1)
        #expect(h.history.first?.inserted == true)
        #expect(h.history.first?.text == "GitHubです")
        #expect(h.history.first?.rawText == "えー、ぎっとはぶです")
        #expect(h.termsUsed == [["GitHub"]])
        #expect(h.states == [.recording(level: 0, preview: ""), .processing, .idle])
    }

    @Test func appSwitchSavesToHistoryOnly() async {
        let h = Harness()
        h.confirm()
        h.frontmost.bundleID = "com.example.other"
        h.session.push(.final("こんにちは"))
        await h.stop()
        await h.respondFinAndWait()
        #expect(h.inserter.inserted.isEmpty)
        #expect(h.history.count == 1)
        #expect(h.history.first?.inserted == false)
        #expect(h.states.last == .notice("アプリが切り替わったため履歴に保存しました"))
        // お知らせは 3 秒後に消える。
        let mark = h.states.count
        await h.clock.waitForSleeper(.seconds(3))
        h.clock.advance(by: .seconds(3))
        await h.waitForState(.idle, from: mark)
    }

    @Test func fillerOnlyUtteranceInsertsNothing() async {
        let h = Harness()
        h.confirm()
        h.session.push(.final("えー、うーん"))
        await h.stop()
        await h.respondFinAndWait()
        #expect(h.inserter.inserted.isEmpty)
        #expect(h.history.isEmpty)
        #expect(h.termsUsed.isEmpty)
        #expect(h.states.last == .idle)
    }

    @Test func socketClosesBeforeFinKeepsFinalsInHistory() async {
        let h = Harness()
        h.confirm()
        h.session.push(.final("途中まで"))
        h.session.fail(SonioxError.connectionClosed)
        await h.controller.waitUntilIdle()
        #expect(h.history.map(\.text) == ["途中まで"])
        #expect(h.history.first?.inserted == false)
        #expect(h.inserter.inserted == ["途中まで"])
        #expect(h.states.last == .error("ネットワークに接続できません"))
        #expect(h.audio.stopped)
        #expect(h.session.log.last == "finish")
        // マイクが止まった後の .stop は無視する。
        h.controller.handle(.stop)
        await h.controller.waitUntilIdle()
        #expect(h.states.last == .error("ネットワークに接続できません"))
    }

    @Test func unauthenticatedShowsKeyError() async {
        let h = Harness()
        h.confirm()
        h.session.fail(SonioxError.unauthenticated)
        await h.controller.waitUntilIdle()
        #expect(h.states.last == .error("API キーが正しくありません"))
        #expect(h.history.isEmpty)
        #expect(h.session.log.last == "finish")
    }

    @Test func finTimeoutAfterFiveSeconds() async {
        let h = Harness()
        h.confirm()
        await h.stop()
        await h.session.waitFor("finalize")
        await h.clock.waitForSleeper(.seconds(5))
        h.clock.advance(by: .seconds(5))
        await h.controller.waitUntilIdle()
        #expect(h.session.log.last == "finish")
        guard case .error = h.states.last else {
            Issue.record("expected error, got \(String(describing: h.states.last))")
            return
        }
    }

    @Test func silenceAutoStops() async {
        let h = Harness()
        h.confirm()
        for i in 0...60 {
            h.audio.emit(Data("s\(i)".utf8), rms: 0.001)
            await h.session.waitFor("audio:s\(i)")
            if i < 60 {
                #expect(h.autoStops == 0)
                h.clock.advance(by: .seconds(1))
            }
        }
        // 自動停止後の追加取り込み中に届いた無音で、もう一度止めたりしない。
        h.audio.emit(Data("tail".utf8), rms: 0.001)
        await h.clock.waitForSleeper(.milliseconds(200))
        h.clock.advance(by: .milliseconds(200))
        await h.respondFinAndWait()
        #expect(h.autoStops == 1)
        #expect(h.session.log.suffix(3) == ["audio:tail", "finalize", "finish"])
    }

    @Test func realtimeInsertsPerChunk() async {
        let h = Harness()
        h.settings.insertionMode = .realtime
        h.confirm()
        h.session.push(.final("これは"))
        h.session.push(.final("テスト。"))
        h.session.push(.final("次も"))
        await h.waitForState(.recording(level: 0, preview: "次も"))
        #expect(h.inserter.inserted == ["これはテスト。"])
        let mark = h.states.count
        await h.clock.waitForSleeper(.milliseconds(100))
        h.clock.advance(by: .milliseconds(500))
        await h.waitForState(.recording(level: 0, preview: ""), from: mark)
        #expect(h.inserter.inserted == ["これはテスト。", "次も"])
        await h.stop()
        await h.respondFinAndWait()
        #expect(h.inserter.inserted == ["これはテスト。", "次も"])
        #expect(h.history.map(\.text) == ["これはテスト。次も"])
        #expect(h.history.first?.inserted == true)
        #expect(h.states.last == .idle)
    }

    @Test func realtimeKeepsLeadingSpaceAfterFirstChunk() async {
        let h = Harness()
        h.settings.insertionMode = .realtime
        h.confirm()
        h.session.push(.final(" OK."))
        h.session.push(.final("テスト。"))
        h.session.push(.final(" I think"))
        await h.stop()
        await h.respondFinAndWait()
        #expect(h.inserter.inserted == ["OK.", "テスト。", " I think"])
        #expect(h.history.map(\.text) == ["OK.テスト。 I think"])
    }

    @Test func secureInputShowsNotice() async {
        let h = Harness()
        h.inserter.error = .secureInput
        h.confirm()
        h.session.push(.final("ひみつ"))
        await h.stop()
        await h.respondFinAndWait()
        #expect(h.states.last == .notice("パスワード欄には入力できません"))
        #expect(h.history.count == 1)
        #expect(h.history.first?.inserted == false)
    }

    @Test func actionsDuringProcessingAreIgnored() async {
        let h = Harness()
        h.confirm()
        await h.stop()
        await h.session.waitFor("finalize")
        h.controller.handle(.beginBuffering)
        h.controller.handle(.confirm(.toggle))
        h.controller.handle(.stop)
        h.session.push(.fin)
        await h.controller.waitUntilIdle()
        #expect(h.factory.sessions.count == 1)
        #expect(h.states.last == .idle)
    }
}
