import AppKit
import Foundation

enum FloatingBarVerticalAnchor: Equatable, Sendable {
    case bottom
    case top
}

struct FloatingBarSnapAxes: OptionSet, Sendable {
    let rawValue: Int
    static let x = FloatingBarSnapAxes(rawValue: 1 << 0)
    static let y = FloatingBarSnapAxes(rawValue: 1 << 1)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }
}

struct FloatingBarSnapper: Sendable {
    private(set) var snapped: FloatingBarSnapAxes = []

    init(snapped: FloatingBarSnapAxes = []) {
        self.snapped = snapped
    }

    /// Returns the adjusted center and the axes that newly entered the snapped state on this update.
    mutating func update(raw: CGPoint, target: CGPoint) -> (adjusted: CGPoint, newlySnapped: FloatingBarSnapAxes) {
        var newlySnapped: FloatingBarSnapAxes = []

        let dx = abs(raw.x - target.x)
        if snapped.contains(.x) {
            if dx > TF.barPlacementSnapExit {
                snapped.remove(.x)
            }
        } else {
            if dx <= TF.barPlacementSnapEnter {
                snapped.insert(.x)
                newlySnapped.insert(.x)
            }
        }

        let dy = abs(raw.y - target.y)
        if snapped.contains(.y) {
            if dy > TF.barPlacementSnapExit {
                snapped.remove(.y)
            }
        } else {
            if dy <= TF.barPlacementSnapEnter {
                snapped.insert(.y)
                newlySnapped.insert(.y)
            }
        }

        let adjustedX = snapped.contains(.x) ? target.x : raw.x
        let adjustedY = snapped.contains(.y) ? target.y : raw.y
        return (CGPoint(x: adjustedX, y: adjustedY), newlySnapped)
    }
}

struct FloatingBarDragLifecycle: Equatable, Sendable {
    enum Action: Equatable {
        case none
        case hideImmediately
        case retainForDrag
        case releaseRetainedAndHide
        case resumeActiveSession
    }

    private(set) var isDragging: Bool = false
    private(set) var isRetainedForDrag: Bool = false
    private(set) var pendingHideAfterDrag: Bool = false

    mutating func dragBegan() {
        isDragging = true
    }

    mutating func hideRequested() -> Action {
        if isDragging {
            pendingHideAfterDrag = true
            isRetainedForDrag = true
            return .retainForDrag
        } else {
            isRetainedForDrag = false
            pendingHideAfterDrag = false
            return .hideImmediately
        }
    }

    mutating func showRequested() -> Action {
        let wasRetained = isRetainedForDrag
        pendingHideAfterDrag = false
        isRetainedForDrag = false
        return wasRetained ? .resumeActiveSession : .none
    }

    mutating func dragEnded() -> Action {
        isDragging = false
        isRetainedForDrag = false
        if pendingHideAfterDrag {
            pendingHideAfterDrag = false
            return .releaseRetainedAndHide
        }
        return .none
    }

    mutating func manualInputStarted() -> Action {
        isDragging = false
        isRetainedForDrag = false
        pendingHideAfterDrag = false
        return .none
    }
}

enum FloatingBarPlacementGeometry {

    static func baseCapsuleHeight(for style: RecordingIndicatorStyle) -> CGFloat {
        style == .compact ? TF.compactIndicatorHeight : TF.barHeight
    }

    static func defaultCenter(visibleFrame v: NSRect, baseHeight h: CGFloat) -> CGPoint {
        CGPoint(x: v.midX, y: v.minY + TF.barBottomOffset + h / 2)
    }

    static func verticalAnchor(center: CGPoint, visibleFrame v: NSRect) -> FloatingBarVerticalAnchor {
        center.y > v.midY ? .top : .bottom
    }

    static func clampCenter(
        _ c: CGPoint,
        baseHeight: CGFloat,
        actualCapsuleHeight: CGFloat,
        anchor: FloatingBarVerticalAnchor,
        handleReserve: CGFloat,
        minCapsuleWidth: CGFloat,
        visibleFrame v: NSRect
    ) -> CGPoint {
        var x = c.x
        let halfW = minCapsuleWidth / 2
        if v.width >= minCapsuleWidth {
            x = max(v.minX + halfW, min(x, v.maxX - halfW))
        } else {
            x = v.midX
        }

        var y = c.y
        switch anchor {
        case .bottom:
            // Capsule base bottom: y - baseHeight / 2
            // Bottom-most extent with handle: y - baseHeight / 2 - handleReserve
            // Top-most extent with actual capsule height: y - baseHeight / 2 + actualCapsuleHeight
            let minYAllowed = v.minY + handleReserve + baseHeight / 2
            let maxYAllowed = v.maxY - actualCapsuleHeight + baseHeight / 2
            if minYAllowed <= maxYAllowed {
                y = max(minYAllowed, min(y, maxYAllowed))
            } else {
                y = minYAllowed
            }
        case .top:
            // Capsule base top: y + baseHeight / 2
            // Top-most extent with handle: y + baseHeight / 2 + handleReserve
            // Bottom-most extent with actual capsule height: y + baseHeight / 2 - actualCapsuleHeight
            let maxYAllowed = v.maxY - handleReserve - baseHeight / 2
            let minYAllowed = v.minY + actualCapsuleHeight - baseHeight / 2
            if minYAllowed <= maxYAllowed {
                y = max(minYAllowed, min(y, maxYAllowed))
            } else {
                y = maxYAllowed
            }
        }

        return CGPoint(x: x, y: y)
    }

