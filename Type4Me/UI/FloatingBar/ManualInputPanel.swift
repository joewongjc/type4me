import AppKit
import SwiftUI

private enum ManualInputLayout {
    // Include the blur tail and downward offset outside both glass surfaces.
    // AppKit clips any pixels that extend past the transparent hosting window.
    static let shadowInset: CGFloat = 32
    static let preferredSurfaceWidth: CGFloat = 684
}

private final class ManualInputPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@Observable
@MainActor
final class ManualInputDraft {
    var text = ""
    var modes: [ProcessingMode]
    var editorHeight: CGFloat = 24
    init(modes: [ProcessingMode]) { self.modes = modes }
}

@MainActor
final class ManualInputController {
    private let panel: ManualInputPanel
    let draft: ManualInputDraft
    private weak var editor: NSTextView?
    private var initialFocusPending = false
    private let width: CGFloat
    private let maximumEditorHeight: CGFloat
    private let anchor: FloatingBarVerticalAnchor
    var hasMarkedText: Bool { editor?.hasMarkedText() == true }

    init(modes: [ProcessingMode], onSubmit: @escaping (ProcessingMode) -> Void, onCancel: @escaping () -> Void) {
        draft = ManualInputDraft(modes: modes)
        let screen = FloatingBarPanel.screenUnderMouse()
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        let placement = FloatingBarPlacementStore.load()
        let style = RecordingIndicatorStyle.current()
        let baseHeight = FloatingBarPlacementGeometry.baseCapsuleHeight(for: style)
        let center = FloatingBarPlacementGeometry.resolveCenter(placement, visibleFrame: visibleFrame, baseHeight: baseHeight)
        let resolvedAnchor = FloatingBarPlacementGeometry.verticalAnchor(center: center, visibleFrame: visibleFrame)
        self.anchor = resolvedAnchor

        width = min(ManualInputLayout.preferredSurfaceWidth + ManualInputLayout.shadowInset * 2,
                    visibleFrame.width - 40)
        let overhead: CGFloat = 44 + 10 + 28 + ManualInputLayout.shadowInset + 16
        let availableHeight: CGFloat
        switch resolvedAnchor {
        case .bottom:
            let capsuleBottom = center.y - baseHeight / 2
            availableHeight = (visibleFrame.maxY - capsuleBottom) - overhead
        case .top:
            let capsuleTop = center.y + baseHeight / 2
            availableHeight = (capsuleTop - visibleFrame.minY) - overhead
        }
        maximumEditorHeight = min(240, max(24, availableHeight))
        let size = NSSize(width: width, height: 44 + 10 + 24 + 28 + ManualInputLayout.shadowInset * 2)
        panel = ManualInputPanel(contentRect: .init(origin: .zero, size: size),
                                 styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.contentView = NSHostingView(rootView: ManualInputView(
            draft: draft, width: width - ManualInputLayout.shadowInset * 2,
            onSubmit: onSubmit, onCancel: onCancel,
            onEditorReady: { [weak self] in self?.connectEditor($0) },
            onHeightChange: { [weak self] in self?.resizeEditor(to: $0) }))
        if let screen {
            let frame = FloatingBarPlacementGeometry.anchoredFrame(
                size: size,
                center: center,
                baseHeight: baseHeight,
                anchor: resolvedAnchor,
                reserve: 0,
                shadowInset: ManualInputLayout.shadowInset,
                visibleFrame: screen.visibleFrame
            )
            panel.setFrame(frame, display: false)
        }
    }

    func show() {
        initialFocusPending = true
        panel.makeKeyAndOrderFront(nil)
        panel.contentView?.layoutSubtreeIfNeeded()
        focusEditorIfNeeded()
        // Hosting may create/attach the editor after the panel was ordered front.
        DispatchQueue.main.async { [weak self] in self?.focusEditorIfNeeded() }
    }

    private func connectEditor(_ editor: NSTextView) {
        self.editor = editor
        panel.initialFirstResponder = editor
        DispatchQueue.main.async { [weak self] in self?.focusEditorIfNeeded() }
    }

    private func focusEditorIfNeeded() {
        guard initialFocusPending, panel.isVisible,
              let editor, editor.window === panel else { return }
        panel.makeKey()
        let accepted = panel.makeFirstResponder(editor)
        if accepted && panel.isKeyWindow && panel.firstResponder === editor {
            initialFocusPending = false
        }
        DebugFileLogger.log("manual input initial focus accepted=\(accepted) key=\(panel.isKeyWindow)")
    }

    func submittedText() -> String? {
        editor?.unmarkText()
        let text = editor?.string ?? draft.text
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            if let editor { panel.makeFirstResponder(editor) }
            NSSound.beep()
            return nil
        }
        return text
    }

