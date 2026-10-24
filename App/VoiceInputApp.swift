import SwiftUI
import VoiceInputCore

@main
struct VoiceInputApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("VoiceInput", systemImage: "mic") {
            MenuContent(coordinator: appDelegate.coordinator)
        }
    }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let coordinator = AppCoordinator()

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator.start()
    }
}

private struct MenuContent: View {
    @ObservedObject var coordinator: AppCoordinator

    var body: some View {
        if !coordinator.keyMonitorRunning {
            Button("アクセシビリティの許可が必要です") { coordinator.openAccessibilitySettings() }
            Divider()
        }
        // 中身は Task 12 で作る。
        Button("履歴") {}.disabled(true)
        Button("用語集") {}.disabled(true)
        Button("設定") {}.disabled(true)
        Divider()
        Button("終了") { NSApplication.shared.terminate(nil) }
    }
}
