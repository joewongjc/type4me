import SwiftUI
import AppKit

struct SmartCorrectionSheet: View {

    var onComplete: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    // MARK: - Phase

    private enum Phase {
        case input, generating, preview
    }

    @State private var phase: Phase = .input

    // MARK: - Input state

    @State private var correctText: String = ""
    @State private var wrongText: String = ""

    // MARK: - History state

    @State private var historyRecords: [(id: String, date: Date, rawText: String)] = []
    @State private var expandedHistoryText: String? = nil
    @State private var characters: [String] = []
    @State private var selectedChars: Set<Int> = []

    // MARK: - Generating state

    @State private var generationTask: Task<Void, Never>?
    @State private var errorMessage: String?

    // MARK: - Preview state

    @State private var snippetSuggestions: [VariantSuggestion] = []
    @State private var hotwordSuggestions: [HotwordSuggestion] = []
    @State private var hotwordReason: String = ""

    private let historyStore = HistoryStore()
    private let generator = ASRVariantGenerator()

    // MARK: - Computed

    private var selectedText: String {
        selectedChars.sorted().compactMap { idx in
            idx < characters.count ? characters[idx] : nil
        }.joined()
    }

    private var canGenerate: Bool {
        let correct = correctText.trimmingCharacters(in: .whitespaces)
        guard !correct.isEmpty else { return false }
        if expandedHistoryText != nil {
            return !selectedChars.isEmpty
        }
        return !wrongText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var selectedCount: Int {
        snippetSuggestions.filter { $0.isSelected && !$0.isDuplicate }.count
        + hotwordSuggestions.filter { $0.isSelected && !$0.isDuplicate }.count
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch phase {
            case .input:
                if expandedHistoryText != nil {
                    historyDetailView
                } else {
                    mainInputView
                }
            case .generating:
                generatingPhaseView
            case .preview:
                previewPhaseView
            }

            Spacer()

            Divider().opacity(0.2)
            bottomButtons
                .padding(.top, TF.spacingMD)
        }
        .padding(20)
        .frame(minWidth: 500, maxWidth: 500, minHeight: 480)
        .background(TF.settingsCardAlt)
        .onAppear { loadHistory() }
    }

    // MARK: - Main Input View

