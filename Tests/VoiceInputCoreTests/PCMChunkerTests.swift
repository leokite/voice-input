import Foundation
import Testing
@testable import VoiceInputCore

@Suite struct PCMChunkerTests {
    @Test func emitsFixedSizeChunksAndKeepsRemainder() {
        var c = PCMChunker(samplesPerChunk: 4)
        #expect(c.append([1, 2, 3]).isEmpty)
        let out = c.append([4, 5, 6, 7, 8, 9])
        #expect(out.count == 2)
        #expect(out[0].data == Data([1, 0, 2, 0, 3, 0, 4, 0]))
        #expect(out[1].data == Data([5, 0, 6, 0, 7, 0, 8, 0]))
        #expect(c.append([10, 11, 12]).first?.data == Data([9, 0, 10, 0, 11, 0, 12, 0]))
    }

    @Test func defaultChunkIs100msAt16kHz() {
        var c = PCMChunker()
        let out = c.append([Int16](repeating: 0, count: 1600))
        #expect(out.count == 1)
        #expect(out[0].data.count == 3200)
    }

    @Test func littleEndianNegative() {
        var c = PCMChunker(samplesPerChunk: 1)
        #expect(c.append([-2]).first?.data == Data([0xFE, 0xFF]))
    }

    @Test func rmsIsNormalized() {
        #expect(PCMChunker.rms([0, 0, 0]) == 0)
        #expect(abs(PCMChunker.rms([Int16.min, Int16.min]) - 1) < 0.0001)
        #expect(abs(PCMChunker.rms([16384, -16384]) - 0.5) < 0.0001)
        #expect(PCMChunker.rms([]) == 0)
    }

    @Test func chunkCarriesItsRMS() {
        var c = PCMChunker(samplesPerChunk: 2)
        #expect(abs((c.append([16384, -16384]).first?.rms ?? 0) - 0.5) < 0.0001)
    }
}
