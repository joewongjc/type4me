import SwiftUI

/// Chrome-style tab shape with concave bottom corners.
///
/// The shape is split into two zones:
/// - **Body** (top portion): the visible tab, with convex rounded top corners
/// - **Feet** (bottom portion, height = footRadius): extends wider than the body,
///   connected by concave quarter-circle arcs
///
///       ╭──────────────╮
///       │   Tab Text   │
///    ╭──╯              ╰──╮
///    ╰────────────────────╯   ← flat bottom, sits on content area
///
private struct ChromeTabShape: Shape {
    var topRadius: CGFloat = 8
    var footRadius: CGFloat = 6
    var skipLeftFoot: Bool = false
    /// Extra height on left side to cover content area's top-left corner
    var leftExtraBottom: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let w = rect.width
        let h = rect.height
        let tr = min(topRadius, (h - footRadius) / 2)
        let fr = min(footRadius, h / 3)

        return Path { p in
            if skipLeftFoot {
                // No left foot: straight left edge, extends below to cover corner gap
                let leftBottom = h + leftExtraBottom
                p.move(to: CGPoint(x: 0, y: leftBottom))
                p.addLine(to: CGPoint(x: 0, y: tr))

                // Top-left corner (convex)
                p.addArc(
                    center: CGPoint(x: tr, y: tr),
                    radius: tr,
                    startAngle: .degrees(180),
                    endAngle: .degrees(270),
                    clockwise: false
                )
            } else {
                // Left foot with concave arc
                p.move(to: CGPoint(x: 0, y: h))
                p.addArc(
                    center: CGPoint(x: 0, y: h - fr),
                    radius: fr,
                    startAngle: .degrees(90),
                    endAngle: .degrees(0),
                    clockwise: true
                )
                p.addLine(to: CGPoint(x: fr, y: tr))

                // Top-left corner (convex)
                p.addArc(
                    center: CGPoint(x: fr + tr, y: tr),
                    radius: tr,
                    startAngle: .degrees(180),
                    endAngle: .degrees(270),
                    clockwise: false
                )
            }

            // Top edge
            let rightBodyX = w - fr - tr
            p.addLine(to: CGPoint(x: rightBodyX, y: 0))

            // Top-right corner (convex)
            p.addArc(
                center: CGPoint(x: rightBodyX, y: tr),
                radius: tr,
                startAngle: .degrees(270),
                endAngle: .degrees(0),
                clockwise: false
            )

            // Right side down to right foot
            p.addLine(to: CGPoint(x: w - fr, y: h - fr))

            // Right foot: concave arc
            p.addArc(
                center: CGPoint(x: w, y: h - fr),
                radius: fr,
                startAngle: .degrees(180),
                endAngle: .degrees(90),
                clockwise: true
            )
        }
    }
}

private struct VocabularyToolbarButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(TF.settingsTextSecondary)
                .frame(width: 34, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isHovered ? TF.settingsControlHover : TF.settingsControl)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.black.opacity(0.06), lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .settingsTooltip(title)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
            if hovering {
                NSCursor.pointingHand.set()
            } else {
                NSCursor.arrow.set()
            }
        }
    }
}

private struct AddAppButtonAnchorKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = nextValue() ?? value
    }
}

struct VocabularyTab: View {

    private enum VocabularyInputFocus: Hashable {
        case hotword
        case snippetTrigger
        case snippetReplacement
    }

    @State private var selectedSection: VocabularySection = .hotwords
    @State private var isSearchExpanded = false
    @State private var searchQuery = ""
    @FocusState private var isSearchFocused: Bool
    @FocusState private var focusedVocabularyInput: VocabularyInputFocus?

    // Hotwords (user file)
    @State private var hotwords: [String] = HotwordStorage.load()
    @State private var newHotword: String = ""
    @State private var showBulkHotwordsSheet = false
    @State private var bulkHotwordsText = ""
    @State private var hoveredHotword: String?
    @State private var editingHotword: String?
    @State private var editingHotwordText = ""

    // Snippets (user file + built-in)
    @State private var snippets: [(trigger: String, value: String)] = SnippetStorage.load()
    @State private var editingGroupReplacement: String? = nil
    @State private var editReplacementText: String = ""
    @State private var newTriggerTexts: [String: String] = [:]
    @State private var newTrigger: String = ""
    @State private var newSnippetTriggers: [String] = []
    @State private var newValue: String = ""
    @State private var hoveredSnippetGroup: String? = nil
    @State private var isAddAppHovered = false
    @State private var showBulkSnippetsSheet = false
    @State private var bulkSnippetsText = ""

