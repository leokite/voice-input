import AppKit
import SwiftUI
import VoiceInputCore

/// フォーカスを奪わない録音中の表示。マウスがある画面の下部中央に出す。
final class OverlayPanel: NSPanel {
    static let size = CGSize(width: 420, height: 44)
    private static let bottomMargin: CGFloat = 24

    private let model = OverlayModel()

    init() {
        super.init(contentRect: CGRect(origin: .zero, size: Self.size),
                   styleMask: [.nonactivatingPanel, .borderless],
                   backing: .buffered, defer: true)
        level = .statusBar
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        contentView = NSHostingView(rootView: OverlayView(model: model))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func show(_ state: SessionState) {
        model.state = state
        guard state != .idle else {
            orderOut(nil)
            return
        }
        if !isVisible {
            reposition()
            orderFrontRegardless()
        }
    }

    private func reposition() {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) })
            ?? NSScreen.main else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(CGPoint(x: visible.midX - Self.size.width / 2,
                               y: visible.minY + Self.bottomMargin))
    }
}
