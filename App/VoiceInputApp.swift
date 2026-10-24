import SwiftUI
import VoiceInputCore

@main
struct VoiceInputApp: App {
    var body: some Scene {
        MenuBarExtra("VoiceInput", systemImage: "mic") {
            Button("終了") { NSApplication.shared.terminate(nil) }
        }
    }
}
