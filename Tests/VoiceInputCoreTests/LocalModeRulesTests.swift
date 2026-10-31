import Testing
@testable import VoiceInputCore

@Suite struct LocalModeRulesTests {
    private let allStatuses: [LocalModelStatus] = [
        .notInstalled, .downloading(fraction: 0.5), .preparing, .ready, .failed("x"),
    ]

    @Test func sonioxPassesRealKeyAndIgnoresModel() {
        for status in allStatuses {
            for warmingUp in [true, false] {
                let yes = LocalModeRules.gateInputs(engine: .soniox, hasAPIKey: true, modelStatus: status,
                                                    warmingUp: warmingUp)
                #expect(yes.hasAPIKey && yes.localModelReady)
                let no = LocalModeRules.gateInputs(engine: .soniox, hasAPIKey: false, modelStatus: status,
                                                   warmingUp: warmingUp)
                #expect(!no.hasAPIKey && no.localModelReady)
            }
        }
    }

    @Test func localNeedsNoKeyButNeedsReadyModel() {
        for hasKey in [true, false] {
            for status in allStatuses {
                let inputs = LocalModeRules.gateInputs(engine: .local, hasAPIKey: hasKey, modelStatus: status,
                                                       warmingUp: false)
                #expect(inputs.hasAPIKey)
                #expect(inputs.localModelReady == (status == .ready), "\(status)")
            }
        }
    }

    @Test func localWaitsWhileWarmingUp() {
        // 読み込みの途中に録音すると、認識が時間内に終わらず声が捨てられるため
        let inputs = LocalModeRules.gateInputs(engine: .local, hasAPIKey: false, modelStatus: .ready, warmingUp: true)
        #expect(inputs.hasAPIKey)
        #expect(!inputs.localModelReady)
    }

    @Test func notReadyWhileWarmingUpOnlyAsksToWait() {
        #expect(LocalModeRules.notReadyReaction(warmingUp: true) == .waitForWarmUp)
        #expect(LocalModeRules.notReadyReaction(warmingUp: false) == .openSettings)
    }

