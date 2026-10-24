import Foundation

/// `flagsChanged` イベントの keyCode とフラグから、修飾キーの down と up を判断する。
public enum ModifierKeys {
    /// keyCode ごとの、そのキーだけを表すデバイス依存のフラグのビット。
    private static let masks: [UInt16: UInt64] = [
        KeyID.rightOption.keyCode: 0x40,      // NX_DEVICERALTKEYMASK
        KeyID.rightCommand.keyCode: 0x10,     // NX_DEVICERCMDKEYMASK
        KeyID.rightControl.keyCode: 0x2000,   // NX_DEVICERCTLKEYMASK
        KeyID.rightShift.keyCode: 0x04,       // NX_DEVICERSHIFTKEYMASK
        KeyID.function.keyCode: 0x800000,     // CGEventFlags.maskSecondaryFn
        58: 0x20,                             // NX_DEVICELALTKEYMASK
        55: 0x08,                             // NX_DEVICELCMDKEYMASK
        59: 0x01,                             // NX_DEVICELCTLKEYMASK
        56: 0x02,                             // NX_DEVICELSHIFTKEYMASK
    ]

    public static func isModifier(_ key: KeyID) -> Bool {
        masks[key.keyCode] != nil
    }

    /// 修飾キーでなければ nil。ビットが立っていれば down、消えていれば up。
    public static func event(keyCode: UInt16, flags: UInt64) -> KeyEvent? {
        guard let mask = masks[keyCode] else { return nil }
        let key = KeyID(keyCode: keyCode)
        return flags & mask != 0 ? .down(key) : .up(key)
    }
}
