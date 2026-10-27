import SwiftUI
import Type4MeTransferCore

/// Pages under Settings. Value based, so Home can open one directly.
enum SettingsRoute: Hashable {
    case asr, llm, modes, hotwords, snippets, appIcon, diagnostics

    @MainActor @ViewBuilder var destination: some View {
        switch self {
        case .asr: ASRSettingsView()
        case .llm: LLMSettingsView()
        case .modes: ModeSettingsView()
        case .hotwords: HotwordSettingsView()
        case .snippets: SnippetSettingsView()
        case .appIcon: AppIconSettingsView()
        case .diagnostics: DiagnosticsView()
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var session: VoiceSession
    @EnvironmentObject private var log: DiagnosticsLog
    @EnvironmentObject private var history: HistoryStore
    @ObservedObject private var modes = ModeStore.shared
    @ObservedObject private var vocabulary = VocabularyStore.shared
    @ObservedObject private var appIcon = AppIconStore.shared

    @State private var timeout = AppSettings.sessionTimeoutMinutes
    @State private var keyHaptics = SharedSettings.keyHaptics
    @State private var keySounds = SharedSettings.keySounds
    @State private var intelliSenseContext = SharedSettings.intelliSenseContext
    @State private var confirmClear = false
    @State private var confirmClearHistory = false
    @State private var language = AppLanguage.override?.rawValue ?? "system"
    @State private var cjkSpacing = TextOutputSettings.cjkSpacing
    @State private var trailingPunctuation = TextOutputSettings.trailingPunctuation
    @State private var cornerQuotes = TextOutputSettings.cornerQuotes

    var body: some View {
        Form {
            Section {
                NavigationLink(value: SettingsRoute.asr) {
                    serviceRow(
                        symbol: "waveform",
                        title: L("识别服务", "Speech Service"),
                        value: ConfigStore.asr.map(asrSummary),
                        ok: SharedSettings.asrConfigured
                    )
                }
                NavigationLink(value: SettingsRoute.llm) {
                    serviceRow(
                        symbol: "text.bubble",
                        title: L("处理模型", "Text Model"),
                        value: ConfigStore.llm.map { "\(ProviderNames.llm($0.provider)) · \($0.fields["model"] ?? "")" },
                        ok: SharedSettings.llmConfigured
                    )
                }
            } header: {
                Text(L("识别与处理", "Speech & Text"))
            } footer: {
                Text(serviceFooter)
            }

            MyModesSection()

            Section {
                NavigationLink(value: SettingsRoute.hotwords) {
                    LabeledContent(L("热词", "Hotwords")) {
                        Text(L("\(vocabulary.hotwords.count) 个", "\(vocabulary.hotwords.count)"))
                    }
                }
                NavigationLink(value: SettingsRoute.snippets) {
                    LabeledContent(L("片段替换", "Snippets")) {
                        Text(L("\(vocabulary.snippets.count) 条", "\(vocabulary.snippets.count)"))
                    }
                }
            } header: {
                Text(L("词汇", "Vocabulary"))
            } footer: {
                Text(L(
                    "热词帮识别服务认准专有名词，片段替换把说出的触发词换成固定内容。",
                    "Hotwords help the speech service get names and terms right; snippets swap a spoken trigger for fixed text."
                ))
            }

            Section {
                Picker(L("盘古之白", "Pangu Spacing"), selection: $cjkSpacing) {
                    ForEach(CJKSpacingMode.allCases, id: \.self) { Text(TextOutputSettings.name($0)).tag($0) }
                }
                Picker(L("去句末标点", "Strip Trailing Punctuation"), selection: $trailingPunctuation) {
                    ForEach([TrailingPunctuationMode.off, .period, .all], id: \.self) { Text(TextOutputSettings.name($0)).tag($0) }
                }
                Toggle(L("用『』代替‘’", "Use 『』 for ‘’"), isOn: $cornerQuotes)
            } header: {
                Text(L("文本输出", "Text Output"))
            } footer: {
                Text(L(
                    "盘古之白会在中文和英文、数字之间加空格。每个模式还能在模式设置里单独指定标点。",
                    "Pangu spacing puts a space between Chinese and Latin letters or digits. Each mode can also set its own punctuation in its settings."
                ))
            }

            Section {
                Button { model.showsScanner = true } label: {
                    actionRow(
                        symbol: "qrcode.viewfinder",
                        title: L("扫码同步", "Scan to Sync"),
                        detail: L(
                            "在 Mac 版 Type4Me 的侧边栏打开「手机版」，对准二维码",
                            "In Type4Me on your Mac, open Mobile in the sidebar and point at the code"
                        )
                    )
                }
            } header: {
                Text(L("从 Mac 同步", "Sync from Mac"))
            } footer: {
                Text(L(
                    "识别服务、处理模型、模式、词汇和文本输出都可以从 Mac 同步。",
                    "Speech services, text models, modes, vocabulary and text output can all sync from your Mac."
                ))
            }

            Section {
                Toggle(L("按键震动", "Key Haptics"), isOn: $keyHaptics)
                    .onChange(of: keyHaptics) { _, on in SharedSettings.keyHaptics = on }
                Toggle(L("按键音", "Key Sounds"), isOn: $keySounds)
                    .onChange(of: keySounds) { _, on in SharedSettings.keySounds = on }
            } header: {
                Text(L("键盘", "Keyboard"))
            }

            Section {
                Picker(L("闲置多久后结束", "End After Idle"), selection: $timeout) {
                    Text(L("15 分钟", "15 min")).tag(15)
                    Text(L("1 小时", "1 hour")).tag(60)
                    Text(L("4 小时", "4 hours")).tag(240)
                    Text(L("一直待命", "Always On")).tag(0)
                }
            } header: {
                Text(L("后台待命", "Background Standby"))
            }

            Section {
                Toggle(L("读取输入框上下文", "Read Field Context"), isOn: $intelliSenseContext)
                    .onChange(of: intelliSenseContext) { _, on in SharedSettings.intelliSenseContext = on }
                if !AppSettings.aiConsentKeys.isEmpty {
                    Button(L("撤回第三方 AI 服务授权", "Withdraw Third-Party AI Permission"), role: .destructive) {
                        model.revokeAIConsent()
                    }
                }
            } header: {
                Text(L("隐私", "Privacy"))
            } footer: {
                Text(privacyFooter)
            }

            Section(L("通用", "General")) {
                Picker(L("语言", "Language"), selection: $language) {
                    Text(L("跟随系统", "System")).tag("system")
                    Text("中文").tag(AppLanguage.zh.rawValue)
                    Text("English").tag(AppLanguage.en.rawValue)
                }
                if appIcon.isSupported {
                    NavigationLink(value: SettingsRoute.appIcon) {
                        LabeledContent(L("应用图标", "App Icon"), value: appIcon.current.title)
                    }
                }
                Button(L("打开系统设置", "Open iOS Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }

            Section(L("关于", "About")) {
                Link(L("帮助与反馈", "Help & Feedback"), destination: AppLinks.support)
                Link(L("隐私政策", "Privacy Policy"), destination: AppLinks.privacyPolicy)
                NavigationLink(L("诊断记录", "Diagnostics"), value: SettingsRoute.diagnostics)
                LabeledContent(L("版本", "Version"), value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
            }

            Section(L("清除数据", "Erase Data")) {
                Button(L("清空历史", "Clear History"), role: .destructive) { confirmClearHistory = true }
                Button(L("删除识别、处理配置和模式", "Delete Speech, Text Setup & Modes"), role: .destructive) { confirmClear = true }
                    .disabled(ConfigStore.asr == nil && ConfigStore.llm == nil && modes.isDefault)
            }
        }
        .scrollContentBackground(.hidden)
        .background(DottedCanvas())
        .navigationTitle(L("设置", "Settings"))
        // Re-read the Keychain-backed rows after an import or an edit.
        .id(model.configVersion)
        .onChange(of: timeout) { _, value in AppSettings.sessionTimeoutMinutes = value }
        .onChange(of: language) { _, value in model.setLanguage(AppLanguage(rawValue: value)) }
        .onChange(of: cjkSpacing) { _, value in TextOutputSettings.cjkSpacing = value }
        .onChange(of: trailingPunctuation) { _, value in TextOutputSettings.trailingPunctuation = value }
        .onChange(of: cornerQuotes) { _, value in TextOutputSettings.cornerQuotes = value }
        .alert(L("清空全部历史？", "Clear all history?"), isPresented: $confirmClearHistory) {
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("清空", "Clear"), role: .destructive) { history.clear() }
        } message: {
            Text(L("这台 iPhone 上的所有听写记录都会删除，无法恢复。", "Every dictation on this iPhone will be deleted. This can't be undone."))
        }
        .alert(L("删除识别、处理配置和模式？", "Delete the speech and text setup and modes?"), isPresented: $confirmClear) {
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("删除", "Delete"), role: .destructive) {
                session.endSession(reason: L("删除配置", "setup deleted"))
                ConfigStore.clearAll()
                modes.resetToDefaults()
                // Bring the import card back on Home for the next setup.
                AppSettings.syncedFromMac = false
                model.configVersion += 1
            }
        } message: {
            Text(L(
                "识别服务和处理模型的密钥会从这台 iPhone 上删除；自己建的和从 Mac 同步的模式也会删除，内置模式恢复默认。之后需要重新填写或从 Mac 同步。",
                "The speech service and text model keys will be removed from this iPhone. Modes you made or synced from your Mac are deleted too, and the built-in modes go back to their defaults. You'll need to set things up again or sync from your Mac."
            ))
        }
    }

    private func asrSummary(_ endpoint: Type4MeTransferPayload.Endpoint) -> String {
        let summary = PhoneASR.summary(for: endpoint)
        let name = ProviderNames.asr(endpoint.provider)
        return summary.isEmpty ? name : "\(name) · \(summary)"
    }

    private var privacyFooter: String {
        let context = L(
            "打开后，光标前后的少量文字（前 300 字、后 100 字）会一起发给处理模型，帮助校正专有词和语气。密码、验证码、银行卡输入框不读取。",
            "When on, a little text around the cursor (300 characters before, 100 after) goes to the text model with your words, to get names and tone right. Password, one-time-code and card fields are never read."
        )
        guard !AppSettings.aiConsentKeys.isEmpty else { return context }
        return context + L(
            "撤回授权会关闭语音会话，下次听写前重新询问。",
            " Withdrawing ends the voice session; you'll be asked again before the next dictation."
        )
    }

    private var serviceFooter: String {
        guard let meta = ConfigStore.meta else {
            return L("可以直接在这里填写，也可以从 Mac 导入。每项里都能测试连接。", "Fill them in here or import them from your Mac. Each one has a connection test.")
        }
        let locale = AppLanguage.current.locale
        if let edited = meta.editedAt {
            let date = edited.formatted(.dateTime.month(.defaultDigits).day().hour().minute().locale(locale))
            return L("\(date) 在 iPhone 上修改。", "Edited on this iPhone · \(date).")
        }
        let source = meta.sourceName ?? "Mac"
        let date = meta.importedAt.formatted(.dateTime.month(.defaultDigits).day().hour().minute().locale(locale))
        return L("\(source) · \(date) 导入。", "Imported from \(source) · \(date).")
    }

    private func serviceRow(symbol: String, title: String, value: String?, ok: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(T4.ink)
                .frame(width: 30, height: 30)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(T4.ink)
                Text(value ?? L("未配置", "Not set up"))
                    .font(.system(size: 13))
                    .foregroundStyle(T4.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Circle()
                .fill(ok ? T4.success : T4.ink.opacity(0.18))
                .frame(width: 8, height: 8)
                .accessibilityLabel(ok ? L("已配置", "Set up") : L("未配置", "Not set up"))
        }
    }

    private func actionRow(symbol: String, title: String, detail: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(T4.ink)
                .frame(width: 30, height: 30)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(T4.ink)
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(T4.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(T4.tertiary)
        }
        .contentShape(Rectangle())
    }
}

/// The keyboard's default mode, moved here from Home. Picks among the modes
/// on the keyboard; the keyboard's top bar still switches at any time.
struct MyModesSection: View {
    @ObservedObject private var modes = ModeStore.shared
    @State private var selected = SharedSettings.selectedMode

    var body: some View {
        Section {
            ForEach(DictationMode.keyboardOrder) { mode in
                row(mode)
            }
        } header: {
            HStack {
                Text(L("我的模式", "My Modes"))
                Spacer()
                NavigationLink(L("管理", "Manage"), value: SettingsRoute.modes)
                    .font(.system(size: 13, weight: .medium))
                    .textCase(nil)
            }
        } footer: {
            Text(L("键盘默认用哪个，也可以在键盘顶部随时切换。", "Choose the keyboard's default. You can switch anytime at the top of the keyboard."))
        }
        .onAppear { selected = SharedSettings.selectedMode }
        .onChange(of: modes.modes) { _, _ in selected = SharedSettings.selectedMode }
    }

    private func row(_ mode: DictationMode) -> some View {
        let available = !mode.usesLLM || SharedSettings.llmConfigured
        // The keyboard falls back to 快速 when the text model is missing.
        let effective = (!selected.usesLLM || SharedSettings.llmConfigured) ? selected : .quick
        let isSelected = effective == mode
        return Button {
            guard available else { return }
            SharedSettings.selectedMode = mode
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { selected = mode }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: mode.symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(T4.ink.opacity(available ? 1 : 0.4))
                    .frame(width: 34, height: 34)
                    .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(mode.title)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(T4.ink.opacity(available ? 1 : 0.4))
                        T4Badge(text: mode.kind == .custom ? L("自定义", "Custom") : L("内置", "Built-in"))
                    }
                    Text(available ? mode.summary : L("需要先导入处理模型", "Import a text model first"))
                        .font(.system(size: 12))
                        .foregroundStyle(T4.tertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21))
                    .foregroundStyle(isSelected ? T4.ink : T4.ink.opacity(0.2))
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject private var log: DiagnosticsLog

    var body: some View {
        List {
            ForEach(log.lines) { line in
                VStack(alignment: .leading, spacing: 2) {
                    Text(line.date, style: .time).font(.system(size: 11)).foregroundStyle(T4.secondary)
                    Text(line.text).font(.system(size: 14))
                }
            }
        }
        .navigationTitle(L("诊断记录", "Diagnostics"))
        .toolbar {
            Button(L("复制", "Copy")) { UIPasteboard.general.string = log.exportText }
        }
        .overlay {
            if log.lines.isEmpty { Text(L("还没有记录", "Nothing logged yet")).foregroundStyle(T4.secondary) }
        }
    }
}
