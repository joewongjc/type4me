import SwiftUI

// MARK: - Shared field label

/// Section field label shared by the mode detail forms: a small semibold title
/// with an optional inline hint to its right (keeps rows compact and uniform).
@ViewBuilder
private func fieldLabel(_ title: String, _ hint: String? = nil) -> some View {
    HStack(spacing: 6) {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(TF.settingsTextTertiary)
        if let hint {
            Text(hint)
                .font(.system(size: 10))
                .foregroundStyle(TF.settingsTextTertiary.opacity(0.7))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        Spacer(minLength: 0)
    }
}

// MARK: - Main View

struct ModesSettingsTab: View, SettingsCardHelpers {

    var showsHeader = true
    let draftCoordinator: SettingsDraftCoordinator

    @Environment(AppState.self) private var appState
    @Environment(AskAnythingCoordinator.self) private var askAnythingCoordinator
    @Environment(AppNavigationModel.self) private var navigationModel
    @State private var modes: [ProcessingMode] = ModeStorage().load()
    @State private var selectedModeId: UUID?
    @State private var recordingTarget: RecordingTarget?
    @State private var deletingModeId: UUID?
    @State private var draggingModeId: UUID?
    @State private var hoveredModeId: UUID?
    /// Latest edited (unsaved) snapshot of the selected mode and whether it differs
    /// from storage. Used to warn before switching away with unsaved changes.
    @State private var draftMode: ProcessingMode?
    @State private var draftDirty = false
    @State private var selectedASRProvider: ASRProvider = KeychainService.selectedASRProvider
    @State private var showClearAskAnythingConfirmation = false
    @State private var askAnythingSettingsError: String?
    @State private var translationStatusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if showsHeader {
                SettingsSectionHeader(
                    label: L("模式", "MODES"),
                    title: L("处理模式", "Modes"),
                    description: L("配置语音转写与后处理流水线。快速模式实时输出，自定义模式可经 LLM 加工。", "Configure speech-to-text and post-processing pipelines. Quick Mode outputs live text, and custom modes can use LLM processing.")
                )
            }

            HStack(alignment: .top, spacing: 0) {
                // Left: mode list (all modes)
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 3) {
                        ForEach(modes) { mode in
                            modeRow(mode)
                        }

                        HStack(spacing: 6) {
                            Button(action: addMode) {
                                HStack(spacing: 5) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(L("添加模式", "Add mode"))
                                        .font(.system(size: 12, weight: .medium))
                                }
                                .foregroundStyle(TF.settingsAccentBlue)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                                        .fill(TF.settingsAccentBlue.opacity(0.08))
                                )
                            }
                            .buttonStyle(SettingsListRowButtonStyle())
                            Spacer()
                        }
                        .padding(.top, 8)
                        .padding(.horizontal, 2)
                    }
                    .padding(.vertical, 4)
                    .padding(.trailing, 8)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: 230)
                .onDrop(of: [.text], isTargeted: nil) { _ in
                    // Fallback: reset drag state when released over empty list space.
                    if draggingModeId != nil {
                        persistModes()
                        draggingModeId = nil
                    }
                    return true
                }

                // Divider
                Rectangle()
                    .fill(TF.settingsTextTertiary.opacity(0.15))
                    .frame(width: 1)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)

                // Right: detail for selected mode
                ScrollView(.vertical, showsIndicators: true) {
                    Group {
                        if let mode = selectedMode {
                            modeDetail(mode)
                        } else {
                            Text(L("选择一个模式查看详情", "Select a mode to view details"))
                                .font(.system(size: 12))
                                .foregroundStyle(TF.settingsTextTertiary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.leading, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            selectedASRProvider = KeychainService.selectedASRProvider
            consumePendingSelection()
            if selectedModeId == nil {
                selectedModeId = modes.first?.id
            }
        }
        .onChange(of: navigationModel.pendingModeSelectionID) { _, _ in
            consumePendingSelection()
        }
        .onReceive(NotificationCenter.default.publisher(for: .asrProviderDidChange)) { note in
            if let provider = note.object as? ASRProvider {
                selectedASRProvider = provider
            } else {
                selectedASRProvider = KeychainService.selectedASRProvider
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .selectMode)) { note in
            guard let modeId = note.object as? UUID else { return }
            attemptSelect(modeId)
        }
        .sheet(item: $recordingTarget) { target in
            HotkeyRecordingSheet(
                target: target,
                checkConflict: ModeHotkeyEditing.makeConflictCheck(in: modes, target: target),
                checkDuplicateInMode: ModeHotkeyEditing.makeDuplicateCheck(in: modes, target: target),
                checkPrefixConflict: ModeHotkeyEditing.makePrefixConflictCheck(in: modes, target: target),
                onConfirm: { code, mods, style in
                    ModeHotkeyEditing.applyBinding(
                        keyCode: code, modifiers: mods, style: style,
                        to: &modes, for: target
                    )
                    persistModes()
                    recordingTarget = nil
                },
                onCancel: { recordingTarget = nil }
            )
        }
        .alert(
            L("删除模式", "Delete Mode"),
            isPresented: Binding(
                get: { deletingModeId != nil },
                set: { if !$0 { deletingModeId = nil } }
            )
        ) {
            Button(L("取消", "Cancel"), role: .cancel) { deletingModeId = nil }
            Button(L("删除", "Delete"), role: .destructive) {
                if let id = deletingModeId {
                    deleteMode(id)
                    deletingModeId = nil
                }
            }
        } message: {
            if let id = deletingModeId, let mode = modes.first(where: { $0.id == id }) {
                Text(L("确定要删除「\(mode.localizedDisplayName)」吗？此操作不可撤销。", "Delete \"\(mode.localizedDisplayName)\"? This cannot be undone."))
            }
        }
        .alert(
            L("清空随便问历史", "Clear Ask Anything History"),
            isPresented: $showClearAskAnythingConfirmation
        ) {
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("全部删除", "Delete All"), role: .destructive) {
                Task { await clearAskAnythingHistory() }
            }
        } message: {
            Text(L(
                "所有随便问会话、选中文本、问题和回答都会被永久删除。",
                "All Ask Anything conversations, selected text, questions, and answers will be permanently deleted."
            ))
        }
        .alert(
            L("无法更新随便问设置", "Unable to Update Ask Anything Settings"),
            isPresented: Binding(
                get: { askAnythingSettingsError != nil },
                set: { if !$0 { askAnythingSettingsError = nil } }
            )
        ) {
            Button(L("好", "OK"), role: .cancel) { askAnythingSettingsError = nil }
        } message: {
            Text(askAnythingSettingsError ?? "")
        }
        .onAppear {
            draftCoordinator.register(
                .modes,
                isDirty: { draftDirty },
                save: saveDraftBeforeLeaving,
                discard: discardDraftBeforeLeaving
            )
        }
        .onDisappear {
            draftCoordinator.unregister(.modes)
        }
    }

    // MARK: - Selection with unsaved-changes guard

    /// Consume a synchronous mode-selection request handed off by navigation
    /// (from Home or the menu bar). Selecting here rather than via an async
    /// notification avoids racing the `onAppear` first-mode fallback below.
    private func consumePendingSelection() {
        guard let id = navigationModel.pendingModeSelectionID else { return }
        navigationModel.pendingModeSelectionID = nil
        guard modes.contains(where: { $0.id == id }) else { return }
        if selectedModeId == nil {
            commitSelection(id)
        } else {
            attemptSelect(id)
        }
    }

    private func attemptSelect(_ id: UUID) {
        guard id != selectedModeId else { return }
        if draftDirty {
            draftCoordinator.confirmUnsavedChanges { result in
                if result != .cancelled {
                    commitSelection(id)
                }
            }
        } else {
            commitSelection(id)
        }
    }

    private func commitSelection(_ id: UUID) {
        draftDirty = false
        draftMode = nil
        var t = Transaction(); t.animation = nil
        withTransaction(t) { selectedModeId = id }
    }


    // MARK: - Mode Row

    private func modeRow(_ mode: ProcessingMode) -> some View {
        let isActive = selectedModeId == mode.id
        let isHovered = hoveredModeId == mode.id
        let isDragging = draggingModeId == mode.id

        let rowFill: Color = isActive
            ? TF.settingsSidebarActive
            : (isHovered ? TF.settingsSidebarHover : .clear)

        return HStack(spacing: 8) {
            dragDots
                .opacity(isHovered || isDragging ? 1 : 0)

            Image(systemName: builtinIcon(for: mode))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isActive ? TF.settingsText : TF.settingsTextSecondary)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 1) {
                Text(mode.localizedDisplayName)
                    .font(.system(size: 12, weight: isActive ? .semibold : .medium))
                    .foregroundStyle(TF.settingsText)
                    .lineLimit(1)
                if mode.id == ProcessingMode.translationModeId,
                   let code = mode.translationTargetLanguageCode,
                   let target = TranslationLanguage(rawValue: code) {
                    Text(L("目标：\(target.displayName)", "Target: \(target.displayName)"))
                        .font(.system(size: 9))
                        .foregroundStyle(TF.settingsTextTertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if mode.isBuiltin {
                Text(L("内置", "BUILT-IN"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(TF.settingsCardAlt))
            }

            if !mode.isBuiltin && isHovered {
                Button { deletingModeId = mode.id } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(TF.settingsAccentRed)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .settingsTooltip(L("删除模式", "Delete mode"))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .frame(height: 34)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(rowFill)
        )
        .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .opacity(isDragging ? 0.45 : 1)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredModeId = hovering ? mode.id : nil
            }
        }
        .onTapGesture {
            attemptSelect(mode.id)
        }
        .onDrag {
            draggingModeId = mode.id
            return NSItemProvider(object: mode.id.uuidString as NSString)
        } preview: {
            Text(mode.localizedDisplayName)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(TF.settingsText)
                .padding(.horizontal, 12)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(TF.settingsCard))
        }
        .onDrop(of: [.text], delegate: ModeDropDelegate(
            targetId: mode.id,
            modes: $modes,
            draggingId: $draggingModeId,
            onReorder: { persistModes() }
        ))
    }

    /// Six-dot drag affordance (2×3), matching common reorder handles.
    private var dragDots: some View {
        VStack(spacing: 2.5) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 2.5) {
                    Circle().frame(width: 2.5, height: 2.5)
                    Circle().frame(width: 2.5, height: 2.5)
                }
            }
        }
        .foregroundStyle(TF.settingsTextTertiary.opacity(0.55))
        .frame(width: 12)
    }

    // MARK: - Mode Detail Header

    @ViewBuilder
    private func modeDetailHeader(
        icon: String,
        title: String,
        isBuiltin: Bool,
        @ViewBuilder trailing: () -> some View = { EmptyView() }
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(TF.settingsText)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(TF.settingsCardAlt)
                )

            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TF.settingsText)

                if isBuiltin {
                    Text(L("内置", "Built-in"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TF.settingsTextTertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(TF.settingsCardAlt))
                } else {
                    Text(L("自定义", "Custom"))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(TF.settingsAccentBlue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1.5)
                        .background(Capsule().fill(TF.settingsAccentBlue.opacity(0.1)))
                }
            }

            Spacer()

            trailing()
        }
        .padding(.bottom, 4)
    }

    // MARK: - Mode Detail

    @ViewBuilder
    private func modeDetail(_ mode: ProcessingMode) -> some View {
        if mode.id == ProcessingMode.translationModeId {
            translationModeDetail(mode)
        } else if mode.id == ProcessingMode.intelliSenseId {
            VStack(alignment: .leading, spacing: 18) {
                IntelliSenseModeDetail(
                    mode: mode,
                    onEditBinding: { editBinding(mode, $0) },
                    onDeleteBinding: { deleteBinding(mode.id, $0) },
                    onAddBinding: { addBinding(mode) }
                )
                PunctuationModeSection(selection: punctuationModeBinding(for: mode.id))
            }
        } else if mode.isBuiltin && mode.id != ProcessingMode.formalWritingId {
            VStack(alignment: .leading, spacing: 18) {
                builtinModeDetail(mode)
                if mode.supportsOutputFormatting {
                    PunctuationModeSection(selection: punctuationModeBinding(for: mode.id))
                }
                HotkeySectionView(
                    bindings: mode.hotkeyBindings,
                    onEdit: { editBinding(mode, $0) },
                    onDelete: { deleteBinding(mode.id, $0) },
                    onAdd: { addBinding(mode) }
                )
            }
            .padding(.bottom, 8)
        } else if mode.id == ProcessingMode.formalWritingId {
            formalWritingModeDetail(mode)
        } else {
            ModeDetailInner(
                mode: mode,
                onSave: { updated in
                    if let idx = modes.firstIndex(where: { $0.id == updated.id }) {
                        modes[idx] = updated
                        persistModes()
                    }
                },
                onDraftChange: { draft, dirty in
                    draftMode = draft
                    draftDirty = dirty
                },
                onEditBinding: { editBinding(mode, $0) },
                onDeleteBinding: { deleteBinding(mode.id, $0) },
                onAddBinding: { addBinding(mode) }
            )
        }
    }

    // MARK: - Hotkey binding actions (shared by all detail variants)

    private func editBinding(_ mode: ProcessingMode, _ binding: HotkeyBinding) {
        recordingTarget = RecordingTarget(
            modeId: mode.id,
            modeName: mode.localizedDisplayName,
            editingBindingId: binding.id,
            initialKeyCode: binding.keyCode,
            initialModifiers: binding.modifiers,
            initialStyle: binding.style
        )
    }

    private func addBinding(_ mode: ProcessingMode) {
        recordingTarget = RecordingTarget(
            modeId: mode.id,
            modeName: mode.localizedDisplayName,
            editingBindingId: nil,
            initialKeyCode: nil,
            initialModifiers: nil,
            initialStyle: ProcessingMode.defaultHotkeyStyle
        )
    }

    private func deleteBinding(_ modeId: UUID, _ binding: HotkeyBinding) {
        if let idx = modes.firstIndex(where: { $0.id == modeId }) {
            modes[idx].hotkeyBindings.removeAll { $0.id == binding.id }
            persistModes()
        }
    }

    private func builtinModeDetail(_ mode: ProcessingMode) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            modeDetailHeader(
                icon: builtinIcon(for: mode),
                title: mode.localizedDisplayName,
                isBuiltin: true
            )

            if mode.id == ProcessingMode.macActionId {
                macActionDescription
            } else if mode.id == ProcessingMode.selectionAskId {
                selectionAskDescription
            } else {
                settingsGroupCard(L("模式说明", "Information"), icon: "info.circle") {
                    Text(mode.localizedDisplayDescription)
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .lineSpacing(3)
                        .padding(.vertical, 4)
                }
            }
        }
    }

    private func builtinIcon(for mode: ProcessingMode) -> String {
        switch mode.id {
        case ProcessingMode.directId, ProcessingMode.smartDirectId: return "bolt.fill"
        case ProcessingMode.formalWritingId: return "wand.and.stars"
        case ProcessingMode.translationModeId: return "character.book.closed.fill"
        case ProcessingMode.intelliSenseId: return "sparkles"
        case ProcessingMode.macActionId: return "command.circle.fill"
        case ProcessingMode.selectionAskId: return "sparkle.magnifyingglass"
        default: return "slider.horizontal.3"
        }
    }

    private func translationModeDetail(_ mode: ProcessingMode) -> some View {
        let currentCode = mode.translationTargetLanguageCode ?? TranslationLanguage.english.rawValue

        let languageOptions = TranslationLanguage.allCases.map { (value: $0.rawValue, label: $0.displayName) }
        let pickerBinding = Binding<String>(
            get: { currentCode },
            set: { updateTranslationTarget($0) }
        )

        return VStack(alignment: .leading, spacing: 14) {
            modeDetailHeader(
                icon: "character.book.closed.fill",
                title: mode.localizedDisplayName,
                isBuiltin: true
            )

            settingsGroupCard(L("翻译参数", "Translation Parameters"), icon: "slider.horizontal.3") {
                settingsOptionRow(
                    L("目标语言", "Target language"),
                    subtitle: L("Type4Me 会自动识别口述语言并翻译为所选语言", "Auto-detects spoken language and translates to selected language"),
                    controlWidth: SettingsControlWidth.input
                ) {
                    settingsDropdown(
                        selection: pickerBinding,
                        options: languageOptions
                    )
                }

                if let translationStatusMessage {
                    SettingsDivider()
                    Label(translationStatusMessage, systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TF.settingsAccentGreen)
                        .padding(.vertical, 4)
                        .transition(.opacity)
                }
            }

            PunctuationModeSection(selection: punctuationModeBinding(for: mode.id))

            HotkeySectionView(
                bindings: mode.hotkeyBindings,
                onEdit: { editBinding(mode, $0) },
                onDelete: { deleteBinding(mode.id, $0) },
                onAdd: { addBinding(mode) }
            )

            Text(L(
                "翻译模式只翻译口述内容，不回答其中的问题，也不执行其中的命令。代码、路径、链接、数字和标识符会尽量保持原样。",
                "Translation only translates what you dictate. It does not answer questions or execute commands found in the input. Code, paths, links, numbers, and identifiers are preserved whenever possible."
            ))
            .font(.system(size: 11))
            .foregroundStyle(TF.settingsTextTertiary)
            .lineSpacing(2)
            .padding(.horizontal, 2)
        }
        .padding(.bottom, 8)
    }

    private func updateTranslationTarget(_ code: String) {
        guard TranslationLanguage(rawValue: code) != nil,
              let index = modes.firstIndex(where: { $0.id == ProcessingMode.translationModeId })
        else { return }

        modes[index].translationTargetLanguageCode = code
        persistModes()
        if let language = TranslationLanguage(rawValue: code) {
            withAnimation(.easeOut(duration: 0.15)) {
                translationStatusMessage = L(
                    "目标语言已设为\(language.displayName)",
                    "Target language set to \(language.displayName)"
                )
            }
        }
    }

    private func punctuationModeBinding(for modeId: UUID) -> Binding<ModePunctuationMode> {
        Binding(
            get: {
                modes.first(where: { $0.id == modeId })?.punctuationMode ?? .inherit
            },
            set: { newValue in
                guard let index = modes.firstIndex(where: { $0.id == modeId }),
                      modes[index].supportsOutputFormatting
                else { return }
                modes[index].punctuationMode = newValue
                persistModes()
            }
        )
    }

    private var selectionAskDescription: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroupCard(L("使用方式", "How it works"), icon: "sparkle.magnifyingglass") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L(
                        "选中文本后按下热键开始录音，说出你的问题或指令，再按热键停止。Type4Me 会结合选中文本流式生成 Markdown 回答，不粘贴、不修改剪贴板。",
                        "Select text, press the hotkey to record your question or instruction, then press it again to stop. Type4Me streams a Markdown answer using the selected text without pasting or changing the clipboard."
                    ))
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextSecondary)
                    .lineSpacing(3)

                    SettingsDivider()

                    ForEach(selectionAskExamples, id: \.self) { item in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                                .font(.system(size: 11))
                                .foregroundStyle(TF.settingsTextTertiary)
                            Text(item)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(TF.settingsText)
                                .lineSpacing(2)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            askAnythingHistorySettings
        }
    }

    private var askAnythingHistorySettings: some View {
        settingsGroupCard(L("会话历史", "Conversation History"), icon: "clock.arrow.circlepath") {
            settingsToggleRow(
                L("保存会话历史", "Save conversation history"),
                subtitle: L(
                    "关闭后，新会话只在当前运行期间保留；已有历史不会被删除。",
                    "When off, new conversations last only for this run; existing history is kept."
                ),
                isOn: Binding(
                    get: { askAnythingCoordinator.historyEnabled },
                    set: { askAnythingCoordinator.historyEnabled = $0 }
                ),
                isEnabled: askAnythingCoordinator.activeBinding == nil && !askAnythingCoordinator.isRecordingFollowUp
            )

            SettingsDivider()

            settingsOptionRow(
                L("清空全部历史", "Clear all history"),
                subtitle: L(
                    "永久删除所有随便问会话、选中文本、问题和回答。",
                    "Permanently delete all conversations, selected text, questions, and answers."
                ),
                controlWidth: SettingsControlWidth.standard
            ) {
                Button(L("清空…", "Clear…"), role: .destructive) {
                    showClearAskAnythingConfirmation = true
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(TF.settingsAccentRed)
                .disabled(askAnythingCoordinator.activeBinding != nil || askAnythingCoordinator.isRecordingFollowUp)
            }
        }
    }

    private func clearAskAnythingHistory() async {
        do {
            try await askAnythingCoordinator.clearHistory()
            askAnythingSettingsError = nil
        } catch {
            askAnythingSettingsError = error.localizedDescription
        }
    }

    private var macActionDescription: some View {
        VStack(alignment: .leading, spacing: 14) {
            settingsGroupCard(L("功能说明", "Description"), icon: "info.circle") {
                Text(L(
                    "用语音直接触发 macOS 操作，不再粘贴文本。需要先在「模型 → 文本处理」中配置大模型。",
                    "Trigger macOS actions by voice instead of typing text. Requires an LLM provider configured under Models → Text Processing."
                ))
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsTextSecondary)
                .lineSpacing(3)
                .padding(.vertical, 4)
            }

            settingsGroupCard(L("支持的操作", "Supported Actions"), icon: "command") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(macActionExamples, id: \.0) { phrase, action in
                        HStack(alignment: .top, spacing: 8) {
                            Text("•")
                                .font(.system(size: 11))
                                .foregroundStyle(TF.settingsTextTertiary)
                            Text("\u{201C}\(phrase)\u{201D}")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(TF.settingsText)
                            Text("→")
                                .font(.system(size: 11))
                                .foregroundStyle(TF.settingsTextTertiary)
                            Text(action)
                                .font(.system(size: 11))
                                .foregroundStyle(TF.settingsTextSecondary)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Text(L(
                "首次使用某些操作时，macOS 可能弹出「辅助功能 / 自动化」授权请求。未匹配到任何操作时会提示，不会粘贴任何文本。",
                "macOS may ask for Accessibility/Automation permission the first time you use certain actions. When no action matches, you'll see a notice and nothing is typed."
            ))
                .font(.system(size: 11))
                .foregroundStyle(TF.settingsTextTertiary)
                .lineSpacing(2)
        }
    }

    private var macActionExamples: [(String, String)] {
        [
            (L("打开热词", "Open hotwords"),
             L("进入 ASR 热词管理", "Open ASR hotword management")),
            (L("打开片段替换", "Open snippets"),
             L("进入片段替换管理", "Open snippet management")),
            (L("替换这个单词", "Replace this word"),
             L("用选中文本预填片段触发词", "Prefill a snippet trigger from selected text")),
            (L("添加热词", "Add hotword"),
             L("将选中文本加入 ASR 热词", "Add selected text to ASR hotwords")),
            (L("打开 Safari", "Open Safari"),
             L("启动应用", "Launch an app")),
            (L("音量调到 30", "Set volume to 30"),
             L("调节系统音量", "Adjust system volume")),
            (L("亮度调到 80", "Set brightness to 80"),
             L("调节屏幕亮度", "Adjust screen brightness")),
            (L("切换深色模式", "Toggle dark mode"),
             L("切换深色/浅色外观", "Switch dark/light appearance")),
            (L("截图", "Take a screenshot"),
             L("启动框选截图", "Start interactive screen capture")),
            (L("复制 hello 到剪贴板", "Copy hello to clipboard"),
             L("写入剪贴板", "Write to clipboard")),
            (L("锁屏", "Lock screen"),
             L("锁定屏幕", "Lock the screen")),
            (L("搜一下 swiftui 教程", "Search SwiftUI tutorial"),
             L("用浏览器搜索", "Open a web search")),
            (L("查看电量", "Check battery"),
             L("显示当前电量", "Show battery status")),
            (L("最小化窗口", "Minimize window"),
             L("最小化当前窗口", "Minimize the frontmost window")),
            (L("全屏", "Fullscreen"),
             L("切换当前窗口全屏", "Toggle fullscreen for frontmost window")),
            (L("关闭窗口", "Close window"),
             L("关闭当前窗口", "Close the frontmost window")),
            (L("提醒我两分钟后检查邮件", "Remind me to check emails in 2 minutes"),
             L("创建 Apple 提醒", "Create an Apple Reminder")),
            (L("向下滚动", "Scroll down"),
             L("向下翻页", "Page down")),
            (L("向上滚动", "Scroll up"),
             L("向上翻页", "Page up")),
        ]
    }

    private var selectionAskExamples: [String] {
        [
            L("选中英文、系统提示、代码片段或术语。", "Select English text, system messages, code snippets, or terms."),
            L("按下「随便问」热键，说出“翻译一下”“这是什么意思”“帮我总结”等问题。", "Press the Ask Anything hotkey and say a question such as translate this, what does this mean, or summarize it."),
            L("再次按热键停止，在弹框中阅读流式 Markdown 回答。", "Press the hotkey again to stop and read the streamed Markdown answer in the popup."),
        ]
    }

    private func formalWritingModeDetail(_ mode: ProcessingMode) -> some View {
        FormalWritingDetailInner(
            mode: mode,
            onSave: { updated in
                if let idx = modes.firstIndex(where: { $0.id == updated.id }) {
                    modes[idx] = updated
                    persistModes()
                }
            },
            onDraftChange: { draft, dirty in
                draftMode = draft
                draftDirty = dirty
            },
            onEditBinding: { editBinding(mode, $0) },
            onDeleteBinding: { deleteBinding(mode.id, $0) },
            onAddBinding: { addBinding(mode) }
        )
    }

    // MARK: - Helpers

    private var selectedMode: ProcessingMode? {
        modes.first { $0.id == selectedModeId }
    }

    private func addMode() {
        let mode = ProcessingMode(
            id: UUID(),
            name: L("新模式", "New Mode"),
            prompt: "{text}",
            isBuiltin: false
        )
        modes.append(mode)
        selectedModeId = mode.id
        persistModes()
    }

    @discardableResult
    private func persistModes() -> Bool {
        ModeHotkeyEditing.persistModes(modes, appState: appState)
    }

    private func saveDraftBeforeLeaving() -> Bool {
        guard draftDirty else { return true }
        guard let draftMode,
              let index = modes.firstIndex(where: { $0.id == draftMode.id })
        else { return false }
        let previous = modes[index]
        modes[index] = draftMode
        guard persistModes() else {
            modes[index] = previous
            return false
        }
        self.draftMode = nil
        draftDirty = false
        return true
    }

    private func discardDraftBeforeLeaving() {
        draftMode = nil
        draftDirty = false
    }

    private func deleteMode(_ id: UUID) {
        guard let mode = modes.first(where: { $0.id == id }), !mode.isBuiltin else { return }
        modes.removeAll { $0.id == id }
        if selectedModeId == id {
            selectedModeId = modes.first?.id
        }
        persistModes()
    }
}

// MARK: - Hotkey Section (detail pane)

/// A hotkey list styled to match the other detail-form fields: a small section
/// label plus a stack of low-chrome rows, each with a subtle color-coded style
/// glyph and hover-revealed edit/delete actions consistent with other pages.
struct HotkeySectionView: View, SettingsCardHelpers {
    let bindings: [HotkeyBinding]
    let onEdit: (HotkeyBinding) -> Void
    let onDelete: (HotkeyBinding) -> Void
    let onAdd: () -> Void
    /// Whether to show the "快捷键" label row (with its hint) above the capsules.
    /// The Home card hides it to keep each mode row compact.
    var showsHeader = true
    /// Whether to render the inline dashed "add hotkey" capsule. The Home card
    /// hides it and provides its own "+" in the mode-name row instead.
    var showsAddButton = true

    @State private var hoveredId: UUID?

    var body: some View {
        if showsHeader {
            settingsGroupCard(L("快捷键", "Hotkeys"), icon: "keyboard") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L("支持键盘组合键、鼠标按键或耳机按键", "Supports keyboard combinations, mouse or headphone keys"))
                        .font(.system(size: 11))
                        .foregroundStyle(TF.settingsTextTertiary)

                    FlowLayout(spacing: 8, lineSpacing: 8) {
                        ForEach(bindings) { binding in
                            capsule(binding)
                        }
                        if showsAddButton {
                            addCapsule
                        }
                    }
                    .padding(.vertical, 2)
                }
                .padding(.vertical, 4)
            }
        } else {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(bindings) { binding in
                    capsule(binding)
                }
                if showsAddButton {
                    addCapsule
                }
            }
        }
    }

    /// A read-style capsule matching the Home dashboard: color-coded style glyph
    /// + key, tap to edit, hover to reveal a delete affordance. Edit is the base
    /// button and delete is an overlay button pinned inside the top-trailing
    /// corner — as an in-bounds sibling on top it reliably receives its own taps,
    /// and being an overlay it never changes the capsule's layout width (which
    /// would otherwise push a neighboring "add" button to the next line and make
    /// hover oscillate near a wrap boundary).
    private func capsule(_ binding: HotkeyBinding) -> some View {
        let accent = styleColor(binding.style)
        let hovered = hoveredId == binding.id
        return Button {
            onEdit(binding)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: styleIcon(binding.style))
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(accent)

                Text(HotkeyRecorderView.keyDisplayName(
                    keyCode: binding.keyCode, modifiers: binding.modifiers))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(TF.settingsText)
            }
            .padding(.horizontal, 9)
            .frame(height: 28)
            .background(Capsule().fill(accent.opacity(0.12)))
            .overlay(Capsule().stroke(accent.opacity(0.35), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(L("点击编辑 · \(styleLabel(binding.style))", "Click to edit · \(styleLabel(binding.style))"))
        .overlay(alignment: .topTrailing) {
            if hovered {
                Button {
                    onDelete(binding)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(TF.settingsAccentRed)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.white))
                        .overlay(Circle().stroke(accent.opacity(0.4), lineWidth: 1))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .settingsTooltip(L("删除", "Delete"))
                .transition(.scale.combined(with: .opacity))
            }
        }
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) {
                hoveredId = h ? binding.id : nil
            }
        }
    }

    private var addCapsule: some View {
        Button(action: onAdd) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text(L("添加快捷键", "Add hotkey"))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(TF.settingsTextSecondary)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(
                Capsule().strokeBorder(
                    TF.settingsTextTertiary.opacity(0.5),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    private func styleIcon(_ style: ProcessingMode.HotkeyStyle) -> String {
        switch style {
        case .hold: return "hand.tap.fill"
        case .toggle: return "arrow.triangle.2.circlepath"
        }
    }

    private func styleColor(_ style: ProcessingMode.HotkeyStyle) -> Color {
        switch style {
        case .hold: return Color(red: 0.20, green: 0.60, blue: 0.86)
        case .toggle: return TF.settingsAccentGreen
        }
    }

    private func styleLabel(_ style: ProcessingMode.HotkeyStyle) -> String {
        switch style {
        case .hold: return L("按住", "Hold")
        case .toggle: return L("切换", "Toggle")
        }
    }
}

// MARK: - Flow Layout (wrapping HStack)

/// A simple wrapping layout: places subviews left-to-right, moving to the next
/// line when the current one runs out of width.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, x - spacing)
        }
        let width = maxWidth == .infinity ? totalWidth : min(totalWidth, maxWidth)
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            sub.place(
                at: CGPoint(x: x, y: y),
                anchor: .topLeading,
                proposal: ProposedViewSize(size)
            )
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Hotkey Recording Sheet

struct HotkeyRecordingSheet: View {

    let target: RecordingTarget
    let checkConflict: (Int?, UInt64?) -> ProcessingMode?
    let checkDuplicateInMode: (Int?, UInt64?) -> Bool
    let checkPrefixConflict: (Int?, UInt64?) -> ProcessingMode?
    let onConfirm: (Int, UInt64?, ProcessingMode.HotkeyStyle) -> Void
    let onCancel: () -> Void

    @State private var capturedKeyCode: Int?
    @State private var capturedModifiers: UInt64?
    @State private var hotkeyStyle: ProcessingMode.HotkeyStyle
    @State private var isListening: Bool
    @State private var eventMonitor: Any?
    @State private var pendingModifierCode: Int?
    @State private var pendingModifierModifiers: UInt64 = 0
    @State private var modifierCaptureTask: Task<Void, Never>?

    init(
        target: RecordingTarget,
        checkConflict: @escaping (Int?, UInt64?) -> ProcessingMode?,
        checkDuplicateInMode: @escaping (Int?, UInt64?) -> Bool,
        checkPrefixConflict: @escaping (Int?, UInt64?) -> ProcessingMode?,
        onConfirm: @escaping (Int, UInt64?, ProcessingMode.HotkeyStyle) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.target = target
        self.checkConflict = checkConflict
        self.checkDuplicateInMode = checkDuplicateInMode
        self.checkPrefixConflict = checkPrefixConflict
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _hotkeyStyle = State(initialValue: target.initialStyle)
        // When editing an existing binding, prefill it and skip the listening state.
        _capturedKeyCode = State(initialValue: target.initialKeyCode)
        _capturedModifiers = State(initialValue: target.initialModifiers)
        _isListening = State(initialValue: target.initialKeyCode == nil)
    }

    private var isEditing: Bool { target.editingBindingId != nil }

    private var conflict: ProcessingMode? {
        checkConflict(capturedKeyCode, capturedModifiers)
    }

    private var isDuplicateInMode: Bool {
        checkDuplicateInMode(capturedKeyCode, capturedModifiers)
    }

    private var prefixConflict: ProcessingMode? {
        guard conflict == nil, !isDuplicateInMode else { return nil }
        return checkPrefixConflict(capturedKeyCode, capturedModifiers)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(isEditing
                ? L("为「\(target.modeName)」编辑快捷键", "Edit hotkey for \"\(target.modeName)\"")
                : L("为「\(target.modeName)」添加快捷键", "Add hotkey for \"\(target.modeName)\""))
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(TF.settingsText)

            VStack(spacing: 6) {
                if isListening {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(TF.settingsAccentRed)
                            .frame(width: 8, height: 8)
                            .opacity(0.8)
                        Text(L("按下快捷键、鼠标或耳机按键...", "Press a key, mouse or headphone button..."))
                            .font(.system(size: 14))
                            .foregroundStyle(TF.settingsTextSecondary)
                    }
                } else if let code = capturedKeyCode {
                    Text(HotkeyRecorderView.keyDisplayName(keyCode: code, modifiers: capturedModifiers))
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(TF.settingsText)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 50)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(TF.settingsBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(
                        isListening ? TF.settingsAccentRed.opacity(0.4) : TF.settingsTextTertiary.opacity(0.2),
                        lineWidth: isListening ? 2 : 1
                    )
            )

            if isDuplicateInMode {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(L("此快捷键在本模式中已存在", "This hotkey already exists in this mode"))
                        .font(.system(size: 11))
                }
                .foregroundStyle(TF.settingsAccentAmber)
            }

            if let conflict {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(L("「\(conflict.localizedDisplayName)」正在使用此快捷键，确认后将移除其绑定",
                           "\"\(conflict.localizedDisplayName)\" is using this hotkey. Confirming will unbind it."))
                        .font(.system(size: 11))
                }
                .foregroundStyle(TF.settingsAccentAmber)
            }

            if let prefixConflict {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(L(
                        "与「\(prefixConflict.localizedDisplayName)」存在前缀冲突；「\(target.modeName)」触发将改为抬起按键时触发，速度稍慢、手感变差",
                        "Prefix conflict with \"\(prefixConflict.localizedDisplayName)\". \"\(target.modeName)\" will trigger when the key is released, which is slightly slower and less responsive"
                    ))
                    .font(.system(size: 11))
                }
                .foregroundStyle(TF.settingsAccentAmber)
                .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("触发方式", "Trigger style"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TF.settingsTextTertiary)

                SettingsInlineSegmentedPicker(
                    selection: Binding(
                        get: { hotkeyStyle.rawValue },
                        set: { raw in
                            if let s = ProcessingMode.HotkeyStyle(rawValue: raw) {
                                hotkeyStyle = s
                            }
                        }
                    ),
                    options: [
                        (ProcessingMode.HotkeyStyle.hold.rawValue, L("按住录制", "Hold to record")),
                        (ProcessingMode.HotkeyStyle.toggle.rawValue, L("按下切换", "Toggle")),
                    ]
                )
            }

            if capturedKeyCode == 63 {
                Text(L(
                    "⚠️ 请在系统设置 → 键盘中，将「按下 🌐 键时」改为「不执行任何操作」，否则会与系统功能冲突",
                    "⚠️ Go to System Settings → Keyboard and set \"Press 🌐 key to\" to \"Do Nothing\" to avoid conflicts"
                ))
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }

            if let kc = capturedKeyCode, ModeBinding.isMediaKeyCode(kc) {
                let keyType = ModeBinding.mediaKeyType(from: kc)
                if keyType == 0 || keyType == 1 || keyType == 7 {
                    Text(L(
                        "⚠️ 绑定音量/静音键后，按下该键时系统音量将不会改变",
                        "⚠️ When volume/mute key is bound, pressing it will not change system volume"
                    ))
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 12) {
                if !isListening && capturedKeyCode != nil {
                    Button(L("重录", "Re-record")) {
                        capturedKeyCode = nil
                        capturedModifiers = nil
                        isListening = true
                        startListening()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(TF.settingsTextSecondary)
                }

                Spacer()

                Button(L("取消", "Cancel")) {
                    cleanup()
                    onCancel()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(TF.settingsTextSecondary)

                Button(prefixConflict == nil ? L("确认", "Confirm") : L("仍要设置", "Set Anyway")) {
                    guard let code = capturedKeyCode, !isDuplicateInMode else { return }
                    cleanup()
                    onConfirm(code, capturedModifiers, hotkeyStyle)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(TF.settingsNavActive))
                .disabled(capturedKeyCode == nil || isDuplicateInMode)
                .opacity((capturedKeyCode == nil || isDuplicateInMode) ? 0.5 : 1)
            }
        }
        .padding(28)
        .frame(width: 360)
        .onAppear {
            NotificationCenter.default.post(name: .hotkeyRecordingDidStart, object: nil)
            // When editing an existing binding, show it and wait; the user taps Re-record to change it.
            if target.initialKeyCode == nil {
                startListening()
            }
        }
        .onDisappear {
            cleanup()
            NotificationCenter.default.post(name: .hotkeyRecordingDidEnd, object: nil)
        }
    }

    // MARK: - Key Event Monitoring

    private func startListening() {
        cleanup()
        isListening = true

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown, .otherMouseDown, .systemDefined]) { event in
            // Media key (headphone buttons, keyboard media keys)
            if event.type == .systemDefined {
                guard event.subtype.rawValue == 8 else { return event }
                let keyType = Int((event.data1 >> 16) & 0xFFFF)
                let keyState = Int((event.data1 >> 8) & 0xFF)
                guard keyState == 0x0A else { return event }  // key down only
                guard HotkeyRecorderView.isKnownMediaKeyType(keyType) else { return event }

                modifierCaptureTask?.cancel()
                modifierCaptureTask = nil
                pendingModifierCode = nil

                capturedKeyCode = ModeBinding.mediaKeyCode(for: keyType)
                capturedModifiers = 0
                isListening = false
                removeMonitor()
                return nil
            }

            // Mouse button (middle click, side buttons)
            if event.type == .otherMouseDown {
                let buttonNumber = event.buttonNumber
                modifierCaptureTask?.cancel()
                modifierCaptureTask = nil
                pendingModifierCode = nil

                capturedKeyCode = ModeBinding.mouseKeyCode(for: buttonNumber)
                capturedModifiers = 0
                isListening = false
                removeMonitor()
                return nil
            }

            if event.type == .flagsChanged {
                let kc = Int(event.keyCode)
                guard HotkeyRecorderView.modifierKeyCodes.contains(kc) else { return event }
                let pressed = isModifierPressed(keyCode: kc, flags: event.modifierFlags)

                if pressed {
                    pendingModifierCode = kc
                    pendingModifierModifiers = modifierComboModifiers(for: kc, flags: event.modifierFlags)
                    modifierCaptureTask?.cancel()
                    modifierCaptureTask = Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            guard let pending = pendingModifierCode else { return }
                            captureModifierOnlyHotkey(pending, modifiers: pendingModifierModifiers)
                        }
                    }
                } else {
                    if let pending = pendingModifierCode {
                        modifierCaptureTask?.cancel()
                        modifierCaptureTask = nil
                        capturedKeyCode = pending
                        capturedModifiers = pendingModifierModifiers
                        pendingModifierCode = nil
                        pendingModifierModifiers = 0
                        isListening = false
                        removeMonitor()
                    }
                }
                return event
            }

            if event.type == .keyDown {
                let kc = Int(event.keyCode)
                modifierCaptureTask?.cancel()
                modifierCaptureTask = nil
                pendingModifierCode = nil

                if kc == 53 && event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]).isEmpty {
                    cleanup()
                    onCancel()
                    return nil
                }

                capturedKeyCode = kc
                let clean = sanitizedModifierFlags(event.modifierFlags, forKeyCode: kc)
                capturedModifiers = clean.isEmpty ? 0 : UInt64(clean.rawValue)
                isListening = false
                removeMonitor()
                return nil
            }

            return event
        }
    }

    @MainActor
    private func captureModifierOnlyHotkey(_ keyCode: Int, modifiers: UInt64) {
        capturedKeyCode = keyCode
        capturedModifiers = modifiers
        pendingModifierCode = nil
        pendingModifierModifiers = 0
        isListening = false
        removeMonitor()
    }

    private func removeMonitor() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func cleanup() {
        modifierCaptureTask?.cancel()
        modifierCaptureTask = nil
        pendingModifierCode = nil
        pendingModifierModifiers = 0
        removeMonitor()
    }

    private func sanitizedModifierFlags(_ flags: NSEvent.ModifierFlags, forKeyCode keyCode: Int? = nil) -> NSEvent.ModifierFlags {
        HotkeyRecorderView.sanitizedModifierFlags(flags, forKeyCode: keyCode)
    }

    private func modifierFlag(for keyCode: Int) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
        case 63: return .function
        default: return nil
        }
    }

    private func modifierComboModifiers(for keyCode: Int, flags: NSEvent.ModifierFlags) -> UInt64 {
        var clean = sanitizedModifierFlags(flags)
        if let own = modifierFlag(for: keyCode) {
            clean.remove(own)
        }
        return UInt64(clean.rawValue)
    }

    private func isModifierPressed(keyCode: Int, flags: NSEvent.ModifierFlags) -> Bool {
        ModeBinding.isModifierPressed(keyCode: keyCode, flags: CGEventFlags(rawValue: UInt64(flags.rawValue)))
    }
}

