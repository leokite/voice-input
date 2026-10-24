import ApplicationServices
import VoiceInputCore

/// 手前のアプリで選ばれている文字を読む。
enum SelectedText {
    /// まずアクセシビリティで聞き、空なら ⌘C を送って読む。どちらでも読めなければ nil。
    @MainActor static func read(copier: SelectionCopier) async -> String? {
        if let text = accessibilitySelection(), !text.isEmpty { return text }
        return await copier.copySelection()
    }

    /// フォーカスされている要素の選択中の文字。VS Code やターミナルでは空になることが多い。
    private static func accessibilitySelection() -> String? {
        let system = AXUIElementCreateSystemWide()
        // 応答しないアプリで固まらないよう、待ち時間を短くする。
        AXUIElementSetMessagingTimeout(system, 0.3)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString,
                                            &selected) == .success else { return nil }
        return (selected as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
