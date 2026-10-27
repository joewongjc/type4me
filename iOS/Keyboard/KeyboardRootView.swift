import SwiftUI
import UIKit

struct KeyboardRootView: View {
    @ObservedObject var model: KeyboardModel
    /// The mode bar opened into a row of every mode.
    @State private var modeBarOpen = false

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
            // Recording and processing leave only the orb and the two
            // targets beside it; the row keeps its room so nothing shifts.
            // Edges line up with the hide and "4" buttons above (8 + 4).
            keyRow
                .padding(.horizontal, 12)
                .padding(.bottom, 4)
                .opacity(model.phase == .idle ? 1 : 0)
                .allowsHitTesting(model.phase == .idle)
                .animation(.easeInOut(duration: 0.2), value: model.phase == .idle)
        }
        .frame(height: KeyboardMetrics.height)
        // Recording or any notice replaces the bar; it comes back folded.
        .onChange(of: model.phase) { _, _ in modeBarOpen = false }
        // A notice takes the bar's place too, and the dial's own fold task
        // ends with it, so the fold has to happen here.
        .onChange(of: model.notice) { _, notice in
            if notice != nil { modeBarOpen = false }
        }
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
            // The dial spans the row; at rest it shows only its middle, and
            // while it turns it widens over the buttons either side, which
            // keep their places.
            ZStack {
                if model.correction == .none {
                    ModePicker(model: model, expanded: $modeBarOpen)
                } else {
                    CorrectionChip(model: model)
                        .padding(.horizontal, 52)
                        .transition(.opacity)
                }
                HStack {
                    // Face ID iPhones give third-party keyboards no way to
                    // close, so the keyboard carries its own.
                    HideKeyboardButton { model.dismissKeyboard() }
                    Spacer()
                    OpenAppButton { model.openSettings() }
                }
                .opacity(modeBarOpen ? 0 : 1)
                .scaleEffect(modeBarOpen ? 0.8 : 1)
                .allowsHitTesting(!modeBarOpen)
            }
            .animation(ModePicker.widen, value: modeBarOpen)
            .animation(.easeInOut(duration: 0.2), value: model.correction == .none)
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
            return .processing(text: model.liveText, label: model.processingLabel)
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
            case .none:
                return model.isCorrecting
                    ? L("← 取消 · 松手纠正 · 锁定 →", "← Cancel · Release to correct · Lock →")
                    : L("← 取消 · 松手出字 · 锁定 →", "← Cancel · Release · Lock →")
            }
        // With no transcript the caption itself names the step; otherwise
        // it keeps the words on screen and the step is named here.
        case .processing: return model.liveText.isEmpty ? " " : model.processingLabel
        case .idle:
            switch model.liveness {
            case .ready:
                switch model.correction {
                case .armed: return L("按住说出正确内容", "Hold and say what it should be")
                case .corrected: return L("还不对？按住再说一次", "Still wrong? Hold and say it again")
                case .none: return L("按住说话 · 轻点锁定", "Hold to talk · Tap to lock")
                }
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
            PunctuationKey(model: model)
            SpaceKey(model: model)
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
    /// The mode dial at rest: barely set off from the keyboard behind it.
    static let dialBase = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.06) : UIColor(white: 1, alpha: 0.4) })
    /// A quiet button inside a glass chip: an ink wash, white on a dark keyboard.
    static let chipButton = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.16) : UIColor(white: 0.075, alpha: 0.08) })
    static let halo = Color(UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.07) })
}

/// The modes on a dial, like the Camera app's. At rest it is a faint
/// capsule with the mode in use in the middle, sitting on a small clear
/// droplet, and half of each neighbour showing. Touch it and the capsule
/// melts into the keyboard, the droplet swells under the middle name and
/// the row widens over the "4"; the names scroll beneath with a tick as
/// each reaches the middle. It is a system scroll view, so the fling, the
/// deceleration and the give at either end are the system's own. Once it
/// settles it narrows again. Tapping a visible name rolls it to the middle.
struct ModePicker: View {
    @ObservedObject var model: KeyboardModel
    /// The dial is turning or has just turned, and covers the whole row.
    @Binding var expanded: Bool

    /// The mode in the middle, which leads `model.mode` while the dial turns.
    @State private var centred: DictationMode?
    @State private var narrowing: Task<Void, Never>?
    /// Moved to exact offsets: the id-and-anchor form of scroll position
    /// left the name a few points off the middle.
    @State private var position = ScrollPosition()
    @State private var width: CGFloat = 0
    @State private var offset = DialOffset()

