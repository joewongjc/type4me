import AppKit
import SwiftUI
import Type4MeIntelliSenseCore
import UniformTypeIdentifiers

extension Notification.Name {
    static let intelliSenseExpressionDataCleared = Notification.Name(
        "Type4Me.intelliSenseExpressionDataCleared"
    )
}

struct IntelliSenseModeDetail: View, SettingsCardHelpers {
    let mode: ProcessingMode
    let onEditBinding: (HotkeyBinding) -> Void
    let onDeleteBinding: (HotkeyBinding) -> Void
    let onAddBinding: () -> Void

    @State private var settings = IntelliSenseSettings()
    @State private var isLoaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            modeHeader

            HotkeySectionView(
                bindings: mode.hotkeyBindings,
                onEdit: onEditBinding,
                onDelete: onDeleteBinding,
                onAdd: onAddBinding
            )

            settingsGroupCard(L("感知能力", "Awareness"), icon: "sparkles") {
                awarenessToggle(
                    L("应用感知", "Application Awareness"),
                    subtitle: L(
                        "根据当前 App 和输入控件选择合适的语气、长度和格式。",
                        "Use the current app and input control to choose tone, length, and formatting."
                    ),
                    keyPath: \.applicationAwarenessEnabled
                )
                SettingsDivider()
                awarenessToggle(
                    L("上下文感知", "Context Awareness"),
                    subtitle: L(
                        "读取光标附近的有限文字以匹配称呼、术语和语气；终端和开发工具不会读取正文。",
                        "Read limited nearby text to match names, terms, and tone. Terminal and development text is excluded."
                    ),
                    keyPath: \.contextAwarenessEnabled
                )
                SettingsDivider()
                awarenessToggle(
                    L("表达习惯感知", "Expression Learning"),
                    subtitle: L(
                        "在本地短暂观察智能感知输出后的修改，并可把最后修改结果保存到对应历史；只学习抽象表达特征，不保存自然语言画像。",
                        "Locally observe edits after Intelli Sense output and save the last edit with its history record; only abstract style features are learned, never a natural-language profile."
                    ),
                    keyPath: \.expressionLearningEnabled
                )
                SettingsDivider()
                awarenessToggle(
                    L("纠错词检测（Beta）", "Correction Detection (Beta)"),
                    subtitle: L(
                        "在本地短暂观察智能感知输出后的修改，最后修改结果可保存到历史；纠错词经你确认后才加入全局生词表。",
                        "Locally observe edits after Intelli Sense output and save the last edit with its history record; a correction joins global vocabulary only after you confirm it."
                    ),
                    keyPath: \.correctionDetectionEnabled
                )
            }

            blacklistSection
            expressionDataSection

            if let statusMessage {
                Text(statusMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextSecondary)
            }
        }
        .padding(.bottom, 8)
        .opacity(isLoaded ? 1 : 0.65)
        .task { await loadSettings() }
        .onDisappear {
            saveTask?.cancel()
            let snapshot = settings
            Task { try? await IntelliSenseSettingsStore.shared.save(snapshot) }
        }
    }

    private var modeHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(TF.settingsAccentAmber)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(TF.settingsCardAlt)
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(mode.localizedDisplayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(TF.settingsText)

                    Text(L("内置", "Built-in"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TF.settingsTextTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(TF.settingsCardAlt))
                }

                Text(mode.localizedDisplayDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextSecondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(.bottom, 4)
    }

    private func awarenessToggle(
        _ title: String,
        subtitle: String,
        keyPath: WritableKeyPath<IntelliSenseSettings, Bool>
    ) -> some View {
        settingsToggleRow(
            title,
            subtitle: subtitle,
            isOn: Binding(
                get: { settings[keyPath: keyPath] },
                set: { value in
                    settings[keyPath: keyPath] = value
                    scheduleSave()
                }
            )
        )
    }

    private var blacklistSection: some View {
        settingsGroupCard(
            L("App 黑名单", "App Blacklist"),
            icon: "hand.raised.fill",
            trailing: AnyView(
                Button(action: chooseApplication) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TF.settingsText)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
                }
                .buttonStyle(.plain)
                .settingsTooltip(L("添加 App", "Add App"))
            )
        ) {
            if settings.blacklistedApps.isEmpty {
                Text(L(
                    "黑名单中的 App 不进行应用、上下文、纠错或表达习惯感知。",
                    "Blacklisted apps never use application, context, correction, or expression awareness."
                ))
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 8)
            } else {
                ForEach(Array(settings.blacklistedApps.enumerated()), id: \.element.id) { index, app in
                    HStack(spacing: 10) {
                        Image(systemName: "app.fill")
                            .foregroundStyle(TF.settingsTextTertiary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(app.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(TF.settingsText)
                            Text(app.bundleIdentifier)
                                .font(.system(size: 10))
                                .foregroundStyle(TF.settingsTextTertiary)
                        }
                        Spacer()
                        Button {
                            settings.blacklistedApps.removeAll { $0.id == app.id }
                            scheduleSave()
                        } label: {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                                .foregroundStyle(TF.settingsAccentRed)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.vertical, 7)
                    if index < settings.blacklistedApps.count - 1 {
                        SettingsDivider()
                    }
                }
            }
        }
    }

    private var expressionDataSection: some View {
        settingsGroupCard(L("表达习惯数据", "Expression Data"), icon: "person.crop.circle.badge.clock") {
            settingsOptionRow(
                L("清除表达习惯数据", "Clear Expression Data"),
                subtitle: L(
                    "清除后台表达模型并记录重算水位；不删除历史记录或已经确认的全局生词。",
                    "Clear the background expression model and set its rebuild watermark; history and confirmed global vocabulary remain."
                ),
                controlWidth: 120
            ) {
                Button(L("清除", "Clear"), action: clearExpressionData)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private func loadSettings() async {
        settings = await IntelliSenseSettingsStore.shared.load()
        isLoaded = true
    }

    private func scheduleSave() {
        statusMessage = nil
        saveTask?.cancel()
        let snapshot = settings
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            do {
                settings = try await IntelliSenseSettingsStore.shared.save(snapshot)
            } catch {
                statusMessage = L("设置保存失败", "Failed to save settings")
            }
        }
    }

    private func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = L("选择要加入黑名单的 App", "Choose an app to blacklist")
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        guard panel.runModal() == .OK,
              let url = panel.url,
              let bundle = Bundle(url: url),
              let bundleIdentifier = bundle.bundleIdentifier,
              bundleIdentifier != Bundle.main.bundleIdentifier
        else { return }

        let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        settings.blacklistedApps.removeAll {
            $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
        }
        settings.blacklistedApps.append(BlacklistedApp(
            bundleIdentifier: bundleIdentifier,
            displayName: displayName
        ))
        settings.blacklistedApps.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        scheduleSave()
    }

    private func clearExpressionData() {
        Task {
            do {
                try await ExpressionProfileStore.shared.clear()
                NotificationCenter.default.post(name: .intelliSenseExpressionDataCleared, object: nil)
                statusMessage = L("表达习惯数据已清除", "Expression data cleared")
            } catch {
                statusMessage = L("表达习惯数据清除失败", "Failed to clear expression data")
            }
        }
    }
}
