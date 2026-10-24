import Testing
@testable import VoiceInputCore

@Suite struct SettingsLogicTests {
    @Test func knownKeyNames() {
        #expect(KeyNames.displayName(for: KeyID(keyCode: 61)) == "右 Option")
        #expect(KeyNames.displayName(for: KeyID(keyCode: 58)) == "左 Option")
        #expect(KeyNames.displayName(for: KeyID(keyCode: 54)) == "右 Command")
        #expect(KeyNames.displayName(for: KeyID(keyCode: 55)) == "左 Command")
        #expect(KeyNames.displayName(for: KeyID(keyCode: 62)) == "右 Control")
        #expect(KeyNames.displayName(for: KeyID(keyCode: 59)) == "左 Control")
        #expect(KeyNames.displayName(for: KeyID(keyCode: 60)) == "右 Shift")
        #expect(KeyNames.displayName(for: KeyID(keyCode: 56)) == "左 Shift")
        #expect(KeyNames.displayName(for: KeyID(keyCode: 63)) == "Fn")
    }

    @Test func onlyModifiersAndF13ToF19CanBeRecordKeys() {
        let modifiers: [UInt16] = [61, 58, 54, 55, 62, 59, 60, 56, 63]
        let f13ToF19: [UInt16] = [105, 107, 113, 106, 64, 79, 80]
        for code in modifiers + f13ToF19 {
            #expect(RecordKeys.isAllowed(KeyID(keyCode: code)), "keyCode \(code)")
        }
        // a、Space、Return、Esc、F1、F12、矢印、Caps Lock は使えない。
        for code: UInt16 in [0, 49, 36, 53, 122, 111, 123, 57] {
            #expect(!RecordKeys.isAllowed(KeyID(keyCode: code)), "keyCode \(code)")
        }
    }

    @Test func functionKeyNames() {
        #expect(KeyNames.displayName(for: KeyID(keyCode: 105)) == "F13")
        #expect(KeyNames.displayName(for: KeyID(keyCode: 80)) == "F19")
    }

    @Test func unknownKeyName() {
        #expect(KeyNames.displayName(for: KeyID(keyCode: 96)) == "キー 96")
    }

    @Test func languageHintsParsing() {
        #expect(LanguageHints.parse("ja, en") == ["ja", "en"])
        #expect(LanguageHints.parse(" ja ,, en , ") == ["ja", "en"])
        #expect(LanguageHints.parse("") == [])
        #expect(LanguageHints.parse("  ") == [])
    }

    @Test func languageHintsFormatting() {
        #expect(LanguageHints.format(["ja", "en"]) == "ja, en")
        #expect(LanguageHints.format([]) == "")
    }

    @Test func leftModifiersAreRecognized() {
        #expect(ModifierKeys.event(keyCode: 58, flags: 0x20) == .down(KeyID(keyCode: 58)))
        #expect(ModifierKeys.event(keyCode: 55, flags: 0x08) == .down(KeyID(keyCode: 55)))
        #expect(ModifierKeys.event(keyCode: 59, flags: 0x01) == .down(KeyID(keyCode: 59)))
        #expect(ModifierKeys.event(keyCode: 56, flags: 0x02) == .down(KeyID(keyCode: 56)))
        #expect(ModifierKeys.event(keyCode: 58, flags: 0x40) == .up(KeyID(keyCode: 58)))
    }
}