    static let widen = Animation.spring(response: 0.28, dampingFraction: 0.86)
    private static let roll = Animation.spring(response: 0.3, dampingFraction: 0.88)
    /// Each name gets its own width plus the same room either side, like
    /// the Camera app's modes.
    private static let gap: CGFloat = 14
    private static let longestName: CGFloat = 150
    private static let nameFont = UIFont.systemFont(ofSize: 15, weight: .semibold)
    private static let restWidth: CGFloat = 200
    /// The droplet spans the middle name and its room, so its bending
    /// edges fall on the gaps between names.
    private static let dropletHeight: CGFloat = 42
    private static let narrowestDroplet: CGFloat = 64
    /// How long the dial stays wide after it settles.
    private static let foldDelay = Duration.milliseconds(250)

    /// Measured at the middle name's weight, so a name doesn't grow when it
    /// reaches the middle.
    static func slotWidth(_ mode: DictationMode) -> CGFloat {
        let text = (mode.title as NSString).size(withAttributes: [.font: nameFont]).width
        return min(ceil(text), longestName) + gap * 2
    }

    var body: some View {
        let modes = DictationMode.keyboardOrder
        GeometryReader { geometry in
            let full = geometry.size.width
            let canvas = expanded ? full : min(full, Self.restWidth)
            ZStack {
                Capsule()
                    .fill(KB.dialBase)
                    .frame(width: canvas, height: 44)
                    .opacity(expanded ? 0 : 1)
                // Under the names, never over them: glass on top of text
                // blurs it.
                Color.clear
                    .frame(width: dropletWidth, height: Self.dropletHeight)
                    .glassEffect(.clear, in: Capsule())
                    .scaleEffect(expanded ? 1 : 0.86)
                    .opacity(expanded ? 1 : 0.5)
                    .animation(Self.roll, value: centred)
                let layout = Self.layout(of: modes, in: full)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        // Room so the first and last names can still reach
                        // the middle. Inside the content rather than as
                        // margins, so every name's centre is known exactly.
                        Color.clear.frame(width: layout.lead, height: 44)
                        HStack(spacing: 0) {
                            ForEach(Array(modes.enumerated()), id: \.element) { index, mode in
                                name(mode)
                                    .frame(width: Self.slotWidth(mode), height: 44)
                                    .contentShape(Rectangle())
                                    .onTapGesture { tap(mode, index: index, in: modes) }
                                    .id(mode)
                            }
                        }
                        .scrollTargetLayout()
                        Color.clear.frame(width: layout.trail, height: 44)
                    }
                }
                .scrollTargetBehavior(CentredSnap(centres: layout.centres, offset: offset))
                .scrollPosition($position)
                // The dial sits on the keyboard's top edge, where the
                // default edge effect blurs the whole row.
                .scrollEdgeEffectHidden(true, for: .all)
                // The name nearest the middle is the one in the middle.
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x + $0.containerSize.width / 2 } action: { _, middle in
                    offset.x = middle - full / 2
                    let nearest = layout.centres.indices.min { abs(layout.centres[$0] - middle) < abs(layout.centres[$1] - middle) }
                    if let nearest, centred != modes[nearest] { centred = modes[nearest] }
                }
                .onChange(of: full, initial: true) { _, full in
                    width = full
                    roll(to: model.mode, in: modes, animated: false)
                }
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting { offset.rolling = false }
                    if phase == .idle {
                        offset.rolling = false
                        commit(in: modes)
                    } else {
                        narrowing?.cancel()
                        expanded = true
                    }
                }
                .mask {
                    // Names fade out at the canvas edges.
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: .black, location: 0.16),
                            .init(color: .black, location: 0.84),
                            .init(color: .clear, location: 1),
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .frame(width: canvas)
                }
            }
            .frame(width: full, height: geometry.size.height)
        }
        .frame(height: 44)
        .animation(Self.widen, value: expanded)
        .sensoryFeedback(.selection, trigger: centred) { old, new in old != nil && new != nil }
        .onChange(of: model.mode) { _, mode in
            if centred != mode { roll(to: mode, in: modes, animated: false) }
        }
        .onDisappear { narrowing?.cancel() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(L("模式：\(model.mode.title)", "Mode: \(model.mode.title)"))
        .accessibilityHint(L("上下轻扫切换模式", "Swipe up or down to switch modes"))
        .accessibilityAdjustableAction { direction in
            guard let index = modes.firstIndex(of: model.mode) else { return }
            let step = direction == .increment ? 1 : -1
            let ahead = stride(from: index + step, to: step > 0 ? modes.count : -1, by: step)
            guard let next = ahead.first(where: { model.isAvailable(modes[$0]) }) else { return }
            roll(to: modes[next], in: modes, animated: false)
            commit(in: modes)
        }
    }

    /// Room before the first name and after the last, so both can reach
    /// the middle, and where each name's centre sits in the content.
    private static func layout(of modes: [DictationMode], in full: CGFloat) -> (lead: CGFloat, trail: CGFloat, centres: [CGFloat]) {
        let lead = max(0, (full - (modes.first.map(slotWidth) ?? 0)) / 2)
        let trail = max(0, (full - (modes.last.map(slotWidth) ?? 0)) / 2)
        var x = lead
        let centres = modes.map { mode in
            let width = slotWidth(mode)
            defer { x += width }
            return x + width / 2
        }
        return (lead, trail, centres)
    }

    /// Puts `mode` exactly on the middle.
    private func roll(to mode: DictationMode, in modes: [DictationMode], animated: Bool = true) {
        centred = mode
        guard width > 0, let index = modes.firstIndex(of: mode) else { return }
        let x = Self.layout(of: modes, in: width).centres[index] - width / 2
        offset.rolling = true
        if animated {
            withAnimation(Self.roll) { position.scrollTo(x: x) }
        } else {
            position.scrollTo(x: x)
        }
    }

    private var dropletWidth: CGFloat {
        max(Self.narrowestDroplet, centred.map(Self.slotWidth) ?? Self.narrowestDroplet)
    }

    private func name(_ mode: DictationMode) -> some View {
        let inMiddle = mode == centred
        let available = model.isAvailable(mode)
        return Text(mode.title)
            .font(.system(size: 15, weight: inMiddle && available ? .semibold : .regular))
            .foregroundStyle(available ? (inMiddle ? KB.ink : KB.secondary) : KB.secondary.opacity(0.4))
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: Self.longestName)
    }

    /// Only names that can be seen take a tap: at rest that is the middle
    /// one and its two neighbours. A greyed-out mode says why instead.
    private func tap(_ mode: DictationMode, index: Int, in modes: [DictationMode]) {
        guard let current = centred, let at = modes.firstIndex(of: current) else { return }
        guard mode != current else { return }
        guard expanded || abs(index - at) <= 1 else { return }
        guard model.isAvailable(mode) else {
            model.select(mode)
            return
        }
        narrowing?.cancel()
        expanded = true
        roll(to: mode, in: modes)
        commit(in: modes)
    }

    /// The dial has settled: the mode in the middle becomes the mode in
    /// use. A greyed-out one isn't a place to stop, so the dial rolls on to
    /// the nearest usable mode, onward first. Then the dial narrows.
    private func commit(in modes: [DictationMode]) {
        if let mode = centred, mode != model.mode {
            if model.isAvailable(mode) {
                model.select(mode, haptic: false)
            } else if let next = nearestAvailable(to: mode, in: modes) {
                roll(to: next, in: modes)
                if next != model.mode { model.select(next, haptic: false) }
            } else {
                // Nothing usable either side: the model says why.
                model.select(mode, haptic: false)
            }
            if centred != model.mode { roll(to: model.mode, in: modes) }
        }
        narrowing?.cancel()
        narrowing = Task { @MainActor in
            try? await Task.sleep(for: Self.foldDelay)
            guard !Task.isCancelled else { return }
            expanded = false
        }
    }

    private func nearestAvailable(to mode: DictationMode, in modes: [DictationMode]) -> DictationMode? {
        guard let at = modes.firstIndex(of: mode) else { return nil }
        let from = modes.firstIndex(of: model.mode) ?? at
        let onward = at >= from ? 1 : -1
        for step in [onward, -onward] {
            var index = at + step
            while modes.indices.contains(index) {
                if model.isAvailable(modes[index]) { return modes[index] }
                index += step
            }
        }
        return nil
    }
}

