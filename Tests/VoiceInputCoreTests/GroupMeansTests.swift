import Testing
@testable import VoiceInputCore

@Suite("GroupMeans")
struct GroupMeansTests {
    @Test func averagesPerGroupInFirstSeenOrder() {
        let means = GroupMeans.compute(scores: [1.0, 0.8, 0.5, 0.9], groups: ["ja", "en", "ja", "en"])
        #expect(means.map(\.group) == ["ja", "en"])
        #expect(abs(means[0].mean - 0.75) < 1e-9)
        #expect(abs(means[1].mean - 0.85) < 1e-9)
    }

    @Test func skipsCasesWithoutGroup() {
        let means = GroupMeans.compute(scores: [1.0, 0.0], groups: [nil, "ja"])
        #expect(means.count == 1)
        #expect(means[0].mean == 0.0)
    }

    @Test func emptyWhenNoGroups() {
        #expect(GroupMeans.compute(scores: [1.0], groups: [nil]).isEmpty)
    }
}
