import AppKit
import ApplicationServices
import AVFoundation
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
    /// API キーがないまま押されたキー。確定したら警告を出す。
    private var pressWithoutKey = false
    /// SessionController に .beginBuffering を渡し、まだ確定も取り消しもしていない。
    private var buffering = false
    /// 録音中のモード。録音中でなければ nil。
    private var activeMode: RecordingMode?
    /// tap のスレッドから読む録音キー。
    private let watchedKeys: LockedValue<Set<KeyID>>
    /// 押した時点で読んだ API キー。確定時にファクトリーが使う。
    private let apiKey = LockedValue<String?>(nil)

    init() {
        let settings = settingsStore.load()
        self.settings = settings
        glossary = glossaryStore.load()
        hasAPIKey = !(KeychainStore.loadAPIKey()?.isEmpty ?? true)
        history = historyStore.load()
        watchedKeys = LockedValue([settings.toggleKey, settings.holdKey])
        keyMachine = KeyStateMachine(toggleKey: settings.toggleKey, holdKey: settings.holdKey,
                                     holdThreshold: settings.holdThreshold)

        session = SessionController(
            audio: AudioCapture(),
            sessions: CachedKeySessionFactory(apiKey: apiKey),
            inserter: PasteboardInserter(),
            frontmost: FrontmostApp(),
            settings: { [unowned self] in self.settings },
            glossary: { [unowned self] in self.glossary },
            onHistory: { [unowned self] entry in self.addHistory(entry) },
            onTermsUsed: { [unowned self] terms in self.markTermsUsed(terms) }
        )
        session.onStateChange = { [unowned self] state in self.sessionStateChanged(state) }
        session.onAutoStop = { [unowned self] in self.keyMachine.reset() }

        // コールバックは tap の専用スレッドで呼ばれる。時刻はその場で取り、処理はメインへ順番どおりに移す。
        keyMonitor = GlobalKeyMonitor(
            watched: { [watchedKeys] in watchedKeys.value },
            onEvent: { [weak self] event in
                let t = ProcessInfo.processInfo.systemUptime
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.handle(event, at: t) }
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

    /// 起動時に案内の画面を開くべきか。
    var needsOnboarding: Bool {
        let micOK = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        return !micOK || !AXIsProcessTrusted() || !hasAPIKey
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
    }

    func endKeyCapture() {
        capturingKey = false
        keyRebuildPending = true
        rebuildKeysIfQuiet()
    }

    /// キーが落ち着いていれば（録音中でも、押下の途中でもなければ）、新しい設定でキーの状態機械と監視キーを作り直す。
    private func rebuildKeysIfQuiet() {
        guard keyRebuildPending, !capturingKey, activeMode == nil, !buffering, !pressWithoutKey else { return }
        if case .recording = sessionState { return }
        keyRebuildPending = false
        thresholdTask?.cancel()
        keyMachine = KeyStateMachine(toggleKey: settings.toggleKey, holdKey: settings.holdKey,
                                     holdThreshold: settings.holdThreshold)
        watchedKeys.value = [settings.toggleKey, settings.holdKey]
    }

    /// 録音と押下の途中を、種類を問わず終わらせて状態を戻す。
    private func abortKeyInteraction() {
        thresholdTask?.cancel()
        if activeMode != nil { session.handle(.stop) }
        if buffering { session.handle(.cancel) }
        buffering = false
        activeMode = nil
        pressWithoutKey = false
        keyMachine.reset()
    }

    // MARK: - Keys

    private func handle(_ event: KeyEvent, at t: TimeInterval) {
        dispatch(keyMachine.handle(event, at: t))
    }

    /// tap が無効にされていた間のイベント（録音キーの up かもしれない）は失われている。
    /// 押し続けの録音が止まらなくなるのを防ぐため、押し続けの録音と確定前の押下を終わらせて状態を戻す。
    /// トグルの録音は続ける。KeyStateMachine はキーを失っても次の押下で止められる状態のままなので触らない。
    private func keyTapWasDisabled() {
        if activeMode == .toggle { return }
        thresholdTask?.cancel()
        if activeMode == .hold { session.handle(.stop) }
        if buffering { session.handle(.cancel) }
        buffering = false
        activeMode = nil
        pressWithoutKey = false
        keyMachine.reset()
    }

    private func dispatch(_ actions: [KeyAction]) {
        for action in actions {
            switch action {
            case .beginBuffering:
                scheduleThresholdTick()
                let key = KeychainStore.loadAPIKey()
                apiKey.value = key
                pressWithoutKey = key?.isEmpty ?? true
                if pressWithoutKey { continue }
                buffering = true
            case .confirm where pressWithoutKey:
                pressWithoutKey = false
                keyMachine.reset()
                showOverlayMessage(.error("API キーが設定されていません"))
                continue
            case .cancel where pressWithoutKey:
                pressWithoutKey = false
                continue
            case .confirm(let mode):
                buffering = false
                activeMode = mode
            case .cancel:
                buffering = false
            case .stop, .abort:
                activeMode = nil
            }
            session.handle(action)
        }
        rebuildKeysIfQuiet()
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

    // MARK: - Session

    private func sessionStateChanged(_ state: SessionState) {
        sessionState = state
        if case .recording = state {} else { activeMode = nil }
        if case .error = state { buffering = false }
        overlayMessageTask?.cancel()
        overlay.show(state)
        if case .error = state { keyMachine.reset() }
        rebuildKeysIfQuiet()
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

/// 押した時点でキーチェーンから読んだ API キーを使う。録音のたびに読むので、後から入れたキーも再起動なしで使える。
private struct CachedKeySessionFactory: TranscriptionSessionFactory {
    let apiKey: LockedValue<String?>

    func makeSession() -> TranscriptionSession {
        SonioxSessionFactory(apiKey: apiKey.value ?? "").makeSession()
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