    @Test func refreshKeepsDownloadAndPreparation() {
        for status: LocalModelStatus in [.downloading(fraction: 0.3), .preparing] {
            #expect(LocalModeRules.refreshedStatus(current: status, hasFiles: false, installed: false,
                                                   tokenizerValid: false) == status)
            #expect(LocalModeRules.refreshedStatus(current: status, hasFiles: true, installed: true,
                                                   tokenizerValid: true) == status)
        }
    }

    @Test func refreshReadsFiles() {
        for current: LocalModelStatus in [.notInstalled, .ready] {
            #expect(LocalModeRules.refreshedStatus(current: current, hasFiles: true, installed: true,
                                                   tokenizerValid: true) == .ready)
            #expect(LocalModeRules.refreshedStatus(current: current, hasFiles: true, installed: false,
                                                   tokenizerValid: false) == .notInstalled)
            #expect(LocalModeRules.refreshedStatus(current: current, hasFiles: false, installed: false,
                                                   tokenizerValid: false) == .notInstalled)
        }
    }

    @Test func refreshReportsBrokenTokenizer() {
        let status = LocalModeRules.refreshedStatus(current: .ready, hasFiles: true, installed: true, tokenizerValid: false)
        guard case .failed(let reason) = status else {
            Issue.record("\(status)")
            return
        }
        #expect(reason.contains("トークナイザー"))
    }

    @Test func refreshKeepsFailureUntilFilesAreGone() {
        // 理由はやり直すか削除するまで見せ続ける
        for (installed, valid) in [(true, true), (true, false), (false, false)] {
            #expect(LocalModeRules.refreshedStatus(current: .failed("x"), hasFiles: true, installed: installed,
                                                   tokenizerValid: valid) == .failed("x"))
        }
        #expect(LocalModeRules.refreshedStatus(current: .failed("x"), hasFiles: false, installed: false,
                                               tokenizerValid: false) == .notInstalled)
    }

    @Test func deleteAllowedOnlyWhenNothingUsesTheModel() {
        #expect(LocalModeRules.canDeleteModel(hasFiles: true, status: .ready, sessionState: .idle, keysQuiet: true, warmingUp: false))
        #expect(LocalModeRules.canDeleteModel(hasFiles: true, status: .failed("x"), sessionState: .error("e"), keysQuiet: true,
                                              warmingUp: false))
        #expect(LocalModeRules.canDeleteModel(hasFiles: true, status: .ready, sessionState: .notice("n"), keysQuiet: true,
                                              warmingUp: false))
        // 準備の途中
        for status: LocalModelStatus in [.downloading(fraction: 0.1), .preparing] {
            #expect(!LocalModeRules.canDeleteModel(hasFiles: true, status: status, sessionState: .idle,
                                                   keysQuiet: true, warmingUp: false))
        }
        // 録音中、処理中、押下の途中、読み込み中
        #expect(!LocalModeRules.canDeleteModel(hasFiles: true, status: .ready, sessionState: .recording(level: 0, preview: ""),
                                               keysQuiet: true, warmingUp: false))
        #expect(!LocalModeRules.canDeleteModel(hasFiles: true, status: .ready, sessionState: .processing, keysQuiet: true,
                                               warmingUp: false))
        #expect(!LocalModeRules.canDeleteModel(hasFiles: true, status: .ready, sessionState: .idle, keysQuiet: false,
                                               warmingUp: false))
        #expect(!LocalModeRules.canDeleteModel(hasFiles: true, status: .ready, sessionState: .idle, keysQuiet: true,
                                               warmingUp: true))
    }

    @Test func warmUpOnlyForLocalWithReadyModel() {
        #expect(LocalModeRules.shouldWarmUp(engine: .local, status: .ready))
        for status in allStatuses where status != .ready {
            #expect(!LocalModeRules.shouldWarmUp(engine: .local, status: status))
        }
        for status in allStatuses {
            #expect(!LocalModeRules.shouldWarmUp(engine: .soniox, status: status))
        }
    }

    @Test func cloudLocatorOffInLocalMode() {
        var settings = AppSettings.default
        settings.useCloudLocator = true
        #expect(LocalModeRules.usesCloudLocator(settings: settings, hasOpenAIKey: true))
        #expect(!LocalModeRules.usesCloudLocator(settings: settings, hasOpenAIKey: false))
        settings.engine = .local
        #expect(!LocalModeRules.usesCloudLocator(settings: settings, hasOpenAIKey: true))
        settings.engine = .soniox
        settings.useCloudLocator = false
        #expect(!LocalModeRules.usesCloudLocator(settings: settings, hasOpenAIKey: true))
    }

    @Test func notInstalledCanDeleteOnlyLeftovers() {
        #expect(LocalModeRules.canDeleteModel(hasFiles: true, status: .notInstalled, sessionState: .idle,
                                              keysQuiet: true, warmingUp: false))
        #expect(!LocalModeRules.canDeleteModel(hasFiles: false, status: .notInstalled, sessionState: .idle,
                                               keysQuiet: true, warmingUp: false))
        #expect(!LocalModeRules.canDeleteModel(hasFiles: true, status: .notInstalled, sessionState: .processing,
                                               keysQuiet: true, warmingUp: false))
    }

    @Test func sonioxKeyNeededOnlyForSoniox() {
        #expect(LocalModeRules.needsAPIKey(engine: .soniox, hasAPIKey: false))
        #expect(!LocalModeRules.needsAPIKey(engine: .soniox, hasAPIKey: true))
        #expect(!LocalModeRules.needsAPIKey(engine: .local, hasAPIKey: false))
        #expect(!LocalModeRules.needsAPIKey(engine: .local, hasAPIKey: true))
    }

    @Test func setupNeededAtLaunch() {
        for status in allStatuses {
            #expect(LocalModeRules.needsSetup(engine: .soniox, hasAPIKey: false, modelStatus: status))
            #expect(!LocalModeRules.needsSetup(engine: .soniox, hasAPIKey: true, modelStatus: status))
            for hasKey in [true, false] {
                #expect(LocalModeRules.needsSetup(engine: .local, hasAPIKey: hasKey, modelStatus: status)
                        == (status != .ready), "\(status)")
            }
        }
    }

    @Test func engineSwitchOnlyWhenNothingIsRecording() {
        #expect(LocalModeRules.canSwitchEngine(sessionState: .idle, keysQuiet: true))
        #expect(LocalModeRules.canSwitchEngine(sessionState: .error("e"), keysQuiet: true))
        #expect(LocalModeRules.canSwitchEngine(sessionState: .notice("n"), keysQuiet: true))
        #expect(!LocalModeRules.canSwitchEngine(sessionState: .recording(level: 0, preview: ""), keysQuiet: true))
        #expect(!LocalModeRules.canSwitchEngine(sessionState: .processing, keysQuiet: true))
        #expect(!LocalModeRules.canSwitchEngine(sessionState: .idle, keysQuiet: false))
    }
}