    private var mainInputView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Close
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, TF.spacingSM)

            // Title
            Text(L("告诉我有什么词识别得不对", "Tell me what was misrecognized"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(TF.settingsText)
                .padding(.bottom, TF.spacingLG)

            // Correct form
            VStack(alignment: .leading, spacing: 6) {
                Text(L("你希望识别出来的词", "WORD YOU EXPECTED").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(TF.settingsTextTertiary)
                TextField("", text: $correctText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsBg))
            }
            .padding(.bottom, TF.spacingMD)

            // Wrong text
            VStack(alignment: .leading, spacing: 6) {
                Text(L("实际识别出来的词", "WORD ACTUALLY RECOGNIZED").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(TF.settingsTextTertiary)
                TextField("", text: $wrongText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsBg))
            }

            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsAccentAmber)
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsTextSecondary)
                }
                .padding(.top, TF.spacingSM)
            }

            // Divider
            Divider().opacity(0.2).padding(.vertical, TF.spacingLG)

            // History section
            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TF.settingsAccentAmber)
                Text(L("或者从历史记录里选", "OR PICK FROM HISTORY").uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            .padding(.bottom, TF.spacingSM)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if historyRecords.isEmpty {
                        Text(L("暂无历史记录", "No history records"))
                            .font(.system(size: 12))
                            .foregroundStyle(TF.settingsTextTertiary)
                            .padding(.vertical, 20)
                            .frame(maxWidth: .infinity)
                    } else {
                        ForEach(historyRecords, id: \.id) { record in
                            historyRow(record)
                        }
                    }
                }
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsBg))
        }
    }

    // MARK: - History Row

    private func historyRow(_ record: (id: String, date: Date, rawText: String)) -> some View {
        Button {
            let chars = record.rawText
                .map { String($0) }
                .filter { $0.rangeOfCharacter(from: .whitespacesAndNewlines) == nil }
            withAnimation(TF.springSnappy) {
                expandedHistoryText = record.rawText
                characters = chars
                selectedChars = []
            }
        } label: {
            HStack(spacing: TF.spacingSM) {
                Text(record.rawText)
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsText)
                    .lineLimit(1)

                Spacer()

                Text(relativeDate(record.date))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)

                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - History Detail View

    private var historyDetailView: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Top bar
            HStack {
                Button {
                    withAnimation(TF.springSnappy) {
                        expandedHistoryText = nil
                        characters = []
                        selectedChars = []
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .semibold))
                        Text(L("返回", "Back"))
                            .font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(TF.settingsAccentBlue)
                }
                .buttonStyle(.plain)

                Spacer()

                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, TF.spacingLG)

            // Correct form
            VStack(alignment: .leading, spacing: 6) {
                Text(L("你希望识别出来的词", "WORD YOU EXPECTED").uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(TF.settingsTextTertiary)
                TextField("", text: $correctText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsBg))
            }
            .padding(.bottom, TF.spacingLG)

            // Character grid
            Text(L("点击选择识别错误的字:", "Tap the misrecognized characters:"))
                .font(.system(size: 11))
                .foregroundStyle(TF.settingsTextTertiary)
                .padding(.bottom, TF.spacingSM)

            WrappingHStack(spacing: 6) {
                ForEach(Array(characters.enumerated()), id: \.offset) { index, char in
                    charTag(char, index: index)
                }
            }

            if !selectedChars.isEmpty {
                HStack(spacing: TF.spacingXS) {
                    Text(L("选中:", "Selected:"))
                        .foregroundStyle(TF.settingsTextTertiary)
                    Text(selectedText)
                        .foregroundStyle(TF.settingsAccentAmber)
                }
                .font(.system(size: 11))
                .padding(.top, TF.spacingSM)
            }

            if let errorMessage {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsAccentAmber)
                    Text(errorMessage)
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsTextSecondary)
                }
                .padding(.top, TF.spacingSM)
            }
        }
    }

    private func charTag(_ char: String, index: Int) -> some View {
        let isSelected = selectedChars.contains(index)
        return Button {
            withAnimation(TF.easeQuick) {
                if isSelected { selectedChars.remove(index) }
                else { selectedChars.insert(index) }
            }
        } label: {
            Text(char)
                .font(.system(size: 14))
                .frame(width: 32, height: 32)
                .foregroundStyle(isSelected ? .white : TF.settingsText)
                .background(
                    RoundedRectangle(cornerRadius: TF.cornerSM)
                        .fill(isSelected ? TF.settingsAccentAmber : TF.settingsBg)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Generating Phase

    private var generatingPhaseView: some View {
        VStack(spacing: TF.spacingMD) {
            Spacer()
            ProgressView()
                .scaleEffect(0.8)
            Text(L("正在生成变体...", "Generating variants..."))
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsTextSecondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Preview Phase

    @ViewBuilder
    private var previewPhaseView: some View {
        HStack {
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.bottom, TF.spacingSM)

        ScrollView {
            VStack(alignment: .leading, spacing: TF.spacingMD) {
                // Snippets
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TF.settingsAccentAmber)
                        Text(L("片段替换建议", "SNIPPET SUGGESTIONS").uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(1.2)
                            .foregroundStyle(TF.settingsTextTertiary)
                    }

                    Spacer()

                    Button { selectAllSnippets() } label: {
                        Text(L("全选", "Select All"))
                            .font(.system(size: 11))
                            .foregroundStyle(TF.settingsAccentBlue)
                    }
                    .buttonStyle(.plain)
                }

                if snippetSuggestions.isEmpty {
                    Text(L("没有生成片段建议", "No snippet suggestions generated"))
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsTextTertiary)
                        .padding(.vertical, TF.spacingSM)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(snippetSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                            if index > 0 { Divider().opacity(0.15) }
                            snippetRow(index: index, suggestion: suggestion)
                        }
                    }
                    .padding(TF.spacingMD)
                    .background(
                        RoundedRectangle(cornerRadius: TF.cornerMD).fill(TF.settingsBg)
                    )
                }

                // Hotwords
                if !hotwordSuggestions.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "text.badge.star")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(TF.settingsAccentAmber)
                        Text(L("热词建议", "HOTWORD SUGGESTIONS").uppercased())
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(1.2)
                            .foregroundStyle(TF.settingsTextTertiary)
                    }
                    .padding(.top, TF.spacingSM)

                    VStack(spacing: 0) {
                        ForEach(Array(hotwordSuggestions.enumerated()), id: \.element.id) { index, suggestion in
                            if index > 0 { Divider().opacity(0.15) }
                            hotwordRow(index: index, suggestion: suggestion)
                        }
                    }
                    .padding(TF.spacingMD)
                    .background(
                        RoundedRectangle(cornerRadius: TF.cornerMD).fill(TF.settingsBg)
                    )

                    if !hotwordReason.isEmpty {
                        Text(hotwordReason)
                            .font(.system(size: 10))
                            .foregroundStyle(TF.settingsTextTertiary)
                            .padding(.top, TF.spacingXS)
                    }
                }
            }
        }
    }

    private func snippetRow(index: Int, suggestion: VariantSuggestion) -> some View {
        HStack(spacing: TF.spacingSM) {
            Toggle("", isOn: Binding(
                get: { suggestion.isSelected },
                set: { snippetSuggestions[index].isSelected = $0 }
            ))
            .toggleStyle(.checkbox)
            .disabled(suggestion.isDuplicate)

            Text(suggestion.trigger)
                .font(.system(size: 12))
                .foregroundStyle(suggestion.isDuplicate ? TF.settingsTextTertiary : TF.settingsText)

            Image(systemName: "arrow.right")
                .font(.system(size: 9))
                .foregroundStyle(TF.settingsTextTertiary)

            Text(suggestion.replacement)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(suggestion.isDuplicate ? TF.settingsTextTertiary : TF.settingsAccentBlue)

            if suggestion.isDuplicate { duplicateBadge }

            Spacer()
        }
        .padding(.vertical, 6)
    }

    private func hotwordRow(index: Int, suggestion: HotwordSuggestion) -> some View {
        HStack(spacing: TF.spacingSM) {
            Toggle("", isOn: Binding(
                get: { suggestion.isSelected },
                set: { hotwordSuggestions[index].isSelected = $0 }
            ))
            .toggleStyle(.checkbox)
            .disabled(suggestion.isDuplicate)

            Text(suggestion.word)
                .font(.system(size: 12))
                .foregroundStyle(suggestion.isDuplicate ? TF.settingsTextTertiary : TF.settingsText)

            if suggestion.isDuplicate { duplicateBadge }

            Spacer()
        }
        .padding(.vertical, 6)
    }

    private var duplicateBadge: some View {
        Text(L("已存在", "Exists"))
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(TF.settingsTextTertiary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: TF.cornerSM).fill(TF.settingsCardAlt)
            )
    }

    // MARK: - Bottom Buttons

    @ViewBuilder
    private var bottomButtons: some View {
        HStack(spacing: TF.spacingMD) {
            switch phase {
            case .input:
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

                Button {
                    startGeneration()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "wand.and.stars")
                            .font(.system(size: 11))
                        Text(L("生成变体", "Generate Variants"))
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 7)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(canGenerate ? TF.settingsAccentAmber : TF.settingsTextTertiary.opacity(0.3))
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!canGenerate)
                .keyboardShortcut(.defaultAction)

            case .generating:
                Spacer()

                Button {
                    generationTask?.cancel()
                    withAnimation(TF.easeQuick) { phase = .input }
                    errorMessage = nil
                } label: {
                    Text(L("取消", "Cancel"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

            case .preview:
                Button {
                    withAnimation(TF.easeQuick) { phase = .input }
                } label: {
                    Text(L("返回修改", "Back to Edit"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TF.settingsAccentBlue)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

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

                Button {
                    saveAndDismiss()
                } label: {
                    Text(L("添加选中项 (\(selectedCount))", "Add Selected (\(selectedCount))"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(selectedCount > 0 ? TF.settingsAccentGreen : TF.settingsTextTertiary.opacity(0.3))
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(selectedCount == 0)
            }
        }
    }

    // MARK: - Actions

    private func loadHistory() {
        Task {
            let records = await historyStore.recentForCorrection(limit: 20)
            await MainActor.run {
                historyRecords = records
            }
        }
    }

    private func startGeneration() {
        guard canGenerate else { return }
        errorMessage = nil

        let wrong: String
        if expandedHistoryText != nil {
            wrong = selectedText
        } else {
            wrong = wrongText.trimmingCharacters(in: .whitespaces)
        }
        let correct = correctText.trimmingCharacters(in: .whitespaces)

        withAnimation(TF.easeQuick) { phase = .generating }

        generationTask = Task {
            do {
                let result = try await generator.generate(wrong: wrong, correct: correct)

                if Task.isCancelled { return }

                await MainActor.run {
                    snippetSuggestions = result.snippets
                    hotwordSuggestions = result.hotwords
                    hotwordReason = result.hotwordReason
                    withAnimation(TF.easeQuick) { phase = .preview }
                }
            } catch {
                if Task.isCancelled { return }

                await MainActor.run {
                    errorMessage = error.localizedDescription
                    withAnimation(TF.easeQuick) { phase = .input }
                }
            }
        }
    }

    private func selectAllSnippets() {
        for i in snippetSuggestions.indices where !snippetSuggestions[i].isDuplicate {
            snippetSuggestions[i].isSelected = true
        }
    }

    private func saveAndDismiss() {
        var currentSnippets = SnippetStorage.load()
        for s in snippetSuggestions where s.isSelected && !s.isDuplicate {
            currentSnippets.append((trigger: s.trigger, value: s.replacement))
        }
        SnippetStorage.save(currentSnippets)

        var currentHotwords = HotwordStorage.load()
        for h in hotwordSuggestions where h.isSelected && !h.isDuplicate {
            currentHotwords.append(h.word)
        }
        HotwordStorage.save(currentHotwords)

        if let url = URL(string: "type4me://reload-vocabulary") {
            NSWorkspace.shared.open(url)
        }

        onComplete?()
        dismiss()
    }

    // MARK: - Helpers

    private func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
