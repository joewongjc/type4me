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
            HStack(spacing: 8) {
                ModePicker(model: model)
                OpenAppButton { model.openSettings() }
            }
            .padding(.horizontal, 4)
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
            // While recording the side keys become the two places the held
            // finger can slide to: cancel on the left, lock on the right.
            // Undo only makes sense once text has landed.
            ZStack {
                if case .recording = model.phase {
                    SlideTargetKey(
                        systemImage: "xmark",
                        title: L("取消", "Cancel"),
                        pull: max(0, -model.holdPull),
                        armed: model.holdZone == .cancel,
                        tint: Bar.recording
                    ) {
                        model.cancelFromKey()
                    }
                    .transition(.blurReplace)
                } else if model.canRedo {
                    SideKey(systemImage: "arrow.uturn.forward", title: L("重做", "Redo"), enabled: model.phase == .idle) {
                        model.redoUndoneInsertion()
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
            .animation(.easeInOut(duration: 0.18), value: model.canRedo)
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
            ZStack {
                switch model.phase {
                case .recording(locked: false):
                    SlideTargetKey(
                        systemImage: "lock.fill",
                        title: L("锁定", "Lock"),
                        pull: max(0, model.holdPull),
                        armed: model.holdZone == .lock,
                        tint: KB.lock
                    ) {
                        model.lockFromKey()
                    }
                    .transition(.blurReplace)
                case .recording(locked: true):
                    SideKey(systemImage: "checkmark", title: L("完成", "Done"), enabled: true) {
                        model.finishFromKey()
                    }
                    .transition(.blurReplace)
                default:
                    RepeatingKey(systemImage: "delete.left", title: L("删除", "Delete")) { model.deleteBackward() }
                        .transition(.blurReplace)
                }
            }
            .animation(.easeInOut(duration: 0.18), value: model.phase)
        }
        .padding(.horizontal, 18)
    }

    private var micCaption: String {
        switch model.phase {
        case .recording(locked: true): return L("已锁定 · 点光球或完成结束", "Locked · Tap the orb or Done")
        case .recording:
            switch model.holdZone {
            case .cancel: return L("松手取消", "Release to cancel")
            case .lock: return L("松手锁定", "Release to lock")
            case .none: return L("← 取消 · 松手出字 · 锁定 →", "← Cancel · Release · Lock →")
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
                KeyCap(title: mark, width: 40, repeats: true) { model.insert(mark) }
            }
            KeyCap(title: L("空格", "space"), repeats: true) { model.insert(" ") }
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
    /// The lock target lights up teal, the cancel target the recording red.
    static let lock = Color(red: 0.11, green: 0.62, blue: 0.46)
    static let halo = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.07) })
}

/// The system segmented control, so it keeps the iOS 26 Liquid Glass thumb
/// that swells under a finger and can be dragged between modes, restyled to
/// read like the tab bar: glass behind it and a faint selected pill. A mode
/// that needs a text model can't be disabled on its own here; picking it
/// without one is refused by the model, which shows why, and the control
/// springs back to the mode in use.
struct ModePicker: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        ModeSegments(
            modes: DictationMode.keyboardOrder,
            selected: model.mode,
            select: { model.select($0) }
        )
        .frame(height: 38)
        .padding(3)
        .glassEffect(.regular.tint(KB.functionTint), in: Capsule())
        .accessibilityLabel(L("模式", "Mode"))
    }
}

private struct ModeSegments: UIViewRepresentable {
    let modes: [DictationMode]
    let selected: DictationMode
    let select: (DictationMode) -> Void

    func makeUIView(context: Context) -> TracklessSegmentedControl {
        let control = TracklessSegmentedControl()
        control.selectedSegmentTintColor = UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.14) : UIColor(white: 0, alpha: 0.07)
        }
        control.addTarget(context.coordinator, action: #selector(Coordinator.changed(_:)), for: .valueChanged)
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return control
    }

    func updateUIView(_ control: TracklessSegmentedControl, context: Context) {
        context.coordinator.parent = self
        let titles = modes.map(\.title)
        if (0..<control.numberOfSegments).map({ control.titleForSegment(at: $0) ?? "" }) != titles {
            control.removeAllSegments()
            for (index, title) in titles.enumerated() {
                control.insertSegment(withTitle: title, at: index, animated: false)
            }
        }
        // Also puts the control back after the model refuses a mode.
        let index = modes.firstIndex(of: selected) ?? UISegmentedControl.noSegment
        if control.selectedSegmentIndex != index { control.selectedSegmentIndex = index }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    @MainActor
    final class Coordinator: NSObject {
        var parent: ModeSegments

        init(parent: ModeSegments) { self.parent = parent }

        @objc func changed(_ control: UISegmentedControl) {
            guard parent.modes.indices.contains(control.selectedSegmentIndex) else { return }
            parent.select(parent.modes[control.selectedSegmentIndex])
        }
    }
}

/// UISegmentedControl without its grey track, so the glass behind it shows
/// through and matches the keys around it. The track is drawn by the
/// control's direct image-view children (one per segment); the selected
/// pill and the drag thumb live in other views and are left alone. If a
/// future iOS draws the track some other way, the grey simply comes back.
final class TracklessSegmentedControl: UISegmentedControl {
    override func layoutSubviews() {
        super.layoutSubviews()
        for view in subviews where view is UIImageView { view.isHidden = true }
    }
}

