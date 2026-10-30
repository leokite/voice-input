import Foundation

/// 音声をためておき、`finalize()` でまとめて `LocalTranscriber` に渡す。
/// 結果は Soniox と同じ形のトークン（確定 1 つと `<fin>`）で流すので、SessionController は違いを意識しない。
public final class LocalTranscriptionSession: TranscriptionSession, @unchecked Sendable {
    public let responses: AsyncThrowingStream<SonioxResponse, Error>
    private let continuation: AsyncThrowingStream<SonioxResponse, Error>.Continuation
    private let transcriber: LocalTranscriber

    private let lock = NSLock()
    private var pcm = Data()
    private var wasLoud = false
    private var languageHints: [String] = []
    private var terms: [String] = []
    private var task: Task<Void, Never>?

    public init(transcriber: LocalTranscriber) {
        self.transcriber = transcriber
        (responses, continuation) = AsyncThrowingStream.makeStream()
    }

    /// 15 秒 + 録音の長さの 3 倍（16kHz、16bit で 1 秒 32000 バイト）。
    public var finalizeTimeout: Duration {
        let bytes = lock.withLock { pcm.count }
        return .seconds(15) + .seconds(Double(bytes) / 32000 * 3)
    }

    public func start(config: SonioxConfig) async throws {
        lock.withLock {
            languageHints = config.languageHints
            terms = config.context.terms
        }
    }

    public func sendAudio(_ data: Data) async throws {
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
        let loud = PCMChunker.rms(samples) >= SilenceDetector.defaultThreshold
        lock.withLock {
            pcm.append(data)
            if loud { wasLoud = true }
        }
    }

    public func finalize() async throws {
        let (audio, loud, hints, terms) = lock.withLock { (pcm, wasLoud, languageHints, terms) }
        let task = Task { [transcriber, continuation] in
            guard loud else {
                continuation.yield(Self.fin)
                return
            }
            do {
                let text = try await transcriber.transcribe(pcm: audio, languageHints: hints, terms: terms)
                if !text.isEmpty {
                    continuation.yield(SonioxResponse(tokens: [SonioxToken(text: text, isFinal: true)],
                                                      finished: false, errorCode: nil, errorMessage: nil))
                }
                continuation.yield(Self.fin)
            } catch {
                continuation.finish(throwing: error)
            }
        }
        lock.withLock { self.task = task }
    }

    public func finish() async {
        let task = lock.withLock { self.task }
        task?.cancel()
        continuation.finish()
    }

    private static let fin = SonioxResponse(tokens: [SonioxToken(text: "<fin>", isFinal: true)],
                                            finished: false, errorCode: nil, errorMessage: nil)
}
