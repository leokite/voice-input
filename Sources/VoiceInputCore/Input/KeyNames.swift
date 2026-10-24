import Foundation

/// 設定画面に出すキーの名前。
public enum KeyNames {
    private static let names: [UInt16: String] = [
        61: "右 Option", 58: "左 Option",
        54: "右 Command", 55: "左 Command",
        62: "右 Control", 59: "左 Control",
        60: "右 Shift", 56: "左 Shift",
        63: "Fn",
        105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19",
    ]

    public static func displayName(for key: KeyID) -> String {
        names[key.keyCode] ?? "キー \(key.keyCode)"
    }
}
