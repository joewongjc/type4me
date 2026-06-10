import SwiftUI

// MARK: - Recording Sheet Target

private struct RecordingTarget: Identifiable {
    let id: UUID
    let name: String
    let currentStyle: ProcessingMode.HotkeyStyle
}

// MARK: - Main View

struct ModesSettingsTab: View {

    @Environment(AppState.self) private var appState
    @State private var modes: [ProcessingMode] = ModeStorage().load()
    @State private var selectedModeId: UUID?
    @State private var recordingTarget: RecordingTarget?
    @State private var deletingModeId: UUID?
    @State private var draggingModeId: UUID?
    @State private var selectedASRProvider: ASRProvider = KeychainService.selectedASRProvider

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                label: "MODES",
                title: L("处理模式", "Modes"),
                description: L("配置语音转写与后处理流水线。快速模式实时输出，自定义模式可经 LLM 加工。", "Configure speech-to-text and post-processing pipelines. Quick Mode outputs live text, and custom modes can use LLM processing.")
            )

            HStack(alignment: .top, spacing: 0) {
                // Left: mode list (all modes)
                ScrollView(.vertical, showsIndicators: true) {
                    VStack(spacing: 3) {
                        ForEach(modes) { mode in
                            modeRow(mode)
                        }

                        HStack(spacing: 6) {
                            Button(action: addMode) {
                                HStack(spacing: 4) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 11))
                                    Text(L("添加模式", "Add mode"))
                                        .font(.system(size: 11, weight: .medium))
                                }
                                .foregroundStyle(TF.settingsTextTertiary)
                            }
                            .buttonStyle(.plain)
                            Spacer()
                        }
                        .padding(.top, 8)
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(width: 320)
                .padding(.trailing, 16)

                // Divider
                Rectangle()
                    .fill(TF.settingsTextTertiary.opacity(0.2))
                    .frame(width: 1)
                    .padding(.vertical, 4)

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
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.leading, 16)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear {
            selectedASRProvider = KeychainService.selectedASRProvider
            if selectedModeId == nil {
                selectedModeId = modes.first?.id
            }
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
            selectedModeId = modeId
        }
        .sheet(item: $recordingTarget) { target in
            HotkeyRecordingSheet(
                target: target,
                checkConflict: { code, mods in
                    guard let code else { return nil }
                    let m = mods ?? 0
                    return modes.first { other in
                        other.id != target.id &&
                        other.hotkeyCode == code &&
                        (other.hotkeyModifiers ?? 0) == m
                    }
                },
                onConfirm: { code, mods, style in
                    let m = mods ?? 0
                    if let conflictIdx = modes.firstIndex(where: {
                        $0.id != target.id &&
                        $0.hotkeyCode == code &&
                        ($0.hotkeyModifiers ?? 0) == m
                    }) {
                        modes[conflictIdx].hotkeyCode = nil
                        modes[conflictIdx].hotkeyModifiers = nil
                    }
                    if let idx = modes.firstIndex(where: { $0.id == target.id }) {
                        modes[idx].hotkeyCode = code
                        modes[idx].hotkeyModifiers = mods
                        modes[idx].hotkeyStyle = style
                    }
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
                Text(L("确定要删除「\(mode.name)」吗？此操作不可撤销。", "Delete \"\(mode.name)\"? This cannot be undone."))
            }
        }
    }

    // MARK: - Mode Row

    private func modeRow(_ mode: ProcessingMode) -> some View {
        let isActive = selectedModeId == mode.id

        return HStack(spacing: 6) {
            // Drag handle
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(isActive ? .white.opacity(0.35) : TF.settingsTextTertiary.opacity(0.5))
                .frame(width: 16)
                .contentShape(Rectangle())
                .onDrag {
                    draggingModeId = mode.id
                    return NSItemProvider(object: mode.id.uuidString as NSString)
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(mode.name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isActive ? .white : TF.settingsText)
                    if mode.isBuiltin {
                        Text(L("内置", "BUILT-IN"))
                            .font(.system(size: 8, weight: .semibold))
                            .foregroundStyle(isActive ? .white.opacity(0.5) : TF.settingsTextTertiary)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(isActive ? Color.white.opacity(0.12) : TF.settingsCardAlt))
                    }
                }

                if let kc = mode.hotkeyCode {
                    HStack(spacing: 4) {
                        Text(hotkeyStyleLabel(mode.hotkeyStyle))
                            .font(.system(size: 9))
                            .foregroundStyle(isActive ? .white.opacity(0.45) : TF.settingsTextTertiary)
                        Text(HotkeyRecorderView.keyDisplayName(keyCode: kc, modifiers: mode.hotkeyModifiers))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(isActive ? .white.opacity(0.6) : TF.settingsTextSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(isActive ? Color.white.opacity(0.12) : TF.settingsBg)
                            )
                        Button {
                            if let idx = modes.firstIndex(where: { $0.id == mode.id }) {
                                modes[idx].hotkeyCode = nil
                                modes[idx].hotkeyModifiers = nil
                                persistModes()
                            }
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 7, weight: .bold))
                                .foregroundStyle(isActive ? .white.opacity(0.4) : TF.settingsTextTertiary)
                                .frame(width: 14, height: 14)
                                .background(Circle().fill(isActive ? Color.white.opacity(0.1) : TF.settingsBg))
                        }
                        .buttonStyle(.plain)
                        .help(L("删除快捷键", "Remove hotkey"))
                    }
                } else {
                    Text(L("未设置快捷键", "No hotkey"))
                        .font(.system(size: 9))
                        .foregroundStyle(isActive ? .white.opacity(0.35) : TF.settingsTextTertiary.opacity(0.6))
                }
            }

            Spacer()

            HStack(spacing: 4) {
                Button {
                    recordingTarget = RecordingTarget(
                        id: mode.id, name: mode.name, currentStyle: mode.hotkeyStyle
                    )
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "record.circle")
                            .font(.system(size: 10))
                        Text(L("按键录制", "Record key"))
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(isActive ? .white.opacity(0.7) : TF.settingsTextSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(isActive ? Color.white.opacity(0.1) : TF.settingsBg)
                    )
                }
                .buttonStyle(.plain)

                Button { deletingModeId = mode.id } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                        .foregroundStyle(isActive ? .white.opacity(0.6) : TF.settingsTextTertiary)
                        .frame(width: 24, height: 24)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(isActive ? Color.white.opacity(0.1) : TF.settingsBg)
                        )
                }
                .buttonStyle(.plain)
                .help(L("删除模式", "Delete mode"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isActive ? TF.settingsNavActive : .clear)
        )
        .onTapGesture {
            var t = Transaction(); t.animation = nil
            withTransaction(t) { selectedModeId = mode.id }
        }
        .onDrop(of: [.text], delegate: ModeDropDelegate(
            targetId: mode.id,
            modes: $modes,
            draggingId: $draggingModeId,
            onReorder: { persistModes() }
        ))
    }

    private func hotkeyStyleLabel(_ style: ProcessingMode.HotkeyStyle) -> String {
        switch style {
        case .hold: return L("按住录制", "Hold to record")
        case .toggle: return L("按下切换", "Toggle")
        }
    }

    // MARK: - Mode Detail

    @ViewBuilder
    private func modeDetail(_ mode: ProcessingMode) -> some View {
        if mode.isBuiltin && mode.id != ProcessingMode.formalWritingId {
            builtinModeDetail(mode)
        } else if mode.id == ProcessingMode.formalWritingId {
            formalWritingModeDetail(mode)
        } else {
            ModeDetailInner(mode: mode) { updated in
                if let idx = modes.firstIndex(where: { $0.id == updated.id }) {
                    modes[idx] = updated
                    persistModes()
                }
            }
        }
    }

    private func builtinModeDetail(_ mode: ProcessingMode) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 6) {
                Image(systemName: builtinIcon(for: mode))
                    .font(.system(size: 14))
                    .foregroundStyle(TF.settingsAccentAmber)
                Text(mode.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TF.settingsText)
                Text(L("内置", "BUILT-IN"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(TF.settingsCardAlt))
            }

            if mode.id == ProcessingMode.macActionId {
                macActionDescription
            } else {
                Text(L("直接使用语音识别 API，识别完成后不做处理、直接粘贴。适合非正式场合、无需纠正口头表达的场景，输入流程更丝滑。",
                         "Uses the ASR API directly, pastes raw output without post-processing. Best for informal contexts where oral expressions don't need correction."))
                    .font(.system(size: 12))
                    .foregroundStyle(TF.settingsTextSecondary)
                    .lineSpacing(3)
            }

            Spacer()
        }
    }

    private func builtinIcon(for mode: ProcessingMode) -> String {
        switch mode.id {
        case ProcessingMode.formalWritingId: return "wand.and.stars"
        case ProcessingMode.macActionId: return "command.circle.fill"
        default: return "bolt.fill"
        }
    }

    private var macActionDescription: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L(
                "用语音直接触发 macOS 操作，不再粘贴文本。需要先在「高级 → LLM」中配置 LLM 提供商。",
                "Trigger macOS actions by voice instead of typing text. Requires an LLM provider configured under Advanced → LLM."
            ))
                .font(.system(size: 12))
                .foregroundStyle(TF.settingsTextSecondary)
                .lineSpacing(3)

            VStack(alignment: .leading, spacing: 6) {
                Text(L("支持的操作", "Supported actions"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TF.settingsText)
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
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))

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

    private func formalWritingModeDetail(_ mode: ProcessingMode) -> some View {
        FormalWritingDetailInner(mode: mode) { updated in
            if let idx = modes.firstIndex(where: { $0.id == updated.id }) {
                modes[idx] = updated
                persistModes()
            }
        }
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

    private func persistModes() {
        try? ModeStorage().save(modes)
        appState.availableModes = modes
        NotificationCenter.default.post(name: .modesDidChange, object: nil)
        if let updatedCurrentMode = modes.first(where: { $0.id == appState.currentMode.id }) {
            appState.currentMode = updatedCurrentMode
        } else if let fallback = modes.first {
            appState.currentMode = fallback
        }
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

// MARK: - Drop Delegate

private struct ModeDropDelegate: DropDelegate {
    let targetId: UUID
    @Binding var modes: [ProcessingMode]
    @Binding var draggingId: UUID?
    let onReorder: () -> Void

    func performDrop(info: DropInfo) -> Bool {
        draggingId = nil
        return true
    }

    func dropEntered(info: DropInfo) {
        guard let dragId = draggingId,
              dragId != targetId,
              let fromIndex = modes.firstIndex(where: { $0.id == dragId }),
              let toIndex = modes.firstIndex(where: { $0.id == targetId })
        else { return }

        withAnimation(.easeInOut(duration: 0.2)) {
            modes.move(fromOffsets: IndexSet(integer: fromIndex), toOffset: toIndex > fromIndex ? toIndex + 1 : toIndex)
        }
        onReorder()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }
}

// MARK: - Hotkey Recording Sheet

private struct HotkeyRecordingSheet: View {

    let target: RecordingTarget
    let checkConflict: (Int?, UInt64?) -> ProcessingMode?
    let onConfirm: (Int, UInt64?, ProcessingMode.HotkeyStyle) -> Void
    let onCancel: () -> Void

    @State private var capturedKeyCode: Int?
    @State private var capturedModifiers: UInt64?
    @State private var hotkeyStyle: ProcessingMode.HotkeyStyle
    @State private var isListening = true
    @State private var eventMonitor: Any?
    @State private var pendingModifierCode: Int?
    @State private var pendingModifierModifiers: UInt64 = 0
    @State private var modifierCaptureTask: Task<Void, Never>?

    init(
        target: RecordingTarget,
        checkConflict: @escaping (Int?, UInt64?) -> ProcessingMode?,
        onConfirm: @escaping (Int, UInt64?, ProcessingMode.HotkeyStyle) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.target = target
        self.checkConflict = checkConflict
        self.onConfirm = onConfirm
        self.onCancel = onCancel
        _hotkeyStyle = State(initialValue: target.currentStyle)
    }

    private var conflict: ProcessingMode? {
        checkConflict(capturedKeyCode, capturedModifiers)
    }

    var body: some View {
        VStack(spacing: 20) {
            Text(L("为「\(target.name)」录制快捷键", "Record hotkey for \"\(target.name)\""))
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

            if let conflict {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    Text(L("「\(conflict.name)」正在使用此快捷键，确认后将移除其绑定",
                           "\"\(conflict.name)\" is using this hotkey. Confirming will unbind it."))
                        .font(.system(size: 11))
                }
                .foregroundStyle(TF.settingsAccentAmber)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(L("触发方式", "Trigger style"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TF.settingsTextTertiary)

                HStack(spacing: 0) {
                    ForEach([ProcessingMode.HotkeyStyle.hold, .toggle], id: \.self) { style in
                        let selected = hotkeyStyle == style
                        Button {
                            withAnimation(.easeInOut(duration: 0.15)) { hotkeyStyle = style }
                        } label: {
                            Text(style == .hold ? L("按住录制", "Hold to record") : L("按下切换", "Toggle"))
                                .font(.system(size: 11, weight: selected ? .semibold : .regular))
                                .foregroundStyle(selected ? .white : TF.settingsTextSecondary)
                                .frame(maxWidth: .infinity, minHeight: 26)
                                .background(
                                    RoundedRectangle(cornerRadius: 5)
                                        .fill(selected ? TF.settingsNavActive : .clear)
                                )
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(
                    RoundedRectangle(cornerRadius: 7)
                        .fill(TF.settingsBg)
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

                Button(L("确认", "Confirm")) {
                    guard let code = capturedKeyCode else { return }
                    cleanup()
                    onConfirm(code, capturedModifiers, hotkeyStyle)
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(TF.settingsNavActive))
                .disabled(capturedKeyCode == nil)
                .opacity(capturedKeyCode == nil ? 0.5 : 1)
            }
        }
        .padding(28)
        .frame(width: 360)
        .onAppear {
            NotificationCenter.default.post(name: .hotkeyRecordingDidStart, object: nil)
            startListening()
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
                let clean = sanitizedModifierFlags(event.modifierFlags)
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

    private func sanitizedModifierFlags(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .shift, .option, .control])
    }

    private func modifierFlag(for keyCode: Int) -> NSEvent.ModifierFlags? {
        switch keyCode {
        case 54, 55: return .command
        case 56, 60: return .shift
        case 58, 61: return .option
        case 59, 62: return .control
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
        if keyCode == 63 { return flags.contains(.function) }
        guard let flag = modifierFlag(for: keyCode) else { return false }
        return flags.contains(flag)
    }
}

// MARK: - Mode Detail Inner

private struct ModeDetailInner: View {

    let mode: ProcessingMode
    let onSave: (ProcessingMode) -> Void

    @State private var name = ""
    @State private var processingLabel = ""
    @State private var prompt = ""
    @State private var saveStatus: SaveStatus = .clean

    private enum SaveStatus: Equatable {
        case clean, dirty, saved
    }

    private var isDirty: Bool {
        name != mode.name || processingLabel != mode.processingLabel || prompt != mode.prompt
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header + save
            HStack(spacing: 6) {
                Text(name.isEmpty ? L("新模式", "New Mode") : name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TF.settingsText)

                Spacer()

                if saveStatus == .saved {
                    HStack(spacing: 4) {
                        Circle().fill(TF.settingsAccentGreen).frame(width: 6, height: 6)
                        Text(L("已保存", "Saved")).font(.system(size: 10)).foregroundStyle(TF.settingsAccentGreen)
                    }
                    .transition(.opacity)
                }
                Button(L("保存", "Save")) {
                    var updated = mode
                    updated.name = name
                    updated.processingLabel = processingLabel
                    updated.prompt = prompt
                    onSave(updated)
                    withAnimation { saveStatus = .saved }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(
                    isDirty ? TF.settingsNavActive : TF.settingsTextTertiary
                ))
                .disabled(!isDirty)
            }

            // Name
            VStack(alignment: .leading, spacing: 4) {
                Text(L("名称", "Name"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TF.settingsTextTertiary)
                TextField(L("模式名称", "Mode name"), text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
            }

            // Processing label
            VStack(alignment: .leading, spacing: 4) {
                Text(L("处理标签", "Processing label"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TF.settingsTextTertiary)
                TextField(L("处理中", "Processing"), text: $processingLabel)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
                Text(L("处理进行时浮窗显示的文案，如「翻译中」「修正中」", "Text shown in the floating bar during processing, e.g. \"Translating\" \"Correcting\""))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }

            // Prompt
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(L("Prompt 模板", "Prompt Template"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TF.settingsTextTertiary)
                    Group {
                        Text("{text}") + Text("  ") + Text("{selected}") + Text("  ") + Text("{clipboard}")
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.6))
                }
                AutoSizingTextEditor(text: $prompt)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
            }

            Spacer()
        }
        .onAppear { syncFields() }
        .onChange(of: mode.id) { syncFields() }
        .onChange(of: name) { _, _ in if saveStatus == .saved { saveStatus = .dirty } }
        .onChange(of: processingLabel) { _, _ in if saveStatus == .saved { saveStatus = .dirty } }
        .onChange(of: prompt) { _, _ in if saveStatus == .saved { saveStatus = .dirty } }
    }

    private func syncFields() {
        name = mode.name
        processingLabel = mode.processingLabel
        prompt = mode.prompt
        saveStatus = .clean
    }
}

// MARK: - Formal Writing Detail Inner

private struct FormalWritingDetailInner: View {

    let mode: ProcessingMode
    let onSave: (ProcessingMode) -> Void

    @AppStorage(ShortTextDirectPolicy.enabledKey) private var shortTextDirectEnabled = true
    @AppStorage(ShortTextDirectPolicy.thresholdKey) private var shortTextDirectThreshold = ShortTextDirectPolicy.defaultThreshold
    @State private var name = ""
    @State private var processingLabel = ""
    @State private var prompt = ""
    @State private var saveStatus: SaveStatus = .clean
    @State private var promptBeforeUpdate: String?

    private enum SaveStatus: Equatable {
        case clean, dirty, saved
    }

    private var isDirty: Bool {
        name != mode.name || processingLabel != mode.processingLabel || prompt != mode.prompt
    }

    private var isLatestPrompt: Bool {
        prompt == ProcessingMode.formalWritingPromptTemplate
    }

    private let directThresholdOptions = [4, 6, 8, 10, 12]

    private var shortTextDirectSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                L("短句直接输出", "Direct Output for Short Phrases"),
                isOn: $shortTextDirectEnabled
            )
            .toggleStyle(.switch)
            Text(L("语义字符不超过阈值时跳过润色，直接使用最终识别结果",
                   "Skip polishing when semantic content does not exceed the threshold"))
                .font(.system(size: 10))
                .foregroundStyle(TF.settingsTextTertiary)
            if shortTextDirectEnabled {
                Picker(
                    L("阈值", "Threshold"),
                    selection: $shortTextDirectThreshold
                ) {
                    ForEach(directThresholdOptions, id: \.self) { value in
                        Text(L("\(value) 个语义字符", "\(value) semantic characters"))
                            .tag(value)
                    }
                }
                .pickerStyle(.menu)
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Header + actions
            HStack(spacing: 6) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 14))
                    .foregroundStyle(TF.settingsAccentAmber)
                Text(mode.name)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(TF.settingsText)
                Text(L("内置", "BUILT-IN"))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(TF.settingsCardAlt))

                Spacer()

                if !isLatestPrompt {
                    Button {
                        promptBeforeUpdate = prompt
                        prompt = ProcessingMode.formalWritingPromptTemplate
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 9))
                            Text(L("还原为官方版", "Restore to official"))
                                .font(.system(size: 10))
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
                                .font(.system(size: 9))
                            Text(L("撤销", "Undo"))
                                .font(.system(size: 10))
                        }
                        .foregroundStyle(TF.settingsTextSecondary)
                    }
                    .buttonStyle(.plain)
                }

                if saveStatus == .saved {
                    HStack(spacing: 4) {
                        Circle().fill(TF.settingsAccentGreen).frame(width: 6, height: 6)
                        Text(L("已保存", "Saved")).font(.system(size: 10)).foregroundStyle(TF.settingsAccentGreen)
                    }
                    .transition(.opacity)
                }

                Button(L("保存", "Save")) {
                    var updated = mode
                    updated.name = name
                    updated.processingLabel = processingLabel
                    updated.prompt = prompt
                    onSave(updated)
                    promptBeforeUpdate = nil
                    withAnimation { saveStatus = .saved }
                }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(
                    isDirty ? TF.settingsNavActive : TF.settingsTextTertiary
                ))
                .disabled(!isDirty)
            }

            // Name
            VStack(alignment: .leading, spacing: 4) {
                Text(L("名称", "Name"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TF.settingsTextTertiary)
                TextField(L("模式名称", "Mode name"), text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
            }

            // Processing label
            VStack(alignment: .leading, spacing: 4) {
                Text(L("处理标签", "Processing label"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TF.settingsTextTertiary)
                TextField(L("处理中", "Processing"), text: $processingLabel)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .padding(.horizontal, 12)
                    .frame(height: 36)
                    .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
                Text(L("处理进行时浮窗显示的文案，如「翻译中」「修正中」",
                         "Text shown in the floating bar during processing"))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }

            shortTextDirectSection

            // Prompt 模板
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(L("Prompt 模板", "Prompt Template"))
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(TF.settingsTextTertiary)
                    Group {
                        Text("{text}") + Text("  ") + Text("{selected}") + Text("  ") + Text("{clipboard}")
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(TF.settingsTextTertiary.opacity(0.6))
                }
                AutoSizingTextEditor(text: $prompt)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 8).fill(TF.settingsCardAlt))
            }

            Spacer()
        }
        .onAppear { syncFields() }
        .onChange(of: mode.id) { syncFields() }
        .onChange(of: name) { _, _ in if saveStatus == .saved { saveStatus = .dirty } }
        .onChange(of: processingLabel) { _, _ in if saveStatus == .saved { saveStatus = .dirty } }
        .onChange(of: prompt) { _, _ in if saveStatus == .saved { saveStatus = .dirty } }
    }

    private func syncFields() {
        name = mode.name
        processingLabel = mode.processingLabel
        prompt = mode.prompt
        saveStatus = .clean
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