    private func resizeEditor(to measuredHeight: CGFloat) {
        let height = min(maximumEditorHeight, max(24, ceil(measuredHeight)))
        guard abs(height - draft.editorHeight) > 0.5 else { return }
        draft.editorHeight = height
        var frame = panel.frame
        let newHeight = 44 + 10 + height + 28 + ManualInputLayout.shadowInset * 2
        let heightDelta = newHeight - frame.size.height
        frame.size.height = newHeight
        if anchor == .top {
            frame.origin.y -= heightDelta
        }
        panel.setFrame(frame, display: true)
    }
    func close() {
        initialFocusPending = false
        panel.orderOut(nil)
    }
}

private struct ManualInputView: View {
    @Bindable var draft: ManualInputDraft
    let width: CGFloat
    let onSubmit: (ProcessingMode) -> Void
    let onCancel: () -> Void
    let onEditorReady: (NSTextView) -> Void
    let onHeightChange: (CGFloat) -> Void
    @AppStorage("tf_language") private var language = "system"
    @AppStorage(RecordingTheme.storageKey) private var theme = RecordingTheme.defaultValue
    @State private var showsMoreModes = false
    private var textColor: Color { theme == .light ? TF.floatingTextLight : TF.floatingText }

    private func shortcut(for mode: ProcessingMode) -> String? {
        mode.hotkeyBindings.first.map {
            HotkeyRecorderView.keyDisplayName(keyCode: $0.keyCode, modifiers: $0.modifiers)
        }
    }

    private func modeWidth(_ mode: ProcessingMode) -> CGFloat {
        let titleWidth = min(150, (mode.localizedDisplayName as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium)]).width)
        let keyWidth = shortcut(for: mode).map { ($0 as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width + 20 } ?? 0
        return titleWidth + keyWidth + 28
    }

    private var visibleModes: [ProcessingMode] {
        var remaining = width - 16
        var visible: [ProcessingMode] = []
        for (index, mode) in draft.modes.enumerated() {
            let needsOverflow = index < draft.modes.count - 1
            let needed = modeWidth(mode) + (visible.isEmpty ? 0 : 2)
            guard needed + (needsOverflow ? 36 : 0) <= remaining else { break }
            visible.append(mode)
            remaining -= needed
        }
        return visible
    }

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 2) {
                ForEach(visibleModes) { mode in
                    modeAction(mode).frame(width: modeWidth(mode))
                }
                if draft.modes.isEmpty {
                    Text(L("暂无可用模式", "No processing modes"))
                        .font(.system(size: 13)).padding(.horizontal, 12)
                }
                Spacer(minLength: 0)
                if visibleModes.count < draft.modes.count {
                    Button { showsMoreModes.toggle() } label: {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 12, weight: .medium))
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(ManualModeButtonStyle(theme: theme))
                    .help(L("更多模式", "More modes"))
                    .accessibilityLabel(L("更多处理模式", "More processing modes"))
                    .popover(isPresented: $showsMoreModes, arrowEdge: .top) {
                        ScrollView {
                            VStack(spacing: 2) {
                                ForEach(draft.modes.dropFirst(visibleModes.count)) { mode in
                                    modeAction(mode, expanded: true)
                                }
                            }.padding(6)
                        }
                        .frame(width: 290, height: min(320, CGFloat(draft.modes.count - visibleModes.count) * 38 + 12))
                        .environment(\.colorScheme, theme == .light ? .light : .dark)
                    }
                }
            }
            .padding(.horizontal, 8)
            .frame(width: width, height: 44)
            .background(glass(cornerRadius: 22))
            .shadow(color: .black.opacity(theme == .light ? 0.10 : 0.22), radius: 5, y: 3)

            HStack(alignment: .top, spacing: 10) {
                ManualTextEditor(draft: draft, theme: theme, onCancel: onCancel,
                                 onReady: onEditorReady, onHeightChange: onHeightChange)
                .frame(height: draft.editorHeight)
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(textColor.opacity(0.5))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(ManualModeButtonStyle(theme: theme))
                .help(L("关闭（Esc）", "Close (Esc)"))
                .accessibilityLabel(L("关闭手动输入", "Close manual input"))
            }
            .padding(.vertical, 14)
            .padding(.leading, 22)
            .padding(.trailing, 14)
            .frame(width: width)
            .background(glass(cornerRadius: 26))
            .shadow(color: .black.opacity(theme == .light ? 0.10 : 0.22), radius: 6, y: 3)
        }
        .foregroundStyle(textColor)
        .environment(\.colorScheme, theme == .light ? .light : .dark)
        .padding(ManualInputLayout.shadowInset)
    }

    private func glass(cornerRadius: CGFloat) -> some View {
        RecordingGlassSurface(cornerRadius: cornerRadius, theme: theme,
                              tintOpacity: theme == .light ? 0.75 : 0.40)
    }

    private func modeAction(_ mode: ProcessingMode, expanded: Bool = false) -> some View {
        Button {
            showsMoreModes = false
            onSubmit(mode)
        } label: {
            HStack(spacing: 8) {
                Text(mode.localizedDisplayName)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                if expanded { Spacer(minLength: 8) }
                if let key = shortcut(for: mode) {
                    Text(key)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(textColor.opacity(0.56))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 5).fill(textColor.opacity(0.055)))
                        .fixedSize()
                }
            }
            .foregroundStyle(textColor)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, minHeight: 34)
            .contentShape(Capsule())
        }
        .buttonStyle(ManualModeButtonStyle(theme: theme))
        .help(L("使用「\(mode.localizedDisplayName)」处理并输入", "Process and insert with \(mode.localizedDisplayName)"))
        .accessibilityLabel(mode.localizedDisplayName)
        .accessibilityHint(L("处理并输入当前文字", "Process and insert the current text"))
    }
}

