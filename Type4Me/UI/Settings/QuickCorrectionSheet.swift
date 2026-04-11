import SwiftUI

struct QuickCorrectionSheet: View {

    let text: String
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

            // Scrollable character grid
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: TF.spacingXS) {
                        Text(L("点击或拖选识别错误的字:", "Tap or drag to select misrecognized characters:"))
                            .foregroundStyle(TF.settingsTextTertiary)
                        if !selectedChars.isEmpty {
                            Text(selectedText)
                                .foregroundStyle(TF.settingsAccentAmber)
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
                            .foregroundStyle(.white)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(canAdd ? TF.settingsAccentGreen : TF.settingsTextTertiary.opacity(0.3))
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
            .foregroundStyle(isSelected ? .white : TF.settingsText)
            .background(
                RoundedRectangle(cornerRadius: TF.cornerSM)
                    .fill(isSelected ? TF.settingsAccentAmber : TF.settingsBg)
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
        if !current.contains(where: { $0.trigger.lowercased() == wrong.lowercased() }) {
            current.append((trigger: wrong, value: correct))
            SnippetStorage.save(current)
        }
        onComplete?()
        withAnimation(.spring(duration: 0.3)) { showSuccess = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { dismiss() }
    }
}

// MARK: - Preference Key

private struct QCCharFrameKey: PreferenceKey {
    static var defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}
