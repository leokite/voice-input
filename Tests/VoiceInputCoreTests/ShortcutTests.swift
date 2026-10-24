import Foundation
import Testing
@testable import VoiceInputCore

@Suite struct ShortcutTests {
    @Test func defaultIsControlOptionD() {
        #expect(Shortcut.glossaryDefault.displayName == "⌃⌥D")
        #expect(Shortcut.glossaryDefault.keyCode == 2)
    }

    @Test func matchesExactModifiersOnly() {
        let s = Shortcut.glossaryDefault
        #expect(s.matches(keyCode: 2, cgFlags: 0x40000 | 0x80000))
        #expect(!s.matches(keyCode: 2, cgFlags: 0x40000))
        #expect(!s.matches(keyCode: 2, cgFlags: 0x40000 | 0x80000 | 0x100000))
        #expect(!s.matches(keyCode: 3, cgFlags: 0x40000 | 0x80000))
    }

    @Test func modifierFlagsIgnoreDeviceBits() {
        #expect(ShortcutModifiers(cgFlags: 0x80000 | 0x40) == [.option])
    }

    @Test func disallowsNoModifierModifierKeyAndRecordKeyCollision() {
        let record = [KeyID.rightOption, KeyID(keyCode: 105)]
        #expect(!Shortcut.isAllowed(Shortcut(modifiers: [], keyCode: 2, keyLabel: "D"), recordKeys: record))
        #expect(!Shortcut.isAllowed(Shortcut(modifiers: [.control], keyCode: 61, keyLabel: "⌥"), recordKeys: record))
        #expect(!Shortcut.isAllowed(Shortcut(modifiers: [.control], keyCode: 105, keyLabel: "F13"), recordKeys: record))
        #expect(Shortcut.isAllowed(.glossaryDefault, recordKeys: record))
    }

    @Test func settingsWithoutShortcutDecodeToDefault() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"insertionMode":"batch"}"#.utf8))
        #expect(s.glossaryShortcut == .glossaryDefault)
    }
}
