import AppKit
import SwiftUI

struct FloatingBarDragHandle: NSViewRepresentable {
    let onDragBegan: (CGPoint) -> Void
    let onDragMoved: (CGPoint) -> Void
    let onDragEnded: (CGPoint) -> Void
    let onHoverChanged: ((Bool) -> Void)?

    init(
        onDragBegan: @escaping (CGPoint) -> Void,
        onDragMoved: @escaping (CGPoint) -> Void,
        onDragEnded: @escaping (CGPoint) -> Void,
        onHoverChanged: ((Bool) -> Void)? = nil
    ) {
        self.onDragBegan = onDragBegan
        self.onDragMoved = onDragMoved
        self.onDragEnded = onDragEnded
        self.onHoverChanged = onHoverChanged
    }

    func makeNSView(context: Context) -> FloatingBarDragHandleView {
        let view = FloatingBarDragHandleView()
        view.onDragBegan = onDragBegan
        view.onDragMoved = onDragMoved
        view.onDragEnded = onDragEnded
        view.onHoverChanged = onHoverChanged
        return view
    }

    func updateNSView(_ nsView: FloatingBarDragHandleView, context: Context) {
        nsView.onDragBegan = onDragBegan
        nsView.onDragMoved = onDragMoved
        nsView.onDragEnded = onDragEnded
        nsView.onHoverChanged = onHoverChanged
        nsView.toolTip = L("拖动以移动指示器", "Drag to move the indicator")
        nsView.setAccessibilityLabel(L("移动录音指示器", "Move recording indicator"))
        nsView.setAccessibilityHelp(L("拖动以改变位置，可在外观设置中恢复默认位置", "Drag to change its position. You can reset it in Appearance settings."))
    }
}

struct FloatingBarGripDotsView: View {
    let color: Color

    var body: some View {
        VStack(spacing: 2) {
            HStack(spacing: 2.8) {
                Circle().fill(color).frame(width: 1.6, height: 1.6)
                Circle().fill(color).frame(width: 1.6, height: 1.6)
                Circle().fill(color).frame(width: 1.6, height: 1.6)
            }
            HStack(spacing: 2.8) {
                Circle().fill(color).frame(width: 1.6, height: 1.6)
                Circle().fill(color).frame(width: 1.6, height: 1.6)
                Circle().fill(color).frame(width: 1.6, height: 1.6)
            }
        }
    }
}

struct FloatingBarDragHandleControl: View {
    let theme: RecordingTheme
    let anchor: FloatingBarVerticalAnchor
    let isVisible: Bool
    let isDragging: Bool
    let onDragBegan: ((CGPoint) -> Void)?
    let onDragMoved: ((CGPoint) -> Void)?
    let onDragEnded: ((CGPoint) -> Void)?
    let onHoverChanged: ((Bool) -> Void)?
    @State private var isHovered = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var shape: UnevenRoundedRectangle {
        switch anchor {
        case .bottom:
            UnevenRoundedRectangle(
                topLeadingRadius: 0,
                bottomLeadingRadius: 4,
                bottomTrailingRadius: 4,
                topTrailingRadius: 0,
                style: .continuous
            )
        case .top:
            UnevenRoundedRectangle(
                topLeadingRadius: 4,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: 4,
                style: .continuous
            )
        }
    }

    private var dotColor: Color {
        if theme == .light {
            return (isHovered || isDragging) ? Color.black.opacity(0.65) : Color.black.opacity(0.35)
        } else {
            return (isHovered || isDragging) ? Color.white.opacity(0.80) : Color.white.opacity(0.45)
        }
    }

    var body: some View {
        ZStack {
            // Glass background matching RecordingGlassSurface
            if reduceTransparency {
                shape.fill(theme == .light ? TF.floatingBackgroundLight : TF.floatingBackground)
            } else if #available(macOS 26.0, *) {
                shape.fill(
                    theme == .dark
                        ? Color.black.opacity(TF.glassDarkContrastFloor)
                        : Color.white.opacity(TF.glassLightContrastFloor)
                )
                Color.clear.glassEffect(.regular, in: shape)
            } else {
                VisualEffectBlur(
                    cornerRadius: 0,
                    appearanceName: theme == .light ? .aqua : .darkAqua
                )
                .allowsHitTesting(false)
                .clipShape(shape)

                if theme == .light {
                    Color.white.opacity(0.68)
                } else {
                    Color.black.opacity(0.32)
                }
            }

            FloatingBarGripDotsView(color: dotColor)
        }
        .frame(width: TF.barPlacementHandleWidth, height: TF.barPlacementHandleThickness)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(
                theme == .light ? TF.recordingLightGlassRim : TF.recordingGlassRim,
                lineWidth: 0.8
            )
        }
        .shadow(
            color: .black.opacity(theme == .light ? 0.08 : 0.20),
            radius: 2,
            x: 0,
            y: anchor == .bottom ? 1 : -1
        )
        .allowsHitTesting(false)
        .frame(width: max(TF.barPlacementHandleWidth, 36), height: TF.barPlacementHandleHitHeight)
        .overlay {
            FloatingBarDragHandle(
                onDragBegan: onDragBegan ?? { _ in },
                onDragMoved: onDragMoved ?? { _ in },
                onDragEnded: onDragEnded ?? { _ in },
                onHoverChanged: { hovering in
                    isHovered = hovering
                    onHoverChanged?(hovering)
                }
            )
        }
        .allowsHitTesting(isVisible)
        .animation(.easeInOut(duration: 0.15), value: isHovered)
        .animation(.easeInOut(duration: 0.15), value: isDragging)
    }
}

final class FloatingBarDragHandleView: NSView {
    var onDragBegan: ((CGPoint) -> Void)?
    var onDragMoved: ((CGPoint) -> Void)?
    var onDragEnded: ((CGPoint) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private var startScreenPoint: CGPoint = .zero
    private var isDragging = false

    override var acceptsFirstResponder: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.handle)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setAccessibilityRole(.handle)
    }

    override func isAccessibilityElement() -> Bool { true }

    override func updateTrackingAreas() {
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        guard containsMouse else { return }
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard !containsMouse else { return }
        onHoverChanged?(false)
    }

    private var containsMouse: Bool {
        guard let window else { return false }
        return bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
    }

    override func mouseDown(with event: NSEvent) {
        startScreenPoint = NSEvent.mouseLocation
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        let currentScreenPoint = NSEvent.mouseLocation
        if !isDragging {
            let dx = currentScreenPoint.x - startScreenPoint.x
            let dy = currentScreenPoint.y - startScreenPoint.y
            if hypot(dx, dy) >= TF.barPlacementDragThreshold {
                isDragging = true
                onDragBegan?(startScreenPoint)
                onDragMoved?(currentScreenPoint)
            }
        } else {
            onDragMoved?(currentScreenPoint)
        }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            onDragEnded?(NSEvent.mouseLocation)
            isDragging = false
        }

        onHoverChanged?(containsMouse)
    }
}
