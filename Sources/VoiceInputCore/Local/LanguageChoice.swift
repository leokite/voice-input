import Foundation

public enum LanguageChoice {
    /// "ja-JP" や "EN_us" を、Whisper の言語コード（"ja"、"en"）にそろえる。空は除き、重複は先のものを残す。
    public static func normalized(_ hints: [String]) -> [String] {
        var result: [String] = []
        for hint in hints {
            let code = hint.trimmingCharacters(in: .whitespaces).lowercased()
                .split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
            if !code.isEmpty, !result.contains(code) { result.append(code) }
        }
        return result
    }

    /// ヒントの中から、検出確率が最も高い言語を選ぶ（ヒントは言語コードにそろえてから照合する）
    public static func pick(hints: [String], probabilities: [String: Float]) -> String? {
        let hints = normalized(hints)
        guard let first = hints.first else { return nil }
        if hints.count == 1 { return first }
        var best: (hint: String, value: Float)?
        for hint in hints {
            guard let value = probabilities[hint], !value.isNaN else { continue }
            if best == nil || value > best!.value { best = (hint, value) }
        }
        return best?.hint ?? first
    }
}
