import AppKit
import SwiftUI

enum AppWindow: String, CaseIterable {
    case settings, glossary, history, permissions

    var title: String {
        switch self {
        case .settings: "設定"
        case .glossary: "用語集"
        case .history: "履歴"
        case .permissions: "権限"
        }
    }

    var size: CGSize {
        switch self {
        case .settings: CGSize(width: 560, height: 640)
        case .glossary: CGSize(width: 640, height: 520)
        case .history: CGSize(width: 640, height: 560)
        case .permissions: CGSize(width: 460, height: 360)
        }
    }
}

/// 画面ごとに NSWindow を 1 つ持つ。閉じても破棄せず、アプリも終わらない。
@MainActor final class WindowPresenter {
    private let coordinator: AppCoordinator
    private var windows: [AppWindow: NSWindow] = [:]

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
    }

    func open(_ kind: AppWindow) {
        let window = windows[kind] ?? makeWindow(kind)
        windows[kind] = window
        // LSUIElement のアプリは自動では前面に出ないので、明示的に出す。
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow(_ kind: AppWindow) -> NSWindow {
        let content: AnyView = switch kind {
        case .settings: AnyView(SettingsView(coordinator: coordinator))
        case .glossary: AnyView(GlossaryView(coordinator: coordinator))
        case .history: AnyView(HistoryView(coordinator: coordinator))
        case .permissions: AnyView(PermissionsView(coordinator: coordinator))
        }
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: kind.size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = kind.title
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: content)
        window.setContentSize(kind.size)
        window.center()
        return window
    }
}
