import Foundation
import Testing
@testable import VoiceInputCore

@Suite struct SonioxMessagesTests {
    @Test func configEncodesExpectedJSON() throws {
        let config = SonioxConfig(languageHints: ["ja", "en"], terms: ["GitHub"])
        let data = try JSONEncoder().encode(config)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["model"] as? String == "stt-rt-v5")
        #expect(obj["audio_format"] as? String == "pcm_s16le")
        #expect(obj["sample_rate"] as? Int == 16000)
        #expect(obj["num_channels"] as? Int == 1)
        #expect(obj["language_hints"] as? [String] == ["ja", "en"])
        #expect(obj["enable_endpoint_detection"] as? Bool == false)
        let context = try #require(obj["context"] as? [String: Any])
        let general = try #require(context["general"] as? [[String: String]])
        #expect(general == [["key": "domain", "value": "ソフトウェア開発"]])
        #expect(context["terms"] as? [String] == ["GitHub"])
    }

    @Test func configEncodesEmptyTermsArray() throws {
        let data = try JSONEncoder().encode(SonioxConfig(languageHints: ["ja"], terms: []))
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let context = try #require(obj["context"] as? [String: Any])
        #expect(context["terms"] as? [String] == [])
    }

    @Test func decodesTokensAndFinished() throws {
        let json = #"{"tokens":[{"text":"こん","is_final":true,"language":"ja","start_ms":0},{"text":"にちは","is_final":false}],"final_audio_proc_ms":100,"total_audio_proc_ms":200}"#
        let r = try JSONDecoder().decode(SonioxResponse.self, from: Data(json.utf8))
        #expect(r.tokens == [SonioxToken(text: "こん", isFinal: true), SonioxToken(text: "にちは", isFinal: false)])
        #expect(r.finished == false)
        #expect(r.errorCode == nil)
    }

    @Test func decodesMissingTokensAsEmptyAndFinished() throws {
        let r = try JSONDecoder().decode(SonioxResponse.self, from: Data(#"{"finished":true}"#.utf8))
        #expect(r.tokens.isEmpty)
        #expect(r.finished == true)
    }

    @Test func decodesNumericErrorCode() throws {
        let r = try JSONDecoder().decode(SonioxResponse.self, from: Data(#"{"error_code":401,"error_message":"bad key"}"#.utf8))
        #expect(r.errorCode == "401")
        #expect(r.errorMessage == "bad key")
    }

    @Test func decodesStringErrorCode() throws {
        let r = try JSONDecoder().decode(SonioxResponse.self, from: Data(#"{"error_code":"rate_limit"}"#.utf8))
        #expect(r.errorCode == "rate_limit")
    }
}
