import AppKit
import Carbon.HIToolbox

/// Full copy of a pasteboard: every item, every type's raw data.
public struct PasteboardSnapshot {
    private let items: [[(type: NSPasteboard.PasteboardType, data: Data)]]

    public static func capture(_ pb: NSPasteboard) -> PasteboardSnapshot {
        let items = (pb.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in
                item.data(forType: type).map { (type: type, data: $0) }
            }
        }
        return PasteboardSnapshot(items: items)
    }

    public func restore(to pb: NSPasteboard) {
        pb.clearContents()
        let restored = items.map { entries -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for entry in entries { item.setData(entry.data, forType: entry.type) }
            return item
        }
        if !restored.isEmpty { pb.writeObjects(restored) }
    }
}

/// Inserts text by pasting: snapshot clipboard, write text, post Cmd+V, restore.
///
/// Restore timing: with `restoreDelay <= 0` the clipboard is restored synchronously
/// (deterministic for tests); otherwise it is scheduled with `DispatchQueue.main.asyncAfter`
/// so `insert` returns right after posting Cmd+V. The restore is skipped when
/// `changeCount` shows something else wrote to the pasteboard after our write.
public final class PasteboardInserter: TextInserter, @unchecked Sendable {
    private let pasteboard: NSPasteboard
    private let isSecureInput: () -> Bool
    private let postPaste: () -> Void
    private let restoreDelay: TimeInterval

    public init(
        pasteboard: NSPasteboard = .general,
        isSecureInput: @escaping () -> Bool = { IsSecureEventInputEnabled() },
        postPaste: @escaping () -> Void = PasteboardInserter.sendCommandV,
        restoreDelay: TimeInterval = 0.25
    ) {
        self.pasteboard = pasteboard
        self.isSecureInput = isSecureInput
        self.postPaste = postPaste
        self.restoreDelay = restoreDelay
    }

    public func insert(_ text: String) throws {
        if isSecureInput() { throw InsertionError.secureInput }
        let snapshot = PasteboardSnapshot.capture(pasteboard)
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            snapshot.restore(to: pasteboard)
            throw InsertionError.failed
        }
        let ourChangeCount = pasteboard.changeCount
        postPaste()

        let pb = pasteboard
        let restore = {
            guard pb.changeCount == ourChangeCount else { return }
            snapshot.restore(to: pb)
        }
        if restoreDelay <= 0 {
            restore()
        } else {
            nonisolated(unsafe) let restoreBlock = restore
            DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) { restoreBlock() }
        }
    }

    /// Posts Cmd+V (virtual key 0x09) to the HID event tap. Not exercised in tests.
    public static func sendCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        for keyDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: keyDown) else { continue }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }
}
