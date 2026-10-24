import CoreGraphics
import VoiceInputCore

/// CGEventTap でキーを監視し、録音キーの down と up、その他のキーの押下を通知する。
@MainActor final class GlobalKeyMonitor {
    private let watched: () -> Set<KeyID>
    private let onEvent: (KeyEvent) -> Void
    private var tap: CFMachPort?

    init(watched: @escaping () -> Set<KeyID>, onEvent: @escaping (KeyEvent) -> Void) {
        self.watched = watched
        self.onEvent = onEvent
    }

    /// tap を作れなければ（アクセシビリティの許可がなければ）false。
    func start() -> Bool {
        if tap != nil { return true }
        let mask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: keyTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// イベントを握りつぶすなら false を返す。
    fileprivate func handle(type: CGEventType, keyCode: UInt16, flags: UInt64) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        case .flagsChanged:
            let key = KeyID(keyCode: keyCode)
            if watched().contains(key), let event = ModifierKeys.event(keyCode: keyCode, flags: flags) {
                onEvent(event)
            }
            return true
        case .keyDown, .keyUp:
            let key = KeyID(keyCode: keyCode)
            if watched().contains(key), !ModifierKeys.isModifier(key) {
                onEvent(type == .keyDown ? .down(key) : .up(key))
                return false
            }
            if type == .keyDown { onEvent(.otherKeyDown) }
            return true
        default:
            return true
        }
    }
}

/// tap はメインの run loop に登録しているので、このコールバックはメインスレッドで呼ばれる。
private func keyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<GlobalKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    let flags = event.flags.rawValue
    let pass = MainActor.assumeIsolated {
        monitor.handle(type: type, keyCode: keyCode, flags: flags)
    }
    return pass ? Unmanaged.passUnretained(event) : nil
}
