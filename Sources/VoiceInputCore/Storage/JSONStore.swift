import Foundation

public final class JSONStore<T: Codable & Sendable>: @unchecked Sendable {
    private let url: URL
    private let defaultValue: T

    public init(url: URL, defaultValue: T) {
        self.url = url
        self.defaultValue = defaultValue
    }

    /// Returns the stored value, or `defaultValue` if the file is missing or corrupt.
    public func load() -> T {
        guard let data = try? Data(contentsOf: url) else { return defaultValue }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(T.self, from: data)) ?? defaultValue
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
