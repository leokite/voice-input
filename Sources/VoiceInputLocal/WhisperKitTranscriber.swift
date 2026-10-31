import Foundation
import VoiceInputCore
import WhisperKit

/// WhisperKit による端末内の文字起こし。モデルは保存場所のファイルだけから読み込む。
public final class WhisperKitTranscriber: LocalTranscriber, Sendable {
    private let engine: WhisperKitEngine

    public init(base: URL) {
        engine = WhisperKitEngine(base: base)
    }

    public func transcribe(pcm: Data, languageHints: [String], terms: [String]) async throws -> String {
        do {
            return try await engine.transcribe(samples: Self.samples(from: pcm), languageHints: languageHints, terms: terms)
        } catch {
            throw Self.wrap(error)
        }
    }

    /// 導入の仕上げ。トークナイザーが無ければ WhisperKit が取得するので、ダウンロードの操作からだけ呼ぶ。
    /// 短い無音を一度認識して、Core ML のコンパイルを済ませる。
    func prepareAfterDownload() async throws {
        do {
            try await engine.load(allowTokenizerFetch: true)
            _ = try await engine.transcribe(samples: [Float](repeating: 0, count: 16000), languageHints: ["ja"], terms: [])
        } catch {
            throw Self.wrap(error)
        }
    }

    /// 読み込んだモデルを手放す（削除の前に呼ぶ）
    func unload() async {
        await engine.unload()
    }

    /// 16kHz、モノラル、s16le を -1...1 の Float に直す
    static func samples(from pcm: Data) -> [Float] {
        stride(from: 0, to: pcm.count - 1, by: 2).map { i in
            Float(Int16(bitPattern: UInt16(pcm[pcm.startIndex + i]) | UInt16(pcm[pcm.startIndex + i + 1]) << 8)) / 32768
        }
    }

    static func wrap(_ error: Error) -> LocalTranscriptionError {
        if let error = error as? LocalTranscriptionError { return error }
        if error is CancellationError { return LocalTranscriptionError(message: "認識を取り消しました") }
        return LocalTranscriptionError(message: "ローカルの認識に失敗しました: \(error)")
    }
}

/// WhisperKit 本体を持ち、読み込みと認識を一か所で順に扱う
actor WhisperKitEngine {
    private let base: URL
    private var kit: WhisperKit?

    init(base: URL) {
        self.base = base
    }

    func load(allowTokenizerFetch: Bool) async throws {
        guard kit == nil else { return }
        // 通常の利用では、ファイルがそろっていないときに読み込まない（WhisperKit はトークナイザーが無いと取得しに行くため）
        guard allowTokenizerFetch || LocalModelLayout.isInstalled(base: base) else {
            throw LocalTranscriptionError(message: "ローカルのモデルが導入されていません")
        }
        let config = WhisperKitConfig(
            modelFolder: LocalModelLayout.modelFolder(base: base).path,
            tokenizerFolder: base,
            verbose: false,
            download: false
        )
        let loaded = try await WhisperKit(config)
        try Task.checkCancellation()
        // 読み込みの途中で別の呼び出しが先に終えていれば、そちらを使う
        if kit == nil { kit = loaded }
    }

    func unload() async {
        await kit?.unloadModels()
        kit = nil
    }

    func transcribe(samples: [Float], languageHints: [String], terms: [String]) async throws -> String {
        try Task.checkCancellation()
        try await load(allowTokenizerFetch: false)
        guard let kit else { throw LocalTranscriptionError(message: "ローカルのモデルを読み込めませんでした") }
        try Task.checkCancellation()

        let language: String?
        if languageHints.count > 1 {
            let detected = try await kit.detectLangauge(audioArray: samples)
            language = LanguageChoice.pick(hints: languageHints, probabilities: detected.langProbs)
            try Task.checkCancellation()
        } else {
            language = languageHints.first
        }

        var options = DecodingOptions(task: .transcribe, language: language, temperature: 0, skipSpecialTokens: true)
        let prompt = PromptTerms.build(from: terms)
        if !prompt.isEmpty, let tokenizer = kit.tokenizer {
            options.promptTokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
            options.usePrefillPrompt = true
        }

        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        try Task.checkCancellation()
        return results.flatMap(\.segments).map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