private struct ManualModeButtonStyle: ButtonStyle {
    let theme: RecordingTheme
    func makeBody(configuration: Configuration) -> some View {
        HoverBody(configuration: configuration, theme: theme)
    }
    private struct HoverBody: View {
        let configuration: Configuration
        let theme: RecordingTheme
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background(Capsule().fill((theme == .light ? Color.black : Color.white)
                    .opacity(configuration.isPressed ? 0.14 : hovered ? 0.08 : 0)))
                .onHover { hovered = $0 }
                .animation(.easeOut(duration: 0.12), value: hovered)
        }
    }
}

private struct ManualTextEditor: NSViewRepresentable {
    let draft: ManualInputDraft
    let theme: RecordingTheme
    let onCancel: () -> Void
    let onReady: (NSTextView) -> Void
    let onHeightChange: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(draft: draft, onCancel: onCancel) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        let editor = ManualInputTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 24))
        editor.minSize = NSSize(width: 0, height: 24)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 15)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 0, height: 2)
        editor.textContainer?.lineFragmentPadding = 0
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.allowsUndo = true
        editor.onHeightChange = onHeightChange
        editor.onWindowAttachment = onReady
        scroll.documentView = editor
        onReady(editor)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? ManualInputTextView else { return }
        editor.textColor = theme == .light ? NSColor(TF.floatingTextLight) : NSColor(TF.floatingText)
        editor.insertionPointColor = editor.textColor
        editor.placeholder = L("输入文字，选择上方模式…", "Type, then choose a mode above…")
        editor.placeholderColor = editor.textColor?.withAlphaComponent(0.42) ?? .placeholderTextColor
        scroll.window?.appearance = NSAppearance(named: theme == .light ? .aqua : .darkAqua)
        editor.setAccessibilityLabel(L("输入要处理的文字", "Text to process"))
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let draft: ManualInputDraft
        let onCancel: () -> Void
        init(draft: ManualInputDraft, onCancel: @escaping () -> Void) {
            self.draft = draft
            self.onCancel = onCancel
        }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? ManualInputTextView else { return }
            draft.text = editor.string
        }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.cancelOperation(_:)), !textView.hasMarkedText() {
                onCancel()
                return true
            }
            return false
        }
    }
}

private final class ManualInputTextView: NSTextView {
    var onHeightChange: ((CGFloat) -> Void)?
    var onWindowAttachment: ((NSTextView) -> Void)?
    var placeholder = "" { didSet { needsDisplay = true } }
    var placeholderColor: NSColor = .placeholderTextColor { didSet { needsDisplay = true } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { onWindowAttachment?(self) }
    }

    // Keep the placeholder in the native text view so it reflects marked text
    // immediately, even when the IME has not sent textDidChange yet.
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !hasMarkedText() else { return }
        (placeholder as NSString).draw(at: textContainerOrigin, withAttributes: [
            .font: font ?? NSFont.systemFont(ofSize: 15),
            .foregroundColor: placeholderColor
        ])
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        refreshTextPresentation()
    }

    override func unmarkText() {
        super.unmarkText()
        refreshTextPresentation()
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        refreshTextPresentation()
    }

    override func didChangeText() {
        super.didChangeText()
        refreshTextPresentation()
    }

    private func refreshTextPresentation() {
        needsDisplay = true
        reportHeight()
    }

    private var lastReportedHeight: CGFloat = 0
    override func layout() {
        super.layout()
        reportHeight()
    }
    func reportHeight() {
        guard let manager = layoutManager, let container = textContainer else { return }
        manager.ensureLayout(for: container)
        let bottom = max(manager.usedRect(for: container).maxY, manager.extraLineFragmentRect.maxY)
        let height = max(24, ceil(bottom + textContainerInset.height * 2))
        guard abs(height - lastReportedHeight) > 0.5 else { return }
        lastReportedHeight = height
        // AppKit layout can run during SwiftUI's update; defer the observable change.
        DispatchQueue.main.async { [weak self] in self?.onHeightChange?(height) }
    }

    /// Keep editing commands in this nonactivating panel, not the target app.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags == .command || flags == [.command, .shift] else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": selectAll(nil)
        case "c": copy(nil)
        case "v": pasteAsPlainText(nil)
        case "x": cut(nil)
        case "z":
            if flags.contains(.shift) { undoManager?.redo() } else { undoManager?.undo() }
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}
