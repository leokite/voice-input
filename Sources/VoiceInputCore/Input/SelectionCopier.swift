import AppKit

/// 手前のアプリに ⌘C を送って選択中の文字を読み、クリップボードを元の中身に戻す。
public final class SelectionCopier: @unchecked Sendable {
    private let pasteboard: NSPasteboard
    private let postCopy: () -> Void
    private let wait: TimeInterval
    private let pollInterval: TimeInterval

    public init(pasteboard: NSPasteboard = .general,
                postCopy: @escaping () -> Void = SelectionCopier.sendCommandC,
                wait: TimeInterval = 0.3, pollInterval: TimeInterval = 0.02) {
        self.pasteboard = pasteboard
        self.postCopy = postCopy
        self.wait = wait
        self.pollInterval = pollInterval
    }

    /// ⌘C でクリップボードが変わらなければ（何も選ばれていなければ）nil。どちらの場合もクリップボードは元に戻す。
    public func copySelection() async -> String? {
        let original = PasteboardSnapshot.capture(pasteboard)
        let before = pasteboard.changeCount
        postCopy()
        let deadline = Date().addingTimeInterval(wait)
        while pasteboard.changeCount == before, Date() < deadline {
            try? await Task.sleep(for: .seconds(pollInterval))
        }
        let copied = pasteboard.changeCount == before ? nil : pasteboard.string(forType: .string)
        original.restore(to: pasteboard)
        return copied
    }

    /// ⌘C（keyCode 8）を送る。押されたままの ⌃⌥ が混ざらないよう、修飾キーは ⌘ だけを明示する。
    /// 自分のキー監視が反応しないよう、文字を入れるときと同じ印を付ける。テストでは呼ばない。
    public static func sendCommandC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: keyDown) else { continue }
            event.flags = .maskCommand
            event.setIntegerValueField(.eventSourceUserData, value: PasteboardInserter.syntheticEventTag)
            event.post(tap: .cghidEventTap)
        }
    }
}
