import Foundation

/// AppCoordinator が KeyAction を SessionController に渡す前後の判断。
/// 押下と録音の途中経過を覚え、録音を始めてはいけない場面（API キーがない、パスワード入力中、前の録音を処理中）を見分ける。
public struct RecordingGate: Sendable {
    public enum Rejection: Equatable, Sendable {
        /// API キーがないまま録音だと確定した。
        case missingAPIKey
        /// 確定した時点でパスワード入力中（Secure Event Input）だった。
        case secureInput
        /// 前の録音をまだ処理している。
        case busy
    }

    public struct Decision: Equatable, Sendable {
        /// SessionController に渡すアクション。nil なら渡さない。
        public var forward: KeyAction?
        /// 断った理由。呼び出し側は KeyStateMachine を reset し、知らせを出す。
        public var rejection: Rejection?

        public init(forward: KeyAction? = nil, rejection: Rejection? = nil) {
            self.forward = forward
            self.rejection = rejection
        }
    }

    /// API キーがないまま押されたキー。確定したら断る。
    private var pressWithoutKey = false
    /// SessionController に .beginBuffering を渡し、まだ確定も取り消しもしていない。
    public private(set) var buffering = false
    /// 録音中のモード。録音中でなければ nil。
    public private(set) var activeMode: RecordingMode?

    public init() {}

    /// 録音中でも、押下の途中でもない。
    public var isQuiet: Bool { !buffering && activeMode == nil && !pressWithoutKey }

    public mutating func decide(_ action: KeyAction, hasAPIKey: Bool, secureInput: Bool) -> Decision {
        switch action {
        case .beginBuffering:
            if !hasAPIKey {
                pressWithoutKey = true
                return Decision()
            }
            buffering = true
            return Decision(forward: action)
        case .confirm where pressWithoutKey:
            pressWithoutKey = false
            return Decision(rejection: .missingAPIKey)
        case .cancel where pressWithoutKey:
            pressWithoutKey = false
            return Decision()
        case .confirm where secureInput:
            let wasBuffering = buffering
            buffering = false
            return Decision(forward: wasBuffering ? .cancel : nil, rejection: .secureInput)
        case .confirm(let mode):
            buffering = false
            activeMode = mode
            return Decision(forward: action)
        case .cancel:
            buffering = false
            return Decision(forward: action)
        case .stop, .abort:
            activeMode = nil
            return Decision(forward: action)
        }
    }

    /// SessionController が `action` を受け付けなかった。断るべきなら理由を返す。
    public mutating func sessionRejected(_ action: KeyAction) -> Rejection? {
        switch action {
        case .beginBuffering:
            buffering = false
            return .busy
        case .confirm:
            activeMode = nil
            return nil
        default:
            return nil
        }
    }

    public mutating func sessionStateChanged(_ state: SessionState) {
        if case .recording = state {} else { activeMode = nil }
        if case .error = state { buffering = false }
    }

    public mutating func reset() {
        pressWithoutKey = false
        buffering = false
        activeMode = nil
    }
}
