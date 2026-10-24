import AppKit
import Testing
@testable import VoiceInputCore

/// 別スレッドから書き込むテスト用。
private struct UncheckedPasteboard: @unchecked Sendable { let pb: NSPasteboard }

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

    // 最終レビューの指摘（I4a）: 待ち時間を過ぎてからコピーが届いても、元の中身に戻す。
    @Test func lateCopyIsStillRestored() async throws {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("original", forType: .string)
        let box = UncheckedPasteboard(pb: pb)
        let copier = SelectionCopier(pasteboard: pb, postCopy: {
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                box.pb.clearContents()
                box.pb.setString("late", forType: .string)
            }
        }, wait: 0.05, lateWindow: 0.5)
        #expect(await copier.copySelection() == nil)
        try await Task.sleep(for: .milliseconds(450))
        #expect(pb.string(forType: .string) == "original")
    }

    // 最終レビューの指摘（I4b）: 文字を入れた直後で、元に戻す処理が残っているときは、その元の中身に戻す。
    @Test func usesPendingOriginalFromInserter() async {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("user clipboard", forType: .string)
        let inserter = PasteboardInserter(pasteboard: pb, isSecureInput: { false }, postPaste: {},
                                          restoreDelay: 10, schedule: { _, _ in })
        try? inserter.insert("dictated text")
        let copier = SelectionCopier(pasteboard: pb, postCopy: {
            pb.clearContents()
            pb.setString("Docker", forType: .string)
        }, pendingOriginal: { inserter.pendingOriginal() })
        #expect(await copier.copySelection() == "Docker")
        #expect(pb.string(forType: .string) == "user clipboard")
    }

    // 最終レビューの指摘（I4）: クリップボードが変わらなければ、書き直さない。
    @Test func unchangedClipboardIsNotRewritten() async {
        let pb = makePasteboard()
        defer { pb.releaseGlobally() }
        pb.clearContents()
        pb.setString("original", forType: .string)
        let count = pb.changeCount
        _ = await SelectionCopier(pasteboard: pb, postCopy: {}, wait: 0.05, lateWindow: 0).copySelection()
        #expect(pb.changeCount == count)
    }
}
