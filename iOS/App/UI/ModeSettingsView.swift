import SwiftUI
import Type4MeTransferCore

/// Observable front for `ModeLibrary`, so the app's screens redraw when a
/// mode is renamed, added or moved on or off the keyboard.
@MainActor
final class ModeStore: ObservableObject {
    static let shared = ModeStore()

    @Published private(set) var modes: [ModeDefinition]

    private init() {
        ModeLibrary.addIntelliSenseIfNeeded()
        modes = ModeLibrary.all
    }

    var keyboardCount: Int { modes.filter(\.onKeyboard).count }

    func update(_ mode: ModeDefinition) {
        guard let index = modes.firstIndex(where: { $0.id == mode.id }) else {
            modes.append(mode)
            persist()
            return
        }
        modes[index] = mode
        persist()
    }

    func delete(id: String) {
        modes.removeAll { $0.id == id && !$0.isBuiltIn }
        persist()
    }

    func move(from source: IndexSet, to destination: Int) {
        modes.move(fromOffsets: source, toOffset: destination)
        persist()
    }

    /// Returns false when the keyboard is already full, or when this is the
    /// last mode left on it.
    @discardableResult
    func setOnKeyboard(_ on: Bool, id: String) -> Bool {
        guard let index = modes.firstIndex(where: { $0.id == id }), modes[index].onKeyboard != on else { return true }
        if on, keyboardCount >= ModeLibrary.keyboardLimit { return false }
        if !on, keyboardCount <= 1 { return false }
        modes[index].onKeyboard = on
        persist()
        return true
    }

    /// Merges modes synced from the Mac. Built-in kinds update the matching
    /// built-in mode's name (and prompt, when the Mac sent one); custom modes
    /// are updated by ID or added, going on the keyboard while there is room.
    func applySync(_ synced: [Type4MeTransferPayload.Mode]) {
        for item in synced {
            let kind = ModeDefinition.Kind(rawValue: item.kind) ?? .custom
            let id = kind == .custom ? item.id : kind.rawValue
            let prompt = item.prompt?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let index = modes.firstIndex(where: { $0.id == id }) {
                if kind == .custom || item.name != nil { modes[index].name = item.name }
                if kind == .translation {
                    // The Mac's target language; its prompt is built here.
                    modes[index].targetLanguage = item.targetLanguage.flatMap(TranslationLanguage.init(rawValue:))?.rawValue
                } else if let prompt, !prompt.isEmpty {
                    modes[index].prompt = prompt
                }
            } else if kind == .custom, let prompt, !prompt.isEmpty {
                modes.append(ModeDefinition(
                    id: id,
                    kind: .custom,
                    name: item.name ?? L("Mac 模式", "Mac Mode"),
                    prompt: prompt,
                    onKeyboard: keyboardCount < ModeLibrary.keyboardLimit
                ))
            }
        }
        persist()
    }

    /// Drops custom and synced modes and puts the built-in ones back as shipped.
    func resetToDefaults() {
        modes = ModeLibrary.defaults
        persist()
    }

    var isDefault: Bool { modes == ModeLibrary.defaults }

    private func persist() {
        ModeLibrary.all = modes
        modes = ModeLibrary.all
    }
}

/// Settings › Modes: every mode in one list. The keyboard toggle on each row
/// picks the (at most four) chips the keyboard shows; drag to reorder.
struct ModeSettingsView: View {
    @ObservedObject private var store = ModeStore.shared
    @State private var notice: String?
    @State private var creating = false

