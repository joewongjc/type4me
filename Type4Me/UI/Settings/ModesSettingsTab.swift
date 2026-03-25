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

    private var builtinModes: [ProcessingMode] {
        modes.filter { $0.isBuiltin }
    }

    private var customModes: [ProcessingMode] {
        modes.filter { !$0.isBuiltin }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SettingsSectionHeader(
                label: "MODES",
                title: L("处理模式", "Modes"),
                description: L("配置语音转写后的文本处理流水线。快速模式输出原文，其他模式经 LLM 加工。", "Configure text processing pipelines after speech-to-text. Quick mode outputs raw text; others use LLM processing.")
            )

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // BLOCK 1: 内置模式
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            sectionHeader(L("内置模式", "Built-in Modes"))

            HStack(spacing: 12) {
                ForEach(builtinModes) { mode in
                    builtinModeCard(mode)
                        .frame(maxWidth: .infinity)
                }
            }

            sectionSpacer()

            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            // BLOCK 2: 自定义 Prompt 模式
            // ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            sectionHeader(L("自定义模式", "Custom Modes"))

            HStack(alignment: .top, spacing: 0) {
                // Mode list
                VStack(spacing: 3) {
                    ForEach(customModes) { mode in
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
                .frame(width: 320)
                .padding(.trailing, 16)

                // Divider
                Rectangle()
                    .fill(TF.settingsTextTertiary.opacity(0.2))
                    .frame(width: 1)
                    .padding(.vertical, 4)

                // Detail
                Group {
                    if let mode = selectedCustomMode {
                        modeDetail(mode)
                    } else {
                        Text(L("选择一个模式查看详情", "Select a mode to view details"))
                            .font(.system(size: 12))
                            .foregroundStyle(TF.settingsTextTertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.leading, 16)
            }
            .frame(maxWidth: .infinity)
        }
        .onAppear {
            if selectedModeId == nil {
                selectedModeId = customModes.first?.id
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

    // MARK: - Section Layout

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(TF.settingsText)
            .padding(.bottom, 12)
    }

    private func sectionSpacer() -> some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 20)
            Divider()
            Spacer().frame(height: 20)
        }
    }

    // MARK: - Builtin Mode Card

    private var builtinMeta: [UUID: (icon: String, desc: String, badge: String)] {
        [
            ProcessingMode.directId: (
                icon: "bolt.fill",
                desc: L("流式语音识别，边说边出字。松开快捷键后立即将文本粘贴到光标位置，响应最快。适合日常短句、即时通讯和快速笔记。",
                         "Streaming ASR, text appears as you speak. Pastes to cursor immediately on key release. Best for short phrases, messaging and quick notes."),
                badge: L("低延迟，边说边出", "Low latency, real-time")
            ),
            ProcessingMode.performanceId: (
                icon: "waveform.badge.magnifyingglass",
                desc: L("录音结束后将完整音频提交识别引擎，获得更准确的全文结果。适合长段落口述、正式文档和需要高准确率的场景。",
                         "Submits full audio after recording for more accurate results. Best for long dictation, formal documents and high-accuracy scenarios."),
                badge: L("高准确率，整段识别", "High accuracy, full-segment")
            ),
        ]
    }

    private func builtinModeCard(_ mode: ProcessingMode) -> some View {
        let meta = builtinMeta[mode.id] ?? (icon: "mic.fill", desc: "", badge: "")

        return VStack(alignment: .leading, spacing: 0) {
            // Header: icon + name + badge
            HStack(spacing: 6) {
                Image(systemName: meta.icon)
                    .font(.system(size: 13))
                    .foregroundStyle(TF.settingsAccentGreen)
                Text(mode.name)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(TF.settingsText)
                Text(L("内置", "Built-in"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(TF.settingsTextTertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(TF.settingsCardAlt))
            }
            .padding(.bottom, 8)

            // Description
            Text(meta.desc)
                .font(.system(size: 11))
                .foregroundStyle(TF.settingsTextSecondary)
                .lineSpacing(3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 8)

            // Feature badge
            HStack(spacing: 5) {
                Image(systemName: meta.icon)
                    .font(.system(size: 9))
                    .foregroundStyle(TF.settingsAccentGreen)
                Text(meta.badge)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(TF.settingsAccentGreen)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(TF.settingsAccentGreen.opacity(0.1))
            )

            Spacer(minLength: 8)

            // Hotkey row (same style as custom mode rows)
            HStack(spacing: 4) {
                if let kc = mode.hotkeyCode {
                    Text(mode.hotkeyStyle == .hold ? L("按住录制", "Hold to record") : L("按下切换", "Toggle"))
                        .font(.system(size: 9))
                        .foregroundStyle(TF.settingsTextTertiary)
                    Text(HotkeyRecorderView.keyDisplayName(keyCode: kc, modifiers: mode.hotkeyModifiers))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(TF.settingsTextSecondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(TF.settingsCardAlt)
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
                            .foregroundStyle(TF.settingsTextTertiary)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(TF.settingsCardAlt))
                    }
                    .buttonStyle(.plain)
                    .help(L("删除快捷键", "Remove hotkey"))
                } else {
                    Text(L("未设置快捷键", "No hotkey"))
                        .font(.system(size: 9))
                        .foregroundStyle(TF.settingsTextTertiary.opacity(0.6))
                }

                Spacer()

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
                    .foregroundStyle(TF.settingsTextSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(TF.settingsCardAlt)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(TF.settingsBg)
        )
    }

    // MARK: - Custom Mode Row

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
                Text(mode.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isActive ? .white : TF.settingsText)

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

    private func modeDetail(_ mode: ProcessingMode) -> some View {
        ModeDetailInner(mode: mode) { updated in
            if let idx = modes.firstIndex(where: { $0.id == updated.id }) {
                modes[idx] = updated
                persistModes()
            }
        }
    }

    // MARK: - Helpers

    private var selectedCustomMode: ProcessingMode? {
        customModes.first { $0.id == selectedModeId }
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
            selectedModeId = customModes.first?.id
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
                        Text(L("按下快捷键...", "Press a key..."))
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

        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            if event.type == .flagsChanged {
                let kc = Int(event.keyCode)
                guard HotkeyRecorderView.modifierKeyCodes.contains(kc) else { return event }
                let pressed = isModifierPressed(keyCode: kc, flags: event.modifierFlags)

                if pressed {
                    pendingModifierCode = kc
                    modifierCaptureTask?.cancel()
                    modifierCaptureTask = Task {
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        await MainActor.run {
                            guard let pending = pendingModifierCode else { return }
                            captureModifierOnlyHotkey(pending)
                        }
                    }
                } else {
                    if let pending = pendingModifierCode {
                        modifierCaptureTask?.cancel()
                        modifierCaptureTask = nil
                        capturedKeyCode = pending
                        capturedModifiers = 0
                        pendingModifierCode = nil
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
                let clean = event.modifierFlags.intersection([.command, .shift, .option, .control])
                capturedModifiers = clean.isEmpty ? 0 : UInt64(clean.rawValue)
                isListening = false
                removeMonitor()
                return nil
            }

            return event
        }
    }

    @MainActor
    private func captureModifierOnlyHotkey(_ keyCode: Int) {
        capturedKeyCode = keyCode
        capturedModifiers = 0
        pendingModifierCode = nil
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
        removeMonitor()
    }

    private func isModifierPressed(keyCode: Int, flags: NSEvent.ModifierFlags) -> Bool {
        switch keyCode {
        case 54, 55: return flags.contains(.command)
        case 56, 60: return flags.contains(.shift)
        case 58, 61: return flags.contains(.option)
        case 59, 62: return flags.contains(.control)
        case 63: return flags.contains(.function)
        default: return false
        }
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
            // Name
            VStack(alignment: .leading, spacing: 4) {
                Text(L("名称", "Name"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TF.settingsTextTertiary)
                TextField(L("模式名称", "Mode name"), text: $name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(TF.settingsBg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(TF.settingsTextTertiary.opacity(0.2), lineWidth: 1)
                    )
            }

            // Processing label
            VStack(alignment: .leading, spacing: 4) {
                Text(L("处理标签", "Processing label"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TF.settingsTextTertiary)
                TextField(L("处理中", "Processing"), text: $processingLabel)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(TF.settingsBg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(TF.settingsTextTertiary.opacity(0.2), lineWidth: 1)
                    )
                Text(L("处理进行时浮窗显示的文案，如「翻译中」「修正中」", "Text shown in the floating bar during processing, e.g. \"Translating\" \"Correcting\""))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }

            // Prompt
            VStack(alignment: .leading, spacing: 4) {
                Text(L("Prompt 模板", "Prompt Template"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(TF.settingsTextTertiary)
                TextEditor(text: $prompt)
                    .font(.system(size: 11, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .frame(minHeight: 80)
                    .background(
                        RoundedRectangle(cornerRadius: 6).fill(TF.settingsBg)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(TF.settingsTextTertiary.opacity(0.2), lineWidth: 1)
                    )
                Text(L("变量: {text} 转写文本, {selected} 选中文本, {clipboard} 剪切板。留空则直接输出",
                       "Variables: {text} transcribed text, {selected} selected text, {clipboard} clipboard. Leave empty for raw output."))
                    .font(.system(size: 10))
                    .foregroundStyle(TF.settingsTextTertiary)
            }

            // Save row
            HStack(spacing: 8) {
                Spacer()

                // Status indicator
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
