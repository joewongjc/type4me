import SwiftUI
import UIKit

struct KeyboardRootView: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        VStack(spacing: 0) {
            if model.hasFullAccess {
                VStack(spacing: 0) {
                    topBar
                        .frame(height: 60)
                        .padding(.horizontal, 8)
                        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: model.phase)
                        .animation(.easeInOut(duration: 0.2), value: model.notice)
                    micArea
                        .frame(maxHeight: .infinity)
                }
                // The caption has no container: it sits in light rising
                // from the orb, and uses the room above the orb as well as
                // the top bar.
                .background(alignment: .top) {
                    if let captionPhase {
                        VoiceAura(phase: captionPhase, level: model.level)
                            .frame(width: Caption.auraWidth, height: Caption.auraHeight)
                            .offset(y: Caption.auraTop)
                            .transition(.opacity)
                    }
                }
                .overlay(alignment: .top) {
                    if let captionPhase {
                        RecordingCaption(phase: captionPhase, meter: model.meter)
                            .padding(.top, Caption.topInset)
                            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
                    }
                }
                .animation(.easeInOut(duration: 0.25), value: captionPhase == nil)
            } else {
                fullAccessNotice
                    .frame(maxHeight: .infinity)
            }
            keyRow
                .padding(.horizontal, 4)
                .padding(.bottom, 4)
        }
        .frame(height: KeyboardMetrics.height)
        .id(model.language)
        // Transparent on purpose: iOS 26 draws the keyboard plate (with its
        // rounded top) behind the extension, and painting our own grey on
        // top of it left a visible seam under that rounded edge.
        .background(Color.clear)
    }

    // MARK: Top bar

    @ViewBuilder
    private var topBar: some View {
        if captionPhase != nil {
            // The caption is drawn over the top bar and the room below it.
            Color.clear
        } else if let notice = model.notice, notice.kind == .info {
            Text(notice.text)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(KB.ink)
                .padding(.horizontal, 18)
                .frame(height: 36)
                .glassEffect(.regular.tint(KB.keyTint), in: Capsule())
                .frame(maxWidth: .infinity)
                .transition(.opacity)
        } else {
            ModePicker(model: model)
                .transition(.opacity)
        }
    }

    /// Recording and processing always show the caption; afterwards it stays
    /// briefly to say "done" or carry an error, like the Mac floating bar.
    private var captionPhase: RecordingCaptionPhase? {
        switch model.phase {
        case .recording(let locked):
            return .recording(text: model.liveText, locked: locked)
        case .processing:
            return .processing(text: model.liveText, label: model.mode.processingLabel)
        case .idle:
            guard let notice = model.notice else { return nil }
            switch notice.kind {
            case .success: return .done(message: notice.text)
            case .error: return .error(message: notice.text)
            case .info: return nil
            }
        }
    }

    // MARK: Mic area

    private var micArea: some View {
        HStack(alignment: .center) {
            // While recording the left key cancels; undo only makes sense
            // once text has landed.
            ZStack {
                if case .recording = model.phase {
                    SideKey(systemImage: "xmark", title: L("取消", "Cancel"), enabled: true) {
                        model.cancelFromKey()
                    }
                    .transition(.blurReplace)
                } else {
                    SideKey(systemImage: "arrow.uturn.backward", title: L("撤销", "Undo"), enabled: model.canUndo && model.phase == .idle) {
                        model.undoLastInsertion()
                    }
                    .transition(.blurReplace)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: model.phase)
            Spacer()
            VStack(spacing: 4) {
                MicButton(model: model)
                Text(micCaption)
                    .font(.system(size: 12, weight: model.holdZone == .none ? .regular : .semibold))
                    .minimumScaleFactor(0.85)
                    .foregroundStyle(model.holdZone == .cancel ? Bar.recording : KB.secondary)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.15), value: model.holdZone)
                    .lineLimit(1)
            }
            Spacer()
            RepeatingKey(systemImage: "delete.left", title: L("删除", "Delete")) { model.deleteBackward() }
        }
        .padding(.horizontal, 18)
    }

    private var micCaption: String {
        switch model.phase {
        case .recording(locked: true): return L("已锁定 · 点一下结束", "Locked · Tap to finish")
        case .recording:
            switch model.holdZone {
            case .cancel: return L("松手取消", "Release to cancel")
            case .lock: return L("松手锁定，可以腾出手来", "Release to lock, no need to keep holding")
            case .none: return L("松手出字 · 左滑取消 · 上滑锁定", "Release to insert · ← Cancel · ↑ Lock")
            }
        // With no transcript the caption itself names the step; otherwise
        // it keeps the words on screen and the step is named here.
        case .processing: return model.liveText.isEmpty ? " " : model.mode.processingLabel
        case .idle:
            switch model.liveness {
            case .ready: return L("按住说话 · 松手出字", "Hold to talk · Release to insert")
            case .checking: return L("正在连接 Type4Me…", "Connecting to Type4Me…")
            case .needsApp: return L("点一下打开 Type4Me 开启会话", "Tap to open Type4Me and start")
            }
        }
    }

    // MARK: Bottom row

    private var keyRow: some View {
        HStack(spacing: 6) {
            if model.needsGlobeKey {
                KeyCap(systemImage: "globe", function: true, width: 44) { model.nextKeyboard() }
            }
            // Face ID iPhones give third-party keyboards no way to close, so
            // the keyboard carries its own.
            KeyCap(systemImage: "keyboard.chevron.compact.down", function: true, width: 44) { model.dismissKeyboard() }
                .accessibilityLabel(L("收起键盘", "Hide keyboard"))
                .accessibilityIdentifier("keyboard.hide")
            // Chinese full-width punctuation, or ASCII in English.
            ForEach([L("，", ","), L("。", "."), L("？", "?")], id: \.self) { mark in
                KeyCap(title: mark, width: 40) { model.insert(mark) }
            }
            KeyCap(title: L("空格", "space")) { model.insert(" ") }
            KeyCap(title: model.returnKeyTitle, function: true, width: 72) { model.returnKey() }
        }
        .frame(height: 44)
    }

    private var fullAccessNotice: some View {
        VStack(spacing: 8) {
            Text(L("需要打开“允许完全访问”", "Turn on “Allow Full Access”"))
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(KB.ink)
            Text(L(
                "设置 › 通用 › 键盘 › 键盘 › Type4Me › 允许完全访问。\n键盘要通过它和 Type4Me App 通信，由 App 录音和识别。",
                "Settings › General › Keyboard › Keyboards › Type4Me › Allow Full Access.\nThe keyboard needs it to talk to the Type4Me app, which does the recording and recognition."
            ))
                .font(.system(size: 13))
                .foregroundStyle(KB.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - Pieces

enum KB {
    static let background = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.16, alpha: 1) : UIColor(red: 0.82, green: 0.83, blue: 0.855, alpha: 1) })
    static let key = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white })
    static let functionKey = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.28, alpha: 1) : UIColor(red: 0.67, green: 0.69, blue: 0.73, alpha: 1) })
    static let ink = Color(UIColor { $0.userInterfaceStyle == .dark ? .white : UIColor(red: 0.075, green: 0.075, blue: 0.075, alpha: 1) })
    static let secondary = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.7, alpha: 1) : UIColor(white: 0.3, alpha: 1) })
    static let mic = Color(UIColor { $0.userInterfaceStyle == .dark ? .white : UIColor(red: 0.075, green: 0.075, blue: 0.075, alpha: 1) })
    static let micGlyph = Color(UIColor { $0.userInterfaceStyle == .dark ? .black : .white })
    /// Recording keeps the floating-bar black so the button and the caption
    /// read as one object; the orb supplies the colour.
    static let recordingFill = Bar.background
    /// Glass tints: character keys sit slightly brighter than function keys,
    /// the way the system keyboard separates them.
    static let keyTint = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 1, alpha: 0.55) })
    static let functionTint = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0, alpha: 0.10) : UIColor(white: 1, alpha: 0.12) })
    static let halo = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.07) })
    static let track = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.07) })
    static let segment = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 0.42, alpha: 1) : .white })
}