    // App-specific scope
    @State private var registeredApps: [SnippetStorage.AppInfo] = []
    @State private var selectedAppScope: String? = nil  // nil = global
    @State private var deletingAppBundleId: String? = nil

    // Built-in example snippet
    private static let builtinExampleReplacement = "Type4Me"
    private static let builtinExampleTriggers = ["typeform me", "typefrom me", "type for me", "typeform"]

    // Highlight & scroll
    @State private var highlightedGroup: String? = nil

    // Sort
    @State private var hotwordSort: VocabSort = .byTime
    @State private var snippetSort: VocabSort = .byTime

    private enum VocabSort {
        case byTime, byAlpha
        mutating func toggle() { self = self == .byTime ? .byAlpha : .byTime }
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(alignment: .leading, spacing: 0) {
                SettingsSectionHeader(
                    label: L("词汇", "VOCABULARY"),
                    title: L("词汇管理", "Vocabulary"),
                    description: L("热词提升识别准确率，片段替换实现语音快捷输入。", "Hotwords improve recognition accuracy. Snippets enable voice shortcuts.")
                )

                HStack(spacing: 16) {
                    vocabularySectionPicker
                    Spacer(minLength: 20)
                    vocabularySectionToolbar
                }
                .padding(.bottom, 8)

                Text(vocabularySectionDescription)
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .padding(.bottom, 18)

                Group {
                    switch selectedSection {
                    case .hotwords:
                        hotwordsSection
                    case .snippets:
                        snippetsSection
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .onReceive(NotificationCenter.default.publisher(for: .navigateToVocabulary)) { note in
                if let request = note.object as? VocabularyNavigationRequest {
                    applyNavigationRequest(request)
                    return
                }
                guard let replacement = note.object as? String else { return }
                // Quick Correction always writes to the global snippet store.
                // Reset view-only filters before resolving the scroll target so
                // the newly added group is guaranteed to exist in the hierarchy.
                searchQuery = ""
                switchScope(to: nil)
                withAnimation(.easeInOut(duration: 0.18)) {
                    selectedSection = .snippets
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    withAnimation(.easeInOut(duration: 0.4)) {
                        proxy.scrollTo("snippet-\(replacement)", anchor: .center)
                    }
                    withAnimation(.easeIn(duration: 0.3).delay(0.2)) {
                        highlightedGroup = replacement
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                        withAnimation(.easeOut(duration: 0.8)) {
                            highlightedGroup = nil
                        }
                    }
                }
            }
        } // ScrollViewReader
        .onAppear {
            hotwords = HotwordStorage.load()
            snippets = SnippetStorage.load()
            registeredApps = SnippetStorage.loadRegistry()
            seedExampleIfNeeded()
            if let request = VocabularyNavigationCenter.shared.pendingRequest {
                applyNavigationRequest(request)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: SnippetStorage.didChangeNotification)) { _ in
            if let bundleId = selectedAppScope {
                snippets = SnippetStorage.loadAppSnippets(bundleId: bundleId)
            } else {
                snippets = SnippetStorage.load()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: HotwordStorage.didChangeNotification)) { _ in
            hotwords = HotwordStorage.load()
        }
        .sheet(isPresented: $showBulkHotwordsSheet) {
            bulkHotwordsSheet
                .onAppear {
                    bulkHotwordsText = hotwords.joined(separator: "\n")
                }
        }
        .sheet(isPresented: $showBulkSnippetsSheet) {
            bulkSnippetsSheet
                .onAppear {
                    bulkSnippetsText = snippetsToBulkText(snippets)
                }
        }
        .alert(
            L("移除应用", "Remove App"),
            isPresented: Binding(
                get: { deletingAppBundleId != nil },
                set: { if !$0 { deletingAppBundleId = nil } }
            )
        ) {
            Button(L("取消", "Cancel"), role: .cancel) { deletingAppBundleId = nil }
            Button(L("移除", "Remove"), role: .destructive) {
                if let id = deletingAppBundleId {
                    removeAppScope(bundleId: id)
                    deletingAppBundleId = nil
                }
            }
        } message: {
            if let id = deletingAppBundleId, let app = registeredApps.first(where: { $0.bundleId == id }) {
                Text(L("确定要移除「\(app.name)」的专属片段吗？已配置的片段将被删除。",
                        "Remove \"\(app.name)\" and its snippets? This cannot be undone."))
            }
        }
    }

    // MARK: - Primary Section Tabs

    private var vocabularySectionPicker: some View {
        LiquidGlassTabPicker(
            items: [.hotwords, .snippets],
            selection: selectedSection,
            onSelectionChange: { selectedSection = $0 }
        ) { section, isSelected, _ in
            Text(section == .hotwords ? L("ASR 热词", "ASR Hotwords") : L("片段替换", "Snippets"))
                .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                .foregroundStyle(isSelected ? TF.settingsText : TF.settingsTextSecondary)
                .padding(.horizontal, 18)
                .frame(height: 32)
        }
        .fixedSize()
    }

    private var vocabularySectionDescription: String {
        switch selectedSection {
        case .hotwords:
            return L(
                "添加热词，将被上传给识别引擎被优先识别。",
                "Added hotwords are uploaded to the ASR engine for priority recognition."
            )
        case .snippets:
            return L(
                "本地执行规则，将任何文字替换成你想要的文字。",
                "Local rules that replace any text with what you want."
            )
        }
    }

    @ViewBuilder
    private var vocabularySectionToolbar: some View {
        switch selectedSection {
        case .hotwords:
            HStack(spacing: 7) {
                vocabularySearchControl

                VocabularyToolbarButton(
                    title: hotwordSort == .byTime
                        ? L("按添加时间排序", "Sort by time added")
                        : L("按首字母排序", "Sort alphabetically"),
                    icon: hotwordSort == .byTime ? "clock.arrow.circlepath" : "textformat.abc"
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        hotwordSort.toggle()
                    }
                }

                VocabularyToolbarButton(
                    title: L("批量编辑", "Bulk Edit"),
                    icon: "list.bullet.rectangle"
                ) {
                    showBulkHotwordsSheet = true
                }
            }
        case .snippets:
            HStack(spacing: 7) {
                vocabularySearchControl

                VocabularyToolbarButton(
                    title: snippetSort == .byTime
                        ? L("按添加时间排序", "Sort by time added")
                        : L("按首字母排序", "Sort alphabetically"),
                    icon: snippetSort == .byTime ? "clock.arrow.circlepath" : "textformat.abc"
                ) {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        snippetSort.toggle()
                    }
                }

                VocabularyToolbarButton(
                    title: L("批量编辑", "Bulk Edit"),
                    icon: "list.bullet.rectangle"
                ) {
                    showBulkSnippetsSheet = true
                }
            }
        }
    }

