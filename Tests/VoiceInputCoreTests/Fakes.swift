import Foundation
@testable import VoiceInputCore

/// 手動で進める時計。`sleep` は時計が締め切りを過ぎるまで（またはタスクが取り消されるまで）戻らない。
@MainActor final class TestClock {
    private struct Sleeper {
        let id: Int
        let deadline: TimeInterval
        let duration: Duration
        let continuation: CheckedContinuation<Void, Never>
    }

    private(set) var now: TimeInterval = 0
    private var sleepers: [Sleeper] = []
    private var waiters: [(duration: Duration, continuation: CheckedContinuation<Void, Never>)] = []
    private var nextID = 0

    func sleep(for duration: Duration) async {
        let id = nextID
        nextID += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                sleepers.append(Sleeper(id: id, deadline: now + duration.seconds,
                                        duration: duration, continuation: continuation))
                let ready = waiters.filter { $0.duration == duration }
                waiters.removeAll { $0.duration == duration }
                ready.forEach { $0.continuation.resume() }
            }
        } onCancel: {
            Task { @MainActor in self.cancelSleeper(id) }
        }
    }

    /// 時間を進め、締め切りを過ぎた `sleep` を締め切り順に再開する。
    func advance(by duration: Duration) {
        now += duration.seconds
        let due = sleepers.filter { $0.deadline <= now + 1e-9 }.sorted { $0.deadline < $1.deadline }
        sleepers.removeAll { $0.deadline <= now + 1e-9 }
        due.forEach { $0.continuation.resume() }
    }

    /// 指定した長さの `sleep` が待機中になるまで待つ。
    func waitForSleeper(_ duration: Duration) async {
        if sleepers.contains(where: { $0.duration == duration }) { return }
        await withCheckedContinuation { waiters.append((duration, $0)) }
    }

    private func cancelSleeper(_ id: Int) {
        guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return }
        sleepers.remove(at: index).continuation.resume()
    }
}

extension Duration {
    var seconds: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

final class FakeAudio: AudioSource {
    private(set) var started = false
    private(set) var stopped = false
    private var onChunk: (@Sendable (Data, Float) -> Void)?

    func start(onChunk: @escaping @Sendable (Data, Float) -> Void) throws {
        started = true
        stopped = false
        self.onChunk = onChunk
    }

    func stop() {
        stopped = true
        onChunk = nil
    }

    func emit(_ data: Data, rms: Float) {
        onChunk?(data, rms)
    }
}

@MainActor final class FakeSession: TranscriptionSession {
    nonisolated let responses: AsyncThrowingStream<SonioxResponse, Error>
    private let continuation: AsyncThrowingStream<SonioxResponse, Error>.Continuation
    private let clock: TestClock
    var startDelay: Duration
    private(set) var config: SonioxConfig?
    private(set) var log: [String] = [] {
        didSet { resumeWaiters() }
    }
    private var waiters: [(entry: String, continuation: CheckedContinuation<Void, Never>)] = []

    init(clock: TestClock, startDelay: Duration) {
        self.clock = clock
        self.startDelay = startDelay
        (responses, continuation) = AsyncThrowingStream.makeStream()
    }

    func start(config: SonioxConfig) async throws {
        self.config = config
        if startDelay > .zero { await clock.sleep(for: startDelay) }
    }

    func sendAudio(_ pcm: Data) async throws {
        log.append("audio:" + String(decoding: pcm, as: UTF8.self))
    }

    func finalize() async throws {
        log.append("finalize")
    }

    func finish() async {
        log.append("finish")
        continuation.finish()
    }

    func push(_ response: SonioxResponse) {
        continuation.yield(response)
    }

    func fail(_ error: Error) {
        continuation.finish(throwing: error)
    }

    /// `log` に `entry` が記録されるまで待つ。
    func waitFor(_ entry: String) async {
        if log.contains(entry) { return }
        await withCheckedContinuation { waiters.append((entry, $0)) }
    }

    private func resumeWaiters() {
        let ready = waiters.filter { log.contains($0.entry) }
        waiters.removeAll { log.contains($0.entry) }
        ready.forEach { $0.continuation.resume() }
    }
}

/// SessionController からは MainActor 上でだけ呼ばれる。
final class FakeFactory: TranscriptionSessionFactory, @unchecked Sendable {
    private let clock: TestClock
    var startDelay: Duration = .zero
    private(set) var sessions: [FakeSession] = []

    @MainActor init(clock: TestClock) {
        self.clock = clock
    }

    func makeSession() -> TranscriptionSession {
        MainActor.assumeIsolated {
            let session = FakeSession(clock: clock, startDelay: startDelay)
            sessions.append(session)
            return session
        }
    }
}

final class FakeInserter: TextInserter {
    private(set) var inserted: [String] = []
    var error: InsertionError?

    func insert(_ text: String) throws {
        if let error { throw error }
        inserted.append(text)
    }
}

final class FakeFrontmost: FrontmostAppProvider {
    var bundleID: String? = "com.example.editor"

    func frontmostBundleID() -> String? { bundleID }
}

extension SonioxResponse {
    static func final(_ text: String) -> SonioxResponse {
        SonioxResponse(tokens: [SonioxToken(text: text, isFinal: true)],
                       finished: false, errorCode: nil, errorMessage: nil)
    }

    static let fin = SonioxResponse(tokens: [SonioxToken(text: "<fin>", isFinal: true)],
                                    finished: false, errorCode: nil, errorMessage: nil)
}
