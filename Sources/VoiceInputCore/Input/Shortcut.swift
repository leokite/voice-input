import Foundation

/// ショートカットの修飾キー。デバイスに依存しない CGEventFlags のビットから作る。
public struct ShortcutModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = ShortcutModifiers(rawValue: 1 << 0)
    public static let option = ShortcutModifiers(rawValue: 1 << 1)
    public static let shift = ShortcutModifiers(rawValue: 1 << 2)
    public static let command = ShortcutModifiers(rawValue: 1 << 3)

    /// 修飾キーと CGEventFlags のビット。並びは表示の順（⌃⌥⇧⌘）。
    private static let table: [(ShortcutModifiers, UInt64, String)] = [
        (.control, 0x40000, "⌃"),   // maskControl
        (.option, 0x80000, "⌥"),    // maskAlternate
        (.shift, 0x20000, "⇧"),     // maskShift
        (.command, 0x100000, "⌘"),  // maskCommand
    ]

    public init(cgFlags: UInt64) {
        self = []
        for (modifier, mask, _) in Self.table where cgFlags & mask != 0 {
            insert(modifier)
        }
    }

    public var symbols: String {
        Self.table.filter { contains($0.0) }.map(\.2).joined()
    }
}

/// 修飾キーと普通のキー 1 つの組み合わせ。
public struct Shortcut: Codable, Hashable, Sendable {
    public var modifiers: ShortcutModifiers
    public var keyCode: UInt16
    /// 表示に使うキーの名前（例 "D"）。
    public var keyLabel: String

    public init(modifiers: ShortcutModifiers, keyCode: UInt16, keyLabel: String) {
        self.modifiers = modifiers
        self.keyCode = keyCode
        self.keyLabel = keyLabel
    }

    /// 用語集に登録するキーの初期値（⌃⌥D）。
    public static let glossaryDefault = Shortcut(modifiers: [.control, .option], keyCode: 2, keyLabel: "D")

    public var displayName: String { modifiers.symbols + keyLabel }

    /// keyCode が同じで、修飾キーがちょうど一致すれば true。
    public func matches(keyCode: UInt16, cgFlags: UInt64) -> Bool {
        keyCode == self.keyCode && ShortcutModifiers(cgFlags: cgFlags) == modifiers
    }

    /// 修飾キーを 1 つ以上含み、普通のキーで、録音キーと keyCode が重ならないこと。
    public static func isAllowed(_ s: Shortcut, recordKeys: [KeyID]) -> Bool {
        !s.modifiers.isEmpty
            && !ModifierKeys.isModifier(KeyID(keyCode: s.keyCode))
            && !recordKeys.contains { $0.keyCode == s.keyCode }
    }
}
