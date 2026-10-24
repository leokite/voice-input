import Foundation

/// 「ja, en」のようなカンマ区切りの文字列と、言語のヒントの配列を行き来する。
public enum LanguageHints {
    public static func parse(_ text: String) -> [String] {
        text.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    public static func format(_ hints: [String]) -> String {
        hints.joined(separator: ", ")
    }
}
