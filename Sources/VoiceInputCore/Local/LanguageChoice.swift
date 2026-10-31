public enum LanguageChoice {
    /// hints は "ja" / "en" のような言語コードだけを渡すこと（完全一致で照合する）。
    /// ヒントの中から、検出確率が最も高い言語を選ぶ
    public static func pick(hints: [String], probabilities: [String: Float]) -> String? {
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
