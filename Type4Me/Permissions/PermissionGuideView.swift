import SwiftUI
import AppKit

/// Unified permission guide presented both at first launch (inside the setup
/// wizard) and when the main app detects a missing authorization.
///
/// Designed in Screenflare style: dark translucent material, grouped card layout,
/// clear "Required" vs "Optional" badge hierarchy, dynamic restart detection,
/// and integrated drag-to-authorize assistance for Accessibility.
struct PermissionGuideView: View {

    @Bindable var model: PermissionGuideModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    let embedded: Bool
    var onFinish: (() -> Void)?
    var onRaiseHostWindow: (() -> Void)?

    init(
        model: PermissionGuideModel,
        embedded: Bool = false,
        onFinish: (() -> Void)? = nil,
        onRaiseHostWindow: (() -> Void)? = nil
    ) {
        self.model = model
        self.embedded = embedded
        self.onFinish = onFinish
        self.onRaiseHostWindow = onRaiseHostWindow
    }

    var body: some View {
        VStack(spacing: 20) {
            // Header
            headerSection

            // Grouped Permissions Container
            permissionGroupContainer

            // Footer Privacy Note
            Text(L(
                "随时可以在 macOS「系统设置」中更改这些权限。",
                "You can change any of these later in System Settings."
            ))
            .font(.system(size: 11))
            .foregroundStyle(Color.white.opacity(0.5))
            .multilineTextAlignment(.center)

            // Bottom Actions Bar
            bottomBar
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(screenflareBackground)
        .preferredColorScheme(.dark)
        .onAppear {
            model.refresh()
        }
        .onDisappear {
            model.dismissDragOverlay()
        }
        // Periodically refresh permissions to catch external System Settings toggles
        .onReceive(
            Timer.publish(every: 1, on: .main, in: .common).autoconnect()
        ) { _ in
            model.refresh()
        }
    }

    // MARK: - Header Section

    private var headerSection: some View {
        VStack(spacing: 8) {
            Text(L("几项系统权限", "A few permissions"))
                .font(.system(size: 20, weight: .bold))
                .foregroundStyle(Color.white)

            Text(L(
                "Type4Me 仅在听写时使用麦克风与快捷键，音频处理取决于你配置的语音识别服务。",
                "Type4Me only accesses your microphone while dictating; audio handling depends on your selected speech recognition provider."
            ))
            .font(.system(size: 12))
            .foregroundStyle(Color.white.opacity(0.65))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 460)
        }
        .padding(.top, embedded ? 0 : 6)
    }

    // MARK: - Grouped Permission Container