// MARK: - Output Formatting

private struct PunctuationModeSection: View, SettingsCardHelpers {
    @Binding var selection: ModePunctuationMode

    private let options: [(value: String, label: String)] = [
        (ModePunctuationMode.inherit.rawValue, L("跟随通用设置", "Follow General Settings")),
        (ModePunctuationMode.preserve.rawValue, L("保留全部标点", "Keep All Punctuation")),
        (ModePunctuationMode.stripTrailing.rawValue, L("去掉句末标点", "Remove Trailing Punctuation")),
        (ModePunctuationMode.questionsAndExclamationsOnly.rawValue, L("仅保留问号和感叹号", "Keep Only ? and !")),
        (ModePunctuationMode.removeAll.rawValue, L("去掉全部标点", "Remove All Punctuation")),
    ]

    var body: some View {
        settingsGroupCard(L("标点与格式", "Punctuation & Format"), icon: "text.quote") {
            settingsOptionRow(
                L("标点规则", "Punctuation rule"),
                subtitle: L(
                    "仅覆盖当前模式；“跟随通用设置”会继续使用通用设置中的句末标点规则。",
                    "Applies only to this mode. Follow General Settings keeps using the global trailing-punctuation preference."
                ),
                controlWidth: SettingsControlWidth.input
            ) {
                settingsDropdown(
                    selection: Binding(
                        get: { selection.rawValue },
                        set: { if let m = ModePunctuationMode(rawValue: $0) { selection = m } }
                    ),
                    options: options
                )
            }
        }
    }
}

