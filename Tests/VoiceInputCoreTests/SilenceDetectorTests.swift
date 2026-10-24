import Foundation
import Testing
@testable import VoiceInputCore

@Suite struct SilenceDetectorTests {
    @Test func silenceFiresAfterTimeout() {
        var d = SilenceDetector()
        for s in 0...59 {
            #expect(d.feed(rms: 0.001, at: TimeInterval(s)) == false)
        }
        #expect(d.feed(rms: 0.001, at: 60) == true)
        #expect(d.feed(rms: 0.001, at: 61) == true)
    }

    @Test func soundResetsSilence() {
        var d = SilenceDetector()
        for s in 0..<30 {
            #expect(d.feed(rms: 0.001, at: TimeInterval(s)) == false)
        }
        #expect(d.feed(rms: 0.2, at: 30) == false)
        for s in 31...89 {
            #expect(d.feed(rms: 0.001, at: TimeInterval(s)) == false)
        }
        #expect(d.feed(rms: 0.001, at: 90) == true)
    }
}
