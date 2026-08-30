import AppKit
import SwiftUI

struct SelectionAskView: View {
    let state: SelectionAskState
    let onClose: () -> Void
    let onFollowUp: () -> Void
    let onCancelFollowUp: () -> Void
    let onOpenInType4Me: () -> Void
    @AppStorage("tf_language") private var language = AppLanguage.systemDefault
    @Environment(\.colorScheme) private var colorScheme
    @State private var isFollowUpHovered = false
    @State private var isOpenInType4MeHovered = false
    private let bottomAnchorID = "selectionAskBottomAnchor"

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: TF.cornerLG, style: .continuous)
                .fill(TF.settingsWindowBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: TF.cornerLG, style: .continuous)
                        .stroke(TF.settingsBorder, lineWidth: 1)
                )

            VStack(spacing: 0) {
                header
                divider
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: TF.spacingMD) {
                            if hasSelectedText {
                                selectedTextCard
                            }

                            if state.turns.isEmpty {
                                turnCard(pendingTurn)
                            } else {
                                ForEach(state.turns) { turn in
                                    turnCard(turn)
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .opacity
                                    ))
                                }
                            }

                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorID)
                        }
                        .padding(TF.spacingXL)
                        .animation(.easeOut(duration: 0.18), value: state.turns)
                    }
                    .onChange(of: state.turns) { _, _ in
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                        }
                    }
                }
                .background(TF.settingsBg)
                divider
                followUpBar
            }
        }
        .padding(8)
        .overlay(alignment: .topTrailing) {
            if isOpenInType4MeHovered {
                SettingsTooltipBubble(text: L("在 Type4Me 中打开", "Open in Type4Me"))
                    .padding(.top, 58)
                    .padding(.trailing, 50)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topTrailing)))
                    .zIndex(100)
            }
        }
        .id(language)
        .settingsTooltipHost(.selectionAsk)
    }

    private var header: some View {
        HStack(spacing: TF.spacingMD) {
            HStack(spacing: 10) {
                AskAnythingIcon()
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("随便问", "Ask Anything"))
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(TF.settingsText)
                    Text(state.isHistoryEnabled
                         ? L("语音提问，流式回答", "Voice questions, streamed answers")
                         : L("本次会话不会保存", "This conversation won't be saved"))
                        .font(.system(size: 12))
                        .foregroundStyle(state.isHistoryEnabled ? TF.settingsTextSecondary : TF.settingsAccentAmber)
                }
            }
            Spacer()
            Button(action: onOpenInType4Me) {
                Image(nsImage: Type4MeWordmarkAsset.image(for: colorScheme))
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 58, height: 22)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(isOpenInType4MeHovered ? TF.settingsSidebarHover : TF.settingsCardAlt)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .stroke(TF.settingsBorder, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            .buttonStyle(.plain)
            .onHover { isOpenInType4MeHovered = $0 }
            .accessibilityLabel(L("在 Type4Me 中打开", "Open in Type4Me"))
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(TF.settingsTextSecondary)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: TF.cornerSM, style: .continuous)
                            .fill(TF.settingsCardAlt)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("关闭", "Close"))
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
    }

    private var selectedTextCard: some View {
        VStack(alignment: .leading, spacing: TF.spacingSM) {
            HStack {
                metadataLabel(L("已选内容", "SELECTED TEXT"))
                Spacer()
                copyButton(text: state.selectedText, systemImage: "doc.on.doc")
            }
            Text(state.selectedText)
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsTextSecondary)
                .lineSpacing(4)
                .lineLimit(3)
                .truncationMode(.tail)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(TF.spacingLG)
        .background(
            RoundedRectangle(cornerRadius: TF.cornerMD, style: .continuous)
                .fill(TF.settingsCardAlt)
        )
    }

    private var pendingTurn: SelectionAskState.Turn {
        SelectionAskState.Turn(
            question: state.question,
            answer: answerText ?? "",
            isLoading: state.isAnswerLoading,
            errorMessage: errorText
        )
    }

    private func turnCard(_ turn: SelectionAskState.Turn) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: TF.spacingSM) {
                metadataLabel(L("问题", "QUESTION"))
                Text(turn.question.isEmpty ? L("正在识别问题...", "Recognizing question...") : turn.question)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TF.settingsText)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(TF.spacingLG)

            divider

            VStack(alignment: .leading, spacing: TF.spacingSM) {
                HStack {
                    metadataLabel(L("回答", "ANSWER"))
                    Spacer()
                    if !turn.answer.isEmpty {
                        copyButton(text: turn.answer, systemImage: "doc.on.doc")
                    }
                }

                if let message = turn.errorMessage {
                    errorView(message)
                } else if turn.isLoading && turn.answer.isEmpty {
                    loadingView
                } else {
                    markdownView(turn.answer)
                }
            }
            .padding(TF.spacingLG)
        }
        .background(
            RoundedRectangle(cornerRadius: TF.cornerMD, style: .continuous)
                .fill(TF.settingsCard)
                .overlay(
                    RoundedRectangle(cornerRadius: TF.cornerMD, style: .continuous)
                        .stroke(TF.settingsBorder, lineWidth: 1)
                )
        )
    }

    private var followUpBar: some View {
        HStack(spacing: TF.spacingMD) {
            HStack(spacing: 6) {
                Circle()
                    .fill(state.isRecordingFollowUp ? TF.settingsAccentRed : TF.settingsAccentGreen)
                    .frame(width: 7, height: 7)
                Text(state.isRecordingFollowUp ? L("正在录音", "Recording") : L("准备追问", "Ready for follow-up"))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.settingsTextSecondary)
            }
            Spacer()
            if isFollowUpHovered,
               !state.isRecordingFollowUp,
               !state.followUpShortcutHint.isEmpty {
                Text(L("快捷键 \(state.followUpShortcutHint)", "Shortcut \(state.followUpShortcutHint)"))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
            if state.isRecordingFollowUp {
                Button(action: onCancelFollowUp) {
                    HStack(spacing: 7) {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                        Text(L("取消追问（ESC）", "Cancel follow-up (ESC)"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 13)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(TF.settingsAccentRed)
                    )
                }
                .buttonStyle(.plain)

                Button(action: onFollowUp) {
                    HStack(spacing: 8) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text(L("结束追问", "Finish follow-up"))
                            .font(.system(size: 12, weight: .semibold))
                        VoiceBars()
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 13)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(TF.settingsAccentGreen)
                    )
                }
                .buttonStyle(.plain)
            } else {
                Button(action: onFollowUp) {
                    HStack(spacing: 8) {
                        Image(systemName: "mic.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text(L("继续追问", "Ask follow-up"))
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 14)
                    .frame(height: 36)
                    .background(
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(TF.settingsNavActive)
                    )
                }
                .buttonStyle(.plain)
                .onHover { isHovered in
                    withAnimation(.easeOut(duration: 0.14)) {
                        isFollowUpHovered = isHovered
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 64)
    }

    private var loadingView: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(L("正在思考...", "Thinking..."))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TF.settingsTextSecondary)
        }
        .frame(minHeight: 96, alignment: .center)
        .frame(maxWidth: .infinity)
    }

    private func markdownView(_ markdown: String) -> some View {
        VStack(alignment: .leading, spacing: TF.spacingSM) {
            ForEach(Array(MarkdownRenderer.displayBlocks(from: markdown).enumerated()), id: \.offset) { _, block in
                Text(MarkdownRenderer.attributedString(from: block))
                    .font(.system(size: 14))
                    .foregroundStyle(TF.settingsText)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(TF.settingsAccentRed)
            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TF.settingsAccentRed)
                .textSelection(.enabled)
        }
        .padding(TF.spacingMD)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: TF.cornerSM, style: .continuous)
                .fill(TF.settingsAccentRed.opacity(0.10))
        )
    }

    private var answerText: String? {
        if case .answered(let answer) = state.phase {
            return answer
        }
        return nil
    }

    private var errorText: String? {
        if case .error(let message) = state.phase {
            return message
        }
        return nil
    }

    private var hasSelectedText: Bool {
        !state.selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var divider: some View {
        Rectangle()
            .fill(TF.settingsBorder)
            .frame(height: 1)
    }

    private func metadataLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(TF.settingsTextTertiary)
    }

    private func copyButton(text: String, systemImage: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TF.settingsTextSecondary)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: TF.cornerSM, style: .continuous)
                        .fill(TF.settingsCardAlt)
                )
        }
        .buttonStyle(.plain)
        .settingsTooltip(L("复制", "Copy"))
    }
}

