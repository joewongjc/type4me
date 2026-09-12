import SwiftUI

struct QuickCorrectionSheet: View {

    /// The recogniser's own output. Corrections are built from this, because a
    /// replacement rule is matched against what the recogniser produced.
    let text: String
    /// What the record actually delivered. When it differs from `text`, a
    /// replacement rule rewrote the output, and the characters below will not
    /// match what the history list showed.
    var finalText: String?
    var onComplete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    @State private var correctText: String = ""
    @State private var characters: [String] = []
    @State private var selectedChars: Set<Int> = []
    @State private var charFrames: [Int: CGRect] = [:]
    @State private var dragStartIndex: Int? = nil
    @State private var dragSelectMode: Bool? = nil
    @State private var preDragSelection: Set<Int> = []
    @State private var showSuccess = false

    private var selectedText: String {
        selectedChars.sorted().compactMap { idx in
            idx < characters.count ? characters[idx] : nil
        }.joined()
    }

    private var canAdd: Bool {
        !correctText.trimmingCharacters(in: .whitespaces).isEmpty && !selectedChars.isEmpty
    }

    /// Non-nil only when the delivered output was rewritten after recognition.
    private var rewrittenOutput: String? {
        guard let finalText, !finalText.isEmpty, finalText != text else { return nil }
        return finalText
    }

    private var appliedRules: [(trigger: String, value: String)] {
        rewrittenOutput == nil ? [] : SnippetStorage.rulesApplied(to: text)
    }