// MARK: - Mode Detail Inner

private struct ModeDetailInner: View, SettingsCardHelpers {

    let mode: ProcessingMode
    let onSave: (ProcessingMode) -> Void
    let onDraftChange: (ProcessingMode, Bool) -> Void
    let onEditBinding: (HotkeyBinding) -> Void
    let onDeleteBinding: (HotkeyBinding) -> Void
    let onAddBinding: () -> Void

    @State private var shortTextExemption = "0"
    @State private var name = ""
    @State private var modeDescription = ""
    @State private var processingLabel = ""
    @State private var prompt = ""
    @State private var punctuationMode: ModePunctuationMode = .inherit
    @State private var saveStatus: SaveStatus = .clean

    private enum SaveStatus: Equatable {
        case clean, dirty, saved
    }

    private var isDirty: Bool {
        name != mode.name
            || modeDescription != mode.description
            || processingLabel != mode.processingLabel
            || prompt != mode.prompt
            || (Int(shortTextExemption) ?? 0) != mode.shortTextExemption
            || punctuationMode != mode.punctuationMode
    }

    private let exemptionOptions: [(value: String, label: String)] = [
        ("0", L("关闭", "Off")),
        ("10", L("10 字以下", "Under 10 chars")),
        ("20", L("20 字以下", "Under 20 chars")),
        ("30", L("30 字以下", "Under 30 chars")),
        ("40", L("40 字以下", "Under 40 chars")),
        ("50", L("50 字以下", "Under 50 chars")),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBar

            // Basic Info Card
            settingsGroupCard(L("基本信息", "Basic Info"), icon: "slider.horizontal.3") {
                settingsField(
                    L("模式名称", "Mode name"),
                    text: $name,
                    prompt: L("例如：邮件润色", "e.g. Email Polish")
                )

                SettingsDivider()

                settingsField(
                    L("描述说明", "Description"),
                    subtitle: L("仅在首页展示，不发送给大模型", "Shown on Home, not sent to the model"),
                    text: $modeDescription,
                    prompt: L("简要说明此模式的用途", "Briefly explain what this mode does")
                )

                SettingsDivider()

                settingsField(
                    L("处理标签", "Processing label"),
                    subtitle: L("录音完成后在悬浮栏展示的文案", "Status label shown in floating bar"),
                    text: $processingLabel,
                    prompt: L("处理中", "Processing")
                )

                SettingsDivider()

                settingsOptionRow(
                    L("短文本跳过", "Short text skip"),
                    subtitle: L("文本少于该字数时跳过润色，直接输出识别结果", "Skip polishing when character count is below threshold"),
                    controlWidth: SettingsControlWidth.input
                ) {
                    settingsDropdown(
                        selection: $shortTextExemption,
                        options: exemptionOptions
                    )
                }
            }

            if mode.supportsOutputFormatting {
                PunctuationModeSection(selection: $punctuationMode)
            }

            HotkeySectionView(
                bindings: mode.hotkeyBindings,
                onEdit: onEditBinding,
                onDelete: onDeleteBinding,
                onAdd: onAddBinding
            )

            // Prompt Template Card
            settingsGroupCard(L("Prompt 模板", "Prompt Template"), icon: "text.alignleft") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(L("支持变量：", "Variables: "))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(TF.settingsTextSecondary)
                        Text("{text}  {selected}  {clipboard}")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(TF.settingsAccentBlue)
                    }