    var body: some View {
        List {
            Section {
                ForEach(store.modes) { mode in
                    NavigationLink {
                        ModeEditorView(mode: mode, isNew: false)
                    } label: {
                        row(mode)
                    }
                }
                .onMove { store.move(from: $0, to: $1) }
            } header: {
                Text(L("键盘上显示 \(store.keyboardCount)/\(ModeLibrary.keyboardLimit)", "On Keyboard \(store.keyboardCount)/\(ModeLibrary.keyboardLimit)"))
            } footer: {
                Text(notice ?? L(
                    "点键盘图标选择放到输入法上的模式，最多 \(ModeLibrary.keyboardLimit) 个。按住拖动可以调整顺序，键盘按这个顺序排列。",
                    "Tap the keyboard icon to choose which modes appear on the keyboard, up to \(ModeLibrary.keyboardLimit). Touch and hold to drag them into the order the keyboard uses."
                ))
                .foregroundStyle(notice == nil ? T4.secondary : T4.recording)
            }

            Section {
                Button {
                    creating = true
                } label: {
                    Label(L("新建模式", "New Mode"), systemImage: "plus")
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DottedCanvas())
        .navigationTitle(L("模式", "Modes"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .sheet(isPresented: $creating) {
            NavigationStack {
                ModeEditorView(mode: ModeDefinition(
                    id: "custom-" + UUID().uuidString.prefix(8).lowercased(),
                    kind: .custom,
                    name: "",
                    // Start from a working prompt with {text} already in place.
                    prompt: ModePrompts.newModeTemplate,
                    onKeyboard: store.keyboardCount < ModeLibrary.keyboardLimit
                ), isNew: true)
            }
        }
    }

    private func row(_ mode: ModeDefinition) -> some View {
        HStack(spacing: 12) {
            Image(systemName: DictationMode(mode).symbol)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(T4.ink)
                .frame(width: 32, height: 32)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(mode.displayName)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(T4.ink)
                        .lineLimit(1)
                    T4Badge(text: mode.isBuiltIn ? L("内置", "Built-in") : L("自定义", "Custom"))
                }
                Text(DictationMode(mode).summary)
                    .font(.system(size: 12))
                    .foregroundStyle(T4.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                toggleKeyboard(mode)
            } label: {
                Image(systemName: mode.onKeyboard ? "keyboard.fill" : "keyboard")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(mode.onKeyboard ? T4.background : T4.ink.opacity(0.45))
                    .frame(width: 38, height: 32)
                    .glassEffect(mode.onKeyboard ? .regular.tint(T4.ink).interactive() : .regular.interactive(), in: Capsule())
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(L("在键盘上显示", "Show on Keyboard"))
            .accessibilityValue(mode.onKeyboard ? L("已显示", "On") : L("未显示", "Off"))
        }
        .padding(.vertical, 2)
    }

    private func toggleKeyboard(_ mode: ModeDefinition) {
        let turningOn = !mode.onKeyboard
        let ok = withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            store.setOnKeyboard(turningOn, id: mode.id)
        }
        if ok {
            notice = nil
            UISelectionFeedbackGenerator().selectionChanged()
        } else {
            notice = turningOn
                ? L("键盘最多放 \(ModeLibrary.keyboardLimit) 个模式，先关掉一个。", "The keyboard holds up to \(ModeLibrary.keyboardLimit) modes. Turn one off first.")
                : L("键盘上至少要留一个模式。", "Keep at least one mode on the keyboard.")
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
    }
}

/// Rename any mode and edit its prompt. Built-in modes start from their
/// default prompt and can go back to it.
struct ModeEditorView: View {
    @ObservedObject private var store = ModeStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var draft: ModeDefinition
    /// What the editor shows: the saved prompt, or the default for an
    /// unedited built-in mode.
    @State private var promptText: String
    @State private var confirmDelete = false
    @State private var keyboardFull = false
    let isNew: Bool

    private let nameLimit = 12

    init(mode: ModeDefinition, isNew: Bool) {
        _draft = State(initialValue: mode)
        let defaultPrompt = ModePrompts.defaultPrompt(for: mode.kind)
        _promptText = State(initialValue: mode.prompt.isEmpty ? (defaultPrompt ?? "") : mode.prompt)
        self.isNew = isNew
    }

    private var defaultPrompt: String? { ModePrompts.defaultPrompt(for: draft.kind) }
    private var trimmedPrompt: String { promptText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var defaultName: String {
        ModeDefinition.builtInName(draft.kind, target: draft.translationTarget)
    }

    private var trimmedName: String {
        (draft.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSave: Bool {
        if draft.isBuiltIn { return defaultPrompt == nil || !trimmedPrompt.isEmpty }
        return !trimmedName.isEmpty && !trimmedPrompt.isEmpty
    }

    private var hasChanges: Bool {
        isNew || store.modes.first { $0.id == draft.id } != normalized
    }

    /// A built-in name left empty or equal to the default goes back to
    /// following the app language.
    private var normalized: ModeDefinition {
        var mode = draft
        if mode.isBuiltIn, trimmedName.isEmpty || trimmedName == defaultName {
            mode.name = nil
        } else {
            mode.name = trimmedName
        }
        if let defaultPrompt {
            // Stored empty while it matches the default, so app updates to the
            // default prompt still reach unedited modes.
            mode.prompt = trimmedPrompt == defaultPrompt.trimmingCharacters(in: .whitespacesAndNewlines) ? "" : trimmedPrompt
        } else {
            mode.prompt = mode.isBuiltIn ? "" : trimmedPrompt
        }
        return mode
    }

    var body: some View {
        Form {
            Section {
                TextField(
                    draft.isBuiltIn ? defaultName : L("例如：邮件、周报", "e.g. Email, Weekly Report"),
                    text: Binding(
                        get: { draft.name ?? "" },
                        set: { draft.name = String($0.prefix(nameLimit)) }
                    )
                )
                if draft.isBuiltIn, draft.name != nil, trimmedName != defaultName {
                    Button(L("恢复默认名称", "Restore Default Name")) { draft.name = nil }
                }
            } header: {
                Text(L("名称", "Name"))
            } footer: {
                Text(L("键盘顶部空间有限，2 到 6 个字最合适。", "Space on the keyboard is tight. Short names work best."))
            }

            Section {
                Toggle(L("在键盘上显示", "Show on Keyboard"), isOn: Binding(
                    get: { draft.onKeyboard },
                    set: { on in
                        if on, !draft.onKeyboard, keyboardSlotsTaken >= ModeLibrary.keyboardLimit {
                            keyboardFull = true
                            return
                        }
                        draft.onKeyboard = on
                    }
                ))
                .tint(T4.success)
                .disabled(draft.onKeyboard && keyboardSlotsTaken == 0)
            } footer: {
                if keyboardFull {
                    Text(L("键盘最多放 \(ModeLibrary.keyboardLimit) 个模式，先在模式列表里关掉一个。", "The keyboard holds up to \(ModeLibrary.keyboardLimit) modes. Turn one off in the mode list first."))
                        .foregroundStyle(T4.recording)
                } else if draft.onKeyboard && keyboardSlotsTaken == 0 {
                    Text(L("键盘上至少要留一个模式。", "Keep at least one mode on the keyboard."))
                }
            }

            if draft.kind == .translation {
                Section {
                    Picker(L("目标语言", "Target Language"), selection: Binding(
                        get: { draft.translationTarget },
                        set: { draft.targetLanguage = $0.rawValue }
                    )) {
                        ForEach(TranslationLanguage.allCases) { Text($0.displayName).tag($0) }
                    }
                } header: {
                    Text(L("翻译参数", "Translation"))
                } footer: {
                    Text(L(
                        "自动识别口述语言，翻译为目标语言。和 Mac 版一样不用写 Prompt；结果不是目标语言时会自动重试一次。需要先配置处理模型。",
                        "Detects the spoken language and translates it into the target. Like the Mac, there's no prompt to write; a reply in the wrong language is retried once. Needs a text model."
                    ))
                }
            } else if draft.kind == .intelliSense {
                Section {
                    Text(DictationMode(draft).summary)
                        .foregroundStyle(T4.secondary)
                } header: {
                    Text(L("作用", "What It Does"))
                } footer: {
                    Text(L(
                        "和 Mac 版用同一套规则：按输入框类型调整语气（聊天、邮件、搜索框等），参考光标前后的文字校正专有词，处理改口，明确列举时整理成列表，结果不可靠时退回原文。iPhone 键盘看不到当前是哪个 App，所以场景从输入框类型推断。没有可编辑的 Prompt，需要先配置处理模型。",
                        "Same rules as the Mac: the tone follows the kind of field (chat, email, search and so on), text around the cursor helps spell names right, self-corrections are cleaned up, clear lists become lists, and an unreliable result falls back to your words. The iPhone keyboard can't tell which app it's in, so the scene comes from the field. There's no prompt to edit, and it needs a text model."
                    ))
                }
            } else if draft.kind == .quick {
                Section {
                    Text(DictationMode(draft).summary)
                        .foregroundStyle(T4.secondary)
                } header: {
                    Text(L("作用", "What It Does"))
                } footer: {
                    Text(L("快速模式直接输出识别结果，不经过处理模型，所以没有 Prompt。", "Quick mode outputs the transcript directly without a text model, so it has no prompt."))
                }
            } else {
                Section {
                    TextEditor(text: $promptText)
                        .font(.system(size: 14))
                        .frame(minHeight: draft.isBuiltIn ? 320 : 200)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if let defaultPrompt, trimmedPrompt != defaultPrompt.trimmingCharacters(in: .whitespacesAndNewlines) {
                        Button(L("恢复默认 Prompt", "Restore Default Prompt")) { promptText = defaultPrompt }
                    }
                } header: {
                    Text("Prompt")
                } footer: {
                    Text(promptFooter)
                }

                if !isNew && !draft.isBuiltIn {
                    Section {
                        Button(L("删除模式", "Delete Mode"), role: .destructive) { confirmDelete = true }
                            .disabled(draft.onKeyboard && keyboardSlotsTaken == 0)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(DottedCanvas())
        .navigationTitle(isNew ? L("新建模式", "New Mode") : draft.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if isNew {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("取消", "Cancel")) { dismiss() }
                }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(isNew ? L("添加", "Add") : L("保存", "Save")) {
                    store.update(normalized)
                    dismiss()
                }
                .disabled(!canSave || !hasChanges)
            }
        }
        .alert(L("删除“\(draft.displayName)”？", "Delete “\(draft.displayName)”?"), isPresented: $confirmDelete) {
            Button(L("取消", "Cancel"), role: .cancel) {}
            Button(L("删除", "Delete"), role: .destructive) {
                store.delete(id: draft.id)
                dismiss()
            }
        } message: {
            Text(L("历史记录会保留，但不再显示这个模式的名字。", "Your history stays, but no longer shows this mode's name."))
        }
    }

    private var promptFooter: String {
        let placeholder = L(
            "{text} 是识别出的原话；不写 {text} 时，这段 Prompt 作为系统指令，原话单独发送。需要先配置处理模型。",
            "{text} is your transcript. Without {text}, the prompt is sent as the instruction and your words follow on their own. Needs a text model."
        )
        switch draft.kind {
        case .formalWriting:
            return placeholder + L("默认 Prompt 和 Mac 版一致。", " The default matches the Mac prompt.")
        case .agentMode:
            return placeholder + L(
                "默认 Prompt 来自 Mac 版，去掉了选中文本和剪贴板部分，iPhone 键盘读不到这两样。",
                " The default comes from the Mac, minus the selected text and clipboard parts the iPhone keyboard can't read."
            )
        default:
            return placeholder
        }
    }

    /// Keyboard slots used by the other modes.
    private var keyboardSlotsTaken: Int {
        store.modes.filter { $0.onKeyboard && $0.id != draft.id }.count
    }
}