    private var permissionGroupContainer: some View {
        VStack(spacing: 0) {
            // 1. Microphone Row
            microphoneRow

            dividerLine

            // 2. Accessibility Row
            accessibilityRow

            // 3. Apple Speech Recognition (only when Apple Speech is selected)
            if model.isAppleASRSelected {
                dividerLine
                speechRecognitionRow
            }
        }
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .stroke(Color.white.opacity(0.1), lineWidth: 1)
        )
        .frame(maxWidth: 480)
    }

    // MARK: - Permission Rows

    private var microphoneRow: some View {
        permissionRow(
            icon: "mic.fill",
            iconColor: Color(red: 1.0, green: 0.35, blue: 0.35),
            title: L("麦克风", "Microphone"),
            isRequired: true,
            description: L("录制你的语音以进行文字识别。", "Records your voice for speech-to-text."),
            isGranted: model.micGranted,
            action: { model.requestMicrophone() }
        )
    }

    private var accessibilityRow: some View {
        permissionRow(
            icon: "accessibility",
            iconColor: Color(red: 0.35, green: 0.65, blue: 1.0),
            title: L("辅助功能", "Accessibility"),
            isRequired: true,
            description: L("监听全局快捷键，并将文字直接输入到目标 App。", "Listens for hotkeys and types text into your active app."),
            statusHint: (model.accessibilityGranted && model.needsRestart)
                ? L("已开启？macOS 可能需要在重启应用后生效。", "Switched it on? macOS applies this on the next launch.")
                : nil,
            isGranted: model.accessibilityGranted,
            action: {
                model.beginAccessibilityFlow {
                    if embedded {
                        if let onRaiseHostWindow {
                            onRaiseHostWindow()
                        } else {
                            AppDelegate.presentSetupWizard()
                        }
                    } else {
                        AppDelegate.openPermissionGuideAction?()
                    }
                }
            }
        )
    }

    private var speechRecognitionRow: some View {
        permissionRow(
            icon: "waveform",
            iconColor: Color(red: 0.3, green: 0.8, blue: 0.6),
            title: L("Apple 语音识别", "Apple Speech Recognition"),
            isRequired: false,
            description: L("使用系统内置语音引擎（使用云端或本地模型可跳过）。", "Transcribes via Apple Speech (can be skipped if using other ASR)."),
            isGranted: model.speechGranted,
            action: { model.requestSpeechRecognition() }
        )
    }

    // MARK: - Generic Row Builder

    private func permissionRow(
        icon: String,
        iconColor: Color,
        title: String,
        isRequired: Bool,
        description: String,
        statusHint: String? = nil,
        isGranted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            // Icon square
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(iconColor.opacity(0.18))
                    .frame(width: 34, height: 34)

                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(iconColor)
            }

            // Texts
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)

                    if isRequired {
                        Text(L("必需", "Required"))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color(red: 1.0, green: 0.3, blue: 0.3).opacity(0.18))
                            .clipShape(Capsule())
                    } else {
                        Text(L("可选", "Optional"))
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.6))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.white.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }

                Text(description)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.white.opacity(0.6))
                    .fixedSize(horizontal: false, vertical: true)

                if let hint = statusHint {
                    Text(hint)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 1.0, green: 0.8, blue: 0.35))
                        .padding(.top, 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            // Status or Action Button
            if isGranted {
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(TF.settingsAccentGreen)
                    Text(L("已允许", "Allowed"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TF.settingsAccentGreen)
                }
                .padding(.vertical, 5)
            } else {
                Button(action: action) {
                    Text(L("允许", "Allow"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(Color(red: 0.22, green: 0.52, blue: 0.98))
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
    }

    // MARK: - Bottom Actions Bar

    private var bottomBar: some View {
        HStack {
            if embedded {
                // Step Indicator Dots
                HStack(spacing: 6) {
                    Circle().fill(Color.white.opacity(0.25)).frame(width: 6, height: 6)
                    Circle().fill(TF.amber).frame(width: 6, height: 6)
                }
            }

            Spacer()

            if model.needsRestart {
                Button(action: handleRelaunch) {
                    Text(L("重启 Type4Me", "Relaunch Type4Me"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(Color(red: 0.22, green: 0.52, blue: 0.98))
                        )
                }
                .buttonStyle(.plain)
            } else {
                Button(action: handlePrimaryAction) {
                    Text(embedded ? L("进入应用", "Launch Type4Me") : L("完成", "Done"))
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 8)
                        .background(
                            Capsule()
                                .fill(model.requiredPermissionsGranted
                                      ? TF.settingsAccentAmber
                                      : Color.white.opacity(0.18))
                        )
                }
                .buttonStyle(.plain)
                .disabled(!model.requiredPermissionsGranted)
            }
        }
        .frame(maxWidth: 480)
    }

    // MARK: - Actions

    private func handlePrimaryAction() {
        if let onFinish {
            onFinish()
        } else {
            dismissGuide()
        }
    }

    private func handleRelaunch() {
        model.relaunchApp(persistSetup: {
            if embedded && model.requiredPermissionsGranted {
                onFinish?()
            }
        })
    }

    private func dismissGuide() {
        model.dismissDragOverlay()
        dismissWindow(id: "permission-guide")
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(height: 1)
            .padding(.horizontal, 14)
    }

    // MARK: - Screenflare Style Background

    @ViewBuilder
    private var screenflareBackground: some View {
        if embedded {
            Color.clear
        } else {
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
        }
    }
}
