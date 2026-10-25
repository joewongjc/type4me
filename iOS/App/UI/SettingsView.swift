import SwiftUI
import Type4MeTransferCore

/// Pages under Settings. Value based, so Home can open one directly.
enum SettingsRoute: Hashable {
    case asr, llm, modes, diagnostics

    @MainActor @ViewBuilder var destination: some View {
        switch self {
        case .asr: ASRSettingsView()
        case .llm: LLMSettingsView()
        case .modes: ModeSettingsView()
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

    @State private var timeout = AppSettings.sessionTimeoutMinutes
    @State private var confirmClear = false
    @State private var confirmClearHistory = false
    @State private var language = AppLanguage.override?.rawValue ?? "system"

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

            Section {
                Button { model.showsScanner = true } label: {
                    actionRow(
                        symbol: "qrcode.viewfinder",
                        title: L("扫码同步", "Scan to Sync"),
                        detail: L(
                            "在 Mac 版 Type4Me 打开「设置 › 模型 › 同步到 iPhone」，对准二维码",
                            "In Type4Me on your Mac, open Settings › Models › Sync to iPhone and point at the code"
                        )
                    )
                }
            } header: {
                Text(L("从 Mac 同步", "Sync from Mac"))
            } footer: {
                Text(L(
                    "内容多时 Mac 会轮播几张码，保持对准直到扫齐。导入前还可以再挑选要同步的内容。",
                    "Larger setups cycle through several codes on the Mac; keep pointing until all are in. You can choose what to import before saving."
                ))
            }

            Section {
                NavigationLink(value: SettingsRoute.modes) {
                    LabeledContent(L("模式", "Modes")) {
                        Text(L("键盘上 \(modes.keyboardCount) 个，共 \(modes.modes.count) 个", "\(modes.keyboardCount) on keyboard, \(modes.modes.count) total"))
                    }
                }
            } header: {
                Text(L("模式", "Modes"))
            } footer: {
                Text(L("新建、改名、调整顺序，并选择最多 \(ModeLibrary.keyboardLimit) 个放到键盘上。", "Add, rename and reorder modes, and pick up to \(ModeLibrary.keyboardLimit) for the keyboard."))
            }

            Section {
                Picker(L("无操作后自动关闭", "Auto-End When Idle"), selection: $timeout) {
                    Text(L("15 分钟", "15 min")).tag(15)
                    Text(L("1 小时", "1 hour")).tag(60)
                    Text(L("4 小时", "4 hours")).tag(240)
                    Text(L("不自动关闭", "Never")).tag(0)
                }
            } header: {
                Text(L("语音会话", "Voice Session"))
            } footer: {
                Text(L(
                    "只在按住说话时打开麦克风，松开就关，其他时候状态栏没有麦克风提示，也不用跳回 App。",
                    "The mic opens only while you hold to talk and closes when you let go. No mic indicator the rest of the time, and no trip back to the app."
                ))
            }

            Section(L("通用", "General")) {
                Picker(L("语言", "Language"), selection: $language) {
                    Text(L("跟随系统", "System")).tag("system")
                    Text("中文").tag(AppLanguage.zh.rawValue)
                    Text("English").tag(AppLanguage.en.rawValue)
                }
                Button(L("打开系统设置", "Open iOS Settings")) {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                NavigationLink(L("诊断记录", "Diagnostics"), value: SettingsRoute.diagnostics)
                LabeledContent(L("版本", "Version"), value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")
            }

            Section {
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
                AppSettings.importCardDismissed = false
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
