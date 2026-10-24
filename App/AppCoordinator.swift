import AppKit
import VoiceInputCore

/// 保存処理、SessionController、KeyStateMachine、GlobalKeyMonitor、OverlayPanel をつなぐ。
@MainActor final class AppCoordinator: ObservableObject {
    @Published private(set) var keyMonitorRunning = false
    @Published private(set) var settings: AppSettings
    @Published private(set) var glossary: Glossary
    @Published private(set) var history: History

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
    private var overlayMessageTask: Task<Void, Never>?
    /// API キーがないまま押されたキー。確定したら警告を出す。
    private var pressWithoutKey = false

    init() {
        let settings = settingsStore.load()
        self.settings = settings
        glossary = glossaryStore.load()
        history = historyStore.load()
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

        keyMonitor = GlobalKeyMonitor(
            watched: { [unowned self] in [self.settings.toggleKey, self.settings.holdKey] },
            onEvent: { [unowned self] event in self.handle(event) }
        )
    }

    func start() {
        keyMonitorRunning = keyMonitor.start()
        if !keyMonitorRunning { retryKeyMonitorUntilPermitted() }
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

    // MARK: - Keys

    /// tap のコールバック内で呼ばれる。判定だけをここで行い、キーチェーンの読み出しやマイクの起動は
    /// コールバックを返した後に回して、キー入力全体を止めないようにする。
    private func handle(_ event: KeyEvent) {
        let actions = keyMachine.handle(event, at: ProcessInfo.processInfo.systemUptime)
        guard !actions.isEmpty else { return }
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { dispatch(actions) }
        }
    }

    private func dispatch(_ actions: [KeyAction]) {
        for action in actions {
            switch action {
            case .beginBuffering:
                scheduleThresholdTick()
                pressWithoutKey = KeychainStore.loadAPIKey()?.isEmpty ?? true
                if pressWithoutKey { continue }
            case .confirm where pressWithoutKey:
                pressWithoutKey = false
                keyMachine.reset()
                showOverlayMessage(.error("API キーが設定されていません"))
                continue
            case .cancel where pressWithoutKey:
                pressWithoutKey = false
                continue
            default:
                break
            }
            session.handle(action)
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

    // MARK: - Session

    private func sessionStateChanged(_ state: SessionState) {
        sessionState = state
        overlayMessageTask?.cancel()
        overlay.show(state)
        if case .error = state { keyMachine.reset() }
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
        history.add(entry, limit: settings.historyLimit)
        do { try historyStore.save(history) } catch { NSLog("VoiceInput: history.json を保存できません: \(error)") }
    }

    private func markTermsUsed(_ terms: Set<String>) {
        glossary.markUsed(terms, at: Date())
        do { try glossaryStore.save(glossary) } catch { NSLog("VoiceInput: glossary.json を保存できません: \(error)") }
    }
}

/// 録音のたびにキーチェーンから API キーを読む。後から入れたキーも再起動なしで使える。
private struct KeychainSessionFactory: TranscriptionSessionFactory {
    func makeSession() -> TranscriptionSession {
        SonioxSessionFactory(apiKey: KeychainStore.loadAPIKey() ?? "").makeSession()
    }
}
