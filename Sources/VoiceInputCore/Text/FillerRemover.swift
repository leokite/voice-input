import Foundation

public struct FillerRemover: Sendable {
    public static let defaultFillers: [String] = [
        "えー", "えーと", "えっと", "あー", "あのー", "うーん", "んー",
        "um", "uh", "uhm", "er", "erm", "hmm",
    ]

    private let patterns: [String]

    public init(fillers: [String]) {
        let sorted = fillers
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }
        self.patterns = sorted.map { filler in
            let escaped = NSRegularExpression.escapedPattern(for: filler)
            if filler.allSatisfy(\.isASCII) {
                return "(?i)\\b\(escaped)\\b[,.]?\\s*"
            }
            let elongated = escaped.replacingOccurrences(of: "ー", with: "ー+")
            return "\(elongated)[、,。]?\\s*"
        }
    }

    public func clean(_ text: String) -> String {
        var result = text
        for pattern in patterns {
            result = Self.replace(pattern, in: result, with: "")
        }
        result = Self.replace("\\s+", in: result, with: " ")
        result = Self.replace("^[、,。]+\\s*", in: result, with: "")
        result = Self.replace("\\s+(?=[、。,.])", in: result, with: "")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ pattern: String, in text: String, with template: String) -> String {
        text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }
}
