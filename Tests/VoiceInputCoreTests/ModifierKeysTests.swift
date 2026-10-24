import Testing
@testable import VoiceInputCore

@Suite struct ModifierKeysTests {
    @Test func rightOptionDownAndUp() {
        #expect(ModifierKeys.event(keyCode: 61, flags: 0x80040) == .down(.rightOption))
        #expect(ModifierKeys.event(keyCode: 61, flags: 0x100) == .up(.rightOption))
    }

    @Test func rightOptionReleasedWhileLeftOptionHeld() {
        // Left Option (0x20) still held keeps maskAlternate set; only the device bit decides.
        #expect(ModifierKeys.event(keyCode: 61, flags: 0x80120) == .up(.rightOption))
    }

    @Test func deviceDependentBits() {
        #expect(ModifierKeys.event(keyCode: 54, flags: 0x10) == .down(.rightCommand))
        #expect(ModifierKeys.event(keyCode: 62, flags: 0x2000) == .down(.rightControl))
        #expect(ModifierKeys.event(keyCode: 60, flags: 0x04) == .down(.rightShift))
        #expect(ModifierKeys.event(keyCode: 63, flags: 0x800000) == .down(.function))
        #expect(ModifierKeys.event(keyCode: 63, flags: 0) == .up(.function))
    }

    @Test func nonModifierKeyCodeIsNil() {
        #expect(ModifierKeys.event(keyCode: 0, flags: 0x40) == nil)
        #expect(ModifierKeys.isModifier(KeyID(keyCode: 123)) == false)
        #expect(ModifierKeys.isModifier(.rightOption))
    }
}