/// Opens Type4Me on its Settings tab. Carries the brand mark: the "4" in the
/// ink colour (black, or white on a dark keyboard) and the red dot.
struct OpenAppButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Image("MarkGlyph")
                    .resizable()
                    .renderingMode(.template)
                    .foregroundStyle(KB.ink)
                Image("MarkDot")
                    .resizable()
            }
            .frame(width: 26, height: 26)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
        }
        .buttonStyle(KeyPressStyle(feedback: .modifier))
        .glassEffect(.regular.tint(KB.functionTint).interactive(), in: Circle())
        .accessibilityLabel(L("打开 Type4Me 设置", "Open Type4Me Settings"))
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
    /// The orb leans a little after the finger, towards the target.
    @State private var drift: CGFloat = 0

    static let size: CGFloat = 84
    /// How far the finger slides sideways to reach cancel or lock.
    static let slideThreshold: CGFloat = 70

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
        .offset(x: isLocked ? 0 : drift)
        .animation(.interactiveSpring(response: 0.2, dampingFraction: 0.8), value: drift)
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
                        KeyFeedback.prepareCrossing()
                        model.micPressed()
                    }
                    guard isRecording, !isLocked else { return }
                    // Sideways only: both targets sit beside the thumb,
                    // where it can see them, instead of under it.
                    let dx = value.translation.width
                    let nowCancel = dx < -Self.slideThreshold
                    let nowLock = dx > Self.slideThreshold
                    if nowCancel != cancelZone || nowLock != lockZone {
                        KeyFeedback.playCrossing(entering: nowCancel || nowLock)
                    }
                    cancelZone = nowCancel
                    lockZone = nowLock
                    drift = max(-14, min(14, dx * 0.2))
                    model.holdZone = nowCancel ? .cancel : (nowLock ? .lock : .none)
                    let pull = (max(-1, min(1, dx / Self.slideThreshold)) * 10).rounded() / 10
                    if pull != model.holdPull { model.holdPull = pull }
                }
                .onEnded { _ in
                    let held = Date().timeIntervalSince(pressStarted ?? Date())
                    pressStarted = nil
                    pressed = false
                    // A quick tap locks recording on, like a toggle.
                    model.micReleased(cancelled: cancelZone, locked: lockZone || held < 0.3)
                    cancelZone = false
                    lockZone = false
                    drift = 0
                    model.holdZone = .none
                    model.holdPull = 0
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
        .buttonStyle(KeyPressStyle(feedback: .modifier))
        .glassEffect(.regular.tint(KB.functionTint).interactive(enabled), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .disabled(!enabled)
    }
}

/// A side key the held mic finger can slide to. It grows and takes its
/// colour as the finger comes closer, and is fully lit once letting go
/// would act. It can be tapped too.
struct SlideTargetKey: View {
    let systemImage: String
    let title: String
    /// 0 at rest, 1 when the finger reaches the threshold.
    let pull: CGFloat
    let armed: Bool
    let tint: Color
    let action: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16, style: .continuous) }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage).font(.system(size: 18, weight: armed ? .bold : .medium))
                Text(title).font(.system(size: 11, weight: armed ? .semibold : .regular))
            }
            .foregroundStyle(armed ? Color.white : KB.ink.opacity(0.55 + 0.45 * pull))
            .frame(width: 64, height: 56)
            .background(shape.fill(tint.opacity(armed ? 0.9 : 0.35 * pull)))
            .contentShape(shape)
        }
        .buttonStyle(KeyPressStyle(feedback: .modifier))
        .glassEffect(.regular.tint(KB.functionTint).interactive(), in: shape)
        .scaleEffect(1 + 0.08 * pull + (armed ? 0.06 : 0))
        .animation(.spring(response: 0.22, dampingFraction: 0.7), value: pull)
        .animation(.spring(response: 0.22, dampingFraction: 0.6), value: armed)
    }
}

/// Delete key that repeats while held, speeding up after a while.
struct RepeatingKey: View {
    let systemImage: String
    let title: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage).font(.system(size: 18, weight: .medium))
            Text(title).font(.system(size: 11))
        }
        .foregroundStyle(KB.ink)
        .frame(width: 64, height: 56)
        .glassEffect(.regular.tint(KB.functionTint).interactive(), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .contentShape(Rectangle())
        .modifier(KeyRepeat(feedback: .delete, accelerates: true, action: action))
        .accessibilityLabel(title)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

/// A key on the bottom row. Character keys can repeat while held; the rest
/// act once on release, like the system keyboard's return and globe keys.
struct KeyCap: View {
    var title: String? = nil
    var systemImage: String? = nil
    var function = false
    var width: CGFloat? = nil
    var repeats = false
    let action: () -> Void

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    var body: some View {
        if repeats {
            face
                .glassEffect(.regular.tint(function ? KB.functionTint : KB.keyTint).interactive(), in: shape)
                .modifier(KeyRepeat(feedback: function ? .modifier : .character, action: action))
                .accessibilityAddTraits(.isButton)
                .accessibilityAction { action() }
        } else {
            Button(action: action) { face }
                .buttonStyle(KeyPressStyle(feedback: function ? .modifier : .character))
                .glassEffect(.regular.tint(function ? KB.functionTint : KB.keyTint).interactive(), in: shape)
        }
    }

    private var face: some View {
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
        .contentShape(shape)
    }
}
