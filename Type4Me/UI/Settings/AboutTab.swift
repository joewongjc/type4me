import SwiftUI

struct AboutTab: View {

    @Environment(AppState.self) private var appState
    @Environment(AppUpdater.self) private var appUpdater

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                label: "ABOUT",
                title: L("关于 Type4Me", "About Type4Me"),
                description: L("语音，流畅输入。基于火山引擎大模型语音识别的 macOS 原生输入工具。", "Voice to text, seamlessly. A native macOS input tool powered by large-model ASR.")
            )

            Spacer().frame(height: 8)

            // App info rows
            SettingsRow(label: L("版本", "Version"), value: appVersion)
            SettingsDivider()
            SettingsRow(label: L("构建", "Build"), value: buildNumber)
            SettingsDivider()
            SettingsRow(label: L("平台", "Platform"), value: "macOS 14+")
            SettingsDivider()
            SettingsRow(label: L("许可证", "License"), value: "MIT")

            Spacer().frame(height: 24)

            // Update check
            updateSection

            Spacer().frame(height: 24)

            // Links
            HStack(spacing: 12) {
                linkButton("GitHub", icon: "chevron.left.forwardslash.chevron.right") {
                    if let url = URL(string: "https://github.com/joewongjc/type4me") {
                        NSWorkspace.shared.open(url)
                    }
                }
                linkButton(L("反馈", "Feedback"), icon: "envelope") {
                    if let url = URL(string: "https://github.com/joewongjc/type4me/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }

            Spacer()

            // Footer
            Text("Made with ♥ and Claude Code")
                .font(.system(size: 10))
                .foregroundStyle(TF.settingsTextTertiary)
        }
    }

    // MARK: - Update Section

    @ViewBuilder
    private var updateSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("软件更新", "Software Update"))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TF.settingsText)

                Spacer()

                if appState.isCheckingUpdate {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button {
                        Task {
                            await UpdateChecker.shared.checkNow(appState: appState)
                        }
                    } label: {
                        Text(L("检查更新", "Check for Updates"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(TF.settingsText)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6).fill(TF.settingsBg)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6)
                                    .stroke(TF.settingsTextTertiary.opacity(0.2), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                }
            }

            if appState.availableUpdates.isEmpty && !appState.isCheckingUpdate {
                if appState.lastUpdateCheck != nil {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                            .font(.system(size: 12))
                        Text(L("已是最新版本", "You're up to date"))
                            .font(.system(size: 12))
                            .foregroundStyle(TF.settingsTextSecondary)
                    }
                }
            } else if !appState.availableUpdates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(appState.availableUpdates) { update in
                        updateCard(update)
                    }
                }

                // Update action area
                updateActionArea

                // GitHub link as secondary option
                Button {
                    if let url = URL(string: "https://github.com/joewongjc/type4me/releases") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label(L("在 GitHub 上查看", "View on GitHub"), systemImage: "arrow.up.right")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Update Action Area

    @ViewBuilder
    private var updateActionArea: some View {
        switch appUpdater.state {
        case .idle:
            if let latest = appState.availableUpdates.first {
                let sizeText = latest.formattedSize.map { " (\($0))" } ?? ""
                Button {
                    appUpdater.downloadUpdate(release: latest)
                } label: {
                    Label(
                        L("下载更新\(sizeText)", "Download Update\(sizeText)"),
                        systemImage: "arrow.down.circle"
                    )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.blue))
                }
                .buttonStyle(.plain)
            }

        case .downloading(let progress):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    ProgressView(value: progress)
                        .progressViewStyle(.linear)

                    Text("\(Int(progress * 100))%")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(TF.settingsTextSecondary)
                        .frame(width: 36, alignment: .trailing)
                }

                Button {
                    appUpdater.cancelDownload()
                } label: {
                    Text(L("取消", "Cancel"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TF.settingsTextSecondary)
                }
                .buttonStyle(.plain)
            }

        case .verifying:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("校验中...", "Verifying..."))
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextSecondary)
            }

        case .readyToInstall:
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    appUpdater.installAndRestart()
                } label: {
                    Label(
                        L("安装并重启", "Install and Restart"),
                        systemImage: "arrow.triangle.2.circlepath"
                    )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.green))
                }
                .buttonStyle(.plain)

                Text(L("Type4Me 将关闭并自动重启", "Type4Me will close and restart automatically"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }

        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L("安装中，请勿关闭应用...", "Installing, do not close the app..."))
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextSecondary)
            }

        case .failed(let message):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.system(size: 12))
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .lineLimit(2)
                }

                Button {
                    appUpdater.retryDownload()
                } label: {
                    Text(L("重试", "Retry"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TF.settingsText)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6).fill(TF.settingsBg)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(TF.settingsTextTertiary.opacity(0.2), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Update Card

    private func updateCard(_ update: UpdateInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("v\(update.version)")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TF.settingsText)
                Text(update.date)
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextTertiary)
            }

            // Render each line of notes
            let lines = update.notes.split(separator: "\n", omittingEmptySubsequences: false)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(String(line))
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsTextSecondary)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(TF.settingsBg)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(TF.settingsTextTertiary.opacity(0.15), lineWidth: 1)
        )
    }

    // MARK: - Helpers

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0"
    }

    private var buildNumber: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
    }

    private func linkButton(_ text: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(text, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TF.settingsText)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6).fill(TF.settingsBg)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(TF.settingsTextTertiary.opacity(0.2), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }
}
