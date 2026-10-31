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
