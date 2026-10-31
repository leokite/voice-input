import Foundation

/// アプリがローカル認識をどう扱うかの判断。AppCoordinator から呼ぶ。
public enum LocalModeRules {
    /// RecordingGate に渡す値。ローカルは Soniox のキーを要らず、モデルが使えて読み込みが済んでいるときだけ録音できる。
    /// 読み込みの途中に録音すると、認識が時間内に終わらず声が捨てられるため。
    public static func gateInputs(engine: TranscriptionEngine, hasAPIKey: Bool, modelStatus: LocalModelStatus,
                                  warmingUp: Bool) -> (hasAPIKey: Bool, localModelReady: Bool) {
        switch engine {
        case .soniox: (hasAPIKey, true)
        case .local: (true, modelStatus == .ready && !warmingUp)
        }
    }

    public enum NotReadyReaction: Equatable, Sendable {
        /// 読み込みの途中。待てば使えるので、設定画面は開かない。
        case waitForWarmUp
        /// 未導入や失敗。設定画面を開いて理由を見せる。
        case openSettings
    }

    /// ローカルのモデルが使えず録音を断ったときの知らせ方。
    public static func notReadyReaction(warmingUp: Bool) -> NotReadyReaction {
        warmingUp ? .waitForWarmUp : .openSettings
    }

    /// ファイルを見直したときの状態。ダウンロードと準備の途中は変えない。
    /// 失敗は、やり直すか削除するまで（ファイルが消えるまで）理由を見せ続ける。
    public static func refreshedStatus(current: LocalModelStatus, hasFiles: Bool, installed: Bool,
                                       tokenizerValid: Bool) -> LocalModelStatus {
        switch current {
        case .downloading, .preparing: return current
        case .failed: return hasFiles ? current : .notInstalled
        case .notInstalled, .ready: break
        }
        guard installed else { return .notInstalled }
        // 読めないトークナイザーで読み込むと、WhisperKit は取得しに行く。使える扱いにしない。
        guard tokenizerValid else { return .failed("トークナイザーのファイルが壊れています。ダウンロードし直してください") }
        return .ready
    }

    /// Soniox のキーが要るのに無いか。ローカルはキーを要らない。
    public static func needsAPIKey(engine: TranscriptionEngine, hasAPIKey: Bool) -> Bool {
        engine == .soniox && !hasAPIKey
    }

    /// 録音できるようにするため、起動時に設定画面を開くべきか（Soniox はキーが無い、ローカルはモデルが使えない）。
    public static func needsSetup(engine: TranscriptionEngine, hasAPIKey: Bool, modelStatus: LocalModelStatus) -> Bool {
        switch engine {
        case .soniox: !hasAPIKey
        case .local: modelStatus != .ready
        }
    }

    /// 録音や処理、押下の途中はエンジンを切り替えない（送らないと表示したまま Soniox の録音が続かないように）。
    public static func canSwitchEngine(sessionState: SessionState, keysQuiet: Bool) -> Bool {
        nothingInFlight(sessionState: sessionState, keysQuiet: keysQuiet)
    }

    private static func nothingInFlight(sessionState: SessionState, keysQuiet: Bool) -> Bool {
        switch sessionState {
        case .recording, .processing: false
        case .idle, .error, .notice: keysQuiet
        }
    }

    /// モデルを消してよいか。未導入でも途中までのファイルが残っていれば消せる。
    /// 録音や処理、押下の途中、裏での読み込みの間は消さない。
    public static func canDeleteModel(hasFiles: Bool, status: LocalModelStatus, sessionState: SessionState,
                                      keysQuiet: Bool, warmingUp: Bool) -> Bool {
        switch status {
        case .ready, .failed: break
        case .notInstalled: guard hasFiles else { return false }
        case .downloading, .preparing: return false
        }
        return nothingInFlight(sessionState: sessionState, keysQuiet: keysQuiet) && !warmingUp
    }

    /// 最初の録音を待たせないよう、裏でモデルを読み込んでおくか。
    public static func shouldWarmUp(engine: TranscriptionEngine, status: LocalModelStatus) -> Bool {
        engine == .local && status == .ready
    }

    /// OpenAI で置き換え元を探すか。ローカルのときは設定やキーがあっても使わない。
    public static func usesCloudLocator(settings: AppSettings, hasOpenAIKey: Bool) -> Bool {
        settings.allowsCloud && settings.useCloudLocator && hasOpenAIKey
    }
}
