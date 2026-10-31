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

    private static let requiredModels = [
        "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc", "MelSpectrogram.mlmodelc",
        "TextDecoderContextPrefill.mlmodelc",
    ]
    // 完成したコンパイル済みモデルが必ず持つファイル（実際のダウンロードで確認）
    private static let requiredModelContents = ["coremldata.bin", "weights/weight.bin"]
    private static let requiredModelFiles = ["config.json"]
    // tokenizer_config.json が無いと WhisperKit はトークナイザーを取得しに行くので、両方を必須にする
    private static let requiredTokenizerFiles = ["tokenizer.json", "tokenizer_config.json"]

    /// 保存場所に何か残っているか（途中までのダウンロードも含む）。削除はこの `models/` を消す。
    public static func hasFiles(base: URL) -> Bool {
        FileManager.default.fileExists(atPath: base.appendingPathComponent("models", isDirectory: true).path)
    }

    /// モデルとトークナイザーの両方が中身までそろっているときだけ true（途中までの取得は未導入扱い）
    public static func isInstalled(base: URL) -> Bool {
        let model = modelFolder(base: base)
        let tokenizer = tokenizerFolder(base: base)
        for name in requiredModels {
            let dir = model.appendingPathComponent(name, isDirectory: true)
            guard isDirectory(dir) else { return false }
            for item in requiredModelContents where !isNonEmptyFile(dir.appendingPathComponent(item)) {
                return false
            }
        }
        return requiredModelFiles.allSatisfy { isNonEmptyFile(model.appendingPathComponent($0)) }
            && requiredTokenizerFiles.allSatisfy { isNonEmptyFile(tokenizer.appendingPathComponent($0)) }
    }

    /// トークナイザーのファイルが JSON のオブジェクトとして読めるときだけ true。
    /// 読めないと WhisperKit は黙ってダウンロードに切り替えるため、通常の読み込みの前に確かめる。
    public static func tokenizerFilesAreValid(base: URL) -> Bool {
        requiredTokenizerFiles.allSatisfy { name in
            guard let data = try? Data(contentsOf: tokenizerFolder(base: base).appendingPathComponent(name)),
                  let object = try? JSONSerialization.jsonObject(with: data)
            else { return false }
            return object is [String: Any]
        }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func isNonEmptyFile(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue,
              let size = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber
        else { return false }
        return size.intValue > 0
    }
}