private enum Type4MeWordmarkAsset {
    private static let light = load("type4me-wordmark-light")
    private static let dark = load("type4me-wordmark-dark")

    static func image(for colorScheme: ColorScheme) -> NSImage {
        colorScheme == .dark ? dark : light
    }

    private static func load(_ name: String) -> NSImage {
        let installedURL = Bundle.main.url(
            forResource: name,
            withExtension: "svg",
            subdirectory: "Assets"
        )
        let sourceURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Assets/\(name).svg")
        if let url = installedURL ?? (FileManager.default.fileExists(atPath: sourceURL.path) ? sourceURL : nil),
           let image = NSImage(contentsOf: url) {
            return image
        }
        return NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 66, height: 25))
    }
}

private struct AskAnythingIcon: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: TF.cornerSM, style: .continuous)
                .fill(TF.settingsCardAlt)
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TF.settingsText)
            Image(systemName: "sparkle")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(TF.settingsAccentAmber)
                .offset(x: 9, y: -8)
        }
        .frame(width: 32, height: 32)
        .accessibilityHidden(true)
    }
}

private struct VoiceBars: View {
    @State private var active = false

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.white.opacity(0.82))
                    .frame(width: 3, height: index.isMultiple(of: 2) ? 12 : 18)
                    .scaleEffect(y: active == index.isMultiple(of: 2) ? 1.35 : 0.72, anchor: .center)
                    .animation(
                        .easeInOut(duration: 0.45 + Double(index) * 0.08)
                            .repeatForever(autoreverses: true),
                        value: active
                    )
            }
        }
        .frame(width: 24)
        .onAppear { active = true }
    }
}
