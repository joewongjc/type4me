import SwiftUI

struct VocabularyTab: View {

    // Hotwords (user file)
    @State private var hotwords: [String] = HotwordStorage.load()
    @State private var newHotword: String = ""
    @State private var builtinHotwordCount: Int = HotwordStorage.builtinCount()
    @State private var showBulkHotwordsSheet = false
    @State private var bulkHotwordsText = ""

    // Snippets (user file)
    @State private var snippets: [(trigger: String, value: String)] = SnippetStorage.load()
    @State private var editingGroupReplacement: String? = nil
    @State private var editReplacementText: String = ""
    @State private var newTriggerTexts: [String: String] = [:]
    @State private var newTrigger: String = ""
    @State private var newValue: String = ""
    @State private var builtinSnippetCount: Int = SnippetStorage.builtinCount()

    // Sort
    @State private var hotwordSort: VocabSort = .byTime
    @State private var snippetSort: VocabSort = .byTime

    private enum VocabSort {
        case byTime, byAlpha
        mutating func toggle() { self = self == .byTime ? .byAlpha : .byTime }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                label: "VOCABULARY",
                title: L("词汇管理", "Vocabulary"),
                description: L("热词提升识别准确率，片段替换实现语音快捷输入。", "Hotwords improve recognition accuracy. Snippets enable voice shortcuts.")
            )

            // MARK: - Hotwords
            HStack(spacing: 8) {
                Text(L("ASR 热词", "ASR Hotwords"))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(TF.settingsText)
                sortToggle($hotwordSort)
            }
            .padding(.bottom, 4)

            Text(L("添加容易被误识别的专有名词，识别引擎会优先匹配。", "Add proper nouns that are often misrecognized. The ASR engine will prioritize them."))
                .font(.system(size: 11))
                .foregroundStyle(TF.settingsTextTertiary)
                .padding(.bottom, 12)

