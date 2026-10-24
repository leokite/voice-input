import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// 端末内AIを使えるかどうか。使えないときは、設定画面に出す 1 行の文言を持つ。
public enum JudgeAvailability: Equatable, Sendable {
    case available
    case unavailable(String)
}

/// Apple の端末内AI（Foundation Models）で判断する `CorrectionJudge` を用意する。
public enum OnDeviceJudge {
    public static func make() -> (judge: CorrectionJudge?, availability: JudgeAvailability) {
        #if canImport(FoundationModels)
        if #available(macOS 26, *) {
            let model = SystemLanguageModel.default
            switch model.availability {
            case .available:
                guard model.supportedLanguages.contains(where: { $0.languageCode?.identifier == "ja" }) else {
                    return (nil, .unavailable("端末内AIが日本語に対応していないため、置き換えは登録されません"))
                }
                return (FoundationModelsJudge(), .available)
            case .unavailable(.deviceNotEligible):
                return (nil, .unavailable("この Mac では端末内AIを使えないため、置き換えは登録されません"))
            case .unavailable(.appleIntelligenceNotEnabled):
                return (nil, .unavailable("Apple Intelligence がオフのため、置き換えは登録されません"))
            case .unavailable(.modelNotReady):
                return (nil, .unavailable("端末内AIを準備中のため、置き換えは登録されません"))
            case .unavailable:
                return (nil, .unavailable("この Mac では端末内AIを使えないため、置き換えは登録されません"))
            }
        }
        #endif
        return (nil, .unavailable("macOS 26 以降でないため、置き換えは登録されません"))
    }
}

#if canImport(FoundationModels)
@available(macOS 26, *)
@Generable
struct WordKind {
    @Guide(description: "日常的に使われる普通の日本語・英語の言葉なら true。誤認識でしか出てこない言葉や、固有名詞・専門用語なら false")
    var isCommon: Bool
}

/// 置き換え元が普通の言葉かどうかを判断する。呼び出しごとに新しいセッションを作る（前の質問に引きずられないように）。
@available(macOS 26, *)
struct FoundationModelsJudge: CorrectionJudge {
    func isCommonWord(_ word: String) async throws -> Bool {
        let session = LanguageModelSession(instructions: """
            与えられた語が、日常的に使われる普通の言葉かどうかを判断する。\
            例1:「どうか」「メイン」「ログ」は普通の言葉。\
            例2:「キューバーニーツ」「ぎっとはぶ」は誤認識でしか出てこないので普通の言葉ではない。
            """)
        let response = try await session.respond(to: "語: \(word)", generating: WordKind.self)
        return response.content.isCommon
    }
}
#endif
