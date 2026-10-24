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