/// Where the dial is right now, for the snap to measure a flick from. A
/// reference, so the snap reads it live rather than as it was when the
/// view last drew.
private final class DialOffset {
    var x: CGFloat = 0
    /// The dial is rolling to a name on its own, not coasting from a flick.
    var rolling = false
}

/// Names are different widths, so the system's view alignment, which lines
/// up leading edges, would stop them off centre. This settles a flick with
/// the nearest name's centre on the dial's middle. The system projects a
/// flick as far as a page scrolls; the dial carries a fifth of that, about
/// what UIKit's fast deceleration rate gives, so it stops promptly.
private struct CentredSnap: ScrollTargetBehavior {
    let centres: [CGFloat]
    let offset: DialOffset
    private static let carry: CGFloat = 0.2

    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let half = context.containerSize.width / 2
        let start = offset.x
        // A roll to a tapped name already ends on it.
        let carry = offset.rolling ? 1 : Self.carry
        let landing = start + (target.rect.minX - start) * carry + half
        guard let nearest = centres.min(by: { abs($0 - landing) < abs($1 - landing) }) else { return }
        target.rect.origin.x = nearest - half
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

/// Takes the dial's place while holding the mic corrects a selection: what
/// will be corrected, then what it became.
struct CorrectionChip: View {
    @ObservedObject var model: KeyboardModel

