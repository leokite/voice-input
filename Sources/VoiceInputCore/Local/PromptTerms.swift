public enum PromptTerms {
    /// 渡された順（最近使った順）に連結し、上限を超える手前で止める
    public static func build(from terms: [String], maxChars: Int = 120) -> String {
        var result = ""
        for term in terms {
            let next = result.isEmpty ? term : result + ", " + term
            if next.count > maxChars { break }
            result = next
        }
        return result
    }
}
