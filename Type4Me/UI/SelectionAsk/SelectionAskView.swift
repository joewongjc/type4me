import AppKit
import SwiftUI

struct SelectionAskView: View {
    let state: SelectionAskState
    let onClose: () -> Void
    let onFollowUp: () -> Void
    private let bottomAnchorID = "selectionAskBottomAnchor"

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28)
                .fill(Color(red: 0.96, green: 0.95, blue: 0.93))

            VStack(spacing: 0) {
                header
                Divider().opacity(0.5)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            questionSection
                            ForEach(state.turns) { turn in
                                turnView(turn)
                                    .transition(.asymmetric(
                                        insertion: .move(edge: .bottom).combined(with: .opacity),
                                        removal: .opacity
                                    ))
                            }
                            if state.turns.isEmpty {
                                answerSection
                            }
                            Color.clear
                                .frame(height: 1)
                                .id(bottomAnchorID)
                        }
                        .padding(.horizontal, 34)
                        .padding(.vertical, 26)
                        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: state.turns)
                    }
                    .onChange(of: state.turns) { _, _ in
                        withAnimation(.easeOut(duration: 0.18)) {
                            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
                        }
                    }
                }
                followUpBar
            }
        }
        .padding(10)
    }

    private var header: some View {
        HStack {
            Spacer()
            HStack(spacing: 10) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 22, weight: .semibold))
                Text(L("随便问", "Ask Anything"))
                    .font(.system(size: 24, weight: .bold))
            }
            .foregroundStyle(Color(red: 0.08, green: 0.08, blue: 0.08))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(Color(red: 0.45, green: 0.45, blue: 0.45))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .frame(height: 74)
    }

    private var questionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "questionmark.bubble")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color(red: 0.45, green: 0.45, blue: 0.45))
                Text(state.question.isEmpty ? L("正在识别问题...", "Recognizing question...") : state.question)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color(red: 0.18, green: 0.18, blue: 0.18))
                Spacer()
                if hasSelectedText {
                    copyButton(text: state.selectedText, systemImage: "doc.on.doc")
                }
            }

            if hasSelectedText {
                HStack(alignment: .top, spacing: 14) {
                    Rectangle()
                        .fill(Color(red: 0.78, green: 0.76, blue: 0.72))
                        .frame(width: 2)
                    Text(state.selectedText)
                        .font(.system(size: 18))
                        .foregroundStyle(Color(red: 0.48, green: 0.48, blue: 0.48))
                        .lineSpacing(5)
                        .lineLimit(3)
                        .truncationMode(.tail)
                        .textSelection(.enabled)
                }
                .padding(.leading, 34)
            }
        }
    }

    private var answerSection: some View {
        turnView(SelectionAskState.Turn(
            question: state.question,
            answer: answerText ?? "",
            isLoading: answerText == nil,
            errorMessage: errorText
        ))
    }

    private func turnView(_ turn: SelectionAskState.Turn) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Color(red: 0.38, green: 0.40, blue: 0.44))
                Text(turn.question.isEmpty ? L("正在识别问题...", "Recognizing question...") : turn.question)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color(red: 0.18, green: 0.20, blue: 0.24))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)
            .padding(.bottom, 12)

            Divider()

            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                Text(L("回答", "Answer"))
                    .font(.system(size: 22, weight: .bold))
                Spacer()
                if !turn.answer.isEmpty {
                    copyButton(text: turn.answer, systemImage: "doc.on.doc")
                }
            }
            .foregroundStyle(Color(red: 0.12, green: 0.12, blue: 0.12))
            .padding(.horizontal, 24)
            .frame(height: 52)

            Divider()

            Group {
                if let message = turn.errorMessage {
                    errorView(message)
                } else if turn.isLoading && turn.answer.isEmpty {
                    loadingView
                } else {
                    markdownView(turn.answer)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.white)
        )
    }

    private var followUpBar: some View {
        HStack(spacing: 12) {
            Spacer()
            Button(action: onFollowUp) {
                HStack(spacing: 10) {
                    Image(systemName: state.isRecordingFollowUp ? "stop.fill" : "mic.fill")
                        .font(.system(size: 16, weight: .bold))
                        .frame(width: 18, height: 18)
                    Text(state.isRecordingFollowUp ? L("停止追问", "Stop follow-up") : L("继续追问", "Ask follow-up"))
                        .font(.system(size: 16, weight: .semibold))
                    if state.isRecordingFollowUp {
                        VoiceBars()
                    }
                }
                .foregroundStyle(Color.white)
                .padding(.horizontal, 18)
                .frame(height: 46)
                .background(
                    Capsule()
                        .fill(state.isRecordingFollowUp
                              ? Color(red: 0.82, green: 0.22, blue: 0.18)
                              : Color(red: 0.10, green: 0.12, blue: 0.16))
                )
                .shadow(color: Color.black.opacity(0.12), radius: 10, y: 4)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 34)
        .padding(.bottom, 24)
    }

    private var loadingView: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(L("正在思考...", "Thinking..."))
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color(red: 0.42, green: 0.42, blue: 0.42))
        }
        .frame(minHeight: 220, alignment: .center)
        .frame(maxWidth: .infinity)
    }

    private func markdownView(_ markdown: String) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(MarkdownRenderer.displayBlocks(from: markdown).enumerated()), id: \.offset) { _, block in
                Text(MarkdownRenderer.attributedString(from: block))
                    .font(.system(size: 19))
                    .foregroundStyle(Color(red: 0.08, green: 0.10, blue: 0.16))
                    .lineSpacing(8)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorView(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(TF.settingsAccentRed)
            Text(message)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color(red: 0.42, green: 0.18, blue: 0.15))
                .textSelection(.enabled)
        }
        .frame(minHeight: 180, alignment: .topLeading)
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

    private func copyButton(text: String, systemImage: String) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Color(red: 0.46, green: 0.46, blue: 0.46))
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
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