    static func resolveCenter(
        _ p: FloatingBarPlacement,
        visibleFrame v: NSRect,
        baseHeight h: CGFloat
    ) -> CGPoint {
        let d = defaultCenter(visibleFrame: v, baseHeight: h)
        let x: CGFloat = switch p.horizontal {
        case .default: d.x
        case .fraction(let f): v.minX + v.width * CGFloat(f)
        }
        let y: CGFloat = switch p.vertical {
        case .default: d.y
        case .fromBottom(let dy): v.minY + CGFloat(dy)
        case .fromTop(let dy): v.maxY - CGFloat(dy)
        }
        let raw = CGPoint(x: x, y: y)
        let anchor = verticalAnchor(center: raw, visibleFrame: v)
        return clampCenter(
            raw,
            baseHeight: h,
            actualCapsuleHeight: h,
            anchor: anchor,
            handleReserve: TF.barPlacementHandleReserve,
            minCapsuleWidth: TF.barWidthCompact,
            visibleFrame: v
        )
    }

    static func horizontalShiftKeepingContentVisible(
        centerX: CGFloat,
        layout: FloatingBarPanelLayout,
        visibleFrame v: NSRect
    ) -> CGFloat {
        let halfContent = layout.contentSize.width / 2 + layout.horizontalOverflow
        let minContentX = centerX - halfContent
        let maxContentX = centerX + halfContent
        if minContentX < v.minX {
            return v.minX - minContentX
        } else if maxContentX > v.maxX {
            return v.maxX - maxContentX
        }
        return 0
    }

    static func panelFrame(
        layout: FloatingBarPanelLayout,
        center: CGPoint,
        baseHeight: CGFloat,
        anchor: FloatingBarVerticalAnchor,
        visibleFrame v: NSRect
    ) -> NSRect {
        let size = layout.panelSize
        let inset = TF.floatingPanelShadowInset
        let reserve = layout.anchorSideReserve
        var x = center.x - size.width / 2
        let y: CGFloat
        switch anchor {
        case .bottom:
            let capsuleBottom = center.y - baseHeight / 2
            y = capsuleBottom - reserve - inset
        case .top:
            let capsuleTop = center.y + baseHeight / 2
            y = capsuleTop + reserve + inset - size.height
        }
        x += horizontalShiftKeepingContentVisible(centerX: center.x, layout: layout, visibleFrame: v)
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    static func anchoredFrame(
        size: NSSize,
        center: CGPoint,
        baseHeight: CGFloat,
        anchor: FloatingBarVerticalAnchor,
        reserve: CGFloat = 0,
        shadowInset: CGFloat,
        visibleFrame v: NSRect
    ) -> NSRect {
        var x = center.x - size.width / 2
        let y: CGFloat
        switch anchor {
        case .bottom:
            let capsuleBottom = center.y - baseHeight / 2
            y = capsuleBottom - reserve - shadowInset
        case .top:
            let capsuleTop = center.y + baseHeight / 2
            y = capsuleTop + reserve + shadowInset - size.height
        }
        let contentLeft = x + shadowInset
        let contentRight = x + size.width - shadowInset
        if contentLeft < v.minX {
            x += (v.minX - contentLeft)
        } else if contentRight > v.maxX {
            x += (v.maxX - contentRight)
        }
        return NSRect(x: x.rounded(), y: y.rounded(), width: size.width, height: size.height)
    }

    static func baseCapsuleRect(
        center: CGPoint,
        style: RecordingIndicatorStyle
    ) -> NSRect {
        let width = style == .compact ? TF.compactIndicatorWidth : TF.barWidthCompact
        let height = baseCapsuleHeight(for: style)
        return NSRect(
            x: center.x - width / 2,
            y: center.y - height / 2,
            width: width,
            height: height
        )
    }

    static func placement(
        droppedCenter c: CGPoint,
        snapped: FloatingBarSnapAxes,
        visibleFrame v: NSRect
    ) -> FloatingBarPlacement {
        let h: FloatingBarPlacement.Horizontal = snapped.contains(.x)
            ? .default : .fraction(Double((c.x - v.minX) / v.width))
        let vert: FloatingBarPlacement.Vertical
        if snapped.contains(.y) {
            vert = .default
        } else if c.y > v.midY {
            vert = .fromTop(Double(v.maxY - c.y))
        } else {
            vert = .fromBottom(Double(c.y - v.minY))
        }
        return FloatingBarPlacement(horizontal: h, vertical: vert)
    }

    static func adjustDragSessionOnLayoutChange(
        center: CGPoint,
        grabOffset: CGVector,
        layout: FloatingBarPanelLayout,
        baseHeight: CGFloat,
        anchor: FloatingBarVerticalAnchor,
        style: RecordingIndicatorStyle,
        visibleFrame v: NSRect
    ) -> (center: CGPoint, grabOffset: CGVector) {
        let actualCapsuleHeight = layout.capsuleSize?.height ?? baseHeight
        let actualContentWidth = layout.contentSize.width + 2 * layout.horizontalOverflow
        let minWidth = max(style == .compact ? TF.compactIndicatorWidth : TF.barWidthCompact, actualContentWidth)
        let clamped = clampCenter(
            center,
            baseHeight: baseHeight,
            actualCapsuleHeight: actualCapsuleHeight,
            anchor: anchor,
            handleReserve: layout.anchorSideReserve,
            minCapsuleWidth: minWidth,
            visibleFrame: v
        )
        let shiftX = clamped.x - center.x
        let shiftY = clamped.y - center.y
        let newGrabOffset = CGVector(dx: grabOffset.dx - shiftX, dy: grabOffset.dy - shiftY)
        return (center: clamped, grabOffset: newGrabOffset)
    }
}
