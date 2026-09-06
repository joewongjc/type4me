import AppKit
import SwiftUI

@MainActor
private final class CorrectionLearningPanelState: ObservableObject {
    enum Status {
        case candidate
        case learned
        case saveFailed
    }

    @Published var candidate: CorrectionCandidate?
    @Published var status: Status = .candidate
    @Published var remainingSeconds = 12
    @Published var isPresented = false
    var onLearn: (() -> Void)?
    var onIgnore: (() -> Void)?
}

private final class CorrectionLearningPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        ignoresMouseEvents = false
        animationBehavior = .utilityWindow
        updateAppearance()
    }

    // Mirrors FloatingBarPanel's lookup rather than sharing one, so this file
    // stays clear of the recording-theme refactor in flight on PR #288.
    func updateAppearance() {
        let themeRaw = UserDefaults.standard.string(forKey: RecordingTheme.storageKey)
            ?? RecordingTheme.defaultValue.rawValue
        let theme = RecordingTheme(rawValue: themeRaw) ?? .dark
        appearance = theme == .light ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func positionAboveFloatingBar() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        let y = visible.origin.y + TF.barBottomOffset + TF.barHeight + 18
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

@MainActor
final class CorrectionLearningPanelController {
    private let panel: CorrectionLearningPanel
    private let state = CorrectionLearningPanelState()
    private var lifecycleTask: Task<Void, Never>?
    private var generation = 0

    init() {
        let frame = NSRect(x: 0, y: 0, width: 500, height: 200)
        panel = CorrectionLearningPanel(contentRect: frame)
        let hosting = NSHostingView(rootView: CorrectionLearningCardView(state: state))
        hosting.frame = frame
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        panel.setFrame(frame, display: false)
    }

    func show(
        candidate: CorrectionCandidate,
        onLearn: @escaping () -> Void,
        onIgnore: @escaping () -> Void
    ) {
        generation &+= 1
        lifecycleTask?.cancel()
        state.candidate = candidate
        state.status = .candidate
        state.remainingSeconds = 12
        state.isPresented = true
        state.onLearn = onLearn
        state.onIgnore = onIgnore
        panel.updateAppearance()
        panel.positionAboveFloatingBar()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        scheduleAutoIgnore()
    }

    func showLearned() {
        state.status = .learned
        state.onLearn = nil
        state.onIgnore = nil
        lifecycleTask?.cancel()
        lifecycleTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.2))
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func showSaveFailure() {
        state.status = .saveFailed
        state.remainingSeconds = 12
        scheduleAutoIgnore()
    }

    func hide() {
        generation &+= 1
        lifecycleTask?.cancel()
        lifecycleTask = nil
        state.onLearn = nil
        state.onIgnore = nil
        state.isPresented = false
        guard panel.isVisible else { return }
        let expectedGeneration = generation
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == expectedGeneration else { return }
                self.panel.orderOut(nil)
            }
        })
    }

    private func scheduleAutoIgnore() {
        lifecycleTask?.cancel()
        let expectedGeneration = generation
        lifecycleTask = Task { [weak self] in
            for remaining in stride(from: 11, through: 0, by: -1) {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled,
                      let self,
                      self.generation == expectedGeneration
                else { return }
                self.state.remainingSeconds = remaining
            }
            guard let self, self.generation == expectedGeneration else { return }
            let ignore = self.state.onIgnore
            self.hide()
            ignore?()
        }
    }
}

private struct CorrectionLearningCardView: View {
    @ObservedObject var state: CorrectionLearningPanelState
    @AppStorage(RecordingTheme.storageKey) private var storedTheme = RecordingTheme.defaultValue

    private var theme: RecordingTheme { storedTheme }

