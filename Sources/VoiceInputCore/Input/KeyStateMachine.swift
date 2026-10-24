import Foundation

public struct KeyID: Codable, Hashable, Sendable {
    public var keyCode: UInt16

    public init(keyCode: UInt16) {
        self.keyCode = keyCode
    }

    public static let rightOption = KeyID(keyCode: 61)
    public static let rightCommand = KeyID(keyCode: 54)
    public static let rightControl = KeyID(keyCode: 62)
    public static let rightShift = KeyID(keyCode: 60)
    public static let function = KeyID(keyCode: 63)
}

public enum KeyEvent: Equatable, Sendable {
    case down(KeyID)
    case up(KeyID)
    case otherKeyDown
}

public enum RecordingMode: String, Codable, Sendable {
    case toggle, hold
}

public enum KeyAction: Equatable, Sendable {
    case beginBuffering
    case confirm(RecordingMode)
    case stop
    case cancel
    /// 押し続けの録音中に別のキーが押された。録音を捨てる（何も入れず、履歴にも残さない）。
    case abort
}

/// Pure state machine turning raw key events into recording actions.
public struct KeyStateMachine: Sendable {
    private enum State: Sendable {
        case idle
        /// Record key held, recording not yet confirmed. `chorded` means a cancel was already emitted.
        case pressed(key: KeyID, at: TimeInterval, chorded: Bool)
        case toggleRecording(pressedAgain: Bool, chorded: Bool)
        case holdRecording
    }

    public let toggleKey: KeyID
    public let holdKey: KeyID
    private let holdThreshold: TimeInterval
    private var state: State = .idle

    public init(toggleKey: KeyID, holdKey: KeyID, holdThreshold: TimeInterval = 0.3) {
        self.toggleKey = toggleKey
        self.holdKey = holdKey
        self.holdThreshold = holdThreshold
    }

    public mutating func handle(_ e: KeyEvent, at t: TimeInterval) -> [KeyAction] {
        switch e {
        case .down(let key) where key == toggleKey || key == holdKey:
            return recordKeyDown(key, at: t)
        case .up(let key) where key == toggleKey || key == holdKey:
            return recordKeyUp(key)
        case .down, .otherKeyDown:
            return otherKeyDown()
        case .up:
            return []
        }
    }

    public mutating func tick(at t: TimeInterval) -> [KeyAction] {
        guard case .pressed(let key, let pressedAt, false) = state,
              key == holdKey, t - pressedAt >= holdThreshold else { return [] }
        state = .holdRecording
        return [.confirm(.hold)]
    }

    public mutating func reset() {
        state = .idle
    }

    private mutating func recordKeyDown(_ key: KeyID, at t: TimeInterval) -> [KeyAction] {
        switch state {
        case .idle:
            state = .pressed(key: key, at: t, chorded: false)
            return [.beginBuffering]
        case .pressed(let pressedKey, _, let chorded):
            if key == pressedKey { return [] } // autorepeat
            return chorded ? [] : chord()
        case .toggleRecording(let pressedAgain, _):
            if pressedAgain && key == toggleKey { return [] } // autorepeat
            if key == toggleKey {
                state = .toggleRecording(pressedAgain: true, chorded: false)
            } else if pressedAgain {
                state = .toggleRecording(pressedAgain: true, chorded: true)
            }
            return []
        case .holdRecording:
            return []
        }
    }

    private mutating func recordKeyUp(_ key: KeyID) -> [KeyAction] {
        switch state {
        case .idle:
            return []
        case .pressed(let pressedKey, _, let chorded):
            guard key == pressedKey else { return [] }
            state = .idle
            if chorded { return [] }
            if key == toggleKey {
                state = .toggleRecording(pressedAgain: false, chorded: false)
                return [.confirm(.toggle)]
            }
            return [.cancel]
        case .toggleRecording(let pressedAgain, let chorded):
            guard key == toggleKey, pressedAgain else { return [] }
            if chorded {
                state = .toggleRecording(pressedAgain: false, chorded: false)
                return []
            }
            state = .idle
            return [.stop]
        case .holdRecording:
            guard key == holdKey else { return [] }
            state = .idle
            return [.stop]
        }
    }

    private mutating func otherKeyDown() -> [KeyAction] {
        switch state {
        case .pressed(_, _, false):
            return chord()
        case .toggleRecording(true, _):
            state = .toggleRecording(pressedAgain: true, chorded: true)
            return []
        case .holdRecording:
            state = .idle
            return [.abort]
        default:
            return []
        }
    }

    private mutating func chord() -> [KeyAction] {
        guard case .pressed(let key, let at, false) = state else { return [] }
        state = .pressed(key: key, at: at, chorded: true)
        return [.cancel]
    }
}
