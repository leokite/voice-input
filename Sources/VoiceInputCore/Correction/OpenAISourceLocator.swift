import Foundation

/// OpenAI の Responses API で、誤認識された置き換え元を探す。
/// 送るのは、直前の音声入力の文と、直した語だけ。答えは JSON スキーマで受け取る。
public struct OpenAISourceLocator: SourceLocator, CorrectionExtractor {
    public enum Failure: Error, Equatable {
        case http(Int)
        case malformed
    }

    public typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let apiKey: String
    public let model: String
    private let send: Send

    public init(apiKey: String, model: String, send: @escaping Send = OpenAISourceLocator.urlSessionSend) {
        self.apiKey = apiKey
        self.model = model
        self.send = send
    }

    /// キーとモデル名がそろっていれば作る。どちらかが空なら nil（OpenAI を使わない）。
    public static func make(apiKey: String, model: String) -> OpenAISourceLocator? {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !model.isEmpty else { return nil }
        return OpenAISourceLocator(apiKey: key, model: model)
    }

    public static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    static let instructions = """
        音声認識の結果（sentence）の一部を、ユーザーが正しい語（word）に直した。\
        sentence の中で、word を聞き間違えて書き起こされた部分を、sentence からそのまま抜き出して source に入れる。\
        読み（発音）が word に近い部分を選ぶ。助詞などの前後の語は含めない。見つからなければ空文字にする。\
        例: sentence「どうかコンテナを再起動」、word「Docker」→ source「どうか」。
        """

    static let extractInstructions = """
        音声認識の結果（sentence）を、ユーザーが手で直した。直した後の文字列の一部（selection）が与えられる。\
        sentence と selection を見比べ、誤認識された部分（from）と、ユーザーが直した正しい語（to）の組み合わせを、最大 3 つ答える。\
        from は sentence から、to は selection から、それぞれそのまま抜き出す。語は途中で切らず、1 つの語の直しは 1 つの組み合わせにする。\
        句読点や助詞だけの違いは含めない。直しがなければ空の配列にする。\
        例: sentence「モデルは、GPT-6、Lunaだと思います」、selection「モデルは、gpt-6-lunaだと思います」→ [{from「GPT-6、Luna」, to「gpt-6-luna」}]。
        """

    /// 履歴の文と選んだ文字列を丸ごと渡して、組み合わせを取り出してもらう。
    public func extract(sentence: String, selection: String) async throws -> [CorrectionPair] {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "pairs": [
                    "type": "array",
                    "items": [
                        "type": "object",
                        "properties": ["from": ["type": "string"], "to": ["type": "string"]],
                        "required": ["from", "to"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "required": ["pairs"],
            "additionalProperties": false,
        ]
        let data = try await respond(instructions: Self.extractInstructions,
                                     user: "sentence: \(sentence)\nselection: \(selection)",
                                     schemaName: "correction_pairs", schema: schema)
        let answer = try Self.answerJSON(from: data)
        guard let pairs = answer["pairs"] as? [[String: Any]] else { throw Failure.malformed }
        return pairs.compactMap { p in
            guard let from = p["from"] as? String, let to = p["to"] as? String else { return nil }
            return CorrectionPair(from: from.trimmingCharacters(in: .whitespacesAndNewlines),
                                  to: to.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public func locate(word: String, in sentence: String) async throws -> String? {
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["source": ["type": "string"]],
            "required": ["source"],
            "additionalProperties": false,
        ]
        let data = try await respond(instructions: Self.instructions, user: "sentence: \(sentence)\nword: \(word)",
                                     schemaName: "correction_source", schema: schema)
        guard let source = (try Self.answerJSON(from: data))["source"] as? String else { throw Failure.malformed }
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Responses API を呼んで、生の応答を返す。
    private func respond(instructions: String, user: String, schemaName: String,
                         schema: [String: Any]) async throws -> Data {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            // 推論を使わない。使うと 1 回 3 秒を超え、待ち時間に収まらない（2026-10-24 の実測）。
            "reasoning": ["effort": "none"],
            "input": [
                ["role": "system", "content": instructions],
                ["role": "user", "content": user],
            ],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": schemaName,
                    "strict": true,
                    "schema": schema,
                ],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else { throw Failure.http(response.statusCode) }
        return data
    }

    /// `output[].content[]` の `output_text` を JSON として読む。
    static func answerJSON(from data: Data) throws -> [String: Any] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = root["output"] as? [[String: Any]] else { throw Failure.malformed }
        for item in output {
            for part in item["content"] as? [[String: Any]] ?? [] where part["type"] as? String == "output_text" {
                guard let text = part["text"] as? String,
                      let answer = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                    throw Failure.malformed
                }
                return answer
            }
        }
        throw Failure.malformed
    }

    public static let urlSessionSend: Send = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.malformed }
        return (data, http)
    }
}