                    AutoSizingTextEditor(text: $prompt)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
                }
                .padding(.vertical, 4)
            }

            Spacer()
        }
        .onAppear { syncFields() }
        .onChange(of: mode.id) { syncFields() }
        .onChange(of: name) { _, _ in reportDraft() }
        .onChange(of: modeDescription) { _, _ in reportDraft() }
        .onChange(of: processingLabel) { _, _ in reportDraft() }
        .onChange(of: prompt) { _, _ in reportDraft() }
        .onChange(of: shortTextExemption) { _, _ in reportDraft() }
        .onChange(of: punctuationMode) { _, _ in reportDraft() }
    }

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(TF.settingsText)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(TF.settingsCardAlt)
                )

            HStack(spacing: 6) {
                Text(name.isEmpty ? L("新模式", "New Mode") : name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TF.settingsText)

                Text(L("自定义", "Custom"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TF.settingsAccentBlue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(TF.settingsAccentBlue.opacity(0.1)))
            }

            Spacer()

            if saveStatus == .saved {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsAccentGreen)
                    Text(L("已保存", "Saved"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TF.settingsAccentGreen)
                }
                .transition(.opacity)
            }

            saveButton
        }
        .padding(.bottom, 4)
    }

    private var saveButton: some View {
        Button {
            var updated = mode
            updated.name = name
            updated.description = modeDescription
            updated.processingLabel = processingLabel
            updated.prompt = prompt
            updated.shortTextExemption = Int(shortTextExemption) ?? 0
            updated.punctuationMode = punctuationMode
            onSave(updated)
            withAnimation { saveStatus = .saved }
            onDraftChange(updated, false)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 11))
                Text(L("保存", "Save"))
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isDirty ? Color.white : TF.settingsTextTertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isDirty ? TF.settingsAccentBlue : TF.settingsCardAlt)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isDirty)
    }

    private func reportDraft() {
        if saveStatus == .saved { saveStatus = .dirty }
        var updated = mode
        updated.name = name
        updated.description = modeDescription
        updated.processingLabel = processingLabel
        updated.prompt = prompt
        updated.shortTextExemption = Int(shortTextExemption) ?? 0
        updated.punctuationMode = punctuationMode
        onDraftChange(updated, isDirty)
    }

    private func syncFields() {
        name = mode.name
        modeDescription = mode.description
        processingLabel = mode.processingLabel
        prompt = mode.prompt
        shortTextExemption = String(mode.shortTextExemption)
        punctuationMode = mode.punctuationMode
        saveStatus = .clean
        onDraftChange(mode, false)
    }
}

