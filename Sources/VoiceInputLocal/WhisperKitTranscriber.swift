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
    /// 前に読み込んだモデルを捨て、新しいファイルから読み込んで短い無音を認識する（Core ML のコンパイルを済ませる）。
    func prepareAfterDownload() async throws {
        do {
            await engine.unload()
            try await engine.load(allowTokenizerFetch: true)
            _ = try await engine.transcribe(samples: [Float](repeating: 0, count: 16000), languageHints: ["ja"], terms: [])
        } catch is CancellationError {
            // 取り消しは呼び出し側（ダウンロード）の言葉で伝える
            throw CancellationError()
        } catch {
            throw Self.wrap(error)
        }
    }

    /// 読み込みの途中なら終わるのを待ち、モデルを手放してからファイルを消す
    func removeModels(at folder: URL) async throws {
        try await engine.unloadAndRemove(folder)
    }

    /// 16kHz、モノラル、s16le を -1...1 の Float に直す
    static func samples(from pcm: Data) -> [Float] {
        stride(from: 0, to: pcm.count - 1, by: 2).map { i in
            Float(Int16(bitPattern: UInt16(pcm[pcm.startIndex + i]) | UInt16(pcm[pcm.startIndex + i + 1]) << 8)) / 32768
        }
    }

    /// 言語が決まっていなければ Whisper に判定させる（prefill の既定は英語なので、明示しないと英語になる）
    static func decodingOptions(language: String?, promptTokens: [Int]) -> DecodingOptions {
        var options = DecodingOptions(
            task: .transcribe, language: language, temperature: 0, usePrefillPrompt: true,
            detectLanguage: language == nil, skipSpecialTokens: true)
        if !promptTokens.isEmpty {
            options.promptTokens = promptTokens
        }
        return options
    }

    static func wrap(_ error: Error) -> LocalTranscriptionError {
        if let error = error as? LocalTranscriptionError { return error }
        if error is CancellationError { return LocalTranscriptionError(message: "認識を取り消しました") }
        return LocalTranscriptionError(message: "ローカルの認識に失敗しました: \(error)")
    }
}

/// WhisperKit 本体を持つ。読み込みは同時に 1 つだけ走らせ、重なった呼び出しはその結果を待つ。
actor WhisperKitEngine {
    private let base: URL
    private var kit: WhisperKit?
    private var loading: Task<Void, Error>?

    init(base: URL) {
        self.base = base
    }

    func load(allowTokenizerFetch: Bool) async throws {
        if kit != nil { return }
        if let loading {
            try await loading.value
            return
        }
        // 通常の利用では、ファイルがそろって読めるときだけ読み込む（WhisperKit はトークナイザーを読めないと取得しに行くため）
        guard allowTokenizerFetch
            || (LocalModelLayout.isInstalled(base: base) && LocalModelLayout.tokenizerFilesAreValid(base: base))
        else {
            throw LocalTranscriptionError(message: "ローカルのモデルが導入されていないか、壊れています")
        }
        let config = WhisperKitConfig(
            modelFolder: LocalModelLayout.modelFolder(base: base).path,
            tokenizerFolder: base,
            verbose: false,
            download: false
        )
        // 呼び出し側が取り消されても読み込みは最後まで続け、次の呼び出しで使う。
        // 終わりの印は読み込み自身が消す（待つ側がいなくても、削除がその終わりを見られるように）
        let task = Task {
            defer { self.loading = nil }
            self.kit = try await WhisperKit(config)
        }
        loading = task
        try await task.value
    }

    func unload() async {
        while let loading { _ = try? await loading.value }
        if let kit {
            self.kit = nil
            await kit.unloadModels()
        }
    }

    /// 読み込みも、読み込んだモデルもない状態にしてから、await をはさまずにファイルを消す（読み込みが割り込まない）
    func unloadAndRemove(_ folder: URL) async throws {
        while loading != nil || kit != nil {
            await unload()
        }
        if FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.removeItem(at: folder)
        }
    }

    func transcribe(samples: [Float], languageHints: [String], terms: [String]) async throws -> String {
        try Task.checkCancellation()
        try await load(allowTokenizerFetch: false)
        guard let kit else { throw LocalTranscriptionError(message: "ローカルのモデルを読み込めませんでした") }
        try Task.checkCancellation()

        // "ja-JP" のようなヒントは、Whisper の言語コード（"ja"）にそろえてから使う
        let hints = LanguageChoice.normalized(languageHints)
        let language: String?
        if hints.count > 1 {
            let detected = try await kit.detectLangauge(audioArray: samples)
            language = LanguageChoice.pick(hints: hints, probabilities: detected.langProbs)
            try Task.checkCancellation()
        } else {
            language = hints.first
        }

        var promptTokens: [Int] = []
        let prompt = PromptTerms.build(from: terms)
        if !prompt.isEmpty, let tokenizer = kit.tokenizer {
            promptTokens = tokenizer.encode(text: " " + prompt)
                .filter { $0 < tokenizer.specialTokens.specialTokenBegin }
        }
        let options = WhisperKitTranscriber.decodingOptions(language: language, promptTokens: promptTokens)

        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        try Task.checkCancellation()
        return results.flatMap(\.segments).map(\.text).joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
