import Foundation

public enum InsertionMode: String, Codable, Sendable {
    case batch, realtime
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
        glossaryShortcut: .glossaryDefault
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
        glossaryShortcut: Shortcut = .glossaryDefault
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
    }
}
