import SwiftUI
import AppKit

/// Simplified 2-step first-run onboarding wizard.
/// Step 0: Welcome & Core concept
/// Step 1: Screenflare-style permissions guidance
/// On completion: marks setup complete, closes wizard, and opens the main app home.
struct SetupWizardView: View {

    @Environment(AppState.self) private var appState
    @Environment(PermissionGuideModel.self) private var permissionGuideModel
    @State private var step = 0
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case 0:
                    welcomeStep
                default:
                    permissionsStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            .animation(TF.springGentle, value: step)
        }
        .frame(width: 640, height: 480)
        .background(
            ZStack {
                Color(red: 0.11, green: 0.12, blue: 0.14)
                RadialGradient(
                    gradient: Gradient(colors: [
                        Color(red: 0.2, green: 0.22, blue: 0.26).opacity(0.6),
                        Color.clear
                    ]),
                    center: .top,
                    startRadius: 20,
                    endRadius: 360
                )
            }
            .ignoresSafeArea()
        )
        .preferredColorScheme(.dark)
        .id(language)
    }

    // MARK: - Step 0: Welcome

    private var welcomeStep: some View {
        VStack(spacing: 28) {
            Spacer()

            ZStack {
                Circle()
                    .fill(TF.amber.opacity(0.12))
                    .frame(width: 96, height: 96)
                Image(systemName: "waveform.and.mic")
                    .font(.system(size: 42))
                    .foregroundStyle(TF.amber)
            }

            VStack(spacing: 8) {
                Text("Type4Me")
                    .font(.system(size: 26, weight: .bold))
                    .foregroundStyle(Color.white)

                Text(L("说话，就是输入", "Speak, and it types"))
                    .font(.system(size: 14))
                    .foregroundStyle(Color.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Spacer()

            HStack {
                // Step Indicator Dots
                HStack(spacing: 6) {
                    Circle().fill(TF.amber).frame(width: 6, height: 6)
                    Circle().fill(Color.white.opacity(0.25)).frame(width: 6, height: 6)
                }

                Spacer()

                Button(action: { step = 1 }) {
                    Text(L("开始设置", "Get Started"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 22)
                        .padding(.vertical, 8)
                        .background(
                            Capsule().fill(TF.amber)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 36)
            .padding(.bottom, 24)
        }
    }

    // MARK: - Step 1: Permissions

    private var permissionsStep: some View {
        PermissionGuideView(
            model: permissionGuideModel,
            embedded: true,
            onFinish: completeSetupAndLaunchHome,
            onRaiseHostWindow: {
                NSApp.activate(ignoringOtherApps: true)
                AppDelegate.presentSetupWizard()
            }
        )
    }

    // MARK: - Completion Handler

    private func completeSetupAndLaunchHome() {
        permissionGuideModel.dismissDragOverlay()
        #if HAS_CLOUD_SUBSCRIPTION
        if appState.appEdition == nil {
            AppEditionMigration.switchTo(.byoKey)
        }
        #endif
        appState.hasCompletedSetup = true
        NSApp.keyWindow?.close()
        AppDelegate.presentSettings()
    }
}
