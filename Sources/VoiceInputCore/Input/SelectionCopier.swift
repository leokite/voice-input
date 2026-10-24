import AppKit

/// 手前のアプリに ⌘C を送って選択中の文字を読み、クリップボードを元の中身に戻す。
public final class SelectionCopier: @unchecked Sendable {
    private let pasteboard: NSPasteboard
    private let postCopy: () -> Void
    private let wait: TimeInterval
    private let pollInterval: TimeInterval
    private let lateWindow: TimeInterval
    private let pendingOriginal: () -> PasteboardSnapshot?

    public init(pasteboard: NSPasteboard = .general,
                postCopy: @escaping () -> Void = SelectionCopier.sendCommandC,
                wait: TimeInterval = 0.3, pollInterval: TimeInterval = 0.02, lateWindow: TimeInterval = 1.0,
                pendingOriginal: @escaping () -> PasteboardSnapshot? = { nil }) {
        self.pasteboard = pasteboard
        self.postCopy = postCopy
        self.wait = wait
        self.pollInterval = pollInterval
        self.lateWindow = lateWindow
        self.pendingOriginal = pendingOriginal
    }

    /// ⌘C でクリップボードが変わらなければ（何も選ばれていなければ）nil。
    /// 変わった場合は読んでから元の中身に戻す。変わらなかった場合は書き直さない（遅れて届いたコピーだけは元に戻す）。
    /// 文字を入れた直後で元に戻す処理が残っていれば、その元の中身（ユーザーのクリップボード）に戻す。
    public func copySelection() async -> String? {
        let original = pendingOriginal() ?? PasteboardSnapshot.capture(pasteboard)
        let before = pasteboard.changeCount
        postCopy()
        let deadline = Date().addingTimeInterval(wait)
        while pasteboard.changeCount == before, Date() < deadline {
            try? await Task.sleep(for: .seconds(pollInterval))
        }
        guard pasteboard.changeCount != before else {
            watchForLateCopy(since: before, restoring: original)
            return nil
        }
        let copied = pasteboard.string(forType: .string)
        original.restore(to: pasteboard)
        return copied
    }

    /// 待ち時間を過ぎてからアプリがコピーを済ませると、ユーザーのクリップボードが上書きされたままになる。
    /// しばらく見張って、変わったら元に戻す。
    private func watchForLateCopy(since count: Int, restoring original: PasteboardSnapshot) {
        guard lateWindow > 0 else { return }
        let deadline = Date().addingTimeInterval(lateWindow)
        Task { [self] in
            while Date() < deadline {
                try? await Task.sleep(for: .seconds(pollInterval))
                if pasteboard.changeCount != count {
                    original.restore(to: pasteboard)
                    return
                }
            }
        }
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
