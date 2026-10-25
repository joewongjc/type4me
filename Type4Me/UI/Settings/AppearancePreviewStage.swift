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

/// What sits behind the preview bar. Glass only shows its translucency and
/// refraction against real content; on the flat stage every glass setting
/// looks the same, so the other backdrops stand in for typical host apps.
enum PreviewBackdrop: String, CaseIterable {
    case plain
    case document
    case colorful
    case dark

    static let storageKey = "tf_appearancePreviewBackdrop"
    static let defaultValue = PreviewBackdrop.plain

    var iconName: String {
        switch self {
        case .plain: "square"
        case .document: "doc.text"
        case .colorful: "paintpalette"
        case .dark: "moon"
        }
    }

    var displayName: String {
        switch self {
        case .plain: L("纯色背景", "Plain Background")
        case .document: L("文档背景", "Document Background")
        case .colorful: L("彩色背景", "Colorful Background")
        case .dark: L("深色背景", "Dark Background")
        }
    }
}

struct AppearancePreviewStage: View {

    let presentation: FloatingBarPresentation
    let formattingOptions: TextOutputFormattingOptions
    let mode: ProcessingMode?

    @State private var demoState = DemoState()
    @State private var previewPhase: PreviewPhase = .recording
    @AppStorage(PreviewBackdrop.storageKey) private var backdrop = PreviewBackdrop.defaultValue
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

                if let mode {
                    Text(mode.localizedDisplayName)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TF.settingsTextSecondary)
                }

                Spacer()

                SettingsInlineSegmentedPicker(
                    selection: Binding(
                        get: { backdrop.rawValue },
                        set: { backdrop = PreviewBackdrop(rawValue: $0) ?? .defaultValue }
                    ),
                    iconOptions: PreviewBackdrop.allCases.map { ($0.rawValue, $0.iconName, $0.displayName) },
                    segmentWidth: 30
                )
                .accessibilityLabel(L("预览背景", "Preview Background"))

                // Phase Switcher
                SettingsInlineSegmentedPicker(
                    selection: Binding(
                        get: { previewPhase.rawValue },
                        set: { rawValue in
                            guard let phase = PreviewPhase(rawValue: rawValue), phase != previewPhase else { return }
                            previewPhase = phase
                            updateDemoState()
                        }
                    ),
                    options: PreviewPhase.allCases.map { ($0.rawValue, $0.displayName) }
                )
            }
            .padding(.horizontal, 2)

            // Stage Card
            VStack(spacing: 0) {
                // Recording Canvas
                ZStack {
                    PreviewBackdropView(backdrop: backdrop)

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
        .onChange(of: mode) { _, newMode in
            demoState.currentMode = newMode ?? .direct
        }
        .onDisappear {
            demoState.stop()
        }
    }

    private func updateDemoState() {
        demoState.currentMode = mode ?? .direct
        switch previewPhase {
        case .recording:
            demoState.startAppearancePreview(sampleText: floatingBarSampleText)
        case .processing:
            demoState.startProcessingPreview()
        }
    }
}

private struct PreviewBackdropView: View {
    let backdrop: PreviewBackdrop

    private var documentLines: [String] {
        [
            L("液态玻璃预览 · 这段文字位于录音条后方", "Liquid Glass preview · this text sits behind the bar"),
            L("调整底色浓度、边缘透光和高光，观察背后内容如何透出与折射。", "Adjust backing, edge clearance and highlight to see the content refract."),
            "func recognize(_ audio: Buffer) async throws -> String {",
            L("    let text = try await asr.stream(audio) // 中文与 English", "    let text = try await asr.stream(audio) // live transcript"),
            "    return llm.polish(text, mode: .smart)",
            "}",
            L("The quick brown fox jumps over the lazy dog. 敏捷的狐狸跳过懒狗。", "The quick brown fox jumps over the lazy dog."),
            L("液态玻璃预览 · 这段文字位于录音条后方", "Liquid Glass preview · this text sits behind the bar"),
            "let session = RecognitionSession(mode: .smart)",
        ]
    }

    var body: some View {
        switch backdrop {
        case .plain:
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(TF.settingsCardAlt.opacity(0.6))
        case .document:
            ZStack(alignment: .topLeading) {
                Color.white
                lines(primary: Color(white: 0.12), accent: Color(red: 0.55, green: 0.25, blue: 0.75))
            }
        case .colorful:
            ZStack(alignment: .topLeading) {
                LinearGradient(
                    colors: [Color(red: 1.0, green: 0.97, blue: 0.92), Color(red: 0.90, green: 0.95, blue: 1.0)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                GeometryReader { proxy in
                    let w = proxy.size.width
                    Circle().fill(Color.orange)
                        .frame(width: 150).position(x: w * 0.22, y: 70)
                    RoundedRectangle(cornerRadius: 14).fill(Color.green)
                        .frame(width: 70, height: 260).position(x: w * 0.5, y: 105)
                    Circle().fill(Color.blue)
                        .frame(width: 130).position(x: w * 0.78, y: 150)
                    Capsule().fill(Color.pink)
                        .frame(width: 180, height: 26).position(x: w * 0.68, y: 40)
                }
                lines(primary: Color(white: 0.10), accent: Color.purple)
            }
        case .dark:
            ZStack(alignment: .topLeading) {
                Color(red: 0.11, green: 0.11, blue: 0.13)
                lines(primary: Color(white: 0.86), accent: Color.cyan)
            }
        }
    }

    private func lines(primary: Color, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(documentLines.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(.system(size: 12, design: index % 3 == 2 ? .monospaced : .default))
                    .foregroundStyle(index % 3 == 0 ? accent : primary)
                    .lineLimit(1)
            }
        }
        .padding(12)
        .accessibilityHidden(true)
    }
}
