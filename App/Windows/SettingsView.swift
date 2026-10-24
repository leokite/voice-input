import AppKit
import ServiceManagement
import SwiftUI
import VoiceInputCore

struct SettingsView: View {
    @ObservedObject var coordinator: AppCoordinator
    @State private var apiKeyInput = ""
    @State private var apiKeyError: String?
    @State private var openAIKeyInput = ""
    @State private var openAIKeyError: String?
    @State private var modelInput = ""
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
                        coordinator.deleteAPIKey()
                        apiKeyInput = ""
                    }
                    .disabled(!coordinator.hasAPIKey)
                    if coordinator.hasAPIKey { Text("保存済み").foregroundStyle(.secondary) }
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
                ShortcutRecorderRow(title: "直した単語を登録するキー", shortcut: binding(\.glossaryShortcut),
                                    coordinator: coordinator)
                Toggle("外部AI（OpenAI）で置き換え元を探す", isOn: binding(\.useCloudLocator))
                if coordinator.settings.useCloudLocator {
                    Text("単語だけを選んだときなどに、直前の音声入力の文と直した語を OpenAI に送ります。")
                        .foregroundStyle(.secondary)
                    TextField("モデル名", text: $modelInput, prompt: Text("例: gpt-6-luna"))
                        .onSubmit { saveModel() }
                        .onAppear { modelInput = coordinator.settings.cloudModel }
                    HStack {
                        Button("モデル名を保存") { saveModel() }
                            .disabled(modelInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                      == coordinator.settings.cloudModel)
                        if coordinator.settings.cloudModel.isEmpty {
                            Text("モデル名を入力してください。空のあいだは OpenAI を使いません。").foregroundStyle(.orange)
                        }
                    }
                    SecureField("OpenAI API キー", text: $openAIKeyInput)
                    HStack {
                        Button("保存") { saveOpenAIKey() }
                            .disabled(openAIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("削除", role: .destructive) {
                            coordinator.deleteOpenAIKey()
                            openAIKeyInput = ""
                        }
                        .disabled(!coordinator.hasOpenAIKey)
                        if coordinator.hasOpenAIKey { Text("保存済み").foregroundStyle(.secondary) }
                    }
                    if let openAIKeyError { Text(openAIKeyError).foregroundStyle(.red) }
                    if !coordinator.hasOpenAIKey {
                        Text("キーがないので、今は読みの近さだけで探します。").foregroundStyle(.orange)
                    }
                }
                switch coordinator.judgeAvailability {
                case .available:
                    Text("端末内AIで置き換えを判断します").foregroundStyle(.secondary)
                case .unavailable(let reason):
                    Text(reason).foregroundStyle(.orange)
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

    /// モデル名は 1 文字打つごとではなく、保存を押したとき（または Return）に設定ファイルへ書く。
    private func saveModel() {
        var s = coordinator.settings
        s.cloudModel = modelInput.trimmingCharacters(in: .whitespacesAndNewlines)
        modelInput = s.cloudModel
        coordinator.updateSettings(s)
    }

    private func saveOpenAIKey() {
        let key = openAIKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try coordinator.saveOpenAIKey(key)
            openAIKeyError = nil
            openAIKeyInput = ""
        } catch {
            openAIKeyError = "キーチェーンに保存できません: \(error.localizedDescription)"
        }
    }

    private func saveKey() {
        let key = apiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try coordinator.saveAPIKey(key)
            apiKeyError = nil
            apiKeyInput = ""
        } catch {
            apiKeyError = "保存できません（\(error)）"
        }
    }
}

/// 「押して設定」。次に押されたキーの keyCode を記録する。使えるのは修飾キーと F13〜F19 だけ。Esc で取り消す。
private struct KeyRecorderRow: View {
    let title: String
    @Binding var key: KeyID
    let coordinator: AppCoordinator
    @State private var recording = false
    @State private var rejected = false
    @State private var monitor: Any?

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(recording ? (rejected ? "このキーは使えません" : "キーを押してください…")
                               : KeyNames.displayName(for: key))
                    .foregroundStyle(recording ? Color.orange : Color.primary)
                Button(recording ? "取り消す" : "押して設定") { recording ? stop() : start() }
            }
        }
        .onDisappear { if recording { stop() } }
        // 別のアプリに移る、ウインドウが閉じるなどで入力を受けられなくなったら、設定を終えて録音キーを戻す。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if recording { stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            if recording { stop() }
        }
        .task(id: recording) {
            guard recording else { return }
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled, recording { stop() }
        }
    }

    private func start() {
        rejected = false
        recording = true
        coordinator.beginKeyCapture()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            if event.type == .keyDown {
                let pressed = KeyID(keyCode: event.keyCode)
                if event.keyCode == 53 {
                    stop()
                } else if RecordKeys.isAllowed(pressed) {
                    key = pressed
                    stop()
                } else {
                    // 普通のキーを録音キーにすると、どのアプリでも打てなくなる。受け付けずに待ち続ける。
                    rejected = true
                }
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

/// 用語集に登録するキーの「押して設定」。修飾キーと普通のキー 1 つの組み合わせを記録する。Esc で取り消す。
private struct ShortcutRecorderRow: View {
    let title: String
    @Binding var shortcut: Shortcut
    let coordinator: AppCoordinator
    @State private var recording = false
    @State private var rejected = false
    @State private var monitor: Any?

    var body: some View {
        LabeledContent(title) {
            HStack {
                Text(recording ? (rejected ? "このキーは使えません" : "キーを押してください…") : shortcut.displayName)
                    .foregroundStyle(recording ? Color.orange : Color.primary)
                Button(recording ? "取り消す" : "押して設定") { recording ? stop() : start() }
            }
        }
        .onDisappear { if recording { stop() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if recording { stop() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in
            if recording { stop() }
        }
        .task(id: recording) {
            guard recording else { return }
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled, recording { stop() }
        }
    }

    private func start() {
        rejected = false
        recording = true
        coordinator.beginKeyCapture()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 {
                stop()
                return nil
            }
            let candidate = Shortcut(
                modifiers: ShortcutModifiers(cgFlags: UInt64(event.modifierFlags.rawValue)),
                keyCode: event.keyCode,
                keyLabel: Self.label(for: event))
            let recordKeys = [coordinator.settings.toggleKey, coordinator.settings.holdKey]
            if Shortcut.isAllowed(candidate, recordKeys: recordKeys) {
                shortcut = candidate
                stop()
            } else {
                // 修飾キーなしの組み合わせは普段の入力を邪魔するので受け付けず、待ち続ける。
                rejected = true
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

    /// 表示用のキーの名前。英数字なら大文字、それ以外（F キーなど）は KeyNames の名前。
    private static func label(for event: NSEvent) -> String {
        if let chars = event.charactersIgnoringModifiers?.uppercased(), chars.count == 1,
           let scalar = chars.unicodeScalars.first, scalar.isASCII, scalar.properties.isAlphabetic || ("0"..."9").contains(chars) {
            return chars
        }
        return KeyNames.displayName(for: KeyID(keyCode: event.keyCode))
    }
}
