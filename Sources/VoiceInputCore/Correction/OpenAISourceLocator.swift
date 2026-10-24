import Foundation

/// OpenAI の Responses API で、誤認識された置き換え元を探す。
/// 送るのは、直前の音声入力の文と、直した語だけ。答えは JSON スキーマで受け取る。
public struct OpenAISourceLocator: SourceLocator {
    public enum Failure: Error, Equatable {
        case http(Int)
        case malformed
    }

    public typealias Send = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private let apiKey: String
    private let model: String
    private let send: Send

    public init(apiKey: String, model: String, send: @escaping Send = OpenAISourceLocator.urlSessionSend) {
        self.apiKey = apiKey
        self.model = model
        self.send = send
    }

    public static let endpoint = URL(string: "https://api.openai.com/v1/responses")!

    static let instructions = """
        音声認識の結果（sentence）の一部を、ユーザーが正しい語（word）に直した。\
        sentence の中で、word を聞き間違えて書き起こされた部分を、sentence からそのまま抜き出して source に入れる。\
        読み（発音）が word に近い部分を選ぶ。助詞などの前後の語は含めない。見つからなければ空文字にする。\
        例: sentence「どうかコンテナを再起動」、word「Docker」→ source「どうか」。
        """

    public func locate(word: String, in sentence: String) async throws -> String? {
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": model,
            "input": [
                ["role": "system", "content": Self.instructions],
                ["role": "user", "content": "sentence: \(sentence)\nword: \(word)"],
            ],
            "text": [
                "format": [
                    "type": "json_schema",
                    "name": "correction_source",
                    "strict": true,
                    "schema": [
                        "type": "object",
                        "properties": ["source": ["type": "string"]],
                        "required": ["source"],
                        "additionalProperties": false,
                    ],
                ],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await send(request)
        guard (200..<300).contains(response.statusCode) else { throw Failure.http(response.statusCode) }
        let source = try Self.source(from: data)
        return source.isEmpty ? nil : source
    }

    /// `output[].content[]` の `output_text` から、JSON の `source` を取り出す。
    static func source(from data: Data) throws -> String {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = root["output"] as? [[String: Any]] else { throw Failure.malformed }
        for item in output {
            for part in item["content"] as? [[String: Any]] ?? [] where part["type"] as? String == "output_text" {
                guard let text = part["text"] as? String,
                      let answer = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                      let source = answer["source"] as? String else { throw Failure.malformed }
                return source.trimmingCharacters(in: .whitespacesAndNewlines)
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
