import Foundation

/// Int16 のサンプルをためて、決まった数ごとに s16le の Data と RMS（0…1）にして返す。
public struct PCMChunker: Sendable {
    private let samplesPerChunk: Int
    private var buffer: [Int16] = []

    /// 既定は 16kHz で 100ms 分（1600 サンプル = 3200 バイト）。
    public init(samplesPerChunk: Int = 1600) {
        self.samplesPerChunk = samplesPerChunk
        buffer.reserveCapacity(samplesPerChunk * 2)
    }

    public mutating func append(_ samples: [Int16]) -> [(data: Data, rms: Float)] {
        buffer.append(contentsOf: samples)
        var out: [(data: Data, rms: Float)] = []
        while buffer.count >= samplesPerChunk {
            let chunk = Array(buffer.prefix(samplesPerChunk))
            buffer.removeFirst(samplesPerChunk)
            // Apple Silicon はリトルエンディアンなので、メモリの並びがそのまま s16le になる。
            let data = chunk.withUnsafeBytes { Data($0) }
            out.append((data, Self.rms(chunk)))
        }
        return out
    }

    /// 決まった数に満たない残りを返して空にする。録音の終わりに呼ぶ。残りがなければ nil。
    public mutating func flush() -> (data: Data, rms: Float)? {
        guard !buffer.isEmpty else { return nil }
        let rest = buffer
        buffer.removeAll(keepingCapacity: true)
        return (rest.withUnsafeBytes { Data($0) }, Self.rms(rest))
    }

    /// Int16 の振幅を 32768 で割った値の二乗平均平方根。
    public static func rms(_ samples: [Int16]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum: Double = 0
        for s in samples {
            let v = Double(s) / 32768
            sum += v * v
        }
        return Float((sum / Double(samples.count)).squareRoot())
    }
}
