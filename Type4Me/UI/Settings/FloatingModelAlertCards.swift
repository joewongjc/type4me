import SwiftUI

/// Floating alert cards shown on the home page (bottom-right) when default ASR
/// or LLM models require configuration. Tapping a card jumps directly to the
/// Models settings tab with the corresponding category focused.
struct FloatingModelAlertCards: View {

    @Environment(AppNavigationModel.self) private var navigationModel
    @State private var isASRMissing = false
    @State private var isLLMMissing = false
    @State private var hoveredCard: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            if isASRMissing {
                alertCard(
                    id: "asr",
                    color: Color(red: 1.0, green: 0.35, blue: 0.35),
                    icon: "waveform.badge.exclamationmark",
                    title: L("需配置默认语音识别模型", "Configure Speech Recognition Model"),
                    subtitle: L("点击前往模型页配置 API Key 或本地模型", "Click to set up API keys or local models"),
                    action: {
                        navigationModel.selectedTab = .models
                        navigationModel.pendingModelCategory = .asr
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            }

            if isLLMMissing {
                alertCard(
                    id: "llm",
                    color: TF.settingsAccentAmber,
                    icon: "sparkles",
                    title: L("需配置默认文本润色模型", "Configure Text Polishing Model"),
                    subtitle: L("用于智能纠错、标点与改写", "Used for smart punctuation and rewriting"),
                    action: {
                        navigationModel.selectedTab = .models
                        navigationModel.pendingModelCategory = .llm
                    }
                )
                .transition(.asymmetric(
                    insertion: .move(edge: .trailing).combined(with: .opacity),
                    removal: .move(edge: .trailing).combined(with: .opacity)
                ))
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: isASRMissing)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: isLLMMissing)
        .onAppear {
            checkModelStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .credentialsDidChange)) { _ in
            checkModelStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: .asrProviderDidChange)) { _ in
            checkModelStatus()
        }
    }

    private func alertCard(
        id: String,
        color: Color,
        icon: String,
        title: String,
        subtitle: String,
        action: @escaping () -> Void
    ) -> some View {
        let isHovered = hoveredCard == id

        return Button(action: action) {
            HStack(spacing: 12) {
                // Icon indicator
                ZStack {
                    Circle()
                        .fill(color.opacity(0.18))
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(color)
                }

                // Title and subtitle
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white)

                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.white.opacity(0.65))
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.4))
                    .padding(.leading, 4)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(red: 0.12, green: 0.13, blue: 0.16).opacity(isHovered ? 0.96 : 0.88))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(color.opacity(isHovered ? 0.6 : 0.3), lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.2), radius: 10, x: 0, y: 4)
            .scaleEffect(isHovered ? 1.015 : 1.0)
            .animation(.easeOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            hoveredCard = hovering ? id : nil
        }
    }

    private func checkModelStatus() {
        let currentASR = KeychainService.selectedASRProvider
        let currentLLM = KeychainService.selectedLLMProvider
        isASRMissing = !ModelSettingsHelpers.hasConfiguredCredentials(for: currentASR)
        isLLMMissing = !ModelSettingsHelpers.hasConfiguredCredentials(for: currentLLM)
    }
}
