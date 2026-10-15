import SwiftUI
import AppKit

struct MagpieProviderSection: View, SettingsCardHelpers {
    @ObservedObject var statusModel: MagpieProviderStatusModel
    @Binding var draftModel: String

    @AppStorage("tf_disableThinking") private var disableThinking: Bool = true
    @State private var isPluginGuideExpanded: Bool = false
    @State private var copiedInstallCmd: Bool = false
    @State private var copiedInstallShellCmd: Bool = false

    private var currentCatalogEntry: MagpieModelCatalog.Entry? {
        statusModel.catalog.first(where: { $0.id == draftModel })
    }

    private var lowestReasoningLevel: String? {
        guard let entry = currentCatalogEntry else { return nil }
        return MagpieModelCatalog.findLowestReasoningEffort(in: entry.reasoningLevels)
    }

    var body: some View {
        VStack(spacing: 0) {
            agentIssueBannerIfNeeded

            switch statusModel.state {
            case .notInstalled:
                notInstalledView
            case .installedNotRunning:
                installedNotRunningView
            case .managedOffline:
                managedOfflineView
            case .directOnline(let version):
                directOnlineView(version: version)
            case .managedOnline(let version):
                managedOnlineView(version: version)
            }

            if draftModel.hasPrefix("group/") {
                SettingsDivider()
                routingGroupWarning
            }
        }
    }

    // MARK: - Warnings and Issue Banners

    @ViewBuilder
    private var agentIssueBannerIfNeeded: some View {
        if let issue = statusModel.connection.agentFileIssue {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(TF.settingsAccentAmber)
                        .font(.system(size: 13))

                    switch issue {
                    case .unreadable, .incomplete:
                        Text(L(
                            "Magpie 接入文件无法读取，已按直连模式处理。",
                            "Can't read the Magpie connection file, so Type4Me is connecting directly."
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsText)

                        Spacer()

                        Button(L("在 Finder 中显示", "Show in Finder")) {
                            NSWorkspace.shared.activateFileViewerSelecting([MagpieAgentFile.defaultURL])
                        }
                        .buttonStyle(SettingsListRowButtonStyle())
                        .font(.system(size: 11))

                    case .nonLoopback:
                        Text(L(
                            "接入文件中的网关地址不是本机地址，已忽略。",
                            "The gateway address in the connection file isn't on this Mac, so it was ignored."
                        ))
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsText)

                        Spacer()

                    case .absent, .managed:
                        EmptyView()
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(TF.settingsAccentAmber.opacity(0.12))
            )
            .padding(.bottom, 8)

            SettingsDivider()
        }
    }

    private var routingGroupWarning: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .font(.system(size: 11))
                .foregroundStyle(TF.settingsAccentBlue)
                .padding(.top, 1)

            Text(L(
                "这是 Magpie 路由组，实际使用的模型由 Magpie 按规则选择，响应速度可能不稳定。",
                "This is a Magpie routing group. Magpie picks the model by its rules, so response time may vary."
            ))
            .font(.system(size: 11))
            .foregroundStyle(TF.settingsTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }

    // MARK: - State D3: Not Installed

