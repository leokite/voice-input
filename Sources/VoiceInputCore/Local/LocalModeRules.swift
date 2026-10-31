import Foundation

/// アプリがローカル認識をどう扱うかの判断。AppCoordinator から呼ぶ。
public enum LocalModeRules {
    /// RecordingGate に渡す値。ローカルは Soniox のキーを要らず、モデルが使えるときだけ録音できる。
    public static func gateInputs(engine: TranscriptionEngine, hasAPIKey: Bool,
                                  modelStatus: LocalModelStatus) -> (hasAPIKey: Bool, localModelReady: Bool) {
        switch engine {
        case .soniox: (hasAPIKey, true)
        case .local: (true, modelStatus == .ready)
        }
    }

    /// モデルを消してよいか。録音や処理、押下の途中、裏での読み込みの間は消さない。
    public static func canDeleteModel(status: LocalModelStatus, sessionState: SessionState, keysQuiet: Bool,
                                      warmingUp: Bool) -> Bool {
        switch status {
        case .ready, .failed: break
        case .notInstalled, .downloading, .preparing: return false
        }
        switch sessionState {
        case .recording, .processing: return false
        case .idle, .error, .notice: break
        }
        return keysQuiet && !warmingUp
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
