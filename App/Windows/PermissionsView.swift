import AVFoundation
import Combine
import ApplicationServices
import SwiftUI
import VoiceInputCore

struct PermissionsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibility = AXIsProcessTrusted()
    @State private var hasAPIKey = Self.apiKeyExists()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("マイク") {
                row(ok: micStatus == .authorized, okText: "許可されています",
                    ngText: micStatus == .notDetermined ? "まだ許可を求めていません" : "許可されていません")
                if micStatus == .notDetermined {
                    Button("許可を求める") {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    }
                } else if micStatus != .authorized {
                    Button("システム設定を開く") {
                        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
                    }
                }
            }
            Section("アクセシビリティ") {
                row(ok: accessibility, okText: "許可されています", ngText: "許可されていません")
                if !accessibility {
                    Button("許可を求める") {
                        let key = "AXTrustedCheckOptionPrompt" as CFString
                        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
                    }
                    Button("システム設定を開く") { coordinator.openAccessibilitySettings() }
                }
            }
            Section("API キー") {
                row(ok: hasAPIKey, okText: "設定されています", ngText: "設定されていません")
                if !hasAPIKey {
                    Button("設定を開く") { (NSApp.delegate as? AppDelegate)?.windows.open(.settings) }
                }
            }
        }
        .formStyle(.grouped)
        .onReceive(timer) { _ in refresh() }
        .onAppear { refresh() }
    }

    private func row(ok: Bool, okText: String, ngText: String) -> some View {
        Label(ok ? okText : ngText,
              systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
            .foregroundStyle(ok ? Color.green : Color.orange)
    }

    private func refresh() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibility = AXIsProcessTrusted()
        hasAPIKey = Self.apiKeyExists()
    }

    private static func apiKeyExists() -> Bool {
        !(KeychainStore.loadAPIKey()?.isEmpty ?? true)
    }

    private func open(_ url: String) {
        if let url = URL(string: url) { NSWorkspace.shared.open(url) }
    }
}
