import AppKit
import SwiftUI

// MARK: - Layout change bridge (avoid capturing `self` in a block before init completes)

private final class FloatingBarLayoutBridge: NSObject {
    weak var controller: FloatingBarController?

    @objc func handleLayoutChange(_ notification: Notification) {
        MainActor.assumeIsolated {
            controller?.applyLayoutToPanel()
        }
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
        animationBehavior = .utilityWindow
        appearance = NSAppearance(named: .darkAqua)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func positionAtBottomCenter() {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) }) ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        let y = visible.origin.y + TF.barBottomOffset - 16  // compensate for shadow inset
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Controller

/// Manages the floating bar panel lifecycle.
/// All visual styling is handled in SwiftUI (FloatingBarView).
@MainActor
final class FloatingBarController {

    private let panel: FloatingBarPanel
    private let state: AppState
    private var panelSize: NSSize
    private let layoutBridge = FloatingBarLayoutBridge()

    init(state: AppState) {
        self.state = state

        let inset: CGFloat = 16  // extra room for shadow/glow
        let layout = FloatingBarLayoutMode.resolved(UserDefaults.standard.string(forKey: FloatingBarLayoutMode.storageKey))
        let frame = NSRect(
            x: 0,
            y: 0,
            width: layout.maxBarWidth + inset * 2,
            height: layout.capsuleHeight + inset * 2
        )
        panelSize = frame.size
        panel = FloatingBarPanel(contentRect: frame)

        let barView = FloatingBarView<AppState>(state: state)
        let hosting = NSHostingView(rootView: barView)
        hosting.layer?.backgroundColor = .clear
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]

        panel.contentView = hosting
        panel.setFrame(frame, display: false)
        panel.positionAtBottomCenter()

        layoutBridge.controller = self
        NotificationCenter.default.addObserver(
            layoutBridge,
            selector: #selector(FloatingBarLayoutBridge.handleLayoutChange),
            name: .floatingBarLayoutDidChange,
            object: nil
        )

        state.onShowPanel = { [weak self] in self?.show() }
        state.onHidePanel = { [weak self] in self?.hide() }
    }

    deinit {
        NotificationCenter.default.removeObserver(layoutBridge)
    }

    fileprivate func applyLayoutToPanel() {
        let inset: CGFloat = 16
        let layout = FloatingBarLayoutMode.resolved(UserDefaults.standard.string(forKey: FloatingBarLayoutMode.storageKey))
        let size = NSSize(width: layout.maxBarWidth + inset * 2, height: layout.capsuleHeight + inset * 2)
        panelSize = size
        panel.contentView?.frame = NSRect(origin: .zero, size: size)
        panel.setContentSize(size)
        if panel.isVisible {
            var r = panel.frame
            r.size = size
            panel.setFrame(r, display: true)
            panel.positionAtBottomCenter()
        }
    }

    func show() {
        // Cancel any in-progress hide animation to prevent race:
        // hide's completion could orderOut after we've shown again.
        panel.animator().alphaValue = 1
        panel.contentView?.layer?.removeAllAnimations()

        applyLayoutToPanel()

        panel.setContentSize(panelSize)
        panel.setFrame(NSRect(origin: panel.frame.origin, size: panelSize), display: false)
        panel.positionAtBottomCenter()
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
        let panelRef = panel
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panelRef.animator().alphaValue = 0
        }, completionHandler: {
            MainActor.assumeIsolated {
                // Only orderOut if still faded — show() may have interrupted
                guard panelRef.alphaValue < 0.01 else { return }
                panelRef.orderOut(nil)
            }
        })
    }
}