    private var vocabularySearchControl: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(TF.settingsTextSecondary)

            if isSearchExpanded {
                TextField(L("搜索词汇", "Search vocabulary"), text: $searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($isSearchFocused)
                    .transition(.opacity)

                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        searchQuery = ""
                        isSearchExpanded = false
                    }
                    isSearchFocused = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(TF.settingsTextTertiary)
                        .frame(width: 18, height: 18)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, isSearchExpanded ? 10 : 0)
        .frame(width: isSearchExpanded ? 190 : 34, height: 34)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(TF.settingsControl)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.black.opacity(0.06), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .settingsTooltip(L("搜索", "Search"), isEnabled: !isSearchExpanded)
        .onTapGesture {
            guard !isSearchExpanded else { return }
            withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                isSearchExpanded = true
            }
            DispatchQueue.main.async {
                isSearchFocused = true
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: isSearchExpanded)
    }

    private var hotwordAddControl: some View {
        HStack(spacing: 10) {
            TextField(L("输入新的热词", "Enter a new hotword"), text: $newHotword)
                .focused($focusedVocabularyInput, equals: .hotword)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(TF.settingsControl)
                )
                .onSubmit { addHotword() }

            Button(action: addHotword) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(newHotword.trimmingCharacters(in: .whitespaces).isEmpty
                              ? TF.settingsTextTertiary
                              : TF.settingsText)
                    )
            }
            .buttonStyle(.plain)
            .disabled(newHotword.trimmingCharacters(in: .whitespaces).isEmpty)
            .settingsTooltip(L("添加新热词", "Add new hotword"))
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(TF.settingsCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(TF.settingsBorder, lineWidth: 1)
        )
    }

    private var hotwordsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            hotwordAddControl
                .zIndex(3)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    WrappingHStack(spacing: 6) {
                        ForEach(displayHotwords, id: \.self) { word in
                            hotwordTag(word)
                        }
                    }

                    if displayHotwords.isEmpty && isSearching {
                        VStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 20))
                                .foregroundStyle(TF.settingsTextTertiary)
                            Text(L("没有匹配的热词", "No matching hotwords"))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(TF.settingsTextSecondary)
                            Text(L("尝试更换搜索关键词。", "Try a different search term."))
                                .font(.system(size: 11))
                                .foregroundStyle(TF.settingsTextTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 30)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var snippetsSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            appScopeBar()
                .zIndex(4)

            newSnippetEditor
                .zIndex(3)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 7) {
                    ForEach(displaySnippets) { group in
                        snippetGroupView(group: group)
                            .id("snippet-\(group.id)")
                    }

                    if displaySnippets.isEmpty {
                        snippetEmptyState
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.bottom, 4)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var newSnippetEditor: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                TextField(L("替换内容", "Replacement text"), text: $newValue)
                    .focused($focusedVocabularyInput, equals: .snippetReplacement)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 12)
                    .frame(width: 240, height: 38)
                    .background(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(TF.settingsControl)
                    )

                Image(systemName: "arrow.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TF.settingsTextTertiary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(newSnippetTriggers, id: \.self) { trigger in
                            draftTriggerTag(trigger)
                        }

                        TextField(
                            L(
                                "输入触发词，回车可继续添加",
                                "Trigger · Return to add more"
                            ),
                            text: $newTrigger
                        )
                        .focused($focusedVocabularyInput, equals: .snippetTrigger)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .frame(minWidth: 130, idealWidth: 170)
                        .onSubmit { stageNewSnippetTrigger() }
                    }
                    .padding(.horizontal, 10)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(TF.settingsControl)
                )

                Button(action: addSnippet) {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 38, height: 38)
                        .background(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(canAddSnippet ? TF.settingsText : TF.settingsTextTertiary)
                        )
                }
                .buttonStyle(.plain)
                .disabled(!canAddSnippet)
                .settingsTooltip(L("添加片段替换", "Add snippet"))
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(TF.settingsCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(TF.settingsBorder, lineWidth: 1)
        )
    }

    private var canAddSnippet: Bool {
        (!newSnippetTriggers.isEmpty || !newTrigger.trimmingCharacters(in: .whitespaces).isEmpty)
            && !newValue.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func draftTriggerTag(_ trigger: String) -> some View {
        HStack(spacing: 5) {
            Text(trigger)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TF.settingsTextSecondary)
            Button {
                newSnippetTriggers.removeAll { $0 == trigger }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .frame(width: 13, height: 13)
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 9)
        .padding(.trailing, 6)
        .frame(height: 26)
        .background(Capsule().fill(Color.white.opacity(0.86)))
        .overlay(Capsule().stroke(Color.black.opacity(0.05), lineWidth: 1))
    }

    private var snippetEmptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: isSearching ? "magnifyingglass" : "text.badge.plus")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(TF.settingsTextTertiary)
            Text(isSearching
                 ? L("没有匹配的片段", "No matching snippets")
                 : L("还没有片段替换规则", "No snippet rules yet"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(TF.settingsTextSecondary)
            Text(isSearching
                 ? L("尝试更换搜索关键词。", "Try a different search term.")
                 : L("添加触发词，让常用内容一说即用。", "Add a trigger phrase to insert frequently used text instantly."))
                .font(.system(size: 11))
                .foregroundStyle(TF.settingsTextTertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 34)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.018))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(TF.settingsBorder, lineWidth: 1)
        )
    }

    // MARK: - Hotword Tag

    private func hotwordTag(_ word: String) -> some View {
        let isHovered = hoveredHotword == word
        let isEditing = editingHotword == word

        return HStack(spacing: 7) {
            if isEditing {
                TextField("", text: $editingHotwordText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TF.settingsText)
                    .frame(minWidth: 90)
                    .fixedSize(horizontal: true, vertical: false)
                    .onSubmit { commitHotwordEdit(original: word) }

                hotwordActionButton(
                    icon: "checkmark",
                    color: TF.settingsAccentGreen,
                    help: L("保存", "Save")
                ) {
                    commitHotwordEdit(original: word)
                }
                hotwordActionButton(
                    icon: "xmark",
                    color: TF.settingsTextTertiary,
                    help: L("取消", "Cancel")
                ) {
                    cancelHotwordEdit()
                }
            } else {
                Text(word)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(TF.settingsText)

                if isHovered {
                    hotwordActionButton(
                        icon: "pencil",
                        color: TF.settingsTextSecondary,
                        help: L("编辑", "Edit")
                    ) {
                        startHotwordEdit(word)
                    }
                    hotwordActionButton(
                        icon: "trash",
                        color: TF.settingsAccentRed,
                        help: L("删除", "Delete")
                    ) {
                        removeHotword(word)
                    }
                }
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, isHovered || isEditing ? 8 : 14)
        .frame(height: 38)
        .background(
            Capsule()
                .fill(isHovered || isEditing
                      ? TF.settingsControlHover
                      : TF.settingsControl)
        )
        .overlay(
            Capsule()
                .stroke(isEditing ? TF.settingsText.opacity(0.18) : Color.black.opacity(0.05), lineWidth: 1)
        )
        .contentShape(Capsule())
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredHotword = hovering ? word : nil
            }
        }
    }

    private func hotwordActionButton(
        icon: String,
        color: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.white.opacity(0.78)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    // MARK: - Snippet Group View

    private struct SnippetGroup: Identifiable {
        var id: String { replacement }
        let replacement: String
        let triggers: [String]
    }

    private var displayHotwords: [String] {
        let filtered = hotwords.filter(matchesSearch)
        switch hotwordSort {
        case .byTime: return filtered
        case .byAlpha: return filtered.sorted { $0.localizedAlphabeticalCompare($1) == .orderedAscending }
        }
    }

    private var displaySnippets: [SnippetGroup] {
        let groups = groupedSnippets.filter { group in
            matchesSearch(group.replacement) || group.triggers.contains(where: matchesSearch)
        }
        switch snippetSort {
        case .byTime: return groups
        case .byAlpha: return groups.sorted { $0.replacement.localizedAlphabeticalCompare($1.replacement) == .orderedAscending }
        }
    }

    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func matchesSearch(_ value: String) -> Bool {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        return value.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive]
        ) != nil
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
        let isHovered = hoveredSnippetGroup == group.replacement
        let isEditing = editingGroupReplacement == group.replacement

        return HStack(spacing: 10) {
            Group {
                if isEditing {
                    TextField("", text: $editReplacementText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(TF.settingsText)
                        .padding(.horizontal, 9)
                        .frame(height: 28)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(TF.settingsBg)
                        )
                        .onSubmit { commitGroupEdit(oldReplacement: group.replacement) }
                } else {
                    HStack(spacing: 6) {
                        Text(group.replacement)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(TF.settingsText)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if group.replacement == Self.builtinExampleReplacement {
                            Text(L("示例", "Example"))
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(TF.settingsTextTertiary)
                                .padding(.horizontal, 6)
                                .frame(height: 18)
                                .background(Capsule().fill(TF.settingsCardAlt))
                        }
                    }
                }
            }
            .frame(width: 180, alignment: .leading)

            Image(systemName: "arrow.left")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(TF.settingsTextTertiary)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(group.triggers, id: \.self) { trigger in
                        triggerTag(
                            trigger: trigger,
                            replacement: group.replacement,
                            showsRemove: isHovered || isEditing
                        )
                    }

                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(TF.settingsTextTertiary)
                        TextField(
                            L("添加触发词", "Add trigger"),
                            text: newTriggerBinding(for: group.replacement)
                        )
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .frame(width: 82)
                        .onSubmit { addTriggerToGroup(replacement: group.replacement) }
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(
                        Capsule()
                            .stroke(
                                TF.settingsTextTertiary.opacity(0.28),
                                style: StrokeStyle(lineWidth: 1, dash: [4])
                            )
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 28)

            if isEditing {
                snippetCardActionButton(
                    icon: "checkmark",
                    color: TF.settingsAccentGreen,
                    tooltip: L("保存", "Save")
                ) { commitGroupEdit(oldReplacement: group.replacement) }
                snippetCardActionButton(
                    icon: "xmark",
                    color: TF.settingsTextTertiary,
                    tooltip: L("取消", "Cancel")
                ) { editingGroupReplacement = nil }
            } else if isHovered {
                snippetCardActionButton(
                    icon: "pencil",
                    color: TF.settingsTextSecondary,
                    tooltip: L("编辑替换内容", "Edit replacement")
                ) { startGroupEdit(replacement: group.replacement) }
                snippetCardActionButton(
                    icon: "trash",
                    color: TF.settingsAccentRed,
                    tooltip: L("删除整组", "Delete group")
                ) { removeGroup(replacement: group.replacement) }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(highlightedGroup == group.replacement
                      ? TF.settingsAccentGreen.opacity(0.10)
                      : (isHovered || isEditing
                         ? TF.settingsRowHover
                         : TF.settingsCard))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    highlightedGroup == group.replacement
                        ? TF.settingsAccentGreen.opacity(0.32)
                        : (isHovered || isEditing ? Color.black.opacity(0.11) : TF.settingsBorder),
                    lineWidth: 1
                )
        )
        .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .zIndex(isHovered || isEditing ? 3 : 0)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.1)) {
                hoveredSnippetGroup = hovering ? group.replacement : nil
            }
        }
    }

    private func snippetCardActionButton(
        icon: String,
        color: Color,
        tooltip: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 24, height: 24)
                .background(Circle().fill(TF.settingsCardAlt))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .settingsTooltip(tooltip)
    }

    private func triggerTag(trigger: String, replacement: String, showsRemove: Bool) -> some View {
        HStack(spacing: 6) {
            Text(trigger)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(TF.settingsTextSecondary)

            if showsRemove {
                Button {
                    removeTrigger(trigger: trigger, replacement: replacement)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(TF.settingsTextTertiary)
                        .frame(width: 14, height: 14)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .settingsTooltip(L("删除触发词", "Remove trigger"))
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, showsRemove ? 6 : 10)
        .frame(height: 26)
        .background(Capsule().fill(TF.settingsControl))
        .overlay(Capsule().stroke(Color.black.opacity(0.045), lineWidth: 1))
    }

    // MARK: - App Scope Bar

    private func appScopeBar() -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                LiquidGlassTabPicker(
                    items: appScopeBundleIDs,
                    selection: selectedAppScope,
                    onSelectionChange: switchScope(to:)
                ) { bundleId, isSelected, _ in
                    let app = bundleId.flatMap { id in
                        registeredApps.first(where: { $0.bundleId == id })
                    }
                    HStack(spacing: 6) {
                        if bundleId == nil {
                            Image(systemName: "globe")
                                .font(.system(size: 11, weight: .medium))
                        } else if let bundleId, let icon = appIcon(for: bundleId) {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 14, height: 14)
                        }
                        Text(app?.name ?? L("全局生效", "Global"))
                            .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isSelected ? TF.settingsText : TF.settingsTextSecondary)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .contextMenu {
                        if let bundleId {
                            Button(role: .destructive) {
                                removeAppScope(bundleId: bundleId)
                            } label: {
                                Label(L("移除", "Remove"), systemImage: "trash")
                            }
                        }
                    }
                }

                Button { pickApp() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .frame(width: 30, height: 30)
                        .background(
                            Circle().fill(
                                isAddAppHovered
                                    ? TF.settingsControlHover
                                    : TF.settingsControl
                            )
                        )
                        .overlay(Circle().stroke(Color.black.opacity(0.06), lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .anchorPreference(key: AddAppButtonAnchorKey.self, value: .bounds) { $0 }
                .onHover { hovering in
                    withAnimation(.easeOut(duration: 0.08)) {
                        isAddAppHovered = hovering
                    }
                    if hovering {
                        NSCursor.pointingHand.set()
                    } else {
                        NSCursor.arrow.set()
                    }
                }
            }
        }
        .overlayPreferenceValue(AddAppButtonAnchorKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor, isAddAppHovered {
                    let buttonFrame = proxy[anchor]
                    SettingsTooltipBubble(text: L("添加应用范围", "Add app scope"))
                        .position(
                            x: buttonFrame.midX,
                            y: buttonFrame.maxY + 20
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                }
            }
        }
    }

    private var appScopeBundleIDs: [String?] {
        [nil] + registeredApps.map { Optional($0.bundleId) }
    }

    private func appIcon(for bundleId: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 14, height: 14)
        return icon
    }

    private func switchScope(to bundleId: String?) {
        selectedAppScope = bundleId
        if let bundleId = bundleId {
            snippets = SnippetStorage.loadAppSnippets(bundleId: bundleId)
        } else {
            snippets = SnippetStorage.load()
        }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.title = L("选择应用", "Select Application")
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        // Use begin() instead of runModal() to avoid first-click focus issues in SwiftUI
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let bundle = Bundle(url: url),
                  let bundleId = bundle.bundleIdentifier else { return }

            let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent

            let app = SnippetStorage.AppInfo(bundleId: bundleId, name: name)
            guard !self.registeredApps.contains(app) else {
                self.switchScope(to: bundleId)
                return
            }
            SnippetStorage.addApp(app)
            self.registeredApps = SnippetStorage.loadRegistry()
            self.switchScope(to: bundleId)
        }
    }

    private func removeAppScope(bundleId: String) {
        SnippetStorage.removeApp(bundleId: bundleId)
        registeredApps = SnippetStorage.loadRegistry()
        if selectedAppScope == bundleId {
            switchScope(to: nil)
        }
    }

    private func saveCurrentSnippets() {
        if let bundleId = selectedAppScope {
            SnippetStorage.saveAppSnippets(snippets, bundleId: bundleId)
        } else {
            SnippetStorage.save(snippets)
        }
    }

    // MARK: - Example Seeding

    private static let seededKey = "tf_snippetExampleSeeded"

    private func seedExampleIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Self.seededKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.seededKey)
        guard snippets.isEmpty else { return }
        for trigger in Self.builtinExampleTriggers {
            snippets.append((trigger: trigger, value: Self.builtinExampleReplacement))
        }
        SnippetStorage.save(snippets)
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
        saveCurrentSnippets()
        editingGroupReplacement = nil
    }

    private func removeGroup(replacement: String) {
        snippets.removeAll { $0.value == replacement }
        saveCurrentSnippets()
    }

    private func removeTrigger(trigger: String, replacement: String) {
        if let idx = snippets.firstIndex(where: { $0.trigger == trigger && $0.value == replacement }) {
            snippets.remove(at: idx)
            saveCurrentSnippets()
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
        saveCurrentSnippets()
        newTriggerTexts[replacement] = ""
    }

    // MARK: - Actions

    private func applyNavigationRequest(_ request: VocabularyNavigationRequest) {
        searchQuery = ""
        isSearchExpanded = false
        switchScope(to: nil)
        selectedSection = request.section

        switch request.section {
        case .hotwords:
            if let word = request.word { newHotword = word }
        case .snippets:
            newSnippetTriggers = []
            newTrigger = request.trigger ?? ""
            newValue = request.replacement ?? ""
        }

        VocabularyNavigationCenter.shared.consume(request)
        DispatchQueue.main.async {
            switch request.focus {
            case .hotword: focusedVocabularyInput = .hotword
            case .snippetTrigger: focusedVocabularyInput = .snippetTrigger
            case .snippetReplacement: focusedVocabularyInput = .snippetReplacement
            case nil: focusedVocabularyInput = nil
            }
        }
    }

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
        if editingHotword == word {
            cancelHotwordEdit()
        }
    }

    private func startHotwordEdit(_ word: String) {
        editingHotword = word
        editingHotwordText = word
    }

    private func cancelHotwordEdit() {
        editingHotword = nil
        editingHotwordText = ""
    }

    private func commitHotwordEdit(original: String) {
        let updated = editingHotwordText.trimmingCharacters(in: .whitespaces)
        guard !updated.isEmpty else {
            cancelHotwordEdit()
            return
        }
        guard !hotwords.contains(where: {
            $0 != original && $0.localizedCaseInsensitiveCompare(updated) == .orderedSame
        }) else {
            return
        }
        guard let index = hotwords.firstIndex(of: original) else {
            cancelHotwordEdit()
            return
        }

        hotwords[index] = updated
        HotwordStorage.save(hotwords)
        cancelHotwordEdit()
    }

    private func addSnippet() {
        let value = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }

        let candidates = newSnippetTriggers + parsedNewSnippetTriggers(from: newTrigger)
        var accepted: [String] = []
        for trigger in candidates {
            let isDuplicate = accepted.contains {
                $0.localizedCaseInsensitiveCompare(trigger) == .orderedSame
            } || snippets.contains {
                $0.trigger.localizedCaseInsensitiveCompare(trigger) == .orderedSame
            }
            if !isDuplicate {
                accepted.append(trigger)
            }
        }
        guard !accepted.isEmpty else { return }

        for trigger in accepted {
            snippets.append((trigger: trigger, value: value))
        }
        saveCurrentSnippets()
        newTrigger = ""
        newSnippetTriggers = []
        newValue = ""
    }

    private func stageNewSnippetTrigger() {
        let candidates = parsedNewSnippetTriggers(from: newTrigger)
        for trigger in candidates {
            let isDuplicate = newSnippetTriggers.contains {
                $0.localizedCaseInsensitiveCompare(trigger) == .orderedSame
            } || snippets.contains {
                $0.trigger.localizedCaseInsensitiveCompare(trigger) == .orderedSame
            }
            if !isDuplicate {
                newSnippetTriggers.append(trigger)
            }
        }
        newTrigger = ""
    }

    private func parsedNewSnippetTriggers(from input: String) -> [String] {
        input
            .components(separatedBy: CharacterSet(charactersIn: ",，\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    // MARK: - Bulk Hotwords Sheet

    private var bulkHotwordsSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L("批量管理热词", "Bulk Edit Hotwords"))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(TF.settingsText)
                Spacer()
                Button {
                    showBulkHotwordsSheet = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(TF.settingsControl)
                        )
                }
                .buttonStyle(.plain)
            }

            Text(L("每行一个热词，保存后将覆盖所有自定义热词。", "One hotword per line. Saving will replace all custom hotwords."))
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsTextTertiary)

            TextEditor(text: $bulkHotwordsText)
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsText)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(TF.settingsControl)
                )
                .frame(minHeight: 300, maxHeight: 400)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(TF.settingsBorder, lineWidth: 1)
                )

            HStack {
                Text(L("\(bulkHotwordsLines.count) 条热词", "\(bulkHotwordsLines.count) hotwords"))
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextTertiary)
                Spacer()
            }

            HStack(spacing: 8) {
                Spacer()
                Button {
                    showBulkHotwordsSheet = false
                } label: {
                    Text(L("取消", "Cancel"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .frame(minWidth: 76, minHeight: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(TF.settingsControl)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(TF.settingsBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    saveBulkHotwords()
                } label: {
                    Text(L("保存", "Save"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 76, minHeight: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(TF.settingsText)
                        )
                }
                .buttonStyle(.plain)
                .disabled(bulkHotwordsLines.isEmpty && hotwords.isEmpty)
                .opacity(bulkHotwordsLines.isEmpty && hotwords.isEmpty ? 0.38 : 1)
            }
        }
        .padding(24)
        .frame(width: 500)
        .background(TF.settingsWindowBackground)
    }

    private var bulkHotwordsLines: [String] {
        bulkHotwordsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func saveBulkHotwords() {
        var seen = Set<String>()
        let newWords = bulkHotwordsLines.filter { word in
            let identity = word.folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: .current
            )
            return seen.insert(identity).inserted
        }
        hotwords = newWords
        HotwordStorage.save(newWords)
        showBulkHotwordsSheet = false
    }

    // MARK: - Bulk Snippets Sheet

    private func snippetsToBulkText(_ snippets: [(trigger: String, value: String)]) -> String {
        // Group by replacement value, then format: "replacement, trigger1, trigger2"
        var groups: [(value: String, triggers: [String])] = []
        var valueIndex: [String: Int] = [:]
        for snippet in snippets {
            if let idx = valueIndex[snippet.value] {
                groups[idx].triggers.append(snippet.trigger)
            } else {
                valueIndex[snippet.value] = groups.count
                groups.append((value: snippet.value, triggers: [snippet.trigger]))
            }
        }
        return groups.map { group in
            ([group.value] + group.triggers).joined(separator: ", ")
        }.joined(separator: "\n")
    }

    private func bulkTextToSnippets(_ text: String) -> [(trigger: String, value: String)] {
        text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .flatMap { line -> [(trigger: String, value: String)] in
                let parts = line.components(separatedBy: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                guard parts.count >= 2 else { return [] }
                let value = parts[0]
                return parts.dropFirst().map { (trigger: $0, value: value) }
            }
    }

    private var bulkSnippetsLineCount: Int {
        bulkSnippetsText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .count
    }

    private var bulkSnippetsSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(L("批量编辑片段替换", "Bulk Edit Snippets"))
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(TF.settingsText)
                Spacer()
                Button {
                    showBulkSnippetsSheet = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(TF.settingsControl)
                        )
                }
                .buttonStyle(.plain)
            }

            Text(L("每行一组: 替换词, 触发词1, 触发词2, ...", "One group per line: replacement, trigger1, trigger2, ..."))
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsTextTertiary)

            TextEditor(text: $bulkSnippetsText)
                .font(.system(size: 13))
                .foregroundStyle(TF.settingsText)
                .scrollContentBackground(.hidden)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(TF.settingsControl)
                )
                .frame(minHeight: 300, maxHeight: 400)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(TF.settingsBorder, lineWidth: 1)
                )

            HStack {
                Text(L("\(bulkSnippetsLineCount) 组替换规则", "\(bulkSnippetsLineCount) replacement groups"))
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextTertiary)
                Spacer()
            }

            HStack(spacing: 8) {
                Spacer()
                Button {
                    showBulkSnippetsSheet = false
                } label: {
                    Text(L("取消", "Cancel"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .frame(minWidth: 76, minHeight: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(TF.settingsControl)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .stroke(TF.settingsBorder, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                Button {
                    let parsed = bulkTextToSnippets(bulkSnippetsText)
                    snippets = parsed
                    saveCurrentSnippets()
                    showBulkSnippetsSheet = false
                } label: {
                    Text(L("保存", "Save"))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(minWidth: 76, minHeight: 34)
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(TF.settingsText)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(24)
        .frame(width: 540)
        .background(TF.settingsWindowBackground)
    }

}
