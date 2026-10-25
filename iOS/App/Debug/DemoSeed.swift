#if DEBUG
import Foundation
import Type4MeTransferCore

/// Simulator screenshots: `T4M_DEMO=1` skips onboarding and fills history and
/// a placeholder config (dummy keys, never used for a request), so every
/// screen can be checked on a fresh simulator. `T4M_TAB` opens a tab, `T4M_LANG=zh|en|system` sets the language,
/// `T4M_RESEED=1` replaces the sample history.
@MainActor
enum DemoSeed {
    nonisolated static func debugFile(_ variable: String) -> String? {
        guard let name = ProcessInfo.processInfo.environment[variable],
              let base = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedContainer.appGroupID)
        else { return nil }
        return try? String(contentsOf: base.appendingPathComponent("Library").appendingPathComponent(name), encoding: .utf8)
    }

    /// `T4M_STEP=0…3` opens onboarding at that step.
    static var onboardingStep: Int? {
        ProcessInfo.processInfo.environment["T4M_STEP"].flatMap(Int.init)
    }

    static var isOn: Bool { ProcessInfo.processInfo.environment["T4M_DEMO"] == "1" }

    static func apply(to model: AppModel) {
        if ProcessInfo.processInfo.environment["T4M_STEP"] != nil {
            AppSettings.onboardingCompleted = false
            model.onboardingCompleted = false
            return
        }
        guard isOn else { return }
        SharedSettings.keyboardDemo = ProcessInfo.processInfo.environment["T4M_KEYBOARD_DEMO"] == "1"
        AppSettings.onboardingCompleted = true
        model.onboardingCompleted = true
        if ConfigStore.meta == nil || ConfigStore.llm?.fields["baseURL"] == nil {
            try? ConfigStore.save(Type4MeTransferPayload(
                asr: .init(provider: "volcano", fields: ["appKey": "demo", "accessKey": "demo"]),
                llm: .init(provider: "deepseek", fields: ["apiKey": "demo", "model": "deepseek-v4-flash", "baseURL": "https://api.deepseek.com/v1"]),
                sourceName: "Mac Studio"
            ))
        }
        AIConsent.grant()
        if let raw = ProcessInfo.processInfo.environment["T4M_LANG"] {
            model.setLanguage(raw == "system" ? nil : AppLanguage(rawValue: raw))
        }
        if ProcessInfo.processInfo.environment["T4M_RESEED"] == "1" { model.history.clear() }
        if model.history.entries.isEmpty {
            let zh = AppLanguage.current == .zh
            typealias Sample = (DictationMode, String, String, TimeInterval)
            let zhSamples: [Sample] = [
                (.formalWriting, "那个，明天下午三点的会改到四点吧，记得通知一下设计组", "明天下午 3 点的会改到 4 点，记得通知设计组。", 60 * 4),
                (.quick, "我已经到楼下了你直接下来就行", "我已经到楼下了，你直接下来就行。", 60 * 37),
                (.translation, "这个版本先不发，等测试把问题都过一遍", "Let's hold this release until QA has gone through all the issues.", 60 * 90),
                (.agentMode, "帮我回复一下他说文档我今晚之前改完发给他", "好的，文档我今晚之前改完发你。", 60 * 60 * 5),
                (.quick, "周末要不要一起去爬山天气好像不错", "周末要不要一起去爬山？天气好像不错。", 60 * 60 * 26),
                (.formalWriting, "整理一下今天的要点第一是登录流程第二是付费墙第三是推送", "今天的要点：\n1. 登录流程\n2. 付费墙\n3. 推送", 60 * 60 * 30),
            ]
            let enSamples: [Sample] = [
                (.formalWriting, "um so let's move tomorrow's three pm meeting to four and tell the design team", "Let's move tomorrow's 3 PM meeting to 4 and let the design team know.", 60 * 4),
                (.quick, "I'm downstairs you can just come down", "I'm downstairs, you can just come down.", 60 * 37),
                (.translation, "这个版本先不发，等测试把问题都过一遍", "Let's hold this release until QA has gone through all the issues.", 60 * 90),
                (.agentMode, "reply to him saying I'll finish the doc and send it before tonight", "Sure, I'll finish the doc and send it to you tonight.", 60 * 60 * 5),
                (.quick, "want to go hiking this weekend the weather looks nice", "Want to go hiking this weekend? The weather looks nice.", 60 * 60 * 26),
                (.formalWriting, "today's key points first login flow second paywall third push notifications", "Today's key points:\n1. Login flow\n2. Paywall\n3. Push notifications", 60 * 60 * 30),
            ]
            let samples = zh ? zhSamples : enSamples
            for (mode, raw, final, ago) in samples.reversed() {
                var entry = HistoryEntry(mode: mode, rawText: raw, finalText: final, delivered: .inserted)
                entry.date = Date().addingTimeInterval(-ago)
                model.history.add(entry)
            }
        }
        // `T4M_IMPORT_FILE` opens the import page with the setup in that file;
        // `T4M_SCAN_FILE` opens the scanner fed with its lines (see
        // ConfigScannerSheet). Files live in the App Group's Library.
        if let text = debugFile("T4M_IMPORT_FILE"), let payload = try? Type4MeTransferCodec.decode(text) {
            model.pendingImport = PendingImport(payload: payload)
        }
        if debugFile("T4M_SCAN_FILE") != nil { model.showsScanner = true }
        switch ProcessInfo.processInfo.environment["T4M_TAB"] {
        case "history": model.tab = .history
        case "settings": model.tab = .settings
        default: break
        }
    }
}
#endif