/// Segmented mode switcher in the Mac settings style: a recessed track with
/// a raised selected segment that slides between modes.
struct ModePicker: View {
    @ObservedObject var model: KeyboardModel
    @Namespace private var selection

    var body: some View {
        HStack(spacing: 2) {
            ForEach(DictationMode.keyboardOrder) { mode in
                let selected = model.mode == mode
                let enabled = !mode.usesLLM || model.llmConfigured
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.82)) { model.select(mode) }
                } label: {
                    Text(mode.title)
                        .font(.system(size: 14, weight: selected ? .semibold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .foregroundStyle(KB.ink.opacity(selected ? 1 : (enabled ? 0.62 : 0.3)))
                        .frame(maxWidth: .infinity)
                        .frame(height: 34)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(KB.segment)
                                    .shadow(color: .black.opacity(0.10), radius: 1.5, y: 1)
                                    .matchedGeometryEffect(id: "segment", in: selection)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .glassEffect(.regular.tint(KB.functionTint), in: Capsule())
        .padding(.horizontal, 4)
    }
}

/// The centre button. Idle it is a solid mic; the moment recording starts it
/// becomes the Mac Liquid Glass orb, which keeps flowing through processing
/// and turns back into the mic when the text lands.
struct MicButton: View {
    @ObservedObject var model: KeyboardModel
    @State private var pressStarted: Date?
    @State private var cancelZone = false
    @State private var lockZone = false
    @State private var pressed = false

    static let size: CGFloat = 84

    private var isRecording: Bool {
        if case .recording = model.phase { return true }
        return false
    }

    private var isLocked: Bool { model.phase == .recording(locked: true) }
    private var showsOrb: Bool { model.phase != .idle }

    var body: some View {
        ZStack {
            // Siri-coloured glow behind the orb, breathing with the voice.
            Circle()
                .fill(AngularGradient(
                    colors: [
                        Color(red: 0.55, green: 0.36, blue: 1.0),
                        Color(red: 1.0, green: 0.42, blue: 0.75),
                        Color(red: 0.36, green: 0.85, blue: 1.0),
                        Color(red: 0.55, green: 0.36, blue: 1.0),
                    ],
                    center: .center
                ))
                .frame(width: Self.size, height: Self.size)
                .blur(radius: 16)
                .scaleEffect(isRecording && !cancelZone ? 0.95 + CGFloat(model.level) * 0.3 : 0.7)
                .opacity(isRecording && !cancelZone ? 0.25 + Double(model.level) * 0.45 : 0)
                .animation(.easeOut(duration: 0.18), value: model.level)
                .allowsHitTesting(false)

            // Prominent Liquid Glass tinted with the ink colour: the one
            // primary control on the keyboard.
            Color.clear
                .frame(width: Self.size, height: Self.size)
                .glassEffect(
                    model.liveness == .needsApp ? .regular.interactive() : .regular.tint(KB.mic).interactive(),
                    in: Circle()
                )
                .overlay(
                    Circle().strokeBorder(KB.ink.opacity(model.liveness == .needsApp ? 0.45 : 0), lineWidth: 1.5)
                )
                .scaleEffect(showsOrb ? 0.7 : 1)
                .opacity(showsOrb ? 0 : 1)
                .animation(.easeOut(duration: showsOrb ? 0.12 : 0.25), value: showsOrb)

            // Kept mounted (frozen) while idle so the first press shows a
            // ready frame instead of a blank layer.
            LiquidGlassOrb(meter: model.meter, size: Self.size + 8, isFrozen: !showsOrb)
                .scaleEffect(showsOrb ? 1 : 0.75)
                .opacity(showsOrb ? (cancelZone ? 0.35 : 1) : 0)
                .animation(showsOrb ? .spring(response: 0.3, dampingFraction: 0.68) : .easeIn(duration: 0.15), value: showsOrb)

            overlayGlyph
        }
        .frame(width: Self.size + 8, height: Self.size + 8)
        .scaleEffect(pressed && !showsOrb ? 0.94 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressed)
        .animation(.spring(response: 0.38, dampingFraction: 0.72), value: showsOrb)
        .animation(.easeInOut(duration: 0.15), value: cancelZone)
        .animation(.easeInOut(duration: 0.15), value: lockZone)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if pressStarted == nil {
                        pressStarted = Date()
                        pressed = true
                        cancelZone = false
                        lockZone = false
                        model.micPressed()
                    }
                    guard isRecording, !isLocked else { return }
                    let nowCancel = value.translation.width < -70
                    let nowLock = value.translation.height < -50 && !nowCancel
                    if nowCancel != cancelZone || nowLock != lockZone {
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                    cancelZone = nowCancel
                    lockZone = nowLock
                    model.holdZone = nowCancel ? .cancel : (nowLock ? .lock : .none)
                }
                .onEnded { _ in
                    let held = Date().timeIntervalSince(pressStarted ?? Date())
                    pressStarted = nil
                    pressed = false
                    // A quick tap locks recording on, like a toggle.
                    model.micReleased(cancelled: cancelZone, locked: lockZone || held < 0.3)
                    cancelZone = false
                    lockZone = false
                    model.holdZone = .none
                }
        )
        .accessibilityLabel(isRecording ? L("结束说话", "Finish talking") : L("按住说话", "Hold to talk"))
        .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var overlayGlyph: some View {
        if cancelZone {
            Image(systemName: "xmark")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(KB.ink)
                .transition(.scale.combined(with: .opacity))
        } else if lockZone {
            glassBadge(Image(systemName: "lock.fill").font(.system(size: 20, weight: .semibold)))
        } else if !showsOrb {
            Image(systemName: model.liveness == .needsApp ? "mic" : "mic.fill")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(model.liveness == .needsApp ? KB.ink : KB.micGlyph)
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    private func glassBadge(_ image: some View) -> some View {
        image
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
            .transition(.scale.combined(with: .opacity))
    }
}

struct SideKey: View {
    let systemImage: String
    let title: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 18, weight: .medium))
                Text(title).font(.system(size: 11))
            }
            .foregroundStyle(KB.ink.opacity(enabled ? 1 : 0.32))
            .frame(width: 64, height: 56)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(KB.functionTint).interactive(enabled), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .disabled(!enabled)
    }
}

/// Delete key that repeats while held.
struct RepeatingKey: View {
    let systemImage: String
    let title: String
    let action: () -> Void
    @State private var timer: Timer?

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 18, weight: .medium))
            Text(title).font(.system(size: 11))
        }
        .foregroundStyle(KB.ink)
        .frame(width: 64, height: 56)
        .glassEffect(.regular.tint(KB.functionTint).interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard timer == nil else { return }
                    action()
                    timer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: false) { _ in
                        timer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in action() }
                    }
                }
                .onEnded { _ in
                    timer?.invalidate()
                    timer = nil
                }
        )
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
    }
}

struct KeyCap: View {
    var title: String? = nil
    var systemImage: String? = nil
    var function = false
    var width: CGFloat? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Group {
                if let systemImage {
                    Image(systemName: systemImage).font(.system(size: 18))
                } else if let title {
                    Text(title).font(.system(size: 16))
                }
            }
            .foregroundStyle(KB.ink)
            .frame(maxWidth: width == nil ? .infinity : width, maxHeight: .infinity)
            .frame(width: width)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(function ? KB.functionTint : KB.keyTint).interactive(),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }
}