    private func openRule(_ rule: (trigger: String, value: String)) {
        dismiss()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            VocabularyNavigationCenter.shared.submit(
                VocabularyNavigationRequest(
                    section: .snippets,
                    trigger: rule.trigger,
                    replacement: rule.value
                )
            )
        }
    }

    /// Explains the mismatch between the characters below and the text the
    /// history list showed, and points at the rule that caused it.
    @ViewBuilder
    private var rewriteNotice: some View {
        if let rewritten = rewrittenOutput {
            VStack(alignment: .leading, spacing: TF.spacingXS) {
                Text(L(
                    "这条记录的输出被替换规则改写过，下方是原始识别结果。",
                    "This record's output was rewritten by a replacement rule. The characters below are the original recognition."
                ))
                .font(.system(size: 11))
                .foregroundStyle(TF.settingsTextSecondary)

                HStack(alignment: .firstTextBaseline, spacing: TF.spacingXS) {
                    Text(L("实际输出", "Delivered"))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(TF.settingsTextTertiary)
                    Text(rewritten)
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsText)
                        .textSelection(.enabled)
                }

                ForEach(appliedRules, id: \.trigger) { rule in
                    HStack(spacing: TF.spacingXS) {
                        Text("\(rule.trigger) → \(rule.value)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(TF.settingsText)
                        Button(L("查看规则", "Open rule")) { openRule(rule) }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(TF.settingsAccentBlue)
                    }
                }
            }
            .padding(TF.spacingSM)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: TF.cornerSM, style: .continuous)
                    .fill(TF.settingsCardAlt.opacity(0.6))
            )
            .padding(.bottom, TF.spacingSM)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top bar
            HStack {
                Text(L("纠错", "Correction"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TF.settingsText)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, TF.spacingLG)

            rewriteNotice

            // Scrollable character grid
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: TF.spacingXS) {
                        Text(L("点击或拖选识别错误的字:", "Tap or drag to select misrecognized characters:"))
                            .foregroundStyle(TF.settingsTextTertiary)
                        if !selectedChars.isEmpty {
                            Text(selectedText)
                                .foregroundStyle(TF.settingsText)
                                .fontWeight(.semibold)
                        }
                    }
                    .font(.system(size: 11))
                    .padding(.bottom, TF.spacingSM)

                    WrappingHStack(spacing: 6) {
                        ForEach(Array(characters.enumerated()), id: \.offset) { index, char in
                            charTag(char, index: index)
                        }
                    }
                    .coordinateSpace(name: "charGrid")
                    .onPreferenceChange(QCCharFrameKey.self) { charFrames = $0 }
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 5, coordinateSpace: .named("charGrid"))
                            .onChanged { value in
                                guard let currentIdx = charFrames.first(where: { $0.value.contains(value.location) })?.key else { return }
                                if dragStartIndex == nil {
                                    dragStartIndex = currentIdx
                                    preDragSelection = selectedChars
                                    dragSelectMode = !selectedChars.contains(currentIdx)
                                }
                                guard let startIdx = dragStartIndex else { return }
                                let dragRange = Set(min(startIdx, currentIdx)...max(startIdx, currentIdx))
                                withAnimation(TF.easeQuick) {
                                    if dragSelectMode == true {
                                        selectedChars = preDragSelection.union(dragRange)
                                    } else {
                                        selectedChars = preDragSelection.subtracting(dragRange)
                                    }
                                }
                            }
                            .onEnded { _ in
                                dragStartIndex = nil
                                dragSelectMode = nil
                                preDragSelection = []
                            }
                    )

                }
            }

            // Sticky bottom: input + buttons
            VStack(alignment: .leading, spacing: 0) {
                Divider().opacity(0.2)

                VStack(alignment: .leading, spacing: 6) {
                    Text(L("正确的词", "CORRECT WORD").uppercased())
                        .font(.system(size: 10, weight: .semibold))
                        .tracking(0.8)
                        .foregroundStyle(TF.settingsTextTertiary)
                    TextField(L("输入正确的词...", "Type the correct word..."), text: $correctText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsBg))
                }
                .padding(.top, TF.spacingMD)

                HStack {
                    Spacer()

                    Button { dismiss() } label: {
                        Text(L("取消", "Cancel"))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(TF.settingsTextSecondary)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)

                    Button { addSnippet() } label: {
                        Text(L("添加", "Add"))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(TF.settingsOnStrong)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(canAdd ? TF.settingsText : TF.settingsTextTertiary.opacity(0.3))
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!canAdd)
                    .keyboardShortcut(.defaultAction)
                }
                .padding(.top, TF.spacingMD)
            }
        }
        .padding(20)
        .frame(minWidth: 460, maxWidth: 460, minHeight: 360, maxHeight: 480)
        .background(TF.settingsCardAlt)
        .overlay {
            if showSuccess {
                VStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(TF.settingsAccentGreen)
                    Text(L("添加成功", "Added"))
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(TF.settingsText)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            }
        }
        .onAppear {
            characters = text
                .map { String($0) }
                .filter { $0.rangeOfCharacter(from: .whitespacesAndNewlines) == nil }
        }
    }

    // MARK: - Char Tag

    private func charTag(_ char: String, index: Int) -> some View {
        let isSelected = selectedChars.contains(index)
        return Text(char)
            .font(.system(size: 14))
            .frame(width: 32, height: 32)
            .foregroundStyle(isSelected ? TF.settingsOnStrong : TF.settingsText)
            .background(
                RoundedRectangle(cornerRadius: TF.cornerSM)
                    .fill(isSelected ? TF.settingsText : TF.settingsBg)
            )
            .background(
                GeometryReader { geo in
                    Color.clear.preference(
                        key: QCCharFrameKey.self,
                        value: [index: geo.frame(in: .named("charGrid"))]
                    )
                }
            )
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(TF.easeQuick) {
                    if isSelected { selectedChars.remove(index) }
                    else { selectedChars.insert(index) }
                }
            }
    }

    // MARK: - Action

    private func addSnippet() {
        guard canAdd else { return }
        let correct = correctText.trimmingCharacters(in: .whitespaces)
        let wrong = selectedText
        var current = SnippetStorage.load()
        let didAdd: Bool
        if !current.contains(where: { $0.trigger.lowercased() == wrong.lowercased() }) {
            current.append((trigger: wrong, value: correct))
            SnippetStorage.save(current)
            didAdd = true
        } else {
            didAdd = false
        }
        onComplete?()
        withAnimation(.spring(duration: 0.3)) { showSuccess = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            dismiss()
            if didAdd {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    NotificationCenter.default.post(name: .navigateToVocabulary, object: correct)
                }
            }
        }
    }
}

// MARK: - Preference Key

private struct QCCharFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
