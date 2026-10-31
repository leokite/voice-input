import Testing
@testable import VoiceInputCore

@Suite struct LocalModeRulesTests {
    private let allStatuses: [LocalModelStatus] = [
        .notInstalled, .downloading(fraction: 0.5), .preparing, .ready, .failed("x"),
    ]

    @Test func sonioxPassesRealKeyAndIgnoresModel() {
        for status in allStatuses {
            let yes = LocalModeRules.gateInputs(engine: .soniox, hasAPIKey: true, modelStatus: status)
            #expect(yes.hasAPIKey && yes.localModelReady)
            let no = LocalModeRules.gateInputs(engine: .soniox, hasAPIKey: false, modelStatus: status)
            #expect(!no.hasAPIKey && no.localModelReady)
        }
    }

    @Test func localNeedsNoKeyButNeedsReadyModel() {
        for hasKey in [true, false] {
            for status in allStatuses {
                let inputs = LocalModeRules.gateInputs(engine: .local, hasAPIKey: hasKey, modelStatus: status)
                #expect(inputs.hasAPIKey)
                #expect(inputs.localModelReady == (status == .ready), "\(status)")
            }
        }
    }

    @Test func deleteAllowedOnlyWhenNothingUsesTheModel() {
        #expect(LocalModeRules.canDeleteModel(status: .ready, sessionState: .idle, keysQuiet: true, warmingUp: false))
        #expect(LocalModeRules.canDeleteModel(status: .failed("x"), sessionState: .error("e"), keysQuiet: true,
                                              warmingUp: false))
        #expect(LocalModeRules.canDeleteModel(status: .ready, sessionState: .notice("n"), keysQuiet: true,
                                              warmingUp: false))
        // 消すものがない、または準備の途中
        for status: LocalModelStatus in [.notInstalled, .downloading(fraction: 0.1), .preparing] {
            #expect(!LocalModeRules.canDeleteModel(status: status, sessionState: .idle, keysQuiet: true,
                                                   warmingUp: false))
        }
        // 録音中、処理中、押下の途中、読み込み中
        #expect(!LocalModeRules.canDeleteModel(status: .ready, sessionState: .recording(level: 0, preview: ""),
                                               keysQuiet: true, warmingUp: false))
        #expect(!LocalModeRules.canDeleteModel(status: .ready, sessionState: .processing, keysQuiet: true,
                                               warmingUp: false))
        #expect(!LocalModeRules.canDeleteModel(status: .ready, sessionState: .idle, keysQuiet: false,
                                               warmingUp: false))
        #expect(!LocalModeRules.canDeleteModel(status: .ready, sessionState: .idle, keysQuiet: true,
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
}
