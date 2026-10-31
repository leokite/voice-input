import Foundation

public enum InsertionMode: String, Codable, Sendable {
    case batch, realtime
}

/// 文字起こしに使うエンジン。
public enum TranscriptionEngine: String, Codable, Sendable {
    case soniox, local
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var toggleKey: KeyID
    public var holdKey: KeyID
    public var holdThreshold: TimeInterval
    public var insertionMode: InsertionMode
    public var languageHints: [String]
    public var fillers: [String]
    public var silenceTimeout: TimeInterval
    public var historyLimit: Int
    public var launchAtLogin: Bool
    public var glossaryShortcut: Shortcut
    /// 単語だけを選んだときなどに、OpenAI で置き換え元を探すか。
    public var useCloudLocator: Bool
    /// OpenAI のモデル名（例 "gpt-6-luna"）。コードには持たず、設定ファイルに書かれた値だけを使う。空なら OpenAI を使わない。
    public var cloudModel: String
    /// 文字起こしエンジン。ローカルのときは音声もテキストも外へ送らない。
    public var engine: TranscriptionEngine

    /// クラウド（Soniox / OpenAI）へ送ってよいか。
    public var allowsCloud: Bool { engine == .soniox }

    public static let `default` = AppSettings(
        toggleKey: .rightOption,
        holdKey: .rightOption,
        holdThreshold: 0.3,
        insertionMode: .batch,
        languageHints: ["ja", "en"],
        fillers: FillerRemover.defaultFillers,
        silenceTimeout: 60,
        historyLimit: 200,
        launchAtLogin: false,
        glossaryShortcut: .glossaryDefault,
        useCloudLocator: false,
        cloudModel: "",
        engine: .soniox
    )

    public init(
        toggleKey: KeyID = .rightOption,
        holdKey: KeyID = .rightOption,
        holdThreshold: TimeInterval = 0.3,
        insertionMode: InsertionMode = .batch,
        languageHints: [String] = ["ja", "en"],
        fillers: [String] = FillerRemover.defaultFillers,
        silenceTimeout: TimeInterval = 60,
        historyLimit: Int = 200,
        launchAtLogin: Bool = false,
        glossaryShortcut: Shortcut = .glossaryDefault,
        useCloudLocator: Bool = false,
        cloudModel: String = "",
        engine: TranscriptionEngine = .soniox
    ) {
        self.toggleKey = toggleKey
        self.holdKey = holdKey
        self.holdThreshold = holdThreshold
        self.insertionMode = insertionMode
        self.languageHints = languageHints
        self.fillers = fillers
        self.silenceTimeout = silenceTimeout
        self.historyLimit = historyLimit
        self.launchAtLogin = launchAtLogin
        self.glossaryShortcut = glossaryShortcut
        self.useCloudLocator = useCloudLocator
        self.cloudModel = cloudModel
        self.engine = engine
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings.default
        toggleKey = try c.decodeIfPresent(KeyID.self, forKey: .toggleKey) ?? d.toggleKey
        holdKey = try c.decodeIfPresent(KeyID.self, forKey: .holdKey) ?? d.holdKey
        holdThreshold = try c.decodeIfPresent(TimeInterval.self, forKey: .holdThreshold) ?? d.holdThreshold
        insertionMode = try c.decodeIfPresent(InsertionMode.self, forKey: .insertionMode) ?? d.insertionMode
        languageHints = try c.decodeIfPresent([String].self, forKey: .languageHints) ?? d.languageHints
        fillers = try c.decodeIfPresent([String].self, forKey: .fillers) ?? d.fillers
        silenceTimeout = try c.decodeIfPresent(TimeInterval.self, forKey: .silenceTimeout) ?? d.silenceTimeout
        historyLimit = try c.decodeIfPresent(Int.self, forKey: .historyLimit) ?? d.historyLimit
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? d.launchAtLogin
        glossaryShortcut = try c.decodeIfPresent(Shortcut.self, forKey: .glossaryShortcut) ?? d.glossaryShortcut
        useCloudLocator = try c.decodeIfPresent(Bool.self, forKey: .useCloudLocator) ?? d.useCloudLocator
        cloudModel = try c.decodeIfPresent(String.self, forKey: .cloudModel) ?? d.cloudModel
        engine = try c.decodeIfPresent(TranscriptionEngine.self, forKey: .engine) ?? d.engine
    }
}
