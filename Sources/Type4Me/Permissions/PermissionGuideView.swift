import SwiftUI
import AppKit

/// Shared light permission UI. Authorization, restart detection and host return
/// continue to use the v2.7.0 permission model.
struct PermissionGuideView: View {
    @Bindable var model: PermissionGuideModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow
    @AppStorage(SettingsTheme.storageKey) private var settingsTheme = SettingsTheme.defaultValue.rawValue
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault

    let embedded: Bool
    var onFinish: (() -> Void)?
    var onRaiseHostWindow: (() -> Void)?
    var onBack: (() -> Void)?

    init(model: PermissionGuideModel, embedded: Bool = false,
         onFinish: (() -> Void)? = nil, onRaiseHostWindow: (() -> Void)? = nil,
         onBack: (() -> Void)? = nil) {
        self.model = model
        self.embedded = embedded
        self.onFinish = onFinish
        self.onRaiseHostWindow = onRaiseHostWindow
        self.onBack = onBack
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    headerSection
                    permissionGroup
                    Text(L("音频处理方式取决于你选择的语音识别服务。你可以随时在 macOS「系统设置」中更改权限。",
                           "Audio handling depends on your speech recognition provider. You can change permissions later in System Settings."))
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 32)
                .padding(.top, embedded ? 48 : 32)
                .padding(.bottom, 24)
            }
            VStack(spacing: 0) {
                SettingsDivider()
                bottomBar.padding(.vertical, 20)
            }.padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(TF.settingsText)
        .background(TF.settingsWindowBackground.ignoresSafeArea())
        .preferredColorScheme(SettingsTheme.resolve(settingsTheme).colorScheme)
        .id(language)
        .onAppear { model.refresh() }
        .onDisappear { model.dismissDragOverlay() }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            model.refresh()
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("让语音顺畅变成文字", "Make voice input work"))
                .font(.system(size: 28, weight: .bold))
            Text(L("开启麦克风与辅助功能，让 Type4Me 听到你的声音，并把文字输入到当前应用。",
                   "Allow microphone and Accessibility access so Type4Me can hear you and type into your current app."))
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsTextSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(3)
            let count = (model.micGranted ? 1 : 0) + (model.accessibilityGranted ? 1 : 0)
            Text(L("必需权限已开启 \(count) / 2", "\(count) of 2 required permissions enabled"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(model.requiredPermissionsGranted ? TF.settingsAccentGreen : TF.settingsTextSecondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(TF.settingsControl, in: Capsule())
        }
    }

    private var permissionGroup: some View {
        VStack(spacing: 0) {
            permissionRow(icon: "mic", title: L("麦克风", "Microphone"), isRequired: true,
                          description: L("录制你的语音以进行文字识别。", "Records your voice for speech-to-text."),
                          isGranted: model.micGranted, action: model.requestMicrophone)
            rowDivider
            permissionRow(icon: "accessibility", title: L("辅助功能", "Accessibility"), isRequired: true,
                          description: L("监听全局快捷键，并将文字直接输入到目标 App。", "Listens for hotkeys and types text into your active app."),
                          statusHint: model.accessibilityGranted && model.needsRestart
                            ? L("权限已开启，请重启 Type4Me 使快捷键生效。", "Access is enabled. Relaunch Type4Me to activate shortcuts.") : nil,
                          isGranted: model.accessibilityGranted, action: beginAccessibilityFlow)
            if model.isAppleASRSelected {
                rowDivider
                permissionRow(icon: "waveform", title: L("Apple 语音识别", "Apple Speech Recognition"), isRequired: false,
                              description: L("使用 Apple 语音识别时需要；使用其他引擎可跳过。", "Needed for Apple Speech; skip if you use another engine."),
                              isGranted: model.speechGranted, action: model.requestSpeechRecognition)
            }
        }
        .background(TF.settingsBg, in: RoundedRectangle(cornerRadius: TF.cornerLG))
        .overlay(RoundedRectangle(cornerRadius: TF.cornerLG).strokeBorder(TF.settingsBorder, lineWidth: 0.5))
    }

    private var rowDivider: some View {
        SettingsDivider().padding(.horizontal, 18)
    }

    private func permissionRow(icon: String, title: String, isRequired: Bool,
                               description: String, statusHint: String? = nil,
                               isGranted: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(isGranted ? TF.settingsAccentGreen : TF.settingsTextSecondary)
                .frame(width: 42, height: 42)
                .background(TF.settingsCard, in: RoundedRectangle(cornerRadius: TF.cornerMD))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(isRequired ? L("必需", "Required") : L("可选", "Optional"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TF.settingsTextSecondary)
                Text(description).font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let statusHint {
                    Text(statusHint).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TF.settingsAccentAmber)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if isGranted {
                Label(L("已允许", "Allowed"), systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.settingsAccentGreen)
                    .fixedSize().padding(.vertical, 10)
            } else {
                Button(L("允许", "Allow"), action: action)
                    .buttonStyle(.tf(.secondary, size: .large))
                    .accessibilityLabel(L("允许\(title)", "Allow \(title)"))
            }
        }
        .padding(18)
    }

    private var bottomBar: some View {
        HStack(spacing: 16) {
            if let onBack {
                Button(L("上一步", "Back"), action: onBack)
                    .buttonStyle(.tf(.secondary, size: .large))
            }
            Spacer()
            if model.needsRestart {
                Button(L("重启 Type4Me", "Relaunch Type4Me"), action: handleRelaunch)
                    .buttonStyle(.tf(.primary, size: .large))
            } else {
                Button(embedded ? L("进入应用", "Open Type4Me") : L("完成", "Done"), action: handlePrimaryAction)
                    .buttonStyle(.tf(.primary, size: .large))
                    .disabled(!model.requiredPermissionsGranted)
            }
        }
    }

    private func beginAccessibilityFlow() {
        model.beginAccessibilityFlow {
            if embedded {
                if let onRaiseHostWindow { onRaiseHostWindow() }
                else { AppDelegate.presentSetupWizard() }
            } else {
                AppDelegate.openPermissionGuideAction?()
            }
        }
    }

    private func handlePrimaryAction() {
        if let onFinish { onFinish() }
        else { dismissGuide() }
    }

    private func handleRelaunch() {
        model.relaunchApp(persistSetup: {
            if embedded && model.requiredPermissionsGranted { onFinish?() }
        })
    }

    private func dismissGuide() {
        model.dismissDragOverlay()
        dismissWindow(id: "permission-guide")
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }
}

