import Testing
@testable import VoiceInputCore

@Suite struct KeyStateMachineTests {
    private func sameKey() -> KeyStateMachine {
        KeyStateMachine(toggleKey: .rightOption, holdKey: .rightOption)
    }

    @Test func tapStartsToggle() {
        var m = sameKey()
        #expect(m.handle(.down(.rightOption), at: 0.0) == [.beginBuffering])
        #expect(m.handle(.up(.rightOption), at: 0.1) == [.confirm(.toggle)])
    }

    @Test func secondTapStopsToggle() {
        var m = sameKey()
        _ = m.handle(.down(.rightOption), at: 0.0)
        _ = m.handle(.up(.rightOption), at: 0.1)
        #expect(m.handle(.down(.rightOption), at: 1.0) == [])
        #expect(m.handle(.up(.rightOption), at: 1.1) == [.stop])
    }

    @Test func holdConfirmsAtThresholdAndStopsOnRelease() {
        var m = sameKey()
        #expect(m.handle(.down(.rightOption), at: 0.0) == [.beginBuffering])
        #expect(m.tick(at: 0.3) == [.confirm(.hold)])
        #expect(m.handle(.up(.rightOption), at: 2.0) == [.stop])
    }

    @Test func tickBeforeThresholdDoesNothing() {
        var m = sameKey()
        _ = m.handle(.down(.rightOption), at: 0.0)
        #expect(m.tick(at: 0.2) == [])
    }

    @Test func chordCancelsBeforeConfirm() {
        var m = sameKey()
        _ = m.handle(.down(.rightOption), at: 0.0)
        #expect(m.handle(.otherKeyDown, at: 0.1) == [.cancel])
        #expect(m.handle(.up(.rightOption), at: 0.2) == [])
        #expect(m.tick(at: 0.3) == [])
        #expect(m.handle(.down(.rightOption), at: 1.0) == [.beginBuffering])
    }

    @Test func chordDuringToggleTapDoesNotStop() {
        var m = sameKey()
        _ = m.handle(.down(.rightOption), at: 0.0)
        _ = m.handle(.up(.rightOption), at: 0.1)
        #expect(m.handle(.down(.rightOption), at: 1.0) == [])
        #expect(m.handle(.otherKeyDown, at: 1.05) == [])
        #expect(m.handle(.up(.rightOption), at: 1.1) == [])
        // Still recording: a clean tap now stops.
        #expect(m.handle(.down(.rightOption), at: 2.0) == [])
        #expect(m.handle(.up(.rightOption), at: 2.1) == [.stop])
    }

    @Test func otherKeysIgnoredWhileToggleRecording() {
        var m = sameKey()
        _ = m.handle(.down(.rightOption), at: 0.0)
        _ = m.handle(.up(.rightOption), at: 0.1)
        #expect(m.handle(.otherKeyDown, at: 0.5) == [])
        #expect(m.tick(at: 5.0) == [])
        #expect(m.handle(.down(.rightOption), at: 6.0) == [])
        #expect(m.handle(.up(.rightOption), at: 6.1) == [.stop])
    }

    @Test func otherKeysIgnoredWhileHoldRecording() {
        var m = sameKey()
        _ = m.handle(.down(.rightOption), at: 0.0)
        _ = m.tick(at: 0.3)
        #expect(m.handle(.otherKeyDown, at: 0.5) == [])
        #expect(m.handle(.up(.rightOption), at: 1.0) == [.stop])
    }

    @Test func autorepeatDownIsIgnored() {
        var m = sameKey()
        _ = m.handle(.down(.rightOption), at: 0.0)
        #expect(m.handle(.down(.rightOption), at: 0.05) == [])
        #expect(m.handle(.up(.rightOption), at: 0.1) == [.confirm(.toggle)])
    }

    @Test func unknownKeyEventsBehaveLikeOtherKeys() {
        var m = sameKey()
        _ = m.handle(.down(.rightOption), at: 0.0)
        #expect(m.handle(.down(.rightShift), at: 0.1) == [.cancel])
        #expect(m.handle(.up(.rightShift), at: 0.2) == [])
        #expect(m.handle(.up(.rightOption), at: 0.3) == [])
    }

    @Test func separateKeys() {
        var m = KeyStateMachine(toggleKey: .rightOption, holdKey: .rightCommand)
        #expect(m.handle(.down(.rightCommand), at: 0.0) == [.beginBuffering])
        #expect(m.tick(at: 0.3) == [.confirm(.hold)])
        #expect(m.handle(.up(.rightCommand), at: 1.0) == [.stop])

        #expect(m.handle(.down(.rightCommand), at: 2.0) == [.beginBuffering])
        #expect(m.handle(.up(.rightCommand), at: 2.1) == [.cancel])

        #expect(m.handle(.down(.rightCommand), at: 3.0) == [.beginBuffering])
        #expect(m.handle(.otherKeyDown, at: 3.1) == [.cancel])
        #expect(m.handle(.up(.rightCommand), at: 3.2) == [])

        #expect(m.handle(.down(.rightOption), at: 4.0) == [.beginBuffering])
        #expect(m.handle(.up(.rightOption), at: 4.1) == [.confirm(.toggle)])
        #expect(m.handle(.down(.rightOption), at: 5.0) == [])
        #expect(m.handle(.up(.rightOption), at: 5.1) == [.stop])

        #expect(m.handle(.down(.rightOption), at: 6.0) == [.beginBuffering])
        #expect(m.tick(at: 6.3) == [])
        #expect(m.handle(.up(.rightOption), at: 8.0) == [.confirm(.toggle)])
    }

    @Test func resetReturnsToIdle() {
        var m = sameKey()
        _ = m.handle(.down(.rightOption), at: 0.0)
        _ = m.handle(.up(.rightOption), at: 0.1)
        m.reset()
        #expect(m.handle(.down(.rightOption), at: 1.0) == [.beginBuffering])
    }
}
