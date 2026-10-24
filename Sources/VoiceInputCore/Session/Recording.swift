import Foundation

struct Chunk: Sendable {
    let data: Data
    let rms: Float
}

/// SessionController が 1 回の録音で使う状態。
@MainActor final class Recording {
    enum Phase { case buffering, recording, finishing }
    enum Blocked { case appSwitched, secureInput, failed }

    let startedAt: TimeInterval
    var stoppedAt: TimeInterval?
    var phase: Phase = .buffering
    var bundleID: String?
    var realtime = false
    var micOn = true

    /// マイクから届いた音声（どのスレッドからでも yield できる）。
    let chunkStream: AsyncStream<Chunk>
    let chunks: AsyncStream<Chunk>.Continuation
    /// Soniox に送る音声。接続できるまではここにたまる。
    let outboxStream: AsyncStream<Data>
    let outbox: AsyncStream<Data>.Continuation

    var silence = SilenceDetector()
    var pipeline = TextPipeline(fillers: FillerRemover(fillers: []), glossary: .empty)
    var assembler = TranscriptAssembler()
    var chunker = RealtimeChunker()
    var level: Float = 0
    var partial = ""
    /// リアルタイム入力で、まだ区切られていない確定テキスト。
    var pendingRaw = ""

    var pump: Task<Void, Never>?
    var receiver: Task<Void, Never>?
    var ticker: Task<Void, Never>?
    var finWaiter: CheckedContinuation<Void, Error>?
    var finReached = false
    /// finish() を呼び始めた後は、受信の終わりを切断として扱わない。
    var finishing = false
    var failure: Error?

    var processedText = ""
    var usedTerms: Set<String> = []
    var allInserted = true
    var blocked: Blocked?

    init(startedAt: TimeInterval) {
        self.startedAt = startedAt
        (chunkStream, chunks) = AsyncStream.makeStream()
        (outboxStream, outbox) = AsyncStream.makeStream()
    }

    func resumeFinWaiter(with error: Error?) {
        guard let waiter = finWaiter else { return }
        finWaiter = nil
        if let error { waiter.resume(throwing: error) } else { waiter.resume() }
    }
}

/// 送信（sendAudio、finalize）の失敗。受信側のエラーと区別するために包む。
struct SendFailure: Error {
    let underlying: Error
}

/// 最初の 1 回だけ値を渡す待ち合わせ。
@MainActor final class Gate<T: Sendable> {
    var continuation: CheckedContinuation<T, Never>?

    func open(_ value: T) {
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(returning: value)
    }
}
