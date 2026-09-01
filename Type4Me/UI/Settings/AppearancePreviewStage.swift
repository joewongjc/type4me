import SwiftUI

// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
// MARK: - Appearance Preview Stage
// ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

enum PreviewPhase: String, CaseIterable {
    case recording
    case processing

    var displayName: String {
        switch self {
        case .recording: return L("录音中", "Recording")
        case .processing: return L("处理中", "Processing")
        }
    }
}

struct AppearancePreviewStage: View {

    let presentation: FloatingBarPresentation
    let formattingOptions: TextOutputFormattingOptions

    @State private var demoState = DemoState()
    @State private var previewPhase: PreviewPhase = .recording
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault

    static let formattingSamples = [
        "我刚刚在MacBook上测试Type4Me 2.1，“这个效果很好”。",
        "I've tested Type4Me on macOS, “it's fast and accurate”."
    ]

    static var formattingSample: String {
        formattingSamples.joined(separator: "\n")
    }

    private var floatingBarSampleText: String {
        L(
            "我正在使用Type4Me测试一段足够长的实时识别文本，方便直接预览悬停窗口和录音动效。",
            "I am testing a sufficiently long live transcript in Type4Me to preview the hover window and recording effects directly."
        )
    }

    private var formattedOutputText: String {
        Self.formattingSamples
            .map { TextOutputFormatter.format($0, options: formattingOptions) }
            .joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Header
            HStack(spacing: 6) {
                Image(systemName: "eye")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TF.settingsText)
                Text(L("预览", "Preview"))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(TF.settingsText)

                Spacer()

                // Phase Switcher
                HStack(spacing: 2) {
                    ForEach(PreviewPhase.allCases, id: \.self) { phase in
                        Button(action: {
                            previewPhase = phase
                            updateDemoState()
                        }) {
                            Text(phase.displayName)
                                .font(.system(size: 11, weight: previewPhase == phase ? .semibold : .regular))
                                .foregroundStyle(previewPhase == phase ? TF.settingsText : TF.settingsTextTertiary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(previewPhase == phase ? TF.settingsCardAlt : Color.clear)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(TF.settingsCard)
                )
            }
            .padding(.horizontal, 2)

            // Stage Card
            VStack(spacing: 0) {
                // Recording Canvas
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(TF.settingsCardAlt.opacity(0.6))

                    if presentation.showsRecordingIndicator {
                        FloatingBarView(
                            state: demoState,
                            presentationOverride: presentation
                        )
                        .id(presentation.theme)
                    } else {
                        Text(L("录音时不显示悬浮条", "The floating bar is hidden while recording."))
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(TF.settingsTextSecondary)
                    }
                }
                .frame(height: 210)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                SettingsDivider()
                    .padding(.vertical, 10)

                // Text Output Comparison (左右布局)
                HStack(alignment: .top, spacing: 18) {
                    // Raw Speech
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("语音识别", "Recognized Speech"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TF.settingsTextTertiary)
                        Text(Self.formattingSample)
                            .font(.system(size: 13))
                            .lineSpacing(3)
                            .foregroundStyle(TF.settingsText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    Divider()
                        .frame(height: 60)

                    // Formatted Text
                    VStack(alignment: .leading, spacing: 5) {
                        Text(L("文本输出", "Text Output"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TF.settingsTextTertiary)
                        Text(formattedOutputText)
                            .font(.system(size: 13))
                            .lineSpacing(3)
                            .foregroundStyle(TF.settingsText)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 4)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(TF.settingsBorder, lineWidth: 1)
                    )
            )
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .task(id: "\(floatingBarSampleText)_\(previewPhase.rawValue)") {
            updateDemoState()
        }
        .onDisappear {
            demoState.stop()
        }
    }

    private func updateDemoState() {
        switch previewPhase {
        case .recording:
            demoState.startAppearancePreview(sampleText: floatingBarSampleText)
        case .processing:
            demoState.startProcessingPreview()
        }
    }
}
