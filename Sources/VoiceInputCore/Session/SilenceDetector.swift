import Foundation

/// 無音（rms < threshold）が timeout 以上続いたかを判定する。
public struct SilenceDetector: Sendable {
    private let timeout: TimeInterval
    private let threshold: Float
    private var silenceStart: TimeInterval?

    public init(timeout: TimeInterval = 60, threshold: Float = 0.01) {
        self.timeout = timeout
        self.threshold = threshold
    }

    public mutating func feed(rms: Float, at t: TimeInterval) -> Bool {
        if rms >= threshold {
            silenceStart = t
            return false
        }
        let start = silenceStart ?? t
        silenceStart = start
        return t - start >= timeout
    }
}
