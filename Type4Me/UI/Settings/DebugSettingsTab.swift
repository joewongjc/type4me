import AppKit
import SwiftUI

enum DebugSettingsAvailability {
    static let defaultsKey = "tf_debug_panel"

    static var defaultEnabled: Bool {
        #if TYPE4ME_DEV_BUILD
        true
        #else
        false
        #endif
    }

    static var buildLabel: String {
        #if TYPE4ME_DEV_BUILD
        return "DEV"
        #else
        return "RELEASE"
        #endif
    }
}

/// Developer diagnostics enabled by default in builds produced by
/// `scripts/dev-run.sh`. DEV users can hide the entry from Advanced settings.
struct DebugSettingsTab: View, SettingsCardHelpers {
    @State private var recentLog = ""
    @State private var refreshedAt = Date()
    @State private var copiedLog = false

    private let logURL = DebugFileLogger.logURL

    var body: some View {
        SettingsSectionHeader(
            label: "DEBUG",
            title: L("调试与诊断", "Debug & Diagnostics"),
            description: L(
                "查看当前构建、运行环境、系统权限与实时日志，快速定位开发版本中的问题。",
                "Inspect the current build, runtime, permissions, and recent logs while diagnosing development builds."
            )
        )

        buildCard
        Spacer().frame(height: 16)
        permissionCard
        Spacer().frame(height: 16)
        logCard

        #if HAS_CLOUD_SUBSCRIPTION
        Spacer().frame(height: 16)
        CloudDebugDiagnosticsSection()
        #endif
    }

    private var buildCard: some View {
        settingsGroupCard(L("构建与运行环境", "Build & Runtime"), icon: "hammer.fill") {
            diagnosticRow(L("构建类型", "Build Type"), value: DebugSettingsAvailability.buildLabel, emphasized: true)
            SettingsDivider()
            diagnosticRow(L("应用版本", "App Version"), value: AppBuildInfo.current.debugLabel)
            SettingsDivider()
            diagnosticRow(L("Bundle ID", "Bundle ID"), value: Bundle.main.bundleIdentifier ?? "—")
            SettingsDivider()
            diagnosticRow(L("系统", "System"), value: ProcessInfo.processInfo.operatingSystemVersionString)
            SettingsDivider()
            diagnosticRow(L("架构", "Architecture"), value: architecture)
            SettingsDivider()
            diagnosticRow(L("进程 ID", "Process ID"), value: String(ProcessInfo.processInfo.processIdentifier))
            SettingsDivider()
            diagnosticRow(L("ASR 引擎", "ASR Provider"), value: KeychainService.selectedASRProvider.displayName)
            SettingsDivider()
            diagnosticRow(L("LLM 引擎", "LLM Provider"), value: KeychainService.selectedLLMProvider.displayName)
        }
    }

    private var permissionCard: some View {
        settingsGroupCard(L("系统权限", "System Permissions"), icon: "checkmark.shield.fill") {
            permissionRow(L("麦克风", "Microphone"), granted: PermissionManager.hasMicrophonePermission)
            SettingsDivider()
            permissionRow(L("语音识别", "Speech Recognition"), granted: PermissionManager.hasSpeechRecognitionPermission)
            SettingsDivider()
            permissionRow(L("辅助功能", "Accessibility"), granted: PermissionManager.hasAccessibilityPermission)
        }
    }

    private var logCard: some View {
        settingsGroupCard(
            L("诊断日志", "Diagnostic Log"),
            icon: "doc.text.magnifyingglass",
            trailing: AnyView(logActions)
        ) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .medium))
                Text(logURL.path)
                    .font(.system(size: 11, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
            }
            .foregroundStyle(TF.settingsTextSecondary)
            .padding(.vertical, 10)

            SettingsDivider()

            ScrollView([.horizontal, .vertical], showsIndicators: true) {
                Text(recentLog.isEmpty ? L("暂无日志。", "No log entries yet.") : recentLog)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(recentLog.isEmpty ? TF.settingsTextTertiary : TF.settingsTextSecondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(12)
            }
            .frame(height: 220)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(TF.settingsCardAlt)
            )
            .padding(.vertical, 10)

            HStack {
                Text(L("最近刷新：", "Last refreshed: ") + refreshedAt.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
                Spacer()
                Text(L("显示最近 200 行", "Showing the latest 200 lines"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            .padding(.bottom, 8)
        }
        .onAppear(perform: refreshLog)
    }

    private var logActions: some View {
        HStack(spacing: 8) {
            compactButton(copiedLog ? L("已复制", "Copied") : L("复制", "Copy"), icon: copiedLog ? "checkmark" : "doc.on.doc") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(recentLog, forType: .string)
                copiedLog = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copiedLog = false }
            }
            compactButton(L("在 Finder 中显示", "Reveal"), icon: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([logURL])
            }
            compactButton(L("刷新", "Refresh"), icon: "arrow.clockwise", action: refreshLog)
        }
    }

    private func diagnosticRow(_ label: String, value: String, emphasized: Bool = false) -> some View {
        HStack(spacing: 20) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TF.settingsTextSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: emphasized ? .bold : .medium, design: emphasized ? .monospaced : .default))
                .foregroundStyle(emphasized ? TF.settingsAccentGreen : TF.settingsText)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .frame(minHeight: 42)
    }

    private func permissionRow(_ label: String, granted: Bool) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TF.settingsTextSecondary)
            Spacer()
            HStack(spacing: 6) {
                Circle()
                    .fill(granted ? TF.settingsAccentGreen : TF.settingsAccentRed)
                    .frame(width: 7, height: 7)
                Text(granted ? L("已授权", "Granted") : L("未授权", "Not Granted"))
                    .font(.system(size: 12, weight: .semibold))
            }
            .foregroundStyle(granted ? TF.settingsAccentGreen : TF.settingsAccentRed)
        }
        .frame(minHeight: 42)
    }

    private func compactButton(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(TF.settingsText)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 7).fill(TF.settingsCardAlt))
        }
        .buttonStyle(.plain)
    }

    private func refreshLog() {
        recentLog = DebugFileLogger.recentLines(200).joined(separator: "\n")
        refreshedAt = Date()
    }

    private var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