    var body: some View {
        // The message stays centred; "Remember" and the close button sit at
        // opposite ends so one can't be hit for the other.
        ZStack {
            Text(message)
                .lineLimit(1)
                .padding(.horizontal, sideRoom)
            HStack(spacing: 0) {
                if case .corrected(let done) = model.correction, done.canRemember {
                    rememberButton(done)
                }
                Spacer(minLength: 0)
                Button { model.exitCorrection() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(KB.secondary)
                        .frame(width: 30, height: 30)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.correction == .none ? "" : L("退出纠正", "Stop correcting"))
            }
        }
        .font(.system(size: 14, weight: .medium))
        .foregroundStyle(KB.ink)
        .padding(.horizontal, 5)
        .frame(maxWidth: .infinity)
        .frame(height: 36)
        .glassEffect(.regular.tint(KB.keyTint), in: Capsule())
    }

    private var message: String {
        switch model.correction {
        case .armed(let request):
            return L("纠正「\(Self.short(request.selected))」", "Correct “\(Self.short(request.selected))”")
        case .corrected(let done):
            let word = Self.short(done.replacement)
            return done.count > 1
                ? L("已改为「\(word)」· 共 \(done.count) 处", "Changed to “\(word)” · \(done.count)")
                : L("已改为「\(word)」", "Changed to “\(word)”")
        case .none:
            return ""
        }
    }

    /// Keeps the centred message clear of whatever sits at either end.
    private var sideRoom: CGFloat {
        if case .corrected(let done) = model.correction, done.canRemember { return 84 }
        return 34
    }

    private func rememberButton(_ done: KeyboardModel.Corrected) -> some View {
        Button { model.rememberCorrection() } label: {
            HStack(spacing: 3) {
                Image(systemName: done.remembered ? "checkmark" : "plus")
                    .font(.system(size: 11, weight: .bold))
                Text(done.remembered ? L("已记住", "Saved") : L("记住", "Remember"))
                    .font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(KB.ink)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(KB.chipButton, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(done.remembered)
        .accessibilityLabel(done.remembered
            ? L("已记住「\(done.replacement)」", "Remembered “\(done.replacement)”")
            : L("记住「\(done.replacement)」", "Remember “\(done.replacement)”"))
    }

    static func short(_ text: String) -> String {
        text.count > 8 ? String(text.prefix(8)) + "…" : text
    }
}

struct HideKeyboardButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "keyboard.chevron.compact.down")
                .font(.system(size: 17))
                .foregroundStyle(KB.ink)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(KeyPressStyle(feedback: .modifier))
        .glassEffect(.regular.tint(KB.functionTint).interactive(), in: Circle())
        .accessibilityLabel(L("收起键盘", "Hide keyboard"))
        .accessibilityIdentifier("keyboard.hide")
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
        .accessibilityLabel(isRecording
            ? L("结束说话", "Finish talking")
            : (model.correction == .none ? L("按住说话", "Hold to talk") : L("按住说出正确内容", "Hold and say what it should be")))
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
            Image(systemName: model.liveness == .needsApp ? "mic" : (model.correction == .none ? "mic.fill" : "pencil"))
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
