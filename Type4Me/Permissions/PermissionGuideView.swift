import SwiftUI
import AppKit

// `dismissWindow` action came in macOS 14.

/// Unified permission guide presented both at first launch (inside the setup
/// wizard) and when the main app detects a missing authorization.
///
/// Visually aligned with the Settings window: amber accent, warm cream
/// background, Settings-style permission cards (icon tile + title + green
/// "已授权" / amber "授权" pill). The shared look keeps the two surfaces
/// feeling like the same app rather than two disconnected dialogs.
///
/// When `embedded` is true the view runs inside the setup wizard, so the
/// cream background and forced light scheme are skipped to blend with the
/// wizard's own framing.
struct PermissionGuideView: View {

    @Bindable var model: PermissionGuideModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.openWindow) private var openWindow

    let embedded: Bool

    init(model: PermissionGuideModel, embedded: Bool = false) {
        self.model = model
        self.embedded = embedded
    }

    private var allGranted: Bool {
        model.micGranted && model.accessibilityGranted
    }

    var body: some View {
        Group {
            if embedded {
                content
            } else {
                content
                    .background(TF.settingsBg)
                    .preferredColorScheme(.light)
            }
        }
        .onAppear { model.refresh() }
        .onDisappear { model.dismissDragOverlay() }
        // Poll state while the guide is on screen. AX is covered by the
        // drag-overlay's own 0.5s poll, but microphone state can change
        // from System Settings *without* Type4Me becoming active (user
        // never switches back), so the normal `didBecomeActive` refresh
        // misses it. 1s poll is lightweight and makes the cards light up
        // as soon as the user toggles the switch, without requiring a
        // relaunch.
        .onReceive(
            Timer.publish(every: 1, on: .main, in: .common).autoconnect()
        ) { _ in
            model.refresh()
        }
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 16) {
            if !embedded {
                headerArtwork
            }

            Text(L(
                "请授权以下权限,以允许 Type4Me 使用你的麦克风并监听快捷键和完成输入",
                "Please grant the permissions below so Type4Me can use your microphone and listen for hotkeys to type for you."
            ))
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(textPrimary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 440)

            VStack(spacing: 10) {
                microphoneCard
                accessibilityCard
            }
            .frame(maxWidth: 440)

            if !embedded {
                launchButton
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, embedded ? 16 : 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Launch Button

    @ViewBuilder
    private var launchButton: some View {
        Button(action: dismissGuide) {
            Text(L("启动 Type4Me", "Launch Type4Me"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(allGranted ? TF.settingsAccentAmber : TF.settingsTextTertiary.opacity(0.4))
                )
        }
        .buttonStyle(.plain)
        .disabled(!allGranted)
        .frame(maxWidth: 440)
    }

    /// Close the guide window, surface the Settings window as the user's
    /// next destination (so "launch" produces a visible window instead of
    /// silently parking the app in the menu bar), and bring Type4Me to the
    /// front.
    private func dismissGuide() {
        model.dismissDragOverlay()
        dismissWindow(id: "permission-guide")
        openWindow(id: "settings")
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Header

    private var headerArtwork: some View {
        Image(nsImage: NSApp.applicationIconImage ?? NSImage())
            .resizable()
            .interpolation(.high)
            .frame(width: 80, height: 80)
            .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 4)
    }

    // MARK: - Cards

    private var microphoneCard: some View {
        permissionBlock(
            icon: "mic.fill",
            name: L("麦克风", "Microphone"),
            subtitle: L("录制你的语音", "Captures your voice"),
            granted: model.micGranted,
            action: { model.requestMicrophone() }
        )
    }

    private var accessibilityCard: some View {
        permissionBlock(
            icon: "accessibility",
            name: L("辅助功能", "Accessibility"),
            subtitle: L("监听全局快捷键并把文字打到其它 App",
                        "Global hotkeys + inject text into other apps"),
            granted: model.accessibilityGranted,
            action: { model.beginAccessibilityFlow() }
        )
    }

    // MARK: - Permission Block (aligned with SettingsTab permissionBlock)

    private func permissionBlock(
        icon: String,
        name: String,
        subtitle: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(.white)
                .frame(width: 36, height: 36)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(granted ? TF.settingsAccentGreen : TF.settingsTextTertiary)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if granted {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsAccentGreen)
                    Text(L("已授权", "Authorized"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TF.settingsAccentGreen)
                }
            } else {
                Button(action: action) {
                    Text(L("授权", "Grant"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(TF.settingsAccentAmber)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(cardBackground)
        )
    }

    // MARK: - Adaptive Colors

    /// In embedded mode we defer to the system-managed primary/secondary so
    /// the wizard's current color scheme is respected. In the standalone
    /// guide window we pin to the Settings cream palette.
    private var textPrimary: Color { embedded ? .primary : TF.settingsText }
    private var textSecondary: Color { embedded ? .secondary : TF.settingsTextSecondary }
    private var textTertiary: Color { embedded ? .secondary : TF.settingsTextTertiary }
    private var cardBackground: Color {
        embedded ? Color.secondary.opacity(0.08) : TF.settingsCardAlt
    }
}
