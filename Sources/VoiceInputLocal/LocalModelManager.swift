import Foundation
import VoiceInputCore
import WhisperKit

/// ローカルモデルの導入、状態、削除。通信するのは `download()` だけ。
@MainActor
public final class LocalModelManager: ObservableObject {
    @Published public private(set) var status: LocalModelStatus = .notInstalled
    public let transcriber: WhisperKitTranscriber
    private let base: URL

    public init(base: URL) {
        self.base = base
        transcriber = WhisperKitTranscriber(base: base)
        refresh()
    }

    /// ファイルを見て、未導入か使えるかにする（ダウンロードと準備の途中は変えない）
    public func refresh() {
        switch status {
        case .downloading, .preparing: return
        default: status = LocalModelLayout.isInstalled(base: base) ? .ready : .notInstalled
        }
    }

    public func download() async {
        switch status {
        case .downloading, .preparing: return
        default: break
        }
        status = .downloading(fraction: 0)
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            _ = try await WhisperKit.download(
                variant: LocalModelLayout.variant,
                downloadBase: base,
                progressCallback: { [weak self] progress in
                    let fraction = min(max(progress.fractionCompleted, 0), 1)
                    Task { @MainActor in
                        // 遅れて届いた進み具合で、準備中や結果を上書きしない
                        guard let self, case .downloading = self.status else { return }
                        self.status = .downloading(fraction: fraction)
                    }
                }
            )
            status = .preparing
            // トークナイザーの取得と Core ML のコンパイルのため、一度読み込んで無音を認識する
            try await transcriber.prepareAfterDownload()
            guard LocalModelLayout.isInstalled(base: base) else {
                throw LocalTranscriptionError(message: "モデルのファイルがそろっていません")
            }
            status = .ready
        } catch {
            status = .failed(Self.reason(error))
        }
    }

    /// モデルとトークナイザー（どちらも `models/` の下）を消す
    public func delete() throws {
        switch status {
        case .downloading, .preparing: throw LocalTranscriptionError(message: "準備の途中は削除できません")
        default: break
        }
        let models = base.appendingPathComponent("models", isDirectory: true)
        if FileManager.default.fileExists(atPath: models.path) {
            try FileManager.default.removeItem(at: models)
        }
        let transcriber = transcriber
        Task { await transcriber.unload() }
        status = .notInstalled
    }

    private static func reason(_ error: Error) -> String {
        if let error = error as? LocalTranscriptionError { return error.message }
        if error is CancellationError { return "ダウンロードを取り消しました" }
        return error.localizedDescription
    }
}
