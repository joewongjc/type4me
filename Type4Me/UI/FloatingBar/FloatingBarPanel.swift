import AppKit
import SwiftUI

struct FloatingBarPanelLayout: Equatable {
    static let hidden = FloatingBarPanelLayout(contentSize: .zero)

    let contentSize: NSSize
    var horizontalOverflow: CGFloat = 0
    var capsuleSize: NSSize? = nil

    var hasVisibleContent: Bool {
        contentSize.width > 0 && contentSize.height > 0
    }

    var panelSize: NSSize {
        guard hasVisibleContent else { return NSSize(width: 1, height: 1) }
        return NSSize(
            width: ceil(contentSize.width + 2 * (horizontalOverflow + TF.floatingPanelShadowInset)),
            height: ceil(contentSize.height + 2 * TF.floatingPanelShadowInset)
        )
    }

    static func fallback(
        for style: RecordingIndicatorStyle,
        showsLiveTranscript: Bool = LiveTranscriptDisplayPreference.isEnabled()
    ) -> FloatingBarPanelLayout {
        let height: CGFloat
        if style == .compact {
            height = showsLiveTranscript
                ? TF.compactTranscriptExpandedHeight
                : TF.compactIndicatorHeight
        } else {
            height = TF.barHeight
        }
        let size = NSSize(
            width: TF.barWidthCompact,
            height: height
        )
        return FloatingBarPanelLayout(contentSize: size, capsuleSize: size)
    }
}

// MARK: - NSPanel Subclass

/// Non-activating floating panel that never steals focus from the target app.
/// Forces dark appearance for the sci-fi themed floating bar.
final class FloatingBarPanel: NSPanel {

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
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        ignoresMouseEvents = true
        acceptsMouseMovedEvents = true
        animationBehavior = .utilityWindow
        updateAppearance()
    }

    func updateAppearance() {
        let themeRaw = UserDefaults.standard.string(forKey: RecordingTheme.storageKey) ?? RecordingTheme.defaultValue.rawValue
        let theme = RecordingTheme(rawValue: themeRaw) ?? .dark
        appearance = theme == .light ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    static func screenUnderMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?
            .uint32Value
    }

    static func bottomCenteredFrame(size: NSSize, visibleFrame: NSRect) -> NSRect {
        NSRect(
            x: visibleFrame.midX - size.width / 2,
            y: visibleFrame.minY + TF.barBottomOffset - TF.floatingPanelShadowInset,
            width: size.width,
            height: size.height
        )
    }
}

// MARK: - Controller

/// Manages the floating bar panel lifecycle and keeps its mouse hit area at the
/// smallest single rectangle containing the currently visible bar and overlay.
@MainActor
final class FloatingBarController {

    private static let capsuleShrinkDelay: Duration = .seconds(TF.recordingCapsuleSpringResponse)

    let panel: FloatingBarPanel
    private let state: AppState
    private var currentLayout = FloatingBarPanelLayout.hidden
    private var anchorDisplayID: CGDirectDisplayID?
    private var panelGeneration = 0
    private var panelShrinkTask: Task<Void, Never>?

    init(state: AppState) {
        self.state = state

        let initialLayout = FloatingBarPanelLayout.fallback(for: RecordingIndicatorStyle.current())
        let frame = NSRect(origin: .zero, size: initialLayout.panelSize)
        panel = FloatingBarPanel(contentRect: frame)

        let barView = FloatingBarView<AppState>(
            state: state,
            onPanelLayoutChange: { [weak self] layout in
                self?.updatePanelLayout(layout)
            }
        )
        let hosting = NSHostingView(rootView: barView)
        hosting.sizingOptions = []
        hosting.layer?.backgroundColor = .clear
        hosting.frame = frame
        hosting.autoresizingMask = [.width, .height]

        panel.contentView = hosting
        panel.setFrame(frame, display: false)

        state.onShowPanel = { [weak self] in self?.show() }
        state.onHidePanel = { [weak self] in self?.hide() }
    }

    func updatePanelLayout(_ layout: FloatingBarPanelLayout) {
        let previousLayout = currentLayout
        currentLayout = layout

        panel.ignoresMouseEvents = !layout.hasVisibleContent || state.barPhase == .hidden

        // Let the existing fade-out finish at its current size. Mouse events are
        // already disabled above, so the disappearing panel cannot block clicks.
        guard state.barPhase != .hidden || !panel.isVisible else {
            cancelPendingPanelShrink()
            return
        }

        let shouldShow = layout.hasVisibleContent
            && state.barPhase != .hidden
            && !panel.isVisible
            && panelGeneration > 0
        resizePanel(from: previousLayout, to: layout, display: panel.isVisible)

        if shouldShow {
            show()
        }
    }

