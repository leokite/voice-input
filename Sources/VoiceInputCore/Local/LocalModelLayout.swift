import Foundation

public enum LocalModelStatus: Equatable, Sendable {
    case notInstalled
    case downloading(fraction: Double)
    case preparing
    case ready
    case failed(String)
}

/// ローカルモデルの保存場所。配置の知識はここだけに置く。
public enum LocalModelLayout {
    public static let variant = "large-v3-v20240930_turbo"

    public static func downloadBase(supportDirectory: URL) -> URL {
        supportDirectory.appendingPathComponent("Models", isDirectory: true)
    }

    public static func modelFolder(base: URL) -> URL {
        base.appendingPathComponent(
            "models/argmaxinc/whisperkit-coreml/openai_whisper-\(variant)", isDirectory: true)
    }

    // トークナイザーは別リポジトリから取得されるため、別フォルダになる
    public static func tokenizerFolder(base: URL) -> URL {
        base.appendingPathComponent("models/openai/whisper-large-v3", isDirectory: true)
    }

    private static let requiredModelItems = [
        "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc", "config.json",
    ]
    private static let requiredTokenizerItems = ["tokenizer.json"]

    /// モデルとトークナイザーの両方がそろっているときだけ true（途中までの取得は未導入扱い）
    public static func isInstalled(base: URL) -> Bool {
        let fm = FileManager.default
        let model = modelFolder(base: base)
        let tokenizer = tokenizerFolder(base: base)
        return requiredModelItems.allSatisfy { fm.fileExists(atPath: model.appendingPathComponent($0).path) }
            && requiredTokenizerItems.allSatisfy { fm.fileExists(atPath: tokenizer.appendingPathComponent($0).path) }
    }
}