// MARK: - Formal Writing Detail Inner

private struct FormalWritingDetailInner: View, SettingsCardHelpers {

    let mode: ProcessingMode
    @State private var shortTextExemption = "0"
    let onSave: (ProcessingMode) -> Void
    let onDraftChange: (ProcessingMode, Bool) -> Void
    let onEditBinding: (HotkeyBinding) -> Void
    let onDeleteBinding: (HotkeyBinding) -> Void
    let onAddBinding: () -> Void

    @State private var name = ""
    @State private var modeDescription = ""
    @State private var processingLabel = ""
    @State private var prompt = ""
    @State private var punctuationMode: ModePunctuationMode = .inherit
    @State private var saveStatus: SaveStatus = .clean
    @State private var promptBeforeUpdate: String?

    private enum SaveStatus: Equatable {
        case clean, dirty, saved
    }

    private var isDirty: Bool {
        name != mode.name
            || modeDescription != mode.description
            || processingLabel != mode.processingLabel
            || prompt != mode.prompt
            || (Int(shortTextExemption) ?? 0) != mode.shortTextExemption
            || punctuationMode != mode.punctuationMode
    }

    private var isLatestPrompt: Bool {
        prompt == ProcessingMode.formalWritingPromptTemplate
    }

    private let exemptionOptions: [(value: String, label: String)] = [
        ("0", L("关闭", "Off")),
        ("10", L("10 字以下", "Under 10 chars")),
        ("20", L("20 字以下", "Under 20 chars")),
        ("30", L("30 字以下", "Under 30 chars")),
        ("40", L("40 字以下", "Under 40 chars")),
        ("50", L("50 字以下", "Under 50 chars")),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            headerBar

            // Basic Info Card
            settingsGroupCard(L("基本信息", "Basic Info"), icon: "slider.horizontal.3") {
                settingsField(
                    L("名称", "Name"),
                    text: $name,
                    prompt: L("模式名称", "Mode name")
                )

                SettingsDivider()

                settingsField(
                    L("描述说明", "Description"),
                    subtitle: L("仅在首页展示，不发送给大模型", "Shown on Home, not sent to the model"),
                    text: $modeDescription,
                    prompt: L("简要说明此模式的用途", "Briefly explain what this mode does")
                )

                SettingsDivider()

                settingsField(
                    L("处理标签", "Processing label"),
                    subtitle: L("录音完成后在悬浮栏展示的文案", "Status label shown in floating bar"),
                    text: $processingLabel,
                    prompt: L("处理中", "Processing")
                )

                SettingsDivider()

                settingsOptionRow(
                    L("短文本跳过", "Short text skip"),
                    subtitle: L("少于字数跳过润色", "Skip polishing under N chars"),
                    controlWidth: SettingsControlWidth.input
                ) {
                    settingsDropdown(
                        selection: $shortTextExemption,
                        options: exemptionOptions
                    )
                }
            }

            PunctuationModeSection(selection: $punctuationMode)

            HotkeySectionView(
                bindings: mode.hotkeyBindings,
                onEdit: onEditBinding,
                onDelete: onDeleteBinding,
                onAdd: onAddBinding
            )

            // Prompt Template Card
            settingsGroupCard(L("Prompt 模板", "Prompt Template"), icon: "text.alignleft") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Text(L("支持变量：", "Variables: "))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(TF.settingsTextSecondary)
                        Text("{text}  {selected}  {clipboard}")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(TF.settingsAccentBlue)
                    }

