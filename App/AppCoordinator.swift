import AppKit
import ApplicationServices
import AVFoundation
import Carbon.HIToolbox
import VoiceInputCore

/// 保存処理、SessionController、KeyStateMachine、GlobalKeyMonitor、OverlayPanel をつなぐ。
@MainActor final class AppCoordinator: ObservableObject {
    @Published private(set) var keyMonitorRunning = false
    @Published private(set) var settings: AppSettings
    @Published private(set) var glossary: Glossary
    @Published private(set) var history: History
    /// 録音キーの設定中。true の間は tap が録音キーを無視する。
    @Published private(set) var capturingKey = false
    /// キーチェーンに API キーがあるか。画面から繰り返し読まないよう、保存と削除のときだけ更新する。
    @Published private(set) var hasAPIKey = false
    /// 端末内AIを使えるか。使えないときは置き換えを登録せず、認識のヒントだけを登録する。
    @Published private(set) var judgeAvailability: JudgeAvailability
    /// 案内の画面を開く。AppDelegate が WindowPresenter につなぐ。
    var openWindow: ((AppWindow) -> Void)?

    private let settingsStore = JSONStore(url: AppPaths.supportDirectory.appendingPathComponent("settings.json"),
                                          defaultValue: AppSettings.default)
    private let glossaryStore = JSONStore(url: AppPaths.supportDirectory.appendingPathComponent("glossary.json"),
                                          defaultValue: Glossary.empty)
    private let historyStore = JSONStore(url: AppPaths.supportDirectory.appendingPathComponent("history.json"),
                                         defaultValue: History())

    private var keyMachine: KeyStateMachine
    private var session: SessionController!
    private var keyMonitor: GlobalKeyMonitor!
    private let overlay = OverlayPanel()

    private var sessionState: SessionState = .idle
    private var thresholdTask: Task<Void, Never>?
    private var permissionRetryTask: Task<Void, Never>?
    private var permissionWatchTask: Task<Void, Never>?
    /// 録音中などに設定が変わった。落ち着いたらキーの設定を作り直す。
    private var keyRebuildPending = false
    private var overlayMessageTask: Task<Void, Never>?
    /// 押下と録音の途中経過。録音を始めてよいかを決める。
    private var gate = RecordingGate()
    /// tap のスレッドから読む録音キー。
    private let watchedKeys: LockedValue<Set<KeyID>>
    /// tap のスレッドから読む、用語集に登録するキー。キーの設定中は nil。
    private let glossaryShortcut: LockedValue<Shortcut?>
    private let judge: CorrectionJudge?
    private let copier = SelectionCopier()
    /// 直前の登録と、その時刻。3 秒以内にもう一度キーを押すと取り消す。
    private var lastRegistration: (registration: Registration, at: Date)?
    /// 登録の処理中（選択の読み取りや AI の判断を待っている）。その間のキーは無視する。
    private var registering = false

