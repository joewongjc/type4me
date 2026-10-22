import AppKit
import SwiftUI

struct FloatingBarPanelLayout: Equatable {
    static let hidden = FloatingBarPanelLayout(contentSize: .zero)

    let contentSize: NSSize
    var horizontalOverflow: CGFloat = 0
    var capsuleSize: NSSize? = nil
    var anchorSideReserve: CGFloat = 0

    var hasVisibleContent: Bool {
        contentSize.width > 0 && contentSize.height > 0
    }

    var panelSize: NSSize {
        guard hasVisibleContent else { return NSSize(width: 1, height: 1) }
        // The width is rounded up to an even number of points so that
        // `midX - width / 2` always lands on the same pixel phase. AppKit rounds
        // the window origin, so an odd width would round the other way and shift
        // the (centered) capsule by half a point whenever an overlay appears.
        return NSSize(
            width: Self.evenCeil(contentSize.width + 2 * (horizontalOverflow + TF.floatingPanelShadowInset)),
            height: ceil(contentSize.height + 2 * TF.floatingPanelShadowInset)
        )
    }

    private static func evenCeil(_ value: CGFloat) -> CGFloat {
        let rounded = ceil(value)
        return rounded.truncatingRemainder(dividingBy: 2) == 0 ? rounded : rounded + 1
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

    func updateAppearance(theme: RecordingTheme? = nil) {
        let resolved: RecordingTheme
        if let theme {
            resolved = theme
        } else {
            let themeRaw = UserDefaults.standard.string(forKey: RecordingTheme.storageKey)
                ?? RecordingTheme.defaultValue.rawValue
            resolved = RecordingTheme(rawValue: themeRaw) ?? .dark
        }
        appearance = resolved == .light ? NSAppearance(named: .aqua) : NSAppearance(named: .darkAqua)
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
        // Pixel-aligned so the capsule cannot drift sideways when the panel is
        // resized for an overlay; AppKit would otherwise round the origin itself.
        NSRect(
            x: (visibleFrame.midX - size.width / 2).rounded(),
            y: (visibleFrame.minY + TF.barBottomOffset - TF.floatingPanelShadowInset).rounded(),
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
    private var isSuppressedForManualInput = false

    let chrome = FloatingBarChromeModel()
    private var placement = FloatingBarPlacementStore.load()
    private var drag: DragSession?
    private var dragLifecycle = FloatingBarDragLifecycle()
    private var isSelfOriginatedPlacementChange = false
    private var guideWindow: FloatingBarPlacementGuideWindow?

    private struct DragSession {
        var grabOffset: CGVector
        var anchor: FloatingBarVerticalAnchor
        var snapper: FloatingBarSnapper
        var center: CGPoint
        var displayID: CGDirectDisplayID?
    }

    func setManualInputEditing(_ editing: Bool) {
        if drag != nil {
            commitCurrentDrag()
        }
        _ = dragLifecycle.manualInputStarted()
        chrome.isRetainedForDrag = dragLifecycle.isRetainedForDrag
        isSuppressedForManualInput = editing
        if editing {
            panelGeneration &+= 1
            cancelPendingPanelShrink()
            panel.ignoresMouseEvents = true
            panel.orderOut(nil)
            anchorDisplayID = nil
        }
    }

    init(state: AppState) {
        self.state = state

        let initialLayout = FloatingBarPanelLayout.fallback(for: RecordingIndicatorStyle.current())
        let frame = NSRect(origin: .zero, size: initialLayout.panelSize)
        panel = FloatingBarPanel(contentRect: frame)

        let barView = FloatingBarView<AppState>(
            state: state,
            chrome: chrome,
            onDragBegan: { [weak self] p in self?.handleDragBegan(at: p) },
            onDragMoved: { [weak self] p in self?.handleDragMoved(to: p) },
            onDragEnded: { [weak self] p in self?.handleDragEnded(at: p) },
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

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handlePlacementDidChange(_:)),
            name: .floatingBarPlacementDidChange,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleScreenParametersDidChange(_:)),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    func updatePanelLayout(_ layout: FloatingBarPanelLayout) {
        let previousLayout = currentLayout
        currentLayout = layout
        guard !isSuppressedForManualInput else { return }

        if drag == nil {
            panel.ignoresMouseEvents = !layout.hasVisibleContent || (state.barPhase == .hidden && !chrome.isRetainedForDrag)
        }

        // Let the existing fade-out finish at its current size. Mouse events are
        // already disabled above, so the disappearing panel cannot block clicks.
        guard drag != nil || state.barPhase != .hidden || !panel.isVisible else {
            cancelPendingPanelShrink()
            return
        }

        let shouldShow = layout.hasVisibleContent
            && (state.barPhase != .hidden || chrome.isRetainedForDrag)
            && !panel.isVisible
            && panelGeneration > 0
        resizePanel(from: previousLayout, to: layout, display: panel.isVisible)

        if shouldShow {
            show()
        }
    }

    func show() {
        guard !isSuppressedForManualInput else { return }
        _ = dragLifecycle.showRequested()
        chrome.isRetainedForDrag = dragLifecycle.isRetainedForDrag
        chrome.resetHover()
        panelGeneration &+= 1
        panel.updateAppearance(theme: currentDisplayOverride()?.theme)

        if drag == nil && (anchorDisplayID == nil || state.barPhase == .preparing) {
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
        let action = dragLifecycle.hideRequested()
        chrome.isRetainedForDrag = dragLifecycle.isRetainedForDrag
        if action == .retainForDrag {
            return
        }
        chrome.resetHover()
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

        let profile = currentDisplayOverride()
        return .fallback(
            for: profile?.indicatorStyle ?? RecordingIndicatorStyle.current(),
            showsLiveTranscript: profile?.showsLiveTranscript ?? LiveTranscriptDisplayPreference.isEnabled()
        )
    }

    /// The current mode's whole-block override, when it has one.
    private func currentDisplayOverride() -> FloatingBarPresentation? {
        state.recordingDisplayOverride(for: state.currentMode.id)
    }

    private func resizePanel(
        from previousLayout: FloatingBarPanelLayout,
        to layout: FloatingBarPanelLayout,
        display: Bool
    ) {
        cancelPendingPanelShrink()
        if drag != nil {
            applyPanelFrame(layout: layout, display: display)
            return
        }


        let targetSize = layout.panelSize
        let currentSize = panel.frame.size

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

        var transitionLayout = layout
        if delaysWidth || delaysHeight {
            let transitionContentSize = NSSize(
                width: delaysWidth ? max(previousLayout.contentSize.width, layout.contentSize.width) : layout.contentSize.width,
                height: delaysHeight ? max(previousLayout.contentSize.height, layout.contentSize.height) : layout.contentSize.height
            )
            transitionLayout = FloatingBarPanelLayout(
                contentSize: transitionContentSize,
                horizontalOverflow: layout.horizontalOverflow,
                capsuleSize: layout.capsuleSize,
                anchorSideReserve: layout.anchorSideReserve
            )
        }
        applyPanelFrame(layout: transitionLayout, display: display)

        guard delaysWidth || delaysHeight else { return }

        panelShrinkTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.capsuleShrinkDelay)
            guard !Task.isCancelled, let self else { return }
            guard (self.state.barPhase != .hidden || self.chrome.isRetainedForDrag),
                  self.approximatelyEqual(self.currentLayout.panelSize, targetSize)
            else { return }

            self.applyPanelFrame(layout: layout, display: self.panel.isVisible)
            self.panelShrinkTask = nil
        }
    }

    private func cancelPendingPanelShrink() {
        panelShrinkTask?.cancel()
        panelShrinkTask = nil
    }

    private func applyPanelFrame(layout: FloatingBarPanelLayout, display: Bool) {
        guard let screen = currentPlacementScreen() else { return }
        let visibleFrame = screen.visibleFrame
        let style = RecordingIndicatorStyle.current()
        let base = FloatingBarPlacementGeometry.baseCapsuleHeight(for: style)
        let actualCapsuleHeight = layout.capsuleSize?.height ?? base
        let targetCenter: CGPoint
        let anchor: FloatingBarVerticalAnchor
        if var session = drag {
            let adjusted = FloatingBarPlacementGeometry.adjustDragSessionOnLayoutChange(
                center: session.center,
                grabOffset: session.grabOffset,
                layout: layout,
                baseHeight: base,
                anchor: session.anchor,
                style: style,
                visibleFrame: visibleFrame
            )
            session.center = adjusted.center
            session.grabOffset = adjusted.grabOffset
            self.drag = session

            anchor = session.anchor
            targetCenter = session.center
        } else {
            let resolved = FloatingBarPlacementGeometry.resolveCenter(placement, visibleFrame: visibleFrame, baseHeight: base)
            anchor = FloatingBarPlacementGeometry.verticalAnchor(center: resolved, visibleFrame: visibleFrame)
            targetCenter = resolved
        }

        let minCapsuleWidth = style == .compact ? TF.compactIndicatorWidth : TF.barWidthCompact

        let clampedCenter = FloatingBarPlacementGeometry.clampCenter(
            targetCenter,
            baseHeight: base,
            actualCapsuleHeight: actualCapsuleHeight,
            anchor: anchor,
            handleReserve: layout.anchorSideReserve,
            minCapsuleWidth: minCapsuleWidth,
            visibleFrame: visibleFrame
        )

        chrome.verticalAnchor = anchor
        let frame = FloatingBarPlacementGeometry.panelFrame(
            layout: layout,
            center: clampedCenter,
            baseHeight: base,
            anchor: anchor,
            visibleFrame: visibleFrame
        )

        if !approximatelyEqual(panel.frame, frame) {
            panel.setFrame(frame, display: display)
        }
    }

    private func currentClampedCenter(for layout: FloatingBarPanelLayout) -> CGPoint {
        if let drag { return drag.center }
        guard let screen = currentPlacementScreen() else { return .zero }
        let visibleFrame = screen.visibleFrame
        let style = RecordingIndicatorStyle.current()
        let base = FloatingBarPlacementGeometry.baseCapsuleHeight(for: style)
        let actualCapsuleHeight = layout.capsuleSize?.height ?? base
        let minCapsuleWidth = style == .compact ? TF.compactIndicatorWidth : TF.barWidthCompact
        let resolved = FloatingBarPlacementGeometry.resolveCenter(placement, visibleFrame: visibleFrame, baseHeight: base)
        let anchor = FloatingBarPlacementGeometry.verticalAnchor(center: resolved, visibleFrame: visibleFrame)
        return FloatingBarPlacementGeometry.clampCenter(
            resolved,
            baseHeight: base,
            actualCapsuleHeight: actualCapsuleHeight,
            anchor: anchor,
            handleReserve: layout.anchorSideReserve,
            minCapsuleWidth: minCapsuleWidth,
            visibleFrame: visibleFrame
        )
    }

    private func currentPlacementScreen() -> NSScreen? {
        if let drag, let displayID = drag.displayID,
           let screen = NSScreen.screens.first(where: { FloatingBarPanel.displayID(for: $0) == displayID }) {
            return screen
        }
        return resolvedAnchorScreen()
    }

    private func handleDragBegan(at screenPoint: CGPoint) {
        cancelPendingPanelShrink()
        applyPanelFrame(layout: currentLayout, display: false)

        guard let screen = currentPlacementScreen() else { return }
        let currentCenter = currentClampedCenter(for: currentLayout)
        let horizontalShift = FloatingBarPlacementGeometry.horizontalShiftKeepingContentVisible(
            centerX: currentCenter.x,
            layout: currentLayout,
            visibleFrame: screen.visibleFrame
        )
        let visualCenter = CGPoint(x: currentCenter.x + horizontalShift, y: currentCenter.y)
        let grabOffset = CGVector(dx: screenPoint.x - visualCenter.x, dy: screenPoint.y - visualCenter.y)

        let style = RecordingIndicatorStyle.current()
        let base = FloatingBarPlacementGeometry.baseCapsuleHeight(for: style)
        let target = FloatingBarPlacementGeometry.defaultCenter(visibleFrame: screen.visibleFrame, baseHeight: base)

        var initialSnapped: FloatingBarSnapAxes = []
        if abs(visualCenter.x - target.x) <= TF.barPlacementSnapEnter {
            initialSnapped.insert(.x)
        }
        if abs(visualCenter.y - target.y) <= TF.barPlacementSnapEnter {
            initialSnapped.insert(.y)
        }
        let snapper = FloatingBarSnapper(snapped: initialSnapped)

        drag = DragSession(
            grabOffset: grabOffset,
            anchor: chrome.verticalAnchor,
            snapper: snapper,
            center: visualCenter,
            displayID: FloatingBarPanel.displayID(for: screen)
        )

        dragLifecycle.dragBegan()
        chrome.isDragging = true
        chrome.snappedAxes = initialSnapped

        let guide = FloatingBarPlacementGuideWindow()
        guide.update(
            visibleFrame: screen.visibleFrame,
            defaultCenter: target,
            snapped: initialSnapped,
            theme: currentRecordingTheme()
        )
        guide.show(relativeTo: panel.windowNumber)
        self.guideWindow = guide
    }

    private func handleDragMoved(to screenPoint: CGPoint) {
        guard var session = drag else { return }
        let raw = CGPoint(
            x: screenPoint.x - session.grabOffset.dx,
            y: screenPoint.y - session.grabOffset.dy
        )

        let screen = NSScreen.screens.first(where: { $0.frame.contains(raw) })
            ?? currentPlacementScreen()
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }

        let style = RecordingIndicatorStyle.current()
        let base = FloatingBarPlacementGeometry.baseCapsuleHeight(for: style)
        let target = FloatingBarPlacementGeometry.defaultCenter(visibleFrame: screen.visibleFrame, baseHeight: base)

        if let displayID = FloatingBarPanel.displayID(for: screen), displayID != session.displayID {
            session.displayID = displayID
        }

        let (c, newlySnapped) = session.snapper.update(raw: raw, target: target)
        let actualHeight = currentLayout.capsuleSize?.height ?? base
        let actualContentWidth = currentLayout.contentSize.width + 2 * currentLayout.horizontalOverflow
        let minWidth = max(style == .compact ? TF.compactIndicatorWidth : TF.barWidthCompact, actualContentWidth)
        let clamped = FloatingBarPlacementGeometry.clampCenter(
            c,
            baseHeight: base,
            actualCapsuleHeight: actualHeight,
            anchor: session.anchor,
            handleReserve: currentLayout.anchorSideReserve,
            minCapsuleWidth: minWidth,
            visibleFrame: screen.visibleFrame
        )

        session.center = clamped
        drag = session

        let origin = FloatingBarPlacementGeometry.panelFrame(
            layout: currentLayout,
            center: clamped,
            baseHeight: base,
            anchor: session.anchor,
            visibleFrame: screen.visibleFrame
        ).origin
        panel.setFrameOrigin(origin)

        guideWindow?.update(
            visibleFrame: screen.visibleFrame,
            defaultCenter: target,
            snapped: session.snapper.snapped,
            theme: currentRecordingTheme()
        )

        if !newlySnapped.isEmpty {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
        chrome.snappedAxes = session.snapper.snapped
    }

    private func handleDragEnded(at screenPoint: CGPoint) {
        commitCurrentDrag(at: screenPoint)
    }

    private func commitCurrentDrag(at screenPoint: CGPoint? = nil) {
        if let screenPoint {
            handleDragMoved(to: screenPoint)
        }
        guard let session = drag, let screen = currentPlacementScreen() else {
            drag = nil
            chrome.isDragging = false
            chrome.snappedAxes = []
            guideWindow?.dismiss()
            guideWindow = nil
            return
        }

        let newPlacement = FloatingBarPlacementGeometry.placement(
            droppedCenter: session.center,
            snapped: session.snapper.snapped,
            visibleFrame: screen.visibleFrame
        )

        placement = newPlacement
        isSelfOriginatedPlacementChange = true
        FloatingBarPlacementStore.save(newPlacement)
        isSelfOriginatedPlacementChange = false

        anchorDisplayID = session.displayID
        drag = nil
        chrome.isDragging = false
        chrome.snappedAxes = []

        guideWindow?.dismiss()
        guideWindow = nil

        let action = dragLifecycle.dragEnded()
        chrome.isRetainedForDrag = dragLifecycle.isRetainedForDrag
        applyPanelFrame(layout: currentLayout, display: true)

        if action == .releaseRetainedAndHide {
            hide()
        }
    }

    private func currentRecordingTheme() -> RecordingTheme {
        let themeRaw = UserDefaults.standard.string(forKey: RecordingTheme.storageKey)
            ?? RecordingTheme.defaultValue.rawValue
        return RecordingTheme(rawValue: themeRaw) ?? .dark
    }

    @objc private func handlePlacementDidChange(_ notification: Notification) {
        guard !isSelfOriginatedPlacementChange else { return }
        placement = FloatingBarPlacementStore.load()
        guard panel.isVisible, drag == nil else { return }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            applyPanelFrame(layout: currentLayout, display: true)
        } else {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                applyPanelFrame(layout: currentLayout, display: true)
            }
        }
    }

    @objc private func handleScreenParametersDidChange(_ notification: Notification) {
        if drag != nil {
            commitCurrentDrag()
        }
        if panel.isVisible {
            applyPanelFrame(layout: currentLayout, display: true)
        }
    }

    private func approximatelyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.5 &&
        abs(lhs.origin.y - rhs.origin.y) < 0.5 &&
        abs(lhs.size.width - rhs.size.width) < 0.5 &&
        abs(lhs.size.height - rhs.size.height) < 0.5
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
