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

struct VocabularyTab: View {

    // Hotwords (user file)
    @State private var hotwords: [String] = HotwordStorage.load()
    @State private var newHotword: String = ""
    @State private var showBulkHotwordsSheet = false
    @State private var bulkHotwordsText = ""

    // Snippets (user file + built-in)
    @State private var snippets: [(trigger: String, value: String)] = SnippetStorage.load()
    @State private var editingGroupReplacement: String? = nil
    @State private var editReplacementText: String = ""
    @State private var newTriggerTexts: [String: String] = [:]
    @State private var newTrigger: String = ""
    @State private var newValue: String = ""
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
                bulkEditButton { showBulkHotwordsSheet = true }
            }
            .padding(.bottom, 4)

            Text(L("添加热词，将被上传给识别引擎被优先识别。", "Added hotwords are uploaded to the ASR engine for priority recognition."))
                .font(.system(size: 11))
                .foregroundStyle(TF.settingsTextTertiary)
                .padding(.bottom, 12)

            // User hotwords
            WrappingHStack(spacing: 6) {
                ForEach(displayHotwords, id: \.self) { word in
                    hotwordTag(word)
                }

                TextField(L("添加热词...", "Add hotword..."), text: $newHotword)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 100, height: 28)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(TF.settingsTextTertiary.opacity(0.3), style: StrokeStyle(lineWidth: 1, dash: [4]))
                    )
                    .onSubmit { addHotword() }
            }

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
                bulkEditButton { showBulkSnippetsSheet = true }
            }
            .padding(.bottom, 4)

            Text(L("本地执行规则，将任何文字替换成你想要的文字。", "Local rules that replace any text with what you want."))
                .font(.system(size: 11))
                .foregroundStyle(TF.settingsTextTertiary)
                .padding(.bottom, 8)

            // Tab bar (Chrome-style: feet sit on top of content area)
            appScopeBar()
                .zIndex(1)

            // Content area
            VStack(alignment: .leading, spacing: 0) {
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
                .padding(.vertical, 8)

                // Snippet list
                ForEach(Array(displaySnippets.enumerated()), id: \.element.id) { index, group in
                    SettingsDivider()
                    snippetGroupView(group: group)
                        .id("snippet-\(group.id)")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(TF.settingsAccentGreen.opacity(0.15))
                                .opacity(highlightedGroup == group.replacement ? 1 : 0)
                        )
                        .padding(.horizontal, -8)
                }

                if displaySnippets.isEmpty {
                    Text(selectedAppScope != nil
                         ? L("这个应用还没有专属片段，从上方添加。", "No app-specific snippets yet. Add one above.")
                         : L("还没有片段，从上方添加。", "No snippets yet. Add one above."))
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsTextTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 16)
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(
                UnevenRoundedRectangle(
                    topLeadingRadius: selectedAppScope == nil ? 0 : 10,
                    bottomLeadingRadius: 10,
                    bottomTrailingRadius: 10,
                    topTrailingRadius: 10
                )
                .fill(TF.settingsBg)
            )

            Spacer()
        }
        .onReceive(NotificationCenter.default.publisher(for: .navigateToVocabulary)) { note in
            guard let replacement = note.object as? String else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
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

    private func bulkEditButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 9))
                Text(L("批量编辑", "Bulk Edit"))
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
        .padding(.vertical, 7)
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
        HStack(alignment: .center, spacing: 6) {
            // Replacement (left side)
            if editingGroupReplacement == group.replacement {
                TextField("", text: $editReplacementText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsText)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .fixedSize()
                    .frame(minWidth: 40)
                    .background(RoundedRectangle(cornerRadius: 4).fill(TF.settingsCard))
                    .onSubmit { commitGroupEdit(oldReplacement: group.replacement) }
            } else {
                HStack(spacing: 4) {
                    if group.replacement == Self.builtinExampleReplacement {
                        Text(L("示例", "Example"))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(TF.settingsTextTertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(TF.settingsCardAlt))
                    }
                    Text(group.replacement)
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsText)
                }
            }

            Image(systemName: "arrow.left")
                .font(.system(size: 9))
                .foregroundStyle(TF.settingsTextTertiary)

            // Trigger words (right side, separated by vertical dividers)
            WrappingHStack(alignment: .center, spacing: 4) {
                ForEach(Array(group.triggers.enumerated()), id: \.element) { index, trigger in
                    if index > 0 {
                        Rectangle()
                            .fill(TF.settingsTextTertiary.opacity(0.3))
                            .frame(width: 1, height: 14)
                    }
                    triggerTag(trigger: trigger, replacement: group.replacement)
                }

                Rectangle()
                    .fill(TF.settingsTextTertiary.opacity(0.3))
                    .frame(width: 1, height: 14)

                TextField(L("添加...", "Add..."), text: newTriggerBinding(for: group.replacement))
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .frame(width: 60)
                    .padding(.horizontal, 4)
                    .onSubmit { addTriggerToGroup(replacement: group.replacement) }
            }

            Spacer()

            if editingGroupReplacement == group.replacement {
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
        HStack(spacing: 3) {
            Text(trigger)
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsTextSecondary)
            Button {
                removeTrigger(trigger: trigger, replacement: replacement)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
    }

    // MARK: - App Scope Bar

    private func appScopeBar() -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                // Global tab (with SF Symbol globe icon)
                appScopeTab(
                    label: L("全局生效", "Global"),
                    bundleId: nil,
                    icon: nil,
                    systemIcon: "globe",
                    isFirst: true
                )

                // Per-app tabs
                ForEach(registeredApps) { app in
                    appScopeTab(
                        label: app.name,
                        bundleId: app.bundleId,
                        icon: appIcon(for: app.bundleId)
                    )
                    .contextMenu {
                        Button(role: .destructive) {
                            removeAppScope(bundleId: app.bundleId)
                        } label: {
                            Label(L("移除", "Remove"), systemImage: "trash")
                        }
                    }
                }

                // Separator + add button (Chrome-style)
                Divider()
                    .frame(height: 14)
                    .padding(.horizontal, 8)

                Button {
                    pickApp()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(TF.settingsTextTertiary)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func appScopeTab(label: String, bundleId: String?, icon: NSImage?, systemIcon: String? = nil, isFirst: Bool = false) -> some View {
        let isSelected = selectedAppScope == bundleId
        let fr: CGFloat = 6
        return Button {
            switchScope(to: bundleId)
        } label: {
            HStack(spacing: 4) {
                if let systemIcon {
                    Image(systemName: systemIcon)
                        .font(.system(size: 11))
                } else if let icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 14, height: 14)
                }
                Text(label)
                    .font(.system(size: 12))
                    .lineLimit(1)

                // Close button on selected app tabs (not global)
                if isSelected && bundleId != nil {
                    Button {
                        deletingAppBundleId = bundleId
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(TF.settingsTextTertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .foregroundStyle(isSelected ? TF.settingsText : TF.settingsTextTertiary)
            .padding(.horizontal, 14)
            .padding(.top, isSelected ? 11 : 6)
            .padding(.bottom, isSelected ? 5 : 6)
            // Foot space: left foot only if not first tab
            .padding(.leading, isSelected && !isFirst ? fr : 0)
            .padding(.trailing, isSelected ? fr : 0)
            .padding(.bottom, isSelected ? fr : 0)
            .zIndex(isSelected ? 1 : 0)
            .background(
                Group {
                    if isSelected {
                        ChromeTabShape(topRadius: 8, footRadius: fr, skipLeftFoot: isFirst)
                            .fill(TF.settingsBg)
                    }
                }
            )
        }
        .buttonStyle(.plain)
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
        saveCurrentSnippets()
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
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsBg))
                .frame(minHeight: 300, maxHeight: 400)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(TF.settingsTextTertiary.opacity(0.2), lineWidth: 1)
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
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(L("批量编辑片段替换", "Bulk Edit Snippets"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TF.settingsText)
                Spacer()
                Button {
                    showBulkSnippetsSheet = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(TF.settingsTextTertiary)
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
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsBg))
                .frame(minHeight: 300, maxHeight: 400)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(TF.settingsTextTertiary.opacity(0.2), lineWidth: 1)
                )

            HStack {
                Text(L("\(bulkSnippetsLineCount) 组替换规则", "\(bulkSnippetsLineCount) replacement groups"))
                    .font(.system(size: 11))
                    .foregroundStyle(TF.settingsTextTertiary)
                Spacer()
            }

            HStack(spacing: 12) {
                Spacer()
                Button {
                    showBulkSnippetsSheet = false
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
                    let parsed = bulkTextToSnippets(bulkSnippetsText)
                    snippets = parsed
                    saveCurrentSnippets()
                    showBulkSnippetsSheet = false
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
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(TF.settingsCardAlt)
    }

}

