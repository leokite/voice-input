import Foundation

/// マイク。`onChunk` には 16kHz、モノラル、s16le の音声と、その区切りの RMS が届く（どのスレッドからでもよい）。
public protocol AudioSource: AnyObject {
    func start(onChunk: @escaping @Sendable (Data, Float) -> Void) throws
    func stop()
}

public protocol TextInserter {
    func insert(_ text: String) throws
}

public enum InsertionError: Error, Equatable {
    case secureInput, failed
}

public protocol FrontmostAppProvider {
    func frontmostBundleID() -> String?
}

public enum SessionState: Equatable, Sendable {
    case idle
    case recording(level: Float, preview: String)
    case processing
    case error(String)
    case notice(String)
}

/// KeyAction を受けて、録音、Soniox とのやり取り、文字の挿入、履歴への保存までを進める。
@MainActor public final class SessionController {
    public var onStateChange: ((SessionState) -> Void)?
    /// 無音で自動停止したときに呼ぶ。呼ばれた側は KeyStateMachine の `reset()` を呼ぶ。
    public var onAutoStop: (() -> Void)?

    private let audio: AudioSource
    private let sessions: TranscriptionSessionFactory
    private let inserter: TextInserter
    private let frontmost: FrontmostAppProvider
    private let settings: () -> AppSettings
    private let glossary: () -> Glossary
    private let onHistory: (HistoryEntry) -> Void
    private let onTermsUsed: (Set<String>) -> Void
    private let now: () -> TimeInterval
    private let sleep: (Duration) async -> Void

    private var state: SessionState = .idle
    private var recording: Recording?
    private var sessionTask: Task<Void, Never>?
    private var displayTask: Task<Void, Never>?

    public init(
        audio: AudioSource,
        sessions: TranscriptionSessionFactory,
        inserter: TextInserter,
        frontmost: FrontmostAppProvider,
        settings: @escaping () -> AppSettings,
        glossary: @escaping () -> Glossary,
        onHistory: @escaping (HistoryEntry) -> Void,
        onTermsUsed: @escaping (Set<String>) -> Void,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping (Duration) async -> Void = { try? await Task.sleep(for: $0) }
    ) {
        self.audio = audio
        self.sessions = sessions
        self.inserter = inserter
        self.frontmost = frontmost
        self.settings = settings
        self.glossary = glossary
        self.onHistory = onHistory
        self.onTermsUsed = onTermsUsed
        self.now = now
        self.sleep = sleep
    }

    public func handle(_ action: KeyAction) {
        switch action {
        case .beginBuffering: beginBuffering()
        case .confirm: confirm()
        case .stop: stop(auto: false)
        case .cancel: cancel()
        }
    }

    /// テスト用。進行中のセッションが終わる（idle、error、notice のいずれかになる）まで待つ。
    public func waitUntilIdle() async {
        await sessionTask?.value
    }

    // MARK: - Actions

    private func beginBuffering() {
        guard recording == nil else { return }
        displayTask?.cancel()
        displayTask = nil
        setState(.idle)
        let r = Recording(startedAt: now())
        let chunks = r.chunks
        do {
            try audio.start(onChunk: { data, rms in chunks.yield(Chunk(data: data, rms: rms)) })
        } catch {
            return
        }
        recording = r
        r.pump = Task { [weak self] in
            for await chunk in r.chunkStream {
                self?.received(chunk, in: r)
            }
            r.outbox.finish()
        }
    }

    private func cancel() {
        guard let r = recording, r.phase == .buffering else { return }
        stopMic(r)
        recording = nil
    }

    private func confirm() {
        guard let r = recording, r.phase == .buffering else { return }
        let settings = settings()
        r.phase = .recording
        r.bundleID = frontmost.frontmostBundleID()
        r.realtime = settings.insertionMode == .realtime
        r.silence = SilenceDetector(timeout: settings.silenceTimeout)
        r.pipeline = TextPipeline(fillers: FillerRemover(fillers: settings.fillers), glossary: glossary())
        let config = SonioxConfig(languageHints: settings.languageHints,
                                  terms: glossary().contextTerms().terms)
        setState(.recording(level: 0, preview: ""))
        let session = sessions.makeSession()
        sessionTask = Task { [weak self] in
            await self?.run(session, config: config, for: r)
        }
        if r.realtime {
            r.ticker = Task { [weak self] in
                while !Task.isCancelled {
                    await self?.sleep(.milliseconds(100))
                    guard !Task.isCancelled, let self else { return }
                    if let chunk = r.chunker.tick(at: self.now()) { self.emitRealtime(chunk, in: r) }
                    self.publishPreview(r)
                }
            }
        }
    }

    private func stop(auto: Bool) {
        guard let r = recording, r.phase == .recording else { return }
        r.phase = .finishing
        r.stoppedAt = now()
        Task { [weak self] in
            await self?.sleep(.milliseconds(200))
            guard let self else { return }
            self.stopMic(r)
            if self.recording === r { self.setState(.processing) }
        }
        if auto { onAutoStop?() }
    }

    // MARK: - Audio

    private func received(_ chunk: Chunk, in r: Recording) {
        r.outbox.yield(chunk.data)
        guard r.phase == .recording, recording === r else { return }
        r.level = chunk.rms
        publishPreview(r)
        if r.silence.feed(rms: chunk.rms, at: now()) {
            stop(auto: true)
        }
    }

