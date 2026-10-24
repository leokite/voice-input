import Foundation
import Testing
@testable import VoiceInputCore

@Suite struct StorageTests {
    @Test func defaultsMatchSpec() {
        let s = AppSettings.default
        #expect(s.toggleKey == .rightOption)
        #expect(s.holdKey == .rightOption)
        #expect(s.holdThreshold == 0.3)
        #expect(s.insertionMode == .batch)
        #expect(s.languageHints == ["ja", "en"])
        #expect(s.fillers == FillerRemover.defaultFillers)
        #expect(s.silenceTimeout == 60)
        #expect(s.historyLimit == 200)
        #expect(s.launchAtLogin == false)
    }

    @Test func settingsDecodeMissingKeysUsesDefaults() throws {
        let data = Data(#"{"insertionMode":"realtime"}"#.utf8)
        let s = try JSONDecoder().decode(AppSettings.self, from: data)
        var expected = AppSettings.default
        expected.insertionMode = .realtime
        #expect(s == expected)
    }

    @Test func historyCapsAtLimitNewestFirst() {
        var h = History(entries: [])
        for i in 0...200 {
            h.add(HistoryEntry(id: UUID(), date: Date(timeIntervalSince1970: Double(i)),
                               text: "t\(i)", rawText: "r\(i)", duration: 1, inserted: true), limit: 200)
        }
        #expect(h.entries.count == 200)
        #expect(h.entries.first?.text == "t200")
        #expect(h.entries.last?.text == "t1")
    }

    @Test func jsonStoreRoundTripAndCorruptFallback() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("nested/settings.json")
        let store = JSONStore<AppSettings>(url: url, defaultValue: .default, log: { _ in })
        #expect(store.load() == .default)
        var s = AppSettings.default
        s.insertionMode = .realtime
        s.historyLimit = 5
        try store.save(s)
        #expect(store.load() == s)
        try Data("garbage{".utf8).write(to: url)
        #expect(store.load() == .default)
    }

    @Test func corruptFileIsSetAsideBeforeDefaultIsReturned() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("settings.json")
        let garbage = Data("garbage{".utf8)
        try garbage.write(to: url)
        let store = JSONStore<AppSettings>(url: url, defaultValue: .default, log: { _ in })
        #expect(store.load() == .default)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(names.count == 1)
        let name = try #require(names.first)
        #expect(name.wholeMatch(of: /settings\.corrupt-\d{8}-\d{6}\.json/) != nil)
        #expect(try Data(contentsOf: dir.appendingPathComponent(name)) == garbage)
        // 次の保存で壊れたファイルが上書きされることはない。
        try store.save(.default)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).count == 2)
    }

    @Test func keychainRoundTrip() throws {
        let service = "dev.ykazama.VoiceInput.tests"
        KeychainStore.deleteAPIKey(service: service)
        defer { KeychainStore.deleteAPIKey(service: service) }
        try KeychainStore.saveAPIKey("secret-1", service: service)
        #expect(KeychainStore.loadAPIKey(service: service) == "secret-1")
        try KeychainStore.saveAPIKey("secret-2", service: service)
        #expect(KeychainStore.loadAPIKey(service: service) == "secret-2")
        KeychainStore.deleteAPIKey(service: service)
        #expect(KeychainStore.loadAPIKey(service: service) == nil)
    }

    @Test func keychainAccountsAreSeparate() throws {
        let service = "dev.ykazama.VoiceInput.tests.accounts"
        defer {
            KeychainStore.deleteAPIKey(service: service)
            KeychainStore.deleteAPIKey(service: service, account: KeychainStore.openAIAccount)
        }
        try KeychainStore.saveAPIKey("soniox", service: service)
        try KeychainStore.saveAPIKey("openai", service: service, account: KeychainStore.openAIAccount)
        #expect(KeychainStore.loadAPIKey(service: service) == "soniox")
        #expect(KeychainStore.loadAPIKey(service: service, account: KeychainStore.openAIAccount) == "openai")
    }

    @Test func cloudLocatorDefaultsOff() throws {
        let s = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"insertionMode":"batch"}"#.utf8))
        #expect(s.useCloudLocator == false)
        #expect(s.cloudModel == "gpt-6-luna")
    }
}
