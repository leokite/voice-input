import Foundation
import Testing
@testable import VoiceInputCore

/// 送ったリクエストを覚えておき、決めた応答を返す偽物の通信。
private final class FakeTransport: @unchecked Sendable {
    var request: URLRequest?
    let status: Int
    let body: String
    init(status: Int = 200, body: String) {
        self.status = status
        self.body = body
    }
    func send(_ r: URLRequest) async throws -> (Data, HTTPURLResponse) {
        request = r
        let response = HTTPURLResponse(url: r.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private let okBody = #"""
{"output":[{"type":"reasoning","summary":[]},{"type":"message","role":"assistant","content":[{"type":"output_text","text":"{\"source\":\"どうか\"}"}]}]}
"""#

@Suite struct OpenAISourceLocatorTests {
    @Test func buildsResponsesRequest() async throws {
        let transport = FakeTransport(body: okBody)
        let locator = OpenAISourceLocator(apiKey: "sk-test", model: "gpt-6-luna", send: transport.send)
        _ = try await locator.locate(word: "Docker", in: "どうかコンテナを再起動")
        let r = try #require(transport.request)
        #expect(r.url?.absoluteString == "https://api.openai.com/v1/responses")
        #expect(r.httpMethod == "POST")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let json = try #require(try JSONSerialization.jsonObject(with: r.httpBody ?? Data()) as? [String: Any])
        #expect(json["model"] as? String == "gpt-6-luna")
        let format = try #require((json["text"] as? [String: Any])?["format"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(format["strict"] as? Bool == true)
        let input = String(data: try JSONSerialization.data(withJSONObject: json["input"] ?? []), encoding: .utf8) ?? ""
        #expect(input.contains("どうかコンテナを再起動"))
        #expect(input.contains("Docker"))
    }

    @Test func parsesSourceFromOutputText() async throws {
        let locator = OpenAISourceLocator(apiKey: "k", model: "gpt-6-luna", send: FakeTransport(body: okBody).send)
        #expect(try await locator.locate(word: "Docker", in: "どうかコンテナを再起動") == "どうか")
    }

    @Test func emptySourceMeansNotFound() async throws {
        let body = #"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"source\":\"\"}"}]}]}"#
        let locator = OpenAISourceLocator(apiKey: "k", model: "gpt-6-luna", send: FakeTransport(body: body).send)
        #expect(try await locator.locate(word: "Docker", in: "コンテナを再起動") == nil)
    }

    @Test func httpErrorThrows() async {
        let locator = OpenAISourceLocator(apiKey: "bad", model: "gpt-6-luna",
                                          send: FakeTransport(status: 401, body: "{}").send)
        await #expect(throws: OpenAISourceLocator.Failure.http(401)) {
            try await locator.locate(word: "Docker", in: "どうか")
        }
    }
}

/// OpenAI を実際に呼ぶテスト。`OPENAI_API_KEY` があるときだけ動かす。
@Suite(.enabled(if: ProcessInfo.processInfo.environment["OPENAI_API_KEY"] != nil))
struct OpenAISourceLocatorLiveTests {
    @Test(arguments: [
        ("Docker", "どうかコンテナを再起動してからAPIを確認します。", "どうか"),
        ("Kubernetes", "キューバーニーツへのデプロイに失敗したのでログを調べます。", "キューバーニーツ"),
        ("GitHub", "新しい機能をぎっとはぶにプッシュしました。", "ぎっとはぶ"),
    ])
    func locatesRealSources(word: String, sentence: String, expected: String) async throws {
        let key = try #require(ProcessInfo.processInfo.environment["OPENAI_API_KEY"])
        let started = Date()
        let source = try await OpenAISourceLocator(apiKey: key, model: "gpt-6-luna").locate(word: word, in: sentence)
        print("LIVE", word, source ?? "nil", String(format: "%.2fs", Date().timeIntervalSince(started)))
        #expect(source == expected)
    }
}