            // Built-in hotwords info bar
            HStack(spacing: 6) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(TF.settingsTextTertiary)
                Text(L("内置 \(builtinHotwordCount) 条热词",
                       "\(builtinHotwordCount) built-in hotwords"))
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextTertiary)

                Divider().frame(height: 12)

                Button {
                    HotwordStorage.revealBuiltinInFinder()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                        Text(L("在 Finder 中打开", "Reveal in Finder"))
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(TF.settingsAccentBlue)
                }
                .buttonStyle(.plain)

                Button {
                    builtinHotwordCount = HotwordStorage.builtinCount()
                    SenseVoiceServerManager.syncHotwordsAndRestart()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsAccentBlue)
                }
                .buttonStyle(.plain)
                .help(L("重新加载内置文件", "Reload built-in file"))

                Spacer()
            }
            .padding(.bottom, 8)

            // User hotwords
            WrappingHStack(spacing: 6) {
                ForEach(displayHotwords, id: \.self) { word in
                    hotwordTag(word)
                }

                TextField(L("添加热词...", "Add hotword..."), text: $newHotword)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 100)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(TF.settingsTextTertiary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4]))
                    )
                    .onSubmit { addHotword() }

                Button {
                    showBulkHotwordsSheet = true
                } label: {
                    Label(L("批量", "Bulk"), systemImage: "list.bullet.rectangle")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(TF.settingsBg))
            }

            Text(L("回车添加，点 × 移除", "Press Enter to add, click x to remove"))
                .font(.system(size: 10))
                .foregroundStyle(TF.settingsTextTertiary)
                .padding(.top, 4)

            // Module separator
            Spacer().frame(height: 20)
            Divider()
            Spacer().frame(height: 20)

            // MARK: - Snippets
            HStack(spacing: 8) {
                Text(L("片段替换", "Snippets"))
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(TF.settingsText)
                sortToggle($snippetSort)
            }
            .padding(.bottom, 4)

            HStack(spacing: 0) {
                Text(L("说到触发词时自动替换为对应内容。搭配 ", "Trigger words are auto-replaced with mapped content. Use with "))
                    .foregroundStyle(TF.settingsTextTertiary)
                Button {
                    NSWorkspace.shared.open(URL(string: "https://github.com/joewongjc/type4me-vocab-skill")!)
                } label: {
                    HStack(spacing: 2) {
                        Text(L("官方 Skill", "official Skill"))
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8))
                    }
                    .foregroundStyle(TF.settingsAccentBlue)
                }
                .buttonStyle(.plain)
                Text(L(" 可快捷管理。", " for easy management."))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            .font(.system(size: 11))
            .padding(.bottom, 12)

            // Built-in snippets info bar
            HStack(spacing: 6) {
                Image(systemName: "tray.full.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(TF.settingsTextTertiary)
                Text(L("内置 \(builtinSnippetCount) 条纠正规则",
                       "\(builtinSnippetCount) built-in correction rules"))
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextTertiary)

                Divider().frame(height: 12)

                Button {
                    SnippetStorage.revealBuiltinInFinder()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                        Text(L("在 Finder 中打开", "Reveal in Finder"))
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(TF.settingsAccentBlue)
                }
                .buttonStyle(.plain)

                Button {
                    builtinSnippetCount = SnippetStorage.builtinCount()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsAccentBlue)
                }
                .buttonStyle(.plain)
                .help(L("重新加载内置文件", "Reload built-in file"))

                Spacer()
            }
            .padding(.bottom, 8)

            // Existing user snippets (grouped by replacement)
            ForEach(Array(displaySnippets.enumerated()), id: \.element.id) { index, group in
                if index > 0 {
                    SettingsDivider()
                }
                snippetGroupView(group: group)
            }

            // Add new row
            HStack(spacing: 8) {
                TextField(L("替换内容", "Replacement"), text: $newValue)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(width: 152)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(TF.settingsTextTertiary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4]))
                    )

                Image(systemName: "arrow.left")
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)

                TextField(L("触发词", "Trigger"), text: $newTrigger)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .frame(width: 120)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(TF.settingsTextTertiary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4]))
                    )
                    .onSubmit { addSnippet() }

                Button {
                    addSnippet()
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(TF.settingsAccentGreen)
                }
                .buttonStyle(.plain)
                .disabled(newTrigger.isEmpty || newValue.isEmpty)
            }
            .padding(.top, 8)

            Text(L("示例: \"hello@example.com\" ← \"我的邮箱\"", "Example: \"hello@example.com\" ← \"my email\""))
                .font(.system(size: 10))
                .foregroundStyle(TF.settingsTextTertiary)
                .padding(.top, 6)

            Spacer()
        }
        .onAppear {
            hotwords = HotwordStorage.load()
            snippets = SnippetStorage.load()
            builtinHotwordCount = HotwordStorage.builtinCount()
            builtinSnippetCount = SnippetStorage.builtinCount()
        }
        .sheet(isPresented: $showBulkHotwordsSheet) {
            bulkHotwordsSheet
                .onAppear {
                    bulkHotwordsText = hotwords.joined(separator: "\n")
                }
        }
    }

    // MARK: - Sort Toggle

    private func sortToggle(_ order: Binding<VocabSort>) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                order.wrappedValue.toggle()
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: order.wrappedValue == .byTime ? "clock" : "textformat.abc")
                    .font(.system(size: 9))
                Text(order.wrappedValue == .byTime
                     ? L("添加时间排序", "Sort by time added")
                     : L("首字母排序", "Sort alphabetically"))
                    .font(.system(size: 10))
            }
            .foregroundStyle(TF.settingsAccentBlue)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Hotword Tag

    private func hotwordTag(_ word: String) -> some View {
        HStack(spacing: 4) {
            Text(word)
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsText)
            Button {
                removeHotword(word)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(TF.settingsBg)
        )
    }

    // MARK: - Snippet Group View

    private struct SnippetGroup: Identifiable {
        var id: String { replacement }
        let replacement: String
        let triggers: [String]
    }

    private var displayHotwords: [String] {
        switch hotwordSort {
        case .byTime: return hotwords
        case .byAlpha: return hotwords.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        }
    }

    private var displaySnippets: [SnippetGroup] {
        let groups = groupedSnippets
        switch snippetSort {
        case .byTime: return groups
        case .byAlpha: return groups.sorted { $0.replacement.localizedCaseInsensitiveCompare($1.replacement) == .orderedAscending }
        }
    }

    private var groupedSnippets: [SnippetGroup] {
        var order: [String] = []
        var dict: [String: [String]] = [:]
        for s in snippets {
            if dict[s.value] == nil {
                order.append(s.value)
            }
            dict[s.value, default: []].append(s.trigger)
        }
        return order.map { SnippetGroup(replacement: $0, triggers: dict[$0]!) }
    }

    private func newTriggerBinding(for replacement: String) -> Binding<String> {
        Binding(
            get: { newTriggerTexts[replacement, default: ""] },
            set: { newTriggerTexts[replacement] = $0 }
        )
    }

    private func snippetGroupView(group: SnippetGroup) -> some View {
        HStack(spacing: 6) {
            // Replacement (left side)
            if editingGroupReplacement == group.replacement {
                TextField("", text: $editReplacementText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 4).fill(TF.settingsBg))
                    .onSubmit { commitGroupEdit(oldReplacement: group.replacement) }

                Button { commitGroupEdit(oldReplacement: group.replacement) } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(TF.settingsAccentGreen)
                }
                .buttonStyle(.plain)

                Button { editingGroupReplacement = nil } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .buttonStyle(.plain)
            } else {
                Text(group.replacement)
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsText)
            }

            Image(systemName: "arrow.left")
                .font(.system(size: 9))
                .foregroundStyle(TF.settingsTextTertiary)

            // Trigger tags (right side)
            WrappingHStack(spacing: 4) {
                ForEach(group.triggers, id: \.self) { trigger in
                    triggerTag(trigger: trigger, replacement: group.replacement)
                }

                TextField(L("添加...", "Add..."), text: newTriggerBinding(for: group.replacement))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11))
                    .frame(width: 60)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(TF.settingsTextTertiary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4]))
                    )
                    .onSubmit { addTriggerToGroup(replacement: group.replacement) }
            }

            Spacer()

            if editingGroupReplacement != group.replacement {
                Button { startGroupEdit(replacement: group.replacement) } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 9))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .buttonStyle(.plain)

                Button { removeGroup(replacement: group.replacement) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
    }

    private func triggerTag(trigger: String, replacement: String) -> some View {
        HStack(spacing: 4) {
            Text(trigger)
                .font(.system(size: 11))
                .foregroundStyle(TF.settingsTextSecondary)
            Button {
                removeTrigger(trigger: trigger, replacement: replacement)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(TF.settingsTextTertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6).fill(TF.settingsBg)
        )
    }

    // MARK: - Group Actions

    private func startGroupEdit(replacement: String) {
        editReplacementText = replacement
        editingGroupReplacement = replacement
    }

    private func commitGroupEdit(oldReplacement: String) {
        let newReplacement = editReplacementText.trimmingCharacters(in: .whitespaces)
        guard !newReplacement.isEmpty, newReplacement != oldReplacement else {
            editingGroupReplacement = nil
            return
        }
        for i in snippets.indices {
            if snippets[i].value == oldReplacement {
                snippets[i] = (trigger: snippets[i].trigger, value: newReplacement)
            }
        }
        SnippetStorage.save(snippets)
        editingGroupReplacement = nil
    }

    private func removeGroup(replacement: String) {
        snippets.removeAll { $0.value == replacement }
        SnippetStorage.save(snippets)
    }

    private func removeTrigger(trigger: String, replacement: String) {
        if let idx = snippets.firstIndex(where: { $0.trigger == trigger && $0.value == replacement }) {
            snippets.remove(at: idx)
            SnippetStorage.save(snippets)
        }
    }

    private func addTriggerToGroup(replacement: String) {
        let trigger = (newTriggerTexts[replacement] ?? "").trimmingCharacters(in: .whitespaces)
        guard !trigger.isEmpty else { return }
        guard !snippets.contains(where: { $0.trigger.lowercased() == trigger.lowercased() }) else {
            newTriggerTexts[replacement] = ""
            return
        }
        snippets.append((trigger: trigger, value: replacement))
        SnippetStorage.save(snippets)
        newTriggerTexts[replacement] = ""
    }

    // MARK: - Actions

    private func addHotword() {
        let word = newHotword.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, !hotwords.contains(word) else {
            newHotword = ""
            return
        }
        hotwords.append(word)
        HotwordStorage.save(hotwords)
        newHotword = ""
    }

    private func removeHotword(_ word: String) {
        hotwords.removeAll { $0 == word }
        HotwordStorage.save(hotwords)
    }

    private func addSnippet() {
        let trigger = newTrigger.trimmingCharacters(in: .whitespaces)
        let value = newValue.trimmingCharacters(in: .whitespaces)
        guard !trigger.isEmpty, !value.isEmpty else { return }
        guard !snippets.contains(where: { $0.trigger == trigger }) else { return }
        snippets.append((trigger: trigger, value: value))
        SnippetStorage.save(snippets)
        newTrigger = ""
        newValue = ""
    }

    // MARK: - Bulk Hotwords Sheet

    private var bulkHotwordsSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                Text(L("批量管理热词", "Bulk Edit Hotwords"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TF.settingsText)
                Spacer()
                Button {
                    showBulkHotwordsSheet = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(TF.settingsTextTertiary)
                }
                .buttonStyle(.plain)
            }

            // Description
            Text(L("每行一个热词，保存后将覆盖所有自定义热词。", "One hotword per line. Saving will replace all custom hotwords."))
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsTextTertiary)

            // Text editor
            TextEditor(text: $bulkHotwordsText)
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsText)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsBg))
                .frame(minHeight: 300, maxHeight: 400)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(TF.settingsTextTertiary.opacity(0.3), lineWidth: 1)
                )

            // Stats
            HStack {
                Text(L("\(bulkHotwordsLines.count) 条热词", "\(bulkHotwordsLines.count) hotwords"))
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextTertiary)
                Spacer()
            }

            // Actions
            HStack(spacing: 12) {
                Spacer()
                Button {
                    showBulkHotwordsSheet = false
                } label: {
                    Text(L("取消", "Cancel"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Button {
                    saveBulkHotwords()
                } label: {
                    Text(L("保存", "Save"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsAccentAmber))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(bulkHotwordsLines.isEmpty && hotwords.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(TF.settingsCardAlt)
    }

    private var bulkHotwordsLines: [String] {
        bulkHotwordsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func saveBulkHotwords() {
        let newWords = bulkHotwordsLines
        hotwords = newWords
        HotwordStorage.save(newWords)
        showBulkHotwordsSheet = false
    }

}
