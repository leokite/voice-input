import CoreGraphics
import Foundation
import VoiceInputCore

/// CGEventTap でキーを監視し、録音キーの down と up、その他のキーの押下を通知する。
///
/// tap は専用スレッドの run loop で動かす。メインスレッドが止まっても（キーチェーンの確認ダイアログや
/// マイクの起動など）、tap の応答が遅れてシステムに無効にされることはない。
/// コールバックはすべてその専用スレッドで呼ばれる。呼ばれた側がメインスレッドへ移す。
final class GlobalKeyMonitor: @unchecked Sendable {
    private let watched: @Sendable () -> Set<KeyID>
    private let onEvent: @Sendable (KeyEvent) -> Void
    private let onDisabled: @Sendable () -> Void
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?

    /// - Parameters:
    ///   - watched: 監視するキー。tap のスレッドから呼ぶので、スレッドセーフであること。
    ///   - onDisabled: tap がシステムに一時的に無効にされたとき（その間のイベントは失われる）。
    init(watched: @escaping @Sendable () -> Set<KeyID>,
         onEvent: @escaping @Sendable (KeyEvent) -> Void,
         onDisabled: @escaping @Sendable () -> Void = {}) {
        self.watched = watched
        self.onEvent = onEvent
        self.onDisabled = onDisabled
    }

    /// tap を作れなければ（アクセシビリティの許可がなければ）false。
    func start() -> Bool {
        lock.lock()
        defer { lock.unlock() }
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
        let port = UncheckedPort(port: tap)
        let thread = Thread { [weak self] in
            self?.lock.withLock { self?.runLoop = CFRunLoopGetCurrent() }
            let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port.port, 0)
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: port.port, enable: true)
            CFRunLoopRun()
        }
        thread.name = "VoiceInput.GlobalKeyMonitor"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    /// tap を止めて捨てる。以後の `start()` は新しく作り直す。
    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        CFMachPortInvalidate(tap)
        if let runLoop { CFRunLoopStop(runLoop) }
        self.tap = nil
        runLoop = nil
    }

    /// イベントを握りつぶすなら false を返す。tap のスレッドで呼ばれる。
    fileprivate func handle(type: CGEventType, keyCode: UInt16, flags: UInt64) -> Bool {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap = lock.withLock({ tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            onDisabled()
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

private struct UncheckedPort: @unchecked Sendable {
    let port: CFMachPort
}

private func keyTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<GlobalKeyMonitor>.fromOpaque(refcon).takeUnretainedValue()
    let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    let pass = monitor.handle(type: type, keyCode: keyCode, flags: event.flags.rawValue)
    return pass ? Unmanaged.passUnretained(event) : nil
}