    var body: some View {
        ZStack {
            if let candidate = state.candidate, state.status != .learned {
                HStack(spacing: 28) {
                    Text(candidate.wrongText)
                        .strikethrough()
                        .foregroundStyle(secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 165, alignment: .trailing)
                    Image(systemName: "arrow.right")
                        .font(.system(size: 24, weight: .semibold))
                        .foregroundStyle(primaryText)
                    Text(candidate.correctedText)
                        .foregroundStyle(primaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: 165, alignment: .leading)
                }
                .font(.system(size: 20, weight: .semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if state.status == .learned {
                Text(L("已加入个人词库", "Added to your vocabulary"))
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(primaryText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 8) {
                    animatedStatusIcon
                    Text(statusTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(primaryText)
                    Spacer()
                }

                Spacer()

                if state.status != .learned {
                    HStack(spacing: 10) {
                        Text(L("添加到热词和片段替换", "Add to hotwords and replacements"))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(secondaryText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)

                        Button(L("忽略 (\(state.remainingSeconds)s)", "Ignore (\(state.remainingSeconds)s)")) {
                            state.onIgnore?()
                        }
                        .buttonStyle(
                            CorrectionCardButtonStyle(isPrimary: false, theme: theme, fixedWidth: 96)
                        )

                        Button(state.status == .saveFailed ? L("重试", "Retry") : L("添加", "Add")) {
                            state.onLearn?()
                        }
                        .buttonStyle(CorrectionCardButtonStyle(isPrimary: true, theme: theme))
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(cardFill)
                .overlay {
                    // The dark card separates itself from any host window by
                    // luminance alone; the light one needs a rim or it dissolves
                    // into a white page underneath.
                    if theme == .light {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .strokeBorder(TF.floatingBorderLight, lineWidth: 0.5)
                    }
                }
        )
        .padding(6)
        .environment(\.colorScheme, theme == .light ? .light : .dark)
    }

    private var cardFill: Color {
        theme == .light
            ? TF.floatingBackgroundLight.opacity(0.98)
            : Color(red: 0.095, green: 0.095, blue: 0.095).opacity(0.98)
    }

    private var primaryText: Color {
        theme == .light ? TF.floatingTextLight : Color(red: 1, green: 1, blue: 1)
    }

    private var secondaryText: Color {
        theme == .light
            ? TF.floatingTextSecondaryLight
            : Color(red: 138 / 255, green: 138 / 255, blue: 138 / 255)
    }

    @ViewBuilder
    private var animatedStatusIcon: some View {
        if #available(macOS 15.0, *), state.status == .candidate {
            Image(systemName: "sparkles")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(primaryText)
                .symbolEffect(.breathe, options: .repeating, isActive: state.isPresented)
        } else {
            Image(systemName: state.status == .candidate ? "sparkles" : statusIcon)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(primaryText)
                .symbolEffect(
                    .pulse,
                    options: .repeating,
                    isActive: state.isPresented && state.status == .candidate
                )
        }
    }

    private var statusTitle: String {
        switch state.status {
        case .candidate: return L("Type4Me 发现了一次纠正", "Type4Me detected a correction")
        case .learned: return L("已学习", "Learned")
        case .saveFailed: return L("保存失败，请重试", "Couldn’t save. Try again")
        }
    }

    private var statusIcon: String {
        switch state.status {
        case .candidate: return "sparkles"
        case .learned: return "checkmark.circle.fill"
        case .saveFailed: return "exclamationmark.triangle.fill"
        }
    }

}

private struct CorrectionCardButtonStyle: ButtonStyle {
    let isPrimary: Bool
    var theme: RecordingTheme = .dark
    var fixedWidth: CGFloat? = nil

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(labelColor)
            .padding(.horizontal, fixedWidth == nil ? 14 : 0)
            .frame(width: fixedWidth, height: 34)
            .background(
                Capsule().fill(fillColor(isPressed: configuration.isPressed))
            )
    }

    /// The primary button is the card's one high-contrast element, so it stays
    /// inverted against the card fill in both themes.
    private var labelColor: Color {
        switch (theme, isPrimary) {
        case (.dark, true): Color.black
        case (.dark, false): Color.white
        case (.light, true): Color.white
        case (.light, false): TF.floatingTextLight
        }
    }

    private func fillColor(isPressed: Bool) -> Color {
        switch (theme, isPrimary) {
        case (.dark, true):
            TF.floatingControlLight.opacity(isPressed ? 0.78 : 1)
        case (.dark, false):
            TF.floatingControl.opacity(isPressed ? 0.76 : 1)
        case (.light, true):
            TF.floatingTextLight.opacity(isPressed ? 0.78 : 1)
        // The light secondary fill is a wash over the card rather than an opaque
        // capsule, so pressing has to deepen it instead of fading it out.
        case (.light, false):
            Color.black.opacity(isPressed ? 0.13 : 0.07)
        }
    }
}
