import AppKit
import Testing
@testable import VoiceInputCore

@Suite struct SelectionCopierTests {
    func makePasteboard() -> NSPasteboard {
        NSPasteboard(name: .init("vi-copier-test-\(UUID().uuidString)"))
    }

    @Test func returnsCopiedTextAndRestoresOriginal() async {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("original", forType: .string)
        let copier = SelectionCopier(pasteboard: pb, postCopy: {
            pb.clearContents()
            pb.setString("Docker", forType: .string)
        })
        let text = await copier.copySelection()
        #expect(text == "Docker")
        #expect(pb.string(forType: .string) == "original")
    }

    @Test func unchangedClipboardReturnsNilAndRestores() async {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("original", forType: .string)
        let copier = SelectionCopier(pasteboard: pb, postCopy: {}, wait: 0.05)
        let text = await copier.copySelection()
        #expect(text == nil)
        #expect(pb.string(forType: .string) == "original")
    }

    @Test func restoresNonTextItems() async {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x01, 0x02, 0x03])
        pb.clearContents()
        pb.setData(png, forType: .png)
        let copier = SelectionCopier(pasteboard: pb, postCopy: {
            pb.clearContents()
            pb.setString("Docker", forType: .string)
        })
        _ = await copier.copySelection()
        #expect(pb.data(forType: .png) == png)
        #expect(pb.string(forType: .string) == nil)
    }
}
