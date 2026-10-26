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
        nsView.toolTip = L("拖动以移动录音条", "Drag to move the recording bar")
        nsView.setAccessibilityLabel(L("移动录音条", "Move recording bar"))
        nsView.setAccessibilityHelp(L("拖动以改变位置，可在外观设置中恢复默认位置", "Drag to change its position. You can reset it in Appearance settings."))
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

    private var isActive: Bool { isHovered || isDragging }

    private var fill: Color {
        theme == .light ? TF.barPlacementHandleFillLight : TF.barPlacementHandleFill
    }

    private var rim: Color {
        switch theme {
        case .light: isActive ? TF.barPlacementHandleRimActiveLight : TF.barPlacementHandleRimLight
        case .dark: isActive ? TF.barPlacementHandleRimActive : TF.barPlacementHandleRim
        }
    }

    var body: some View {
        // A solid grabber pill; glass doesn't read at this size. The rim keeps
        // it visible whatever host content sits behind it.
        Capsule(style: .continuous)
            .fill(fill)
            .overlay(Capsule(style: .continuous).strokeBorder(rim, lineWidth: 1))
            .shadow(color: .black.opacity(theme == .light ? 0.10 : 0.25), radius: 1.5, y: 0.5)
            .frame(
                width: isActive ? TF.barPlacementHandleActiveWidth : TF.barPlacementHandleWidth,
                height: TF.barPlacementHandleThickness
            )
            .padding(anchor == .bottom ? .top : .bottom, TF.barPlacementHandleInset)
            .frame(
                width: TF.barPlacementHandleHitWidth,
                height: TF.barPlacementHandleHitHeight,
                alignment: anchor == .bottom ? .top : .bottom
            )
            .allowsHitTesting(false)
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
            .animation(.spring(response: 0.22, dampingFraction: 0.8), value: isActive)
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
