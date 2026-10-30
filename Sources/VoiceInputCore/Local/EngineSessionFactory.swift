import Foundation

/// 録音のたびに設定のエンジンを読み、選ばれた側のセッションだけを作る（選ばれなかった側は呼ばない）。
public struct EngineSessionFactory: TranscriptionSessionFactory {
    private let settings: @Sendable () -> AppSettings
    private let soniox: @Sendable () -> TranscriptionSession
    private let local: @Sendable () -> TranscriptionSession

    public init(
        settings: @escaping @Sendable () -> AppSettings,
        soniox: @escaping @Sendable () -> TranscriptionSession,
        local: @escaping @Sendable () -> TranscriptionSession
    ) {
        self.settings = settings
        self.soniox = soniox
        self.local = local
    }

    public func makeSession() -> TranscriptionSession {
        switch settings().engine {
        case .soniox: soniox()
        case .local: local()
        }
    }
}
