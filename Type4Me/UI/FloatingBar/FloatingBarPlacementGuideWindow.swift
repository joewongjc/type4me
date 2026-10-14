import AppKit
import SwiftUI

private struct FloatingBarPlacementGuideView: View {
    let visibleFrame: NSRect
    let defaultCenter: CGPoint
    let snapped: FloatingBarSnapAxes
    let theme: RecordingTheme

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private func drawGuideLine(
        context: GraphicsContext,
        path: Path,
        isSnapped: Bool
    ) {
        if isSnapped {
            context.stroke(
                path,
                with: .color(Color.black.opacity(0.40)),
                style: StrokeStyle(lineWidth: 3.0)
            )
            context.stroke(
                path,
                with: .color(TF.amber),
                style: StrokeStyle(lineWidth: 1.5)
            )
        } else {
            context.stroke(
                path,
                with: .color(Color.black.opacity(0.35)),
                style: StrokeStyle(lineWidth: 2.2, dash: TF.barPlacementGuideDash)
            )
            context.stroke(
                path,
                with: .color(Color.white.opacity(0.85)),
                style: StrokeStyle(lineWidth: 1.0, dash: TF.barPlacementGuideDash)
            )
        }
    }

    var body: some View {
        Canvas { context, size in
            // Vertical guide line
            let x = (defaultCenter.x - visibleFrame.minX).rounded()
            var vPath = Path()
            vPath.move(to: CGPoint(x: x, y: 0))
            vPath.addLine(to: CGPoint(x: x, y: size.height))

            drawGuideLine(context: context, path: vPath, isSnapped: snapped.contains(.x))

            // Horizontal guide line: AppKit origin is bottom-left, SwiftUI is top-left
            let dy = defaultCenter.y - visibleFrame.minY
            let y = (size.height - dy).rounded()
            var hPath = Path()
            hPath.move(to: CGPoint(x: 0, y: y))
            hPath.addLine(to: CGPoint(x: size.width, y: y))

            drawGuideLine(context: context, path: hPath, isSnapped: snapped.contains(.y))
        }
        .edgesIgnoringSafeArea(.all)
    }
}

final class FloatingBarPlacementGuideWindow: NSPanel {
    private var visibleFrame: NSRect = .zero
    private var defaultCenter: CGPoint = .zero
    private var snapped: FloatingBarSnapAxes = []
    private var theme: RecordingTheme = .dark

    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
    }

    func update(
        visibleFrame: NSRect,
        defaultCenter: CGPoint,
        snapped: FloatingBarSnapAxes,
        theme: RecordingTheme
    ) {
        self.visibleFrame = visibleFrame
        self.defaultCenter = defaultCenter
        self.snapped = snapped
        self.theme = theme

        if !approximatelyEqual(frame, visibleFrame) {
            setFrame(visibleFrame, display: false)
        }

        let guideView = FloatingBarPlacementGuideView(
            visibleFrame: visibleFrame,
            defaultCenter: defaultCenter,
            snapped: snapped,
            theme: theme
        )
        contentView = NSHostingView(rootView: guideView)
    }

    func show(relativeTo barPanelWindowNumber: Int) {
        order(.below, relativeTo: barPanelWindowNumber)
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            alphaValue = 1
        } else {
            alphaValue = 0
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = 1
            }
        }
    }

    func dismiss() {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            alphaValue = 0
            orderOut(nil)
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.2
                ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
                self.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                self?.orderOut(nil)
            })
        }
    }

    private func approximatelyEqual(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) < 0.5 &&
        abs(lhs.origin.y - rhs.origin.y) < 0.5 &&
        abs(lhs.size.width - rhs.size.width) < 0.5 &&
        abs(lhs.size.height - rhs.size.height) < 0.5
    }
}
