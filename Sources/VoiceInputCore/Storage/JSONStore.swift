import Foundation

public final class JSONStore<T: Codable & Sendable>: @unchecked Sendable {
    private let url: URL
    private let defaultValue: T
    private let log: @Sendable (String) -> Void

    public init(url: URL, defaultValue: T, log: @escaping @Sendable (String) -> Void = { NSLog("%@", $0) }) {
        self.url = url
        self.defaultValue = defaultValue
        self.log = log
    }

    /// Returns the stored value, or `defaultValue` if the file is missing or corrupt.
    /// A file that cannot be decoded is renamed to `<name>.corrupt-<yyyyMMdd-HHmmss>.json` first,
    /// so the next `save` does not overwrite it.
    public func load() -> T {
        guard let data = try? Data(contentsOf: url) else { return defaultValue }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(T.self, from: data)
        } catch {
            setAsideCorruptFile(error)
            return defaultValue
        }
    }

    private func setAsideCorruptFile(_ error: Error) {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = url.deletingPathExtension().lastPathComponent
        let backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(name).corrupt-\(formatter.string(from: Date())).json")
        do {
            try FileManager.default.moveItem(at: url, to: backup)
            log("VoiceInput: \(url.lastPathComponent) を読めないため \(backup.lastPathComponent) に移し、初期値を使います: \(error)")
        } catch {
            log("VoiceInput: \(url.lastPathComponent) を読めず、退避もできません: \(error)")
        }
    }

    public func save(_ v: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(v)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

public enum AppPaths {
    /// `~/Library/Application Support/VoiceInput/`. Not created here; `JSONStore.save` creates parents.
    public static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VoiceInput", isDirectory: true)
    }
}