    func show() {
        panelGeneration &+= 1
        panel.updateAppearance()

        if anchorDisplayID == nil || state.barPhase == .preparing {
            anchorDisplayID = FloatingBarPanel.screenUnderMouse()
                .flatMap(FloatingBarPanel.displayID)
        }

        let layout = layoutForShow()
        guard layout.hasVisibleContent else {
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
            return
        }

        resizePanel(from: currentLayout, to: layout, display: panel.isVisible)
        panel.ignoresMouseEvents = false

        panel.contentView?.layer?.removeAllAnimations()
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        cancelPendingPanelShrink()
        panel.ignoresMouseEvents = true

        let expectedGeneration = panelGeneration
        let panelRef = panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panelRef.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panelGeneration == expectedGeneration else { return }
                panelRef.orderOut(nil)
                self.anchorDisplayID = nil
            }
        })
    }

    private func layoutForShow() -> FloatingBarPanelLayout {
        if currentLayout.hasVisibleContent {
            return currentLayout
        }

        return .fallback(for: RecordingIndicatorStyle.current())
    }

    private func resizePanel(
        from previousLayout: FloatingBarPanelLayout,
        to layout: FloatingBarPanelLayout,
        display: Bool
    ) {
        cancelPendingPanelShrink()

        let targetSize = layout.panelSize
        let currentSize = panel.frame.size
        guard !approximatelyEqual(currentSize, targetSize) else { return }

        let capsuleWidthShrinks = previousLayout.capsuleSize.map { previous in
            layout.capsuleSize.map { $0.width < previous.width - 0.5 } ?? false
        } ?? false
        let capsuleHeightShrinks = previousLayout.capsuleSize.map { previous in
            layout.capsuleSize.map { $0.height < previous.height - 0.5 } ?? false
        } ?? false
        let delaysWidth = display
            && targetSize.width < currentSize.width - 0.5
            && capsuleWidthShrinks
        let delaysHeight = display
            && targetSize.height < currentSize.height - 0.5
            && capsuleHeightShrinks

        // Overlay-only axes resize immediately. Only axes whose visible capsule
        // is still springing retain their old bounds until that spring ends.
        let transitionSize = NSSize(
            width: delaysWidth ? max(currentSize.width, targetSize.width) : targetSize.width,
            height: delaysHeight ? max(currentSize.height, targetSize.height) : targetSize.height
        )
        if !approximatelyEqual(currentSize, transitionSize) {
            applyPanelSize(transitionSize, display: display)
        }

        guard delaysWidth || delaysHeight else { return }

        panelShrinkTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.capsuleShrinkDelay)
            guard !Task.isCancelled, let self else { return }
            guard self.state.barPhase != .hidden,
                  self.approximatelyEqual(self.currentLayout.panelSize, targetSize)
            else { return }

            self.applyPanelSize(targetSize, display: self.panel.isVisible)
            self.panelShrinkTask = nil
        }
    }

    private func cancelPendingPanelShrink() {
        panelShrinkTask?.cancel()
        panelShrinkTask = nil
    }

    private func applyPanelSize(_ size: NSSize, display: Bool) {
        guard let screen = resolvedAnchorScreen() else { return }
        let frame = FloatingBarPanel.bottomCenteredFrame(
            size: size,
            visibleFrame: screen.visibleFrame
        )
        panel.setFrame(frame, display: display)
    }

    private func resolvedAnchorScreen() -> NSScreen? {
        if let anchorDisplayID,
           let screen = NSScreen.screens.first(where: {
               FloatingBarPanel.displayID(for: $0) == anchorDisplayID
           }) {
            return screen
        }
        let replacement = FloatingBarPanel.screenUnderMouse()
        anchorDisplayID = replacement.flatMap(FloatingBarPanel.displayID)
        return replacement
    }

    private func approximatelyEqual(_ lhs: NSSize, _ rhs: NSSize) -> Bool {
        abs(lhs.width - rhs.width) < 0.5 && abs(lhs.height - rhs.height) < 0.5
    }
}
