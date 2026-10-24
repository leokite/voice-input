import AppKit
import ServiceManagement
import SwiftUI
import VoiceInputCore

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var apiKeyInput = ""
    @State private var hasAPIKey = !(KeychainStore.loadAPIKey()?.isEmpty ?? true)
    @State private var apiKeyError: String?
    @State private var languageText = ""
    @State private var newFiller = ""
    @State private var launchError: String?

    private func binding<T>(_ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
        Binding(get: { coordinator.settings[keyPath: keyPath] },
                set: { value in
                    var s = coordinator.settings
                    s[keyPath: keyPath] = value
                    coordinator.updateSettings(s)
                })
    }

    var body: some View {
        Form {
            Section("API キー") {
                SecureField("Soniox API キー", text: $apiKeyInput)
                HStack {
                    Button("保存") { saveKey() }
                        .disabled(apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("削除", role: .destructive) {
                        KeychainStore.deleteAPIKey()
                        hasAPIKey = false
                        apiKeyInput = ""
                    }
                    .disabled(!hasAPIKey)
                    if hasAPIKey { Text("保存済み").foregroundStyle(.secondary) }
                }
                if let apiKeyError { Text(apiKeyError).foregroundStyle(.red) }
            }

            Section("キー") {
                KeyRecorderRow(title: "短く押して開始と停止", key: binding(\.toggleKey), coordinator: coordinator)
                KeyRecorderRow(title: "押し続けて録音", key: binding(\.holdKey), coordinator: coordinator)
                LabeledContent("短押しと長押しの境目") {
                    HStack {
                        Slider(value: binding(\.holdThreshold), in: 0.15...1.0, step: 0.05)
                        Text(String(format: "%.2f 秒", coordinator.settings.holdThreshold))
                            .monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                }
            }

            Section("入力") {
                Picker("文字の入れ方", selection: binding(\.insertionMode)) {
                    Text("話し終えてからまとめて").tag(InsertionMode.batch)
                    Text("文の区切りごと").tag(InsertionMode.realtime)
                }
                TextField("言語のヒント（例: ja, en）", text: $languageText)
                    .onSubmit(commitLanguage)
                    .onChange(of: languageText) { _, _ in commitLanguage() }
                Stepper(value: binding(\.silenceTimeout), in: 10...600, step: 10) {
                    Text("無音で自動停止: \(Int(coordinator.settings.silenceTimeout)) 秒")
                }
            }

            Section("フィラー") {
                ForEach(coordinator.settings.fillers.indices, id: \.self) { i in
                    HStack {
                        Text(coordinator.settings.fillers[i])
                        Spacer()
                        Button(role: .destructive) {
                            var s = coordinator.settings
                            s.fillers.remove(at: i)
                            coordinator.updateSettings(s)
                        } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                    }
                }
                HStack {
                    TextField("追加するフィラー", text: $newFiller).onSubmit(addFiller)
                    Button("追加", action: addFiller)
                        .disabled(newFiller.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                Button("初期値に戻す") {
                    var s = coordinator.settings
                    s.fillers = FillerRemover.defaultFillers
                    coordinator.updateSettings(s)
                }
            }

            Section("用語集") {
                if coordinator.glossary.contextTerms().truncated {
                    Label("用語が多すぎて、一部は音声認識のヒントに送られていません。古い用語を整理してください。",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                } else {
                    Text("用語はすべて音声認識のヒントに送られています。").foregroundStyle(.secondary)
                }
            }

            Section("起動") {
                Toggle("ログイン時に起動", isOn: launchBinding)
                if let launchError { Text(launchError).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .onAppear { languageText = LanguageHints.format(coordinator.settings.languageHints) }
    }

    private var launchBinding: Binding<Bool> {
        Binding(get: { coordinator.settings.launchAtLogin }, set: { enabled in
            do {
                if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                launchError = nil
                var s = coordinator.settings
                s.launchAtLogin = enabled
                coordinator.updateSettings(s)
            } catch {
                // 失敗したら設定は変えず、トグルは元に戻る。
                launchError = "ログイン時の起動を変更できません: \(error.localizedDescription)"
            }
        })
    }

    private func commitLanguage() {
        let hints = LanguageHints.parse(languageText)
        guard hints != coordinator.settings.languageHints else { return }
        var s = coordinator.settings
        s.languageHints = hints
        coordinator.updateSettings(s)
    }

    private func addFiller() {
        let text = newFiller.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !coordinator.settings.fillers.contains(text) else { newFiller = ""; return }
        var s = coordinator.settings
        s.fillers.append(text)
        coordinator.updateSettings(s)
        newFiller = ""
    }

    private func saveKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try KeychainStore.saveAPIKey(key)
            hasAPIKey = true
            apiKeyError = nil
            apiKeyInput = ""
        } catch {
            apiKeyError = "保存できません（\(error)）"
        }
    }
}

/// 「押して設定」。次に押されたキーの keyCode を記録する。修飾キーにも対応。Esc で取り消す。
private struct KeyRecorderRow: View {
    let title: String
    @Binding var key: KeyID
    let coordinator: AppCoordinator
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(recording ? "キーを押してください…" : KeyNames.displayName(for: key))
                    .foregroundStyle(recording ? Color.orange : Color.primary)
                Button(recording ? "取り消す" : "押して設定") { recording ? stop() : start() }
            }
        }
        .onDisappear { if recording { stop() } }
    }

    private func start() {
        recording = true
        coordinator.beginKeyCapture()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .keyDown {
                if event.keyCode != 53 { key = KeyID(keyCode: event.keyCode) }
                stop()
                return nil
            }
            // 修飾キーは押した瞬間（フラグが立った）だけ拾う。
            if case .down? = ModifierKeys.event(keyCode: event.keyCode, flags: UInt64(event.modifierFlags.rawValue)) {
                key = KeyID(keyCode: event.keyCode)
                stop()
            }
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        coordinator.endKeyCapture()
    }
}