    init() {
        let settings = settingsStore.load()
        self.settings = settings
        glossary = glossaryStore.load()
        hasAPIKey = !(KeychainStore.loadAPIKey()?.isEmpty ?? true)
        history = historyStore.load()
        watchedKeys = LockedValue([settings.toggleKey, settings.holdKey])
        glossaryShortcut = LockedValue(settings.glossaryShortcut)
        (judge, judgeAvailability) = OnDeviceJudge.make()
        keyMachine = KeyStateMachine(toggleKey: settings.toggleKey, holdKey: settings.holdKey,
                                     holdThreshold: settings.holdThreshold)

        session = SessionController(
            audio: AudioCapture(),
            sessions: KeychainSessionFactory(),
            inserter: PasteboardInserter(),
            frontmost: FrontmostApp(),
            settings: { [unowned self] in self.settings },
            glossary: { [unowned self] in self.glossary },
            onHistory: { [unowned self] entry in self.addHistory(entry) },
            onTermsUsed: { [unowned self] terms in self.markTermsUsed(terms) }
        )
        session.onStateChange = { [unowned self] state in self.sessionStateChanged(state) }
        session.onAutoStop = { [unowned self] in self.keyMachine.reset() }
        session.onError = { [unowned self] error in self.guide(for: error) }

        // コールバックは tap の専用スレッドで呼ばれる。時刻はその場で取り、処理はメインへ順番どおりに移す。
        keyMonitor = GlobalKeyMonitor(
            watched: { [watchedKeys] in watchedKeys.value },
            shortcut: { [glossaryShortcut] in glossaryShortcut.value },
            onEvent: { [weak self] event in
                let t = ProcessInfo.processInfo.systemUptime
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.handle(event, at: t) }
                }
            },
            onShortcut: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.handleGlossaryShortcut() }
                }
            },
            onDisabled: { [weak self] in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.keyTapWasDisabled() }
                }
            }
        )
    }

    func start() {
        keyMonitorRunning = keyMonitor.start()
        if !keyMonitorRunning { retryKeyMonitorUntilPermitted() }
        watchAccessibilityRevocation()
    }

    /// 起動中にアクセシビリティの許可が外されたら、tap を捨てて許可待ちに戻る。
    private func watchAccessibilityRevocation() {
        permissionWatchTask?.cancel()
        permissionWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                if self.keyMonitorRunning, !AXIsProcessTrusted() {
                    self.keyMonitor.stop()
                    self.keyMonitorRunning = false
                    self.abortKeyInteraction()
                    self.retryKeyMonitorUntilPermitted()
                }
            }
        }
    }

    /// 起動時に権限の画面を開くべきか（マイクかアクセシビリティの許可がない）。
    var needsPermissions: Bool {
        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        return !micOK || !AXIsProcessTrusted()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    /// 許可されたら再起動なしで監視を始められるよう、2 秒ごとに tap の作成を試す。
    private func retryKeyMonitorUntilPermitted() {
        permissionRetryTask?.cancel()
        permissionRetryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, !Task.isCancelled else { return }
                if self.keyMonitor.start() {
                    self.keyMonitorRunning = true
                    return
                }
            }
        }
    }

    // MARK: - Settings, glossary, history

    func updateSettings(_ new: AppSettings) {
        guard new != settings else { return }
        settings = new
        do { try settingsStore.save(new) } catch { NSLog("VoiceInput: settings.json を保存できません: \(error)") }
        keyRebuildPending = true
        rebuildKeysIfQuiet()
    }

    func saveAPIKey(_ key: String) throws {
        try KeychainStore.saveAPIKey(key)
        hasAPIKey = true
    }

    func deleteAPIKey() {
        KeychainStore.deleteAPIKey()
        hasAPIKey = false
    }

    func updateGlossary(_ new: Glossary) {
        glossary = new
        do { try glossaryStore.save(new) } catch { NSLog("VoiceInput: glossary.json を保存できません: \(error)") }
    }

    func updateHistory(_ new: History) {
        history = new
        do { try historyStore.save(new) } catch { NSLog("VoiceInput: history.json を保存できません: \(error)") }
    }

    /// 録音キーの設定を始める。録音中や押下の途中なら先に終わらせ、tap が録音キーを無視するようにする。
    func beginKeyCapture() {
        abortKeyInteraction()
        capturingKey = true
        watchedKeys.value = []
        glossaryShortcut.value = nil
    }

    func endKeyCapture() {
        capturingKey = false
        keyRebuildPending = true
        rebuildKeysIfQuiet()
    }

    /// キーが落ち着いていれば（録音中でも、押下の途中でもなければ）、新しい設定でキーの状態機械と監視キーを作り直す。
    private func rebuildKeysIfQuiet() {
        guard keyRebuildPending, !capturingKey, gate.isQuiet else { return }
        if case .recording = sessionState { return }
        keyRebuildPending = false
        thresholdTask?.cancel()
        keyMachine = KeyStateMachine(toggleKey: settings.toggleKey, holdKey: settings.holdKey,
                                     holdThreshold: settings.holdThreshold)
        watchedKeys.value = [settings.toggleKey, settings.holdKey]
        glossaryShortcut.value = settings.glossaryShortcut
    }

    /// 録音と押下の途中を、種類を問わず終わらせて状態を戻す。
    private func abortKeyInteraction() {
        thresholdTask?.cancel()
        if gate.activeMode != nil { session.handle(.stop) }
        if gate.buffering { session.handle(.cancel) }
        gate.reset()
        keyMachine.reset()
    }

    // MARK: - Keys

    private func handle(_ event: KeyEvent, at t: TimeInterval) {
        dispatch(keyMachine.handle(event, at: t))
    }

    /// メニューの「録音の開始と停止」。切り替えの録音だけを始めたり止めたりする。
    /// 始めるときは切り替えモードのキーを短く押したのと同じ道を通す（そのキーの短押しでも止められるように）。
    /// 押し続けの録音には触れない（メニューを開くクリックで、もう捨てられている）。
    func toggleRecordingFromMenu() {
        switch gate.activeMode {
        case .toggle:
            keyMachine.reset()
            dispatch([.stop])
        case nil where gate.isQuiet:
            let t = ProcessInfo.processInfo.systemUptime
            handle(.down(keyMachine.toggleKey), at: t)
            handle(.up(keyMachine.toggleKey), at: t)
        default:
            break
        }
    }

    /// tap が無効にされていた間のイベント（録音キーの up かもしれない）は失われている。
    /// 押し続けの録音が止まらなくなるのを防ぐため、押し続けの録音と確定前の押下を終わらせて状態を戻す。
    /// トグルの録音は続ける。KeyStateMachine はキーを失っても次の押下で止められる状態のままなので触らない。
    private func keyTapWasDisabled() {
        if gate.activeMode == .toggle { return }
        thresholdTask?.cancel()
        if gate.activeMode == .hold { session.handle(.stop) }
        if gate.buffering { session.handle(.cancel) }
        gate.reset()
        keyMachine.reset()
    }

    /// 押した時点ではキーチェーンを読まない（確認のダイアログが普段の入力中に出ないよう、保存の有無だけを見る）。
    /// キーそのものは確定したときに KeychainSessionFactory が読む。
    private func dispatch(_ actions: [KeyAction]) {
        for action in actions {
            if action == .beginBuffering { scheduleThresholdTick() }
            var secureInput = false
            if case .confirm = action { secureInput = IsSecureEventInputEnabled() }
            let decision = gate.decide(action, hasAPIKey: hasAPIKey, secureInput: secureInput)
            if let forward = decision.forward, !session.handle(forward),
               let rejection = gate.sessionRejected(forward) {
                reject(rejection)
                break
            }
            if let rejection = decision.rejection {
                reject(rejection)
                break
            }
        }
        rebuildKeysIfQuiet()
    }

    /// 録音を始めない。キーの状態を戻し、理由を短く知らせる。
    private func reject(_ rejection: RecordingGate.Rejection) {
        thresholdTask?.cancel()
        keyMachine.reset()
        switch rejection {
        case .missingAPIKey:
            showOverlayMessage(.error("API キーが設定されていません"))
            openWindow?(.settings)
        case .secureInput:
            showOverlayMessage(.notice("パスワード入力中は使えません"))
        case .busy:
            showOverlayMessage(.notice("処理中です"))
        }
    }

    private func scheduleThresholdTick() {
        thresholdTask?.cancel()
        let delay = settings.holdThreshold + 0.01
        thresholdTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, !Task.isCancelled else { return }
            self.dispatch(self.keyMachine.tick(at: ProcessInfo.processInfo.systemUptime))
        }
    }

    // MARK: - Glossary shortcut

    /// 用語集に登録するキーが押された。直した部分の選択を読み、直前の音声入力と比べて登録する。
    func handleGlossaryShortcut() {
        if let last = lastRegistration, Date().timeIntervalSince(last.at) <= 3 {
            var updated = glossary
            CorrectionRegistrar.undo(last.registration, in: &updated)
            updateGlossary(updated)
            lastRegistration = nil
            showOverlayMessage(.notice("登録を取り消しました"))
            return
        }
        guard !registering else { return }
        switch sessionState {
        case .recording, .processing:
            showOverlayMessage(.notice("処理中です"))
            return
        case .idle, .error, .notice:
            break
        }
        if IsSecureEventInputEnabled() {
            showOverlayMessage(.notice("パスワード入力中は使えません"))
            return
        }
        registering = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.registering = false }
            guard let selection = await SelectedText.read(copier: self.copier) else {
                self.showOverlayMessage(.notice("文字を選んでからキーを押してください"))
                return
            }
            guard selection.count <= 200 else {
                self.showOverlayMessage(.notice("選んだ範囲が長すぎます"))
                return
            }
            guard let candidates = CorrectionMatcher.match(selection: selection, history: self.history.entries,
                                                           now: Date()) else {
                self.showOverlayMessage(.notice("登録できる直しが見つかりませんでした"))
                return
            }
            var updated = self.glossary
            guard let registration = await CorrectionRegistrar(judge: self.judge)
                .register(candidates, into: &updated) else {
                self.showOverlayMessage(.notice("登録できる直しが見つかりませんでした"))
                return
            }
            self.updateGlossary(updated)
            self.lastRegistration = (registration, Date())
            self.showOverlayMessage(.notice(registration.message))
        }
    }

    // MARK: - Session

    private func sessionStateChanged(_ state: SessionState) {
        sessionState = state
        gate.sessionStateChanged(state)
        overlayMessageTask?.cancel()
        overlay.show(state)
        if case .error = state { keyMachine.reset() }
        rebuildKeysIfQuiet()
    }

    /// エラーが出たら、直し方の分かる場所を開く。SessionController はエラー 1 回につき 1 回だけ呼ぶ。
    private func guide(for error: SessionError) {
        switch error {
        case .unauthenticated:
            openWindow?(.settings)
        case .paymentRequired:
            if let url = URL(string: "https://console.soniox.com") { NSWorkspace.shared.open(url) }
        case .micUnavailable:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .notDetermined:
                // 押しただけでは求めない。録音だと確定したここで初めて許可のダイアログを出す。
                AVCaptureDevice.requestAccess(for: .audio) { _ in }
            case .authorized:
                break
            default:
                openWindow?(.permissions)
            }
        case .network:
            break
        }
    }

    /// SessionController を通さない警告を 3 秒出す。その間にセッションが始まればそちらを優先する。
    private func showOverlayMessage(_ state: SessionState) {
        overlayMessageTask?.cancel()
        overlay.show(state)
        overlayMessageTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled else { return }
            self.overlay.show(self.sessionState)
        }
    }

    // MARK: - Persistence

    private func addHistory(_ entry: HistoryEntry) {
        var updated = history
        updated.add(entry, limit: settings.historyLimit)
        updateHistory(updated)
    }

    private func markTermsUsed(_ terms: Set<String>) {
        var updated = glossary
        updated.markUsed(terms, at: Date())
        updateGlossary(updated)
    }
}

/// 録音だと確定したときに、キーチェーンから API キーを読む。録音のたびに読むので、後から入れたキーも再起動なしで使える。
private struct KeychainSessionFactory: TranscriptionSessionFactory {
    func makeSession() -> TranscriptionSession {
        SonioxSessionFactory(apiKey: KeychainStore.loadAPIKey() ?? "").makeSession()
    }
}

/// スレッドをまたいで読み書きする値。
final class LockedValue<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) {
        stored = value
    }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
