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

    /// 削除の途中。録音の入口は閉じたまま、見直しやダウンロードで状態を戻さない。
    private var deleting = false

    /// ファイルを見て状態を決め直す（ダウンロードと準備の途中、失敗の理由は残す。LocalModeRules.refreshedStatus）
    public func refresh() {
        guard !deleting else { return }
        let installed = LocalModelLayout.isInstalled(base: base)
        status = LocalModeRules.refreshedStatus(
            current: status, hasFiles: LocalModelLayout.hasFiles(base: base), installed: installed,
            tokenizerValid: installed && LocalModelLayout.tokenizerFilesAreValid(base: base))
    }

    /// 裏での読み込みに失敗した。使える状態のときだけ失敗にして、録音を断り理由を見せる。
    public func loadFailed(_ message: String) {
        guard status == .ready else { return }
        status = .failed("読み込みに失敗しました: \(message)")
    }

    public func download() async {
        guard !deleting else { return }
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
            guard LocalModelLayout.isInstalled(base: base), LocalModelLayout.tokenizerFilesAreValid(base: base) else {
                throw LocalTranscriptionError(message: "モデルのファイルがそろっていません")
            }
            status = .ready
        } catch {
            status = .failed(Self.reason(error))
        }
    }

    /// モデルとトークナイザー（どちらも `models/` の下）を消す。
    /// 先に未導入にして録音の入口を閉じ、読み込みの途中ならその終わりを待って手放してから消す
    /// （読み込みの途中にファイルを消すと、WhisperKit がトークナイザーを取りに行くため）。
    public func delete() async throws {
        if deleting { throw LocalTranscriptionError(message: "削除の途中です") }
        switch status {
        case .downloading, .preparing: throw LocalTranscriptionError(message: "準備の途中は削除できません")
        default: break
        }
        deleting = true
        status = .notInstalled
        defer {
            deleting = false
            status = .notInstalled
            refresh()
        }
        try await transcriber.removeModels(at: base.appendingPathComponent("models", isDirectory: true))
    }

    private static func reason(_ error: Error) -> String {
        if error is CancellationError || Task.isCancelled { return "ダウンロードを取り消しました" }
        if let error = error as? LocalTranscriptionError { return error.message }
        return error.localizedDescription
    }
}