    private var notInstalledView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L(
                "Magpie 是一个本机模型网关，可以让 Type4Me 使用你在 Magpie 中登录的订阅或 API Key，并和其他 Agent 一起切换模型、统计用量。",
                "Magpie is a local model gateway. Type4Me can use the subscriptions and API keys you set up in Magpie, and switch models and track usage alongside your other agents."
            ))
            .font(.system(size: 12))
            .foregroundStyle(TF.settingsTextSecondary)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text("curl -fsSL https://usemagpie.ai/install.sh | sh")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TF.settingsText)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(TF.settingsCardAlt)
                    )

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("curl -fsSL https://usemagpie.ai/install.sh | sh", forType: .string)
                    copiedInstallShellCmd = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        copiedInstallShellCmd = false
                    }
                } label: {
                    Text(copiedInstallShellCmd ? L("已复制", "Copied") : L("复制", "Copy"))
                        .font(.system(size: 11, weight: .medium))
                }
                .buttonStyle(SettingsListRowButtonStyle())
            }
        }
        .padding(.vertical, 8)
    }

    // MARK: - State D2: Installed Not Running

    private var installedNotRunningView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(TF.settingsTextTertiary)
                    .frame(width: 8, height: 8)
                Text(L("Magpie 已安装但未运行", "Magpie is installed but not running"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.settingsTextSecondary)
                Spacer()
            }
            .padding(.vertical, 8)

            SettingsDivider()

            settingsOptionRow(L("模型", "Model")) {
                Text(draftModel.isEmpty ? L("未选择模型", "No model selected") : draftModel)
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    // MARK: - State T2: Managed Offline

    private var managedOfflineView: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(TF.settingsTextTertiary)
                    .frame(width: 8, height: 8)
                Text(L("Magpie 未运行", "Magpie isn't running"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.settingsTextSecondary)
                Spacer()
            }
            .padding(.vertical, 8)

            SettingsDivider()

            settingsOptionRow(L("模型", "Model")) {
                Text(statusModel.connection.model)
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    // MARK: - State D1: Direct Online

    private func directOnlineView(version: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(TF.settingsAccentGreen)
                    .frame(width: 8, height: 8)
                Text(String(format: L("Magpie 正在运行（%@）", "Magpie is running (%@)"), version))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.settingsText)
                Spacer()
            }
            .padding(.vertical, 8)

            SettingsDivider()

            modelPickerRow

            if lowestReasoningLevel != nil {
                SettingsDivider()
                thinkingToggleRow
            }

            SettingsDivider()

            privacyNoticeRow

            SettingsDivider()

            pluginGuideRow
        }
    }

    // MARK: - State T1: Managed Online

    private func managedOnlineView(version: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(TF.settingsAccentGreen)
                    .font(.system(size: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("已与 Magpie 同步", "Synced with Magpie"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TF.settingsText)
                    Text(L("在这里或 Magpie 菜单栏切换模型都会同步", "Switching the model here or in Magpie's menu bar keeps both in sync"))
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsTextSecondary)
                }
                Spacer()
            }
            .padding(.vertical, 8)

            SettingsDivider()

            modelPickerRow

            SettingsDivider()

            settingsOptionRow(L("网关", "Gateway")) {
                Text(statusModel.connection.baseURL.absoluteString)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(TF.settingsTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }

            if lowestReasoningLevel != nil {
                SettingsDivider()
                thinkingToggleRow
            }

            SettingsDivider()

            privacyNoticeRow
        }
    }

    // MARK: - Common Subviews

    private var modelPickerRow: some View {
        settingsOptionRow(L("模型", "Model")) {
            let groups = statusModel.catalog.filter(\.isGroup)
            let regular = statusModel.catalog.filter { !$0.isGroup }

            Picker("", selection: $draftModel) {
                if !groups.isEmpty {
                    Section(header: Text(L("路由组", "Routing Groups"))) {
                        ForEach(groups, id: \.id) { item in
                            Text(item.label ?? item.id).tag(item.id)
                        }
                    }
                }

                if !regular.isEmpty {
                    Section(header: Text(L("模型", "Models"))) {
                        ForEach(regular, id: \.id) { item in
                            Text(item.label ?? item.id).tag(item.id)
                        }
                    }
                }

                if !draftModel.isEmpty && !statusModel.catalog.contains(where: { $0.id == draftModel }) {
                    Text(draftModel).tag(draftModel)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .frame(maxWidth: 320, alignment: .trailing)
        }
    }

    private var thinkingToggleRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            settingsOptionRow(L("关闭思考", "Disable Thinking")) {
                Toggle("", isOn: $disableThinking)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .controlSize(.small)
            }

            if let level = lowestReasoningLevel {
                Text(String(format: L("使用该模型支持的最低推理档位，降低延迟。（%@）", "Uses the lowest reasoning level this model supports, to cut latency. (%@)"), level))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .padding(.horizontal, 2)
            }
        }
        .padding(.vertical, 4)
    }

    private var privacyNoticeRow: some View {
        Text(L(
            "文本会经 Magpie 转发给你在 Magpie 中为该模型配置的服务商。",
            "Text is sent through Magpie to the provider you set up for this model in Magpie."
        ))
        .font(.system(size: 10))
        .foregroundStyle(TF.settingsTextTertiary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6)
    }

    private var pluginGuideRow: some View {
        DisclosureGroup(
            isExpanded: $isPluginGuideExpanded,
            content: {
                VStack(alignment: .leading, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L("① 安装 Type4Me 插件", "① Install the Type4Me plugin"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(TF.settingsText)

                        HStack(spacing: 8) {
                            Text(MagpieInstallation.agentPluginInstallCommand)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(TF.settingsText)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(TF.settingsCardAlt)
                                )

                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(MagpieInstallation.agentPluginInstallCommand, forType: .string)
                                copiedInstallCmd = true
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                    copiedInstallCmd = false
                                }
                            } label: {
                                Text(copiedInstallCmd ? L("已复制", "Copied") : L("复制", "Copy"))
                                    .font(.system(size: 10, weight: .medium))
                            }
                            .buttonStyle(SettingsListRowButtonStyle())
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(L("② 在 Magpie 的 Agent 页为 Type4Me 选择模型", "② Pick a model for Type4Me on Magpie's Agents page"))
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(TF.settingsText)

                            Spacer()

                            Button(L("打开 Magpie", "Open Magpie")) {
                                MagpieInstallation.openApp()
                            }
                            .buttonStyle(SettingsListRowButtonStyle())
                            .font(.system(size: 10))
                        }
                    }

                    Text(L("完成后此页面会自动切换为“已与 Magpie 同步”。", "This page switches to \"Synced with Magpie\" on its own when you're done."))
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsTextTertiary)
                        .padding(.top, 2)
                }
                .padding(.top, 6)
                .padding(.bottom, 4)
            },
            label: {
                Text(L("想在 Magpie 菜单栏切换 Type4Me 的模型？", "Want to switch Type4Me's model from Magpie's menu bar?"))
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(TF.settingsAccentBlue)
            }
        )
        .padding(.vertical, 6)
    }
}