                    AutoSizingTextEditor(text: $prompt)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
                }
                .padding(.vertical, 4)
            }

            Spacer()
        }
        .onAppear { syncFields() }
        .onChange(of: mode.id) { syncFields() }
        .onChange(of: name) { _, _ in reportDraft() }
        .onChange(of: modeDescription) { _, _ in reportDraft() }
        .onChange(of: processingLabel) { _, _ in reportDraft() }
        .onChange(of: prompt) { _, _ in reportDraft() }
        .onChange(of: shortTextExemption) { _, _ in reportDraft() }
        .onChange(of: punctuationMode) { _, _ in reportDraft() }
    }

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(TF.settingsAccentAmber)
                .frame(width: 32, height: 32)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(TF.settingsCardAlt)
                )

            HStack(spacing: 6) {
                Text(mode.localizedDisplayName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(TF.settingsText)

                Text(L("内置", "Built-in"))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(TF.settingsCardAlt))
            }

            Spacer()

            if !isLatestPrompt {
                Button {
                    promptBeforeUpdate = prompt
                    prompt = ProcessingMode.formalWritingPromptTemplate
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 10))
                        Text(L("还原为官方版", "Restore to official"))
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(TF.settingsAccentBlue)
                }
                .buttonStyle(.plain)
            }

            if promptBeforeUpdate != nil {
                Button {
                    prompt = promptBeforeUpdate!
                    promptBeforeUpdate = nil
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10))
                        Text(L("撤销", "Undo"))
                            .font(.system(size: 11))
                    }
                    .foregroundStyle(TF.settingsTextSecondary)
                }
                .buttonStyle(.plain)
            }

            if saveStatus == .saved {
                HStack(spacing: 4) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(TF.settingsAccentGreen)
                    Text(L("已保存", "Saved"))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(TF.settingsAccentGreen)
                }
                .transition(.opacity)
            }

            saveButton
        }
        .padding(.bottom, 4)
    }

    private var saveButton: some View {
        Button {
            var updated = mode
            updated.name = name
            updated.description = modeDescription
            updated.processingLabel = processingLabel
            updated.prompt = prompt
            updated.shortTextExemption = Int(shortTextExemption) ?? 0
            updated.punctuationMode = punctuationMode
            onSave(updated)
            promptBeforeUpdate = nil
            withAnimation { saveStatus = .saved }
            onDraftChange(updated, false)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 11))
                Text(L("保存", "Save"))
                    .font(.system(size: 12, weight: .medium))
            }
            .foregroundStyle(isDirty ? Color.white : TF.settingsTextTertiary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(
                Capsule()
                    .fill(isDirty ? TF.settingsAccentBlue : TF.settingsCardAlt)
            )
        }
        .buttonStyle(.plain)
        .disabled(!isDirty)
    }

    private func reportDraft() {
        if saveStatus == .saved { saveStatus = .dirty }
        var updated = mode
        updated.name = name
        updated.description = modeDescription
        updated.processingLabel = processingLabel
        updated.prompt = prompt
        updated.shortTextExemption = Int(shortTextExemption) ?? 0
        updated.punctuationMode = punctuationMode
        onDraftChange(updated, isDirty)
    }

    private func syncFields() {
        name = mode.name
        modeDescription = mode.description
        processingLabel = mode.processingLabel
        prompt = mode.prompt
        shortTextExemption = String(mode.shortTextExemption)
        punctuationMode = mode.punctuationMode
        saveStatus = .clean
        onDraftChange(mode, false)
    }
}

