import SwiftUI
import AppKit

/// The existing two-step setup, using the main window's light design system.
struct SetupWizardView: View {
    @Environment(AppState.self) private var appState
    @Environment(PermissionGuideModel.self) private var permissionGuideModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step = 0
    @AppStorage(SettingsTheme.storageKey) private var settingsTheme = SettingsTheme.defaultValue.rawValue
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Group {
                if step == 0 { welcomeStep } else { permissionsStep }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 840, height: 600)
        .background(TF.settingsWindowBackground.ignoresSafeArea())
        .foregroundStyle(TF.settingsText)
        .preferredColorScheme(SettingsTheme.resolve(settingsTheme).colorScheme)
        .id(language)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                    .resizable().frame(width: 32, height: 32)
                Text("Type4Me").font(.system(size: 18, weight: .bold))
            }
            Text(L("设置引导", "SETUP"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TF.settingsTextTertiary)
            VStack(spacing: 8) {
                stepLabel(0, L("欢迎", "Welcome"))
                stepLabel(1, L("系统权限", "Permissions"))
            }
            Spacer()
            Text(L("让想法自然成文。", "Make room for your ideas."))
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsTextTertiary)
            Picker(L("语言", "Language"), selection: $language) {
                ForEach(AppLanguage.allCases, id: \.rawValue) { item in
                    Text(item.displayName).tag(item.rawValue)
                }
            }
            .labelsHidden()
            .accessibilityLabel(L("语言", "Language"))
        }
        .padding(.horizontal, 20)
        .padding(.top, 48)
        .padding(.bottom, 24)
        .frame(width: 210)
        .background(TF.settingsSidebar)
    }

    private func stepLabel(_ index: Int, _ title: String) -> some View {
        HStack(spacing: 12) {
            Text(String(index + 1))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .frame(width: 24, height: 24)
                .background(TF.settingsCard, in: Circle())
            Text(title).font(.system(size: 13, weight: index == step ? .semibold : .regular))
            Spacer(minLength: 0)
        }
        .foregroundStyle(index == step ? TF.settingsText : TF.settingsTextSecondary)
        .padding(10)
        .background(index == step ? TF.settingsSidebarActive : .clear,
                    in: RoundedRectangle(cornerRadius: TF.cornerMD))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(index == step ? [.isSelected] : [])
    }

    private var welcomeStep: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 32) {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L("说出想法，即刻成文", "Speak your mind.\nMake it text."))
                        .font(.system(size: 28, weight: .bold))
                    Text(L("简单几步，让 Type4Me 为你完成语音输入。", "A few simple steps to start writing with your voice."))
                        .font(.system(size: 13))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(spacing: 24) {
                    instructionRow("waveform", L("说出你的想法", "Speak naturally"),
                                   L("用快捷键开始口述，无需切换当前应用。", "Start dictating with a shortcut, right in the app you use."))
                    instructionRow("text.cursor", L("文字到达光标", "Text where you need it"),
                                   L("结束录音后，文字自动输入到光标位置。", "Finish speaking and your words appear at the cursor."))
                    instructionRow("slider.horizontal.3", L("按你的方式工作", "Make it yours"),
                                   L("在首页选择模式，随时调整引擎和快捷键。", "Choose a mode on Home, then customize engines and shortcuts."))
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 32)
            .padding(.top, 48)
            VStack(spacing: 0) {
                SettingsDivider()
                HStack {
                    Spacer()
                    Button(L("开始设置", "Get started")) { step = 1 }
                        .buttonStyle(.tf(.primary, size: .large))
                }.padding(.vertical, 20)
            }.padding(.horizontal, 32)
        }
    }

    private func instructionRow(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 20, weight: .medium))
                .frame(width: 42, height: 42)
                .background(TF.settingsControl, in: RoundedRectangle(cornerRadius: TF.cornerMD))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(detail).font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var permissionsStep: some View {
        PermissionGuideView(
            model: permissionGuideModel,
            embedded: true,
            onFinish: completeSetupAndLaunchHome,
            onRaiseHostWindow: {
                NSApp.activate(ignoringOtherApps: true)
                AppDelegate.presentSetupWizard()
            },
            onBack: { step = 0 }
        )
    }

    private func completeSetupAndLaunchHome() {
        permissionGuideModel.dismissDragOverlay()
        #if HAS_CLOUD_SUBSCRIPTION
        if appState.appEdition == nil { AppEditionMigration.switchTo(.byoKey) }
        #endif
        appState.hasCompletedSetup = true
        dismissWindow(id: "setup")
        AppDelegate.presentSettings()
    }
}
