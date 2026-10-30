import Foundation

/// 文字起こしセッションの抽象。SessionController はこのプロトコル越しに駆動する。
public protocol TranscriptionSession: AnyObject, Sendable {
    func start(config: SonioxConfig) async throws
    func sendAudio(_ pcm: Data) async throws
    func finalize() async throws
    func finish() async
    /// 1 回だけ iterate できる。ソケットが閉じるかエラーになると必ず終了する。
    var responses: AsyncThrowingStream<SonioxResponse, Error> { get }
    /// `finalize()` から `<fin>` を待つ最長の時間。
    var finalizeTimeout: Duration { get }
}

extension TranscriptionSession {
    public var finalizeTimeout: Duration { .seconds(5) }
}

public protocol TranscriptionSessionFactory: Sendable {
    func makeSession() -> TranscriptionSession
}

public enum SonioxError: Error, Equatable {
    case unauthenticated
    case paymentRequired
    case connectionClosed
    case finTimeout
    case server(code: String, message: String)
}

public final class SonioxWebSocketSession: TranscriptionSession, @unchecked Sendable {
    public let responses: AsyncThrowingStream<SonioxResponse, Error>

    private let apiKey: String
    private let url: URL
    private let continuation: AsyncThrowingStream<SonioxResponse, Error>.Continuation
    private let lock = NSLock()
    private var task: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var receiveTask: Task<Void, Never>?
    private var receivedFinished = false
    private var closedByUs = false
    private var terminated = false

    public init(
        apiKey: String,
        url: URL = URL(string: "wss://stt-rt.soniox.com/transcribe-websocket")!
    ) {
        self.apiKey = apiKey
        self.url = url
        (responses, continuation) = AsyncThrowingStream.makeStream()
    }

    public func start(config: SonioxConfig) async throws {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let session = URLSession(configuration: .ephemeral)
        let task = session.webSocketTask(with: request)
        lock.withLock {
            self.urlSession = session
            self.task = task
        }
        task.resume()
        receiveTask = Task { [weak self] in
            await self?.receiveLoop(task)
        }
        let data = try JSONEncoder().encode(config)
        do {
            try await task.send(.string(String(decoding: data, as: UTF8.self)))
        } catch {
            // ストリームの終了は受信ループに任せる (サーバーの本当のエラーを優先するため)。
            throw mapClosure(error, task: task)
        }
    }

    public func sendAudio(_ pcm: Data) async throws {
        try await send(.data(pcm))
    }

    public func finalize() async throws {
        try await send(.string(#"{"type":"finalize"}"#))
    }

    public func finish() async {
        let (task, session) = lock.withLock { () -> (URLSessionWebSocketTask?, URLSession?) in
            closedByUs = true
            return (self.task, urlSession)
        }
        // 送信を待つ前にストリームを終える (ハンドシェイク中でもハングさせない)。
        terminate(throwing: nil)
        // 空のテキストフレームがストリーム終端の合図。待ち過ぎないよう 1 秒で打ち切る。
        if let task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { try? await task.send(.string("")) }
                group.addTask {
                    // 送信が 1 秒で終わらなければソケットを閉じ、保留中の送信を失敗させる。
                    guard (try? await Task.sleep(for: .seconds(1))) != nil else { return }
                    task.cancel(with: .goingAway, reason: nil)
                }
                await group.next()
                group.cancelAll()
            }
            task.cancel(with: .normalClosure, reason: nil)
        }
        session?.finishTasksAndInvalidate()
    }

    // MARK: - Private

    private func send(_ message: URLSessionWebSocketTask.Message) async throws {
        guard let task = lock.withLock({ self.task }) else { throw SonioxError.connectionClosed }
        do {
            try await task.send(message)
        } catch {
            // 受信ループが本当のエラーでストリームを終えるので、ここでは終えない。
            throw mapClosure(error, task: task)
        }
    }

    private func receiveLoop(_ task: URLSessionWebSocketTask) async {
        while true {
            let message: URLSessionWebSocketTask.Message
            do {
                message = try await task.receive()
            } catch {
                let (finished, byUs) = lock.withLock { (receivedFinished, closedByUs) }
                if finished || byUs {
                    terminate(throwing: nil)
                } else {
                    terminate(throwing: mapClosure(error, task: task))
                }
                return
            }
            let data: Data
            switch message {
            case .string(let s): data = Data(s.utf8)
            case .data(let d): data = d
            @unknown default: continue
            }
            guard let response = try? JSONDecoder().decode(SonioxResponse.self, from: data) else {
                continue
            }
            if let code = response.errorCode {
                terminate(throwing: Self.map(code: code, message: response.errorMessage ?? ""))
                task.cancel(with: .normalClosure, reason: nil)
                return
            }
            continuation.yield(response)
            if response.finished {
                lock.withLock { receivedFinished = true }
                terminate(throwing: nil)
                task.cancel(with: .normalClosure, reason: nil)
                return
            }
        }
    }

    /// ストリームを一度だけ終了させる。
    private func terminate(throwing error: Error?) {
        let first = lock.withLock { () -> Bool in
            if terminated { return false }
            terminated = true
            return true
        }
        guard first else { return }
        continuation.finish(throwing: error)
    }

    /// ハンドシェイク拒否 (HTTP 401/402) とそれ以外の切断を区別する。
    private func mapClosure(_ error: Error, task: URLSessionWebSocketTask) -> SonioxError {
        if let http = task.response as? HTTPURLResponse {
            if http.statusCode == 401 { return .unauthenticated }
            if http.statusCode == 402 { return .paymentRequired }
        }
        return .connectionClosed
    }

    static func map(code: String, message: String) -> SonioxError {
        switch code {
        case "401": .unauthenticated
        case "402": .paymentRequired
        default: .server(code: code, message: message)
        }
    }
}

public struct SonioxSessionFactory: TranscriptionSessionFactory {
    private let apiKey: String

    public init(apiKey: String) {
        self.apiKey = apiKey
    }

    public func makeSession() -> TranscriptionSession {
        SonioxWebSocketSession(apiKey: apiKey)
    }
}