// MARK: - Auto-sizing TextEditor without scrollbars

private struct AutoSizingTextEditor: View {
    @Binding var text: String
    @State private var height: CGFloat = 80

    var body: some View {
        AutoSizingTextEditorRep(text: $text, height: $height)
            .frame(height: max(80, height))
    }
}

private struct AutoSizingTextEditorRep: NSViewRepresentable {
    @Binding var text: String
    @Binding var height: CGFloat

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = NSTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 13)
        textView.textColor = NSColor(TF.settingsText)
        textView.backgroundColor = .clear
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0
        textView.delegate = context.coordinator
        textView.postsFrameChangedNotifications = true

        scrollView.documentView = textView
        context.coordinator.scrollView = scrollView

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.frameDidChange),
            name: NSView.frameDidChangeNotification,
            object: textView
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // Sync text container width to scroll view's content width
        let availableWidth = scrollView.contentSize.width
        if availableWidth > 0 {
            textView.textContainer?.containerSize = NSSize(width: availableWidth, height: CGFloat.greatestFiniteMagnitude)
        }
        if textView.string != text {
            textView.string = text
            DispatchQueue.main.async { recalcHeight(textView) }
        }
    }

    private func recalcHeight(_ textView: NSTextView) {
        textView.layoutManager?.ensureLayout(for: textView.textContainer!)
        let newHeight = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 80
        let padded = ceil(newHeight) + 8
        if abs(padded - height) > 1 { height = padded }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: AutoSizingTextEditorRep
        weak var scrollView: NSScrollView?
        init(_ parent: AutoSizingTextEditorRep) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            parent.text = tv.string
            recalc(tv)
        }

        @objc func frameDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            recalc(tv)
        }

        private func recalc(_ textView: NSTextView) {
            textView.layoutManager?.ensureLayout(for: textView.textContainer!)
            let newHeight = textView.layoutManager?.usedRect(for: textView.textContainer!).height ?? 80
            let padded = ceil(newHeight) + 8
            if abs(padded - parent.height) > 1 {
                DispatchQueue.main.async { self.parent.height = padded }
            }
        }
    }
}