    /// マイクを止める。まだ届いていない音声は捨て、ためた分を送り終えたら送信を終える。
    private func stopMic(_ r: Recording) {
        guard r.micOn else { return }
        r.micOn = false
        if r.phase != .buffering { r.phase = .finishing }
        audio.stop()
        r.chunks.finish()
    }

    // MARK: - Soniox

    private func run(_ session: TranscriptionSession, config: SonioxConfig, for r: Recording) async {
        do {
            try await session.start(config: config)
            r.receiver = Task { [weak self] in
                await self?.receive(session.responses, for: r)
            }
            for await data in r.outboxStream {
                if r.failure != nil { break }
                try await session.sendAudio(data)
            }
            if let failure = r.failure { throw failure }
            try await session.finalize()
            try await waitForFin(r)
        } catch {
            fail(r, error)
        }
        r.finishing = true
        await session.finish()
        await r.receiver?.value
        complete(r)
    }

    private func receive(_ responses: AsyncThrowingStream<SonioxResponse, Error>, for r: Recording) async {
        do {
            for try await response in responses {
                let update = r.assembler.ingest(response)
                r.partial = update.partialText
                if r.realtime, !update.newFinalText.isEmpty {
                    r.pendingRaw += update.newFinalText
                    if let chunk = r.chunker.append(update.newFinalText, at: now()) {
                        emitRealtime(chunk, in: r)
                    }
                }
                publishPreview(r)
                if update.reachedFin {
                    r.finReached = true
                    r.resumeFinWaiter(with: nil)
                }
            }
            if !r.finReached && !r.finishing { fail(r, SonioxError.connectionClosed) }
        } catch {
            fail(r, error)
        }
    }

    private func waitForFin(_ r: Recording) async throws {
        if r.finReached { return }
        let timeout = Task { [weak self] in
            await self?.sleep(.seconds(5))
            if !Task.isCancelled { r.resumeFinWaiter(with: SonioxError.finTimeout) }
        }
        defer { timeout.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if let failure = r.failure {
                continuation.resume(throwing: failure)
            } else if r.finReached {
                continuation.resume()
            } else {
                r.finWaiter = continuation
            }
        }
    }

    /// 最初の失敗だけを記録し、マイクを止めて待ち合わせを解く。
    private func fail(_ r: Recording, _ error: Error) {
        if r.failure == nil { r.failure = error }
        if r.stoppedAt == nil { r.stoppedAt = now() }
        stopMic(r)
        r.resumeFinWaiter(with: error)
    }

    // MARK: - Text

    private func emitRealtime(_ raw: String, in r: Recording) {
        r.pendingRaw = ""
        let processed = r.pipeline.process(raw)
        guard !processed.text.isEmpty else { return }
        var text = processed.text
        if raw.first?.isWhitespace == true && !r.processedText.isEmpty { text = " " + text }
        r.processedText += text
        r.usedTerms.formUnion(processed.usedTerms)
        deliver(text, in: r)
    }

    private func deliver(_ text: String, in r: Recording) {
        guard r.blocked == nil else {
            r.allInserted = false
            return
        }
        guard frontmost.frontmostBundleID() == r.bundleID else {
            r.blocked = .appSwitched
            r.allInserted = false
            return
        }
        do {
            try inserter.insert(text)
        } catch InsertionError.secureInput {
            r.blocked = .secureInput
            r.allInserted = false
        } catch {
            r.blocked = .failed
            r.allInserted = false
        }
    }

    private func complete(_ r: Recording) {
        r.ticker?.cancel()
        if r.realtime {
            if let rest = r.chunker.flush() { emitRealtime(rest, in: r) }
        } else {
            let processed = r.pipeline.process(r.assembler.finalText)
            if !processed.text.isEmpty {
                r.processedText = processed.text
                r.usedTerms = processed.usedTerms
                deliver(processed.text, in: r)
            }
        }
        if !r.processedText.isEmpty {
            onHistory(HistoryEntry(
                date: Date(),
                text: r.processedText,
                rawText: r.assembler.finalText,
                duration: (r.stoppedAt ?? now()) - r.startedAt,
                inserted: r.failure == nil && r.allInserted
            ))
        }
        if !r.usedTerms.isEmpty { onTermsUsed(r.usedTerms) }
        recording = nil
        if let failure = r.failure {
            show(.error(Self.message(for: failure)))
        } else if r.blocked == .appSwitched {
            show(.notice("アプリが切り替わったため履歴に保存しました"))
        } else if r.blocked == .secureInput {
            show(.notice("パスワード欄には入力できません"))
        } else {
            setState(.idle)
        }
    }

    static func message(for error: Error) -> String {
        switch error as? SonioxError {
        case .unauthenticated: "API キーが正しくありません"
        case .paymentRequired: "Soniox の残高または予算が不足しています"
        default: "ネットワークに接続できません"
        }
    }

    // MARK: - State

    private func publishPreview(_ r: Recording) {
        guard r.phase == .recording, recording === r else { return }
        let preview = r.realtime ? r.pendingRaw + r.partial : ""
        setState(.recording(level: r.level, preview: preview))
    }

    /// error と notice は 3 秒表示してから idle に戻す。
    private func show(_ s: SessionState) {
        setState(s)
        displayTask = Task { [weak self] in
            await self?.sleep(.seconds(3))
            guard !Task.isCancelled, let self, self.state == s else { return }
            self.setState(.idle)
        }
    }

    private func setState(_ s: SessionState) {
        guard s != state else { return }
        state = s
        onStateChange?(s)
    }
}
