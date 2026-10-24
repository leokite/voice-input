import CoreGraphics
import Foundation
import VoiceInputCore

/// CGEventTap でキーを監視し、録音キーの down と up、その他のキーの押下、用語集に登録するキーの押下を通知する。
/// クリックとスクロールも「その他のキー」として通知する（Option+クリックなどで録音が始まらないように）。
///
/// tap は専用スレッドの run loop で動かす。メインスレッドが止まっても（キーチェーンの確認ダイアログや
/// マイクの起動など）、tap の応答が遅れてシステムに無効にされることはない。
/// コールバックはすべてその専用スレッドで呼ばれる。呼ばれた側がメインスレッドへ移す。
final class GlobalKeyMonitor: @unchecked Sendable {
    private let watched: @Sendable () -> Set<KeyID>
    private let shortcut: @Sendable () -> Shortcut?
    private let onEvent: @Sendable (KeyEvent) -> Void
    private let onShortcut: @Sendable () -> Void
    private let onDisabled: @Sendable () -> Void
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    /// 握りつぶしたショートカットの keyDown の keyCode。対応する keyUp も握りつぶす。
    private var swallowedShortcutKey: UInt16?

    /// - Parameters:
    ///   - watched: 監視するキー。tap のスレッドから呼ぶので、スレッドセーフであること。
    ///   - shortcut: 用語集に登録するキー。nil なら監視しない。tap のスレッドから呼ぶ。
    ///   - onShortcut: そのキーが押されたとき（オートリピートでは呼ばない）。
    ///   - onDisabled: tap がシステムに一時的に無効にされたとき（その間のイベントは失われる）。
    init(watched: @escaping @Sendable () -> Set<KeyID>,
         shortcut: @escaping @Sendable () -> Shortcut? = { nil },
         onEvent: @escaping @Sendable (KeyEvent) -> Void,
         onShortcut: @escaping @Sendable () -> Void = {},
         onDisabled: @escaping @Sendable () -> Void = {}) {
        self.watched = watched
        self.shortcut = shortcut
        self.onEvent = onEvent
        self.onShortcut = onShortcut
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
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
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
    fileprivate func handle(type: CGEventType, keyCode: UInt16, flags: UInt64, autorepeat: Bool) -> Bool {
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
        case .keyDown where shortcut()?.matches(keyCode: keyCode, cgFlags: flags) == true:
            lock.withLock { swallowedShortcutKey = keyCode }
            if !autorepeat { onShortcut() }
            return false
        case .keyUp where lock.withLock({ swallowedShortcutKey == keyCode }):
            lock.withLock { swallowedShortcutKey = nil }
            return false
        case .keyDown, .keyUp:
            let key = KeyID(keyCode: keyCode)
            if watched().contains(key), !ModifierKeys.isModifier(key) {
                onEvent(type == .keyDown ? .down(key) : .up(key))
                return false
            }
            if type == .keyDown { onEvent(.otherKeyDown) }
            return true
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            // そのまま通す。録音キーとの同時押しとしてだけ扱う。
            onEvent(.otherKeyDown)
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
    // 文字を入れるために自分で送った Cmd+V。録音キーとの同時押しや、録音を捨てる操作と見なさない。
    if event.getIntegerValueField(.eventSourceUserData) == PasteboardInserter.syntheticEventTag {
        return Unmanaged.passUnretained(event)
    }
    // 指を離した後の慣性スクロールは操作ではない。押し続けの録音を捨てないよう無視する。
    if type == .scrollWheel, event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 {
        return Unmanaged.passUnretained(event)
    }
    let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
    let autorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
    let pass = monitor.handle(type: type, keyCode: keyCode, flags: event.flags.rawValue, autorepeat: autorepeat)
    return pass ? Unmanaged.passUnretained(event) : nil
}
