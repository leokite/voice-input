import Foundation
import Testing
@testable import VoiceInputCore

/// 端末内AIを実際に呼ぶテスト。`VOICEINPUT_FM_TESTS=1` のときだけ動かす。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["VOICEINPUT_FM_TESTS"] == "1"))
struct FoundationModelsJudgeLiveTests {
    @Test func classifiesCommonWords() async throws {
        let judge = try #require(OnDeviceJudge.make().judge)
        #expect(try await judge.isCommonWord("どうか") == true)
        #expect(try await judge.isCommonWord("キューバーニーツ") == false)
    }
}
