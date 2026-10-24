import AppKit
import Testing
@testable import VoiceInputCore

@Suite struct PasteboardInserterTests {
    private func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("vi-test-\(UUID())"))
    }

    @Test func pastesTextAndRestoresString() throws {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("original", forType: .string)
        var seen: String?
        let inserter = PasteboardInserter(
            pasteboard: pb, isSecureInput: { false },
            postPaste: { seen = pb.string(forType: .string) }, restoreDelay: 0)
        try inserter.insert("hello")
        #expect(seen == "hello")
        #expect(pb.string(forType: .string) == "original")
    }

    @Test func restoresNonTextPasteboardItems() throws {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF, 0x10])
        let url = Data("file:///tmp/example.txt".utf8)
        pb.clearContents()
        let item = NSPasteboardItem()
        item.setData(png, forType: .png)
        item.setData(url, forType: .fileURL)
        #expect(pb.writeObjects([item]))
        let inserter = PasteboardInserter(
            pasteboard: pb, isSecureInput: { false }, postPaste: {}, restoreDelay: 0)
        try inserter.insert("hello")
        #expect(pb.data(forType: .png) == png)
        #expect(pb.data(forType: .fileURL) == url)
    }

    @Test func secureInputThrows() {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("original", forType: .string)
        var posted = false
        let inserter = PasteboardInserter(
            pasteboard: pb, isSecureInput: { true },
            postPaste: { posted = true }, restoreDelay: 0)
        #expect(throws: InsertionError.secureInput) { try inserter.insert("hello") }
        #expect(!posted)
        #expect(pb.string(forType: .string) == "original")
    }

    @Test func doesNotClobberNewerClipboard() throws {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("original", forType: .string)
        let inserter = PasteboardInserter(
            pasteboard: pb, isSecureInput: { false },
            postPaste: {
                pb.clearContents()
                pb.setString("new", forType: .string)
            }, restoreDelay: 0)
        try inserter.insert("hello")
        #expect(pb.string(forType: .string) == "new")
    }
}
