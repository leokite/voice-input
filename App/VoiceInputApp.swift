import SwiftUI
import VoiceInputCore

@main
struct VoiceInputApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("VoiceInput", systemImage: "mic") {
            MenuContent(coordinator: appDelegate.coordinator, windows: appDelegate.windows)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()
    lazy var windows = WindowPresenter(coordinator: coordinator)

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.openWindow = { [weak self] window in self?.windows.open(window) }
        coordinator.start()
        if coordinator.needsPermissions { windows.open(.permissions) }
        if !coordinator.hasAPIKey { windows.open(.settings) }
    }
}

private struct MenuContent: View {
    @ObservedObject var coordinator: AppCoordinator
    let windows: WindowPresenter

    var body: some View {
        if !coordinator.keyMonitorRunning {
            Button("アクセシビリティの許可が必要です") { windows.open(.permissions) }
            Divider()
        }
        Button("録音の開始と停止") { coordinator.toggleRecordingFromMenu() }
        Divider()
        Button("履歴") { windows.open(.history) }
        Button("用語集") { windows.open(.glossary) }
        Button("設定") { windows.open(.settings) }
        Button("権限") { windows.open(.permissions) }
        Divider()
        Button("終了") { NSApplication.shared.terminate(nil) }
    }
}
