import Testing
@testable import VoiceInputCore

@Suite struct RecordingGateTests {
    typealias Decision = RecordingGate.Decision

    @Test func normalToggleRecordingIsForwarded() {
        var g = RecordingGate()
        #expect(g.isQuiet)
        #expect(g.decide(.beginBuffering, hasAPIKey: true, secureInput: false) == Decision(forward: .beginBuffering))
        #expect(!g.isQuiet)
        #expect(g.decide(.confirm(.toggle), hasAPIKey: true, secureInput: false) == Decision(forward: .confirm(.toggle)))
        #expect(g.activeMode == .toggle)
        #expect(g.decide(.stop, hasAPIKey: true, secureInput: false) == Decision(forward: .stop))
        #expect(g.isQuiet)
    }

    @Test func cancelEndsBuffering() {
        var g = RecordingGate()
        _ = g.decide(.beginBuffering, hasAPIKey: true, secureInput: false)
        #expect(g.decide(.cancel, hasAPIKey: true, secureInput: false) == Decision(forward: .cancel))
        #expect(g.isQuiet)
    }

    @Test func abortEndsHoldRecording() {
        var g = RecordingGate()
        _ = g.decide(.beginBuffering, hasAPIKey: true, secureInput: false)
        _ = g.decide(.confirm(.hold), hasAPIKey: true, secureInput: false)
        #expect(g.decide(.abort, hasAPIKey: true, secureInput: false) == Decision(forward: .abort))
        #expect(g.isQuiet)
    }

    @Test func missingKeyIsReportedOnlyAtConfirm() {
        var g = RecordingGate()
        #expect(g.decide(.beginBuffering, hasAPIKey: false, secureInput: false) == Decision())
        #expect(!g.isQuiet)
        #expect(g.decide(.confirm(.hold), hasAPIKey: false, secureInput: false)
                == Decision(rejection: .missingAPIKey))
        #expect(g.isQuiet)
        #expect(g.activeMode == nil)
    }

    @Test func missingKeyChordShowsNothing() {
        var g = RecordingGate()
        _ = g.decide(.beginBuffering, hasAPIKey: false, secureInput: false)
        #expect(g.decide(.cancel, hasAPIKey: false, secureInput: false) == Decision())
        #expect(g.isQuiet)
    }

    @Test func secureInputAtConfirmCancelsBuffering() {
        var g = RecordingGate()
        _ = g.decide(.beginBuffering, hasAPIKey: true, secureInput: false)
        #expect(g.decide(.confirm(.toggle), hasAPIKey: true, secureInput: true)
                == Decision(forward: .cancel, rejection: .secureInput))
        #expect(g.isQuiet)
        #expect(g.activeMode == nil)
    }

    @Test func busySessionRejectsNewPress() {
        var g = RecordingGate()
        _ = g.decide(.beginBuffering, hasAPIKey: true, secureInput: false)
        #expect(g.sessionRejected(.beginBuffering) == .busy)
        #expect(g.isQuiet)
    }

    @Test func sessionLeavingRecordingClearsMode() {
        var g = RecordingGate()
        _ = g.decide(.beginBuffering, hasAPIKey: true, secureInput: false)
        _ = g.decide(.confirm(.toggle), hasAPIKey: true, secureInput: false)
        g.sessionStateChanged(.recording(level: 0, preview: ""))
        #expect(g.activeMode == .toggle)
        g.sessionStateChanged(.error("ネットワークに接続できません"))
        #expect(g.isQuiet)
    }

    @Test func modelNotReadyRejectsOnConfirm() {
        var g = RecordingGate()
        let begin = g.decide(.beginBuffering, hasAPIKey: true, secureInput: false, localModelReady: false)
        #expect(begin.forward == nil)
        let confirm = g.decide(.confirm(.toggle), hasAPIKey: true, secureInput: false, localModelReady: false)
        #expect(confirm.rejection == .localModelNotReady)
        #expect(confirm.forward == nil)
        #expect(g.isQuiet)
    }

    @Test func modelNotReadyCancelIsQuiet() {
        var g = RecordingGate()
        _ = g.decide(.beginBuffering, hasAPIKey: true, secureInput: false, localModelReady: false)
        let cancel = g.decide(.cancel, hasAPIKey: true, secureInput: false, localModelReady: false)
        #expect(cancel.rejection == nil)
        #expect(g.isQuiet)
    }

    @Test func recordsWithoutAPIKeyWhenCallerPassesTrue() {
        var g = RecordingGate()
        let begin = g.decide(.beginBuffering, hasAPIKey: true, secureInput: false, localModelReady: true)
        #expect(begin.forward == .beginBuffering)
    }

    @Test func missingAPIKeyTakesPrecedenceOverModelNotReady() {
        var g = RecordingGate()
        _ = g.decide(.beginBuffering, hasAPIKey: false, secureInput: false, localModelReady: false)
        let confirm = g.decide(.confirm(.toggle), hasAPIKey: false, secureInput: false, localModelReady: false)
        #expect(confirm.rejection == .missingAPIKey)
    }
}
