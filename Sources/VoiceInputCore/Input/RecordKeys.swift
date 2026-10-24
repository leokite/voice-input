import Foundation

/// 録音キーに選べるキー。録音キーは tap が全体で握りつぶすので、普段の入力に使わないキーに限る。
public enum RecordKeys {
    /// F13 から F19 の keyCode。
    static let f13ToF19: Set<UInt16> = [105, 107, 113, 106, 64, 79, 80]

    /// 左右の Option、Command、Control、Shift、Fn と、F13 から F19。
    public static func isAllowed(_ key: KeyID) -> Bool {
        ModifierKeys.isModifier(key) || f13ToF19.contains(key.keyCode)
    }
}
