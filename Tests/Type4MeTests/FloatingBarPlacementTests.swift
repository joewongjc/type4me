import AppKit
import XCTest
@testable import Type4Me

final class FloatingBarPlacementTests: XCTestCase {

    // MARK: - 1. 默认回归 (Pixel-for-pixel regression with bottomCenteredFrame)

    func testDefaultPanelFrameMatchesBottomCenteredFrameExactly() {
        let screens: [NSRect] = [
            NSRect(x: 0, y: 25, width: 1440, height: 875),       // Built-in MacBook screen
            NSRect(x: -1920, y: 0, width: 1920, height: 1080),   // External screen to the left
            NSRect(x: 1440, y: 100, width: 2560, height: 1340),  // External screen to the right with dock
            NSRect(x: 50, y: 80, width: 3840, height: 2080),     // 4K screen
        ]

        let styles: [RecordingIndicatorStyle] = [.regular, .compact]

        let layouts: [FloatingBarPanelLayout] = [
            FloatingBarPanelLayout(
                contentSize: NSSize(width: TF.barWidthCompact, height: TF.barHeight),
                capsuleSize: NSSize(width: TF.barWidthCompact, height: TF.barHeight)
            ),
            FloatingBarPanelLayout(
                contentSize: NSSize(width: TF.barWidth, height: TF.barHeight),
                capsuleSize: NSSize(width: TF.barWidth, height: TF.barHeight)
            ),
            // With horizontal overflow and top overlay
            FloatingBarPanelLayout(
                contentSize: NSSize(width: 420, height: 180),
                horizontalOverflow: 24,
                capsuleSize: NSSize(width: 380, height: TF.barHeight)
            ),
            // Compact styles
            FloatingBarPanelLayout(
                contentSize: NSSize(width: TF.compactIndicatorWidth, height: TF.compactIndicatorHeight),
                capsuleSize: NSSize(width: TF.compactIndicatorWidth, height: TF.compactIndicatorHeight)
            ),
            FloatingBarPanelLayout(
                contentSize: NSSize(width: TF.compactIndicatorWidth, height: TF.compactTranscriptExpandedHeight),
                capsuleSize: NSSize(width: TF.compactIndicatorWidth, height: TF.compactTranscriptExpandedHeight)
            ),
        ]

        for screen in screens {
            for style in styles {
                let baseHeight = FloatingBarPlacementGeometry.baseCapsuleHeight(for: style)
                let center = FloatingBarPlacementGeometry.defaultCenter(visibleFrame: screen, baseHeight: baseHeight)
                let anchor = FloatingBarPlacementGeometry.verticalAnchor(center: center, visibleFrame: screen)
                XCTAssertEqual(anchor, .bottom, "Default anchor must be bottom")

                for layout in layouts {
                    var testLayout = layout
                    testLayout.anchorSideReserve = 0

                    let frameFromPlacement = FloatingBarPlacementGeometry.panelFrame(
                        layout: testLayout,
                        center: center,
                        baseHeight: baseHeight,
                        anchor: anchor,
                        visibleFrame: screen
                    )

                    let frameFromBottomCentered = FloatingBarPanel.bottomCenteredFrame(
                        size: testLayout.panelSize,
                        visibleFrame: screen
                    )

                    XCTAssertEqual(
                        frameFromPlacement.origin.x,
                        frameFromBottomCentered.origin.x,
                        accuracy: 0.001,
                        "origin.x mismatch on screen \(screen), layout \(layout)"
                    )
                    XCTAssertEqual(
                        frameFromPlacement.origin.y,
                        frameFromBottomCentered.origin.y,
                        accuracy: 0.001,
                        "origin.y mismatch on screen \(screen), layout \(layout)"
                    )
                    XCTAssertEqual(
                        frameFromPlacement.size.width,
                        frameFromBottomCentered.size.width,
                        accuracy: 0.001
                    )
                    XCTAssertEqual(
                        frameFromPlacement.size.height,
                        frameFromBottomCentered.size.height,
                        accuracy: 0.001
                    )
                }
            }
        }
    }

    // MARK: - 2. 解析 (Center Resolution)

    func testFractionalHorizontalPositionOnDifferentScreens() {
        let p = FloatingBarPlacement(horizontal: .fraction(0.3), vertical: .default)
        let baseHeight = TF.barHeight

        let screen1 = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let c1 = FloatingBarPlacementGeometry.resolveCenter(p, visibleFrame: screen1, baseHeight: baseHeight)
        XCTAssertEqual(c1.x, 1440 * 0.3, accuracy: 0.5)

        let screen2 = NSRect(x: 100, y: 0, width: 2560, height: 1440)
        let c2 = FloatingBarPlacementGeometry.resolveCenter(p, visibleFrame: screen2, baseHeight: baseHeight)
        XCTAssertEqual(c2.x, 100 + 2560 * 0.3, accuracy: 0.5)
    }

    func testFromBottomVerticalPositionIsConstantAcrossHeights() {
        let p = FloatingBarPlacement(horizontal: .default, vertical: .fromBottom(150))
        let baseHeight = TF.barHeight

        let screen1 = NSRect(x: 0, y: 50, width: 1440, height: 900)
        let c1 = FloatingBarPlacementGeometry.resolveCenter(p, visibleFrame: screen1, baseHeight: baseHeight)
        XCTAssertEqual(c1.y - screen1.minY, 150, accuracy: 0.5)

        let screen2 = NSRect(x: 0, y: 100, width: 2560, height: 1440)
        let c2 = FloatingBarPlacementGeometry.resolveCenter(p, visibleFrame: screen2, baseHeight: baseHeight)
        XCTAssertEqual(c2.y - screen2.minY, 150, accuracy: 0.5)
    }

    func testFromTopVerticalPositionIsConstantAcrossHeights() {
        let p = FloatingBarPlacement(horizontal: .default, vertical: .fromTop(150))
        let baseHeight = TF.barHeight

        let screen1 = NSRect(x: 0, y: 50, width: 1440, height: 900)
        let c1 = FloatingBarPlacementGeometry.resolveCenter(p, visibleFrame: screen1, baseHeight: baseHeight)
        XCTAssertEqual(screen1.maxY - c1.y, 150, accuracy: 0.5)

        let screen2 = NSRect(x: 0, y: 100, width: 2560, height: 1440)
        let c2 = FloatingBarPlacementGeometry.resolveCenter(p, visibleFrame: screen2, baseHeight: baseHeight)
        XCTAssertEqual(screen2.maxY - c2.y, 150, accuracy: 0.5)
    }

    func testOutOfrangeValuesAreClampedSafely() {
        let p = FloatingBarPlacement(horizontal: .fraction(1.5), vertical: .fromBottom(-100))
        let baseHeight = TF.barHeight
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)

        let c = FloatingBarPlacementGeometry.resolveCenter(p, visibleFrame: screen, baseHeight: baseHeight)
        XCTAssertLessThanOrEqual(c.x, screen.maxX - TF.barWidthCompact / 2)
        XCTAssertGreaterThanOrEqual(c.y - baseHeight / 2 - TF.barPlacementHandleReserve, screen.minY)
    }

    // MARK: - 3. 锚定与生长 (Anchor and Growth Direction)

    func testVerticalAnchorThreshold() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800) // midY = 400
        XCTAssertEqual(
            FloatingBarPlacementGeometry.verticalAnchor(center: CGPoint(x: 500, y: 399), visibleFrame: screen),
            .bottom
        )
        XCTAssertEqual(
            FloatingBarPlacementGeometry.verticalAnchor(center: CGPoint(x: 500, y: 400), visibleFrame: screen),
            .bottom
        )
        XCTAssertEqual(
            FloatingBarPlacementGeometry.verticalAnchor(center: CGPoint(x: 500, y: 401), visibleFrame: screen),
            .top
        )
    }

    func testTopAnchorGrowthPreservesCapsuleTopEdge() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        let center = CGPoint(x: 500, y: 800) // In top half
        let baseHeight = TF.compactIndicatorHeight // 24
        let anchor: FloatingBarVerticalAnchor = .top

        // Layout 1: collapsed (24pt)
        let layout1 = FloatingBarPanelLayout(
            contentSize: NSSize(width: 180, height: 24),
            capsuleSize: NSSize(width: 180, height: 24)
        )
        let frame1 = FloatingBarPlacementGeometry.panelFrame(
            layout: layout1,
            center: center,
            baseHeight: baseHeight,
            anchor: anchor,
            visibleFrame: screen
        )

        // Layout 2: expanded to 48pt with live transcript
        let layout2 = FloatingBarPanelLayout(
            contentSize: NSSize(width: 180, height: 48),
            capsuleSize: NSSize(width: 180, height: 48)
        )
        let frame2 = FloatingBarPlacementGeometry.panelFrame(
            layout: layout2,
            center: center,
            baseHeight: baseHeight,
            anchor: anchor,
            visibleFrame: screen
        )

        // For .top anchor, the top of the panel is: frame.maxY - shadowInset.
        // The top of the capsule is at center.y + baseHeight / 2.
        // That top edge must remain unchanged!
        let top1 = frame1.maxY
        let top2 = frame2.maxY
        XCTAssertEqual(top1, top2, accuracy: 0.5, "Top anchor must keep top edge constant when expanding downward")
        XCTAssertGreaterThan(frame2.height, frame1.height)
        XCTAssertLessThan(frame2.origin.y, frame1.origin.y)
    }

    func testBottomAnchorGrowthPreservesCapsuleBottomEdge() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        let center = CGPoint(x: 500, y: 200) // In bottom half
        let baseHeight = TF.compactIndicatorHeight
        let anchor: FloatingBarVerticalAnchor = .bottom

        let layout1 = FloatingBarPanelLayout(
            contentSize: NSSize(width: 180, height: 24),
            capsuleSize: NSSize(width: 180, height: 24)
        )
        let frame1 = FloatingBarPlacementGeometry.panelFrame(
            layout: layout1,
            center: center,
            baseHeight: baseHeight,
            anchor: anchor,
            visibleFrame: screen
        )

        let layout2 = FloatingBarPanelLayout(
            contentSize: NSSize(width: 180, height: 48),
            capsuleSize: NSSize(width: 180, height: 48)
        )
        let frame2 = FloatingBarPlacementGeometry.panelFrame(
            layout: layout2,
            center: center,
            baseHeight: baseHeight,
            anchor: anchor,
            visibleFrame: screen
        )

        let bottom1 = frame1.origin.y
        let bottom2 = frame2.origin.y
        XCTAssertEqual(bottom1, bottom2, accuracy: 0.5, "Bottom anchor must keep bottom edge constant when expanding upward")
    }

    func testHandleReserveDoesNotMoveCapsuleOnScreen() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        let baseHeight = TF.barHeight

        // Test bottom anchor
        let centerBottom = CGPoint(x: 500, y: 200)
        var layoutBottomNoHandle = FloatingBarPanelLayout(
            contentSize: NSSize(width: 300, height: baseHeight),
            capsuleSize: NSSize(width: 300, height: baseHeight)
        )
        layoutBottomNoHandle.anchorSideReserve = 0
        let frameBottomNoHandle = FloatingBarPlacementGeometry.panelFrame(
            layout: layoutBottomNoHandle,
            center: centerBottom,
            baseHeight: baseHeight,
            anchor: .bottom,
            visibleFrame: screen
        )

        var layoutBottomWithHandle = FloatingBarPanelLayout(
            contentSize: NSSize(width: 300, height: baseHeight + TF.barPlacementHandleReserve),
            capsuleSize: NSSize(width: 300, height: baseHeight)
        )
        layoutBottomWithHandle.anchorSideReserve = TF.barPlacementHandleReserve
        let frameBottomWithHandle = FloatingBarPlacementGeometry.panelFrame(
            layout: layoutBottomWithHandle,
            center: centerBottom,
            baseHeight: baseHeight,
            anchor: .bottom,
            visibleFrame: screen
        )

        // In bottom anchor, the capsule bottom is at frame.origin.y + shadowInset + reserve.
        let capsuleBottomWithout = frameBottomNoHandle.origin.y + TF.floatingPanelShadowInset + 0
        let capsuleBottomWith = frameBottomWithHandle.origin.y + TF.floatingPanelShadowInset + TF.barPlacementHandleReserve
        XCTAssertEqual(capsuleBottomWithout, capsuleBottomWith, accuracy: 0.5)

        // Test top anchor
        let centerTop = CGPoint(x: 500, y: 800)
        var layoutTopNoHandle = FloatingBarPanelLayout(
            contentSize: NSSize(width: 300, height: baseHeight),
            capsuleSize: NSSize(width: 300, height: baseHeight)
        )
        layoutTopNoHandle.anchorSideReserve = 0
        let frameTopNoHandle = FloatingBarPlacementGeometry.panelFrame(
            layout: layoutTopNoHandle,
            center: centerTop,
            baseHeight: baseHeight,
            anchor: .top,
            visibleFrame: screen
        )

        var layoutTopWithHandle = FloatingBarPanelLayout(
            contentSize: NSSize(width: 300, height: baseHeight + TF.barPlacementHandleReserve),
            capsuleSize: NSSize(width: 300, height: baseHeight)
        )
        layoutTopWithHandle.anchorSideReserve = TF.barPlacementHandleReserve
        let frameTopWithHandle = FloatingBarPlacementGeometry.panelFrame(
            layout: layoutTopWithHandle,
            center: centerTop,
            baseHeight: baseHeight,
            anchor: .top,
            visibleFrame: screen
        )

        // In top anchor, the capsule top is at frame.maxY - shadowInset - reserve.
        let capsuleTopWithout = frameTopNoHandle.maxY - TF.floatingPanelShadowInset - 0
        let capsuleTopWith = frameTopWithHandle.maxY - TF.floatingPanelShadowInset - TF.barPlacementHandleReserve
        XCTAssertEqual(capsuleTopWithout, capsuleTopWith, accuracy: 0.5)
    }

    // MARK: - 4. 限位 (Clamping & Content Shifting)

    func testClampCenterKeepsHandleAndCapsuleInsideVisibleFrame() {
        let screen = NSRect(x: 100, y: 100, width: 800, height: 600)
        let baseHeight = TF.barHeight // 55
        let minW = TF.barWidthCompact // 180
        let reserve = TF.barPlacementHandleReserve

        // Extreme bottom-left
        let clampedBL = FloatingBarPlacementGeometry.clampCenter(
            CGPoint(x: 0, y: 0),
            baseHeight: baseHeight,
            actualCapsuleHeight: baseHeight,
            anchor: .bottom,
            handleReserve: reserve,
            minCapsuleWidth: minW,
            visibleFrame: screen
        )
        XCTAssertGreaterThanOrEqual(clampedBL.x - minW / 2, screen.minX)
        XCTAssertGreaterThanOrEqual(clampedBL.y - baseHeight / 2 - reserve, screen.minY)

        // Extreme top-right
        let clampedTR = FloatingBarPlacementGeometry.clampCenter(
            CGPoint(x: 2000, y: 2000),
            baseHeight: baseHeight,
            actualCapsuleHeight: baseHeight,
            anchor: .top,
            handleReserve: reserve,
            minCapsuleWidth: minW,
            visibleFrame: screen
        )
        XCTAssertLessThanOrEqual(clampedTR.x + minW / 2, screen.maxX)
        XCTAssertLessThanOrEqual(clampedTR.y + baseHeight / 2 + reserve, screen.maxY)
    }

    func testWideCapsuleHorizontalShift() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let center = CGPoint(x: 950, y: 200) // Near right edge
        let wideLayout = FloatingBarPanelLayout(
            contentSize: NSSize(width: 400, height: TF.barHeight),
            capsuleSize: NSSize(width: 400, height: TF.barHeight)
        )

        let shift = FloatingBarPlacementGeometry.horizontalShiftKeepingContentVisible(
            centerX: center.x,
            layout: wideLayout,
            visibleFrame: screen
        )

        // Right edge of content before shift = 950 + 200 = 1150.
        // Overflow = 1150 - 1000 = 150. Shift should be -150.
        XCTAssertEqual(shift, -150, accuracy: 0.1)

        let frame = FloatingBarPlacementGeometry.panelFrame(
            layout: wideLayout,
            center: center,
            baseHeight: TF.barHeight,
            anchor: .bottom,
            visibleFrame: screen
        )

        // Visible content inside panel: [frame.minX + shadowInset, frame.maxX - shadowInset]
        let contentLeft = frame.minX + TF.floatingPanelShadowInset
        let contentRight = frame.maxX - TF.floatingPanelShadowInset
        XCTAssertGreaterThanOrEqual(contentLeft, screen.minX - 0.5)
        XCTAssertLessThanOrEqual(contentRight, screen.maxX + 0.5)
    }

    // MARK: - 5. 拖动边界 (Drag Boundaries)

    func testBottomAnchorExpandedCapsuleAtTopBoundaryDoesNotOverflow() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        let baseHeight: CGFloat = 24
        let actualHeight: CGFloat = 48
        let reserve = TF.barPlacementHandleReserve
        let minW: CGFloat = 180

        // User drags towards top while frozen in .bottom anchor
        let draggedTop = CGPoint(x: 500, y: screen.maxY)
        let clamped = FloatingBarPlacementGeometry.clampCenter(
            draggedTop,
            baseHeight: baseHeight,
            actualCapsuleHeight: actualHeight,
            anchor: .bottom,
            handleReserve: reserve,
            minCapsuleWidth: minW,
            visibleFrame: screen
        )

        // In bottom anchor, top of actual capsule = clamped.y - baseHeight / 2 + actualHeight
        let capsuleTop = clamped.y - baseHeight / 2 + actualHeight
        XCTAssertLessThanOrEqual(capsuleTop, screen.maxY + 0.001)
    }

    func testTopAnchorExpandedCapsuleAtBottomBoundaryDoesNotOverflow() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 1000)
        let baseHeight: CGFloat = 24
        let actualHeight: CGFloat = 48
        let reserve = TF.barPlacementHandleReserve
        let minW: CGFloat = 180

        // User drags towards bottom while frozen in .top anchor
        let draggedBottom = CGPoint(x: 500, y: screen.minY)
        let clamped = FloatingBarPlacementGeometry.clampCenter(
            draggedBottom,
            baseHeight: baseHeight,
            actualCapsuleHeight: actualHeight,
            anchor: .top,
            handleReserve: reserve,
            minCapsuleWidth: minW,
            visibleFrame: screen
        )

        // In top anchor, bottom of actual capsule = clamped.y + baseHeight / 2 - actualHeight
        let capsuleBottom = clamped.y + baseHeight / 2 - actualHeight
        XCTAssertGreaterThanOrEqual(capsuleBottom, screen.minY - 0.001)
    }

    // MARK: - 6. 吸附 (Snapping & Hysteresis)

    func testSnappingHysteresis() {
        var snapper = FloatingBarSnapper()
        let target = CGPoint(x: 500, y: 100)

        // Distance = 20: not snapped
        var result = snapper.update(raw: CGPoint(x: 520, y: 100), target: target)
        XCTAssertFalse(snapper.snapped.contains(.x))
        XCTAssertFalse(result.newlySnapped.contains(.x))
        XCTAssertEqual(result.adjusted.x, 520)

        // Distance = 8: enters snap
        result = snapper.update(raw: CGPoint(x: 508, y: 100), target: target)
        XCTAssertTrue(snapper.snapped.contains(.x))
        XCTAssertTrue(result.newlySnapped.contains(.x))
        XCTAssertEqual(result.adjusted.x, 500) // Snapped to target

        // Distance = 10: stays snapped
        result = snapper.update(raw: CGPoint(x: 510, y: 100), target: target)
        XCTAssertTrue(snapper.snapped.contains(.x))
        XCTAssertFalse(result.newlySnapped.contains(.x)) // Already snapped, no new event
        XCTAssertEqual(result.adjusted.x, 500)

        // Distance = 14: still snapped
        result = snapper.update(raw: CGPoint(x: 514, y: 100), target: target)
        XCTAssertTrue(snapper.snapped.contains(.x))
        XCTAssertEqual(result.adjusted.x, 500)

        // Distance = 14.5: exits snap
        result = snapper.update(raw: CGPoint(x: 514.5, y: 100), target: target)
        XCTAssertFalse(snapper.snapped.contains(.x))
        XCTAssertEqual(result.adjusted.x, 514.5)

        // Distance = 10 while unsnapped: does NOT snap
        result = snapper.update(raw: CGPoint(x: 510, y: 100), target: target)
        XCTAssertFalse(snapper.snapped.contains(.x))
        XCTAssertEqual(result.adjusted.x, 510)

        // Distance = 8: re-enters snap
        result = snapper.update(raw: CGPoint(x: 508, y: 100), target: target)
        XCTAssertTrue(snapper.snapped.contains(.x))
        XCTAssertTrue(result.newlySnapped.contains(.x))
        XCTAssertEqual(result.adjusted.x, 500)
    }

    func testSimultaneousAxesSnap() {
        var snapper = FloatingBarSnapper()
        let target = CGPoint(x: 500, y: 100)

        let result = snapper.update(raw: CGPoint(x: 505, y: 106), target: target)
        XCTAssertEqual(result.newlySnapped, [.x, .y])
        XCTAssertEqual(result.adjusted, target)
    }

    func testInitialDefaultSnapDoesNotTriggerHapticOnStart() {
        // Dragging starting from default center is seeded with [.x, .y]
        var snapper = FloatingBarSnapper(snapped: [.x, .y])
        let target = CGPoint(x: 500, y: 100)

        // First move stays within exit distance
        let result = snapper.update(raw: CGPoint(x: 504, y: 103), target: target)
        XCTAssertTrue(result.newlySnapped.isEmpty, "No newly snapped axes on initial movement from default")
        XCTAssertEqual(result.adjusted, target)
    }

    // MARK: - 7. 拖动与会话生命周期 (Drag Lifecycle State Machine)

    func testDragLifecycleRetainsUntilDragEnd() {
        var lifecycle = FloatingBarDragLifecycle()

        // 1. Drag starts
        lifecycle.dragBegan()
        XCTAssertTrue(lifecycle.isDragging)
        XCTAssertFalse(lifecycle.isRetainedForDrag)

        // 2. Session ends mid-drag (hideRequested)
        let action1 = lifecycle.hideRequested()
        XCTAssertEqual(action1, .retainForDrag)
        XCTAssertTrue(lifecycle.isRetainedForDrag)
        XCTAssertTrue(lifecycle.pendingHideAfterDrag)

        // 3. User releases handle (dragEnded)
        let action2 = lifecycle.dragEnded()
        XCTAssertEqual(action2, .releaseRetainedAndHide)
        XCTAssertFalse(lifecycle.isDragging)
        XCTAssertFalse(lifecycle.isRetainedForDrag)
        XCTAssertFalse(lifecycle.pendingHideAfterDrag)
    }

    func testDragLifecycleNewSessionCancelsPendingHide() {
        var lifecycle = FloatingBarDragLifecycle()
        lifecycle.dragBegan()
        _ = lifecycle.hideRequested()
        XCTAssertTrue(lifecycle.pendingHideAfterDrag)

        // New recording starts before release
        let action = lifecycle.showRequested()
        XCTAssertEqual(action, .resumeActiveSession)
        XCTAssertFalse(lifecycle.pendingHideAfterDrag)
        XCTAssertFalse(lifecycle.isRetainedForDrag)

        // Release handle
        let endAction = lifecycle.dragEnded()
        XCTAssertEqual(endAction, .none)
    }

    func testDragLifecycleManualInputClearsDrag() {
        var lifecycle = FloatingBarDragLifecycle()
        lifecycle.dragBegan()
        _ = lifecycle.hideRequested()

        let action = lifecycle.manualInputStarted()
        XCTAssertEqual(action, .none)
        XCTAssertFalse(lifecycle.isDragging)
        XCTAssertFalse(lifecycle.isRetainedForDrag)
        XCTAssertFalse(lifecycle.pendingHideAfterDrag)
    }

    func testDragLifecycleNormalHideWhenNotDragging() {
        var lifecycle = FloatingBarDragLifecycle()
        let action = lifecycle.hideRequested()
        XCTAssertEqual(action, .hideImmediately)
        XCTAssertFalse(lifecycle.isRetainedForDrag)
    }

    // MARK: - 8. 反算与持久化 (Roundtrip & Store)

    func testPlacementRoundtripPrecision() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let baseHeight = TF.barHeight

        // Dropped point in lower half, not snapped
        let dropBottom = CGPoint(x: 400, y: 250)
        let pBottom = FloatingBarPlacementGeometry.placement(
            droppedCenter: dropBottom,
            snapped: [],
            visibleFrame: screen
        )
        if case .fraction(let f) = pBottom.horizontal {
            XCTAssertEqual(f, 400.0 / 1440.0, accuracy: 0.001)
        } else {
            XCTFail("Expected fractional horizontal")
        }
        if case .fromBottom(let dy) = pBottom.vertical {
            XCTAssertEqual(dy, 250.0, accuracy: 0.001)
        } else {
            XCTFail("Expected fromBottom vertical")
        }

        let resolvedBottom = FloatingBarPlacementGeometry.resolveCenter(pBottom, visibleFrame: screen, baseHeight: baseHeight)
        XCTAssertEqual(resolvedBottom.x, dropBottom.x, accuracy: 0.5)
        XCTAssertEqual(resolvedBottom.y, dropBottom.y, accuracy: 0.5)

        // Dropped point in upper half, snapped horizontal
        let dropTop = CGPoint(x: 720, y: 700)
        let pTop = FloatingBarPlacementGeometry.placement(
            droppedCenter: dropTop,
            snapped: [.x],
            visibleFrame: screen
        )
        XCTAssertEqual(pTop.horizontal, .default)
        if case .fromTop(let dy) = pTop.vertical {
            XCTAssertEqual(dy, 200.0, accuracy: 0.001)
        } else {
            XCTFail("Expected fromTop vertical")
        }

        let resolvedTop = FloatingBarPlacementGeometry.resolveCenter(pTop, visibleFrame: screen, baseHeight: baseHeight)
        XCTAssertEqual(resolvedTop.x, screen.midX, accuracy: 0.5)
        XCTAssertEqual(resolvedTop.y, dropTop.y, accuracy: 0.5)
    }

    func testPlacementStoreJSONRoundtripAndFallbacks() {
        let placement = FloatingBarPlacement(
            version: 1,
            horizontal: .fraction(0.35),
            vertical: .fromBottom(180)
        )

        guard let json = FloatingBarPlacementStore.encode(placement) else {
            XCTFail("Failed to encode placement")
            return
        }

        let decoded = FloatingBarPlacementStore.decode(json)
        XCTAssertEqual(decoded, placement)

        // Corrupted strings & unknown versions fall back to default
        XCTAssertEqual(FloatingBarPlacementStore.decode(""), .default)
        XCTAssertEqual(FloatingBarPlacementStore.decode("invalid json {"), .default)
        XCTAssertEqual(FloatingBarPlacementStore.decode("{\"version\": 99}"), .default)
    }

    func testSaveDefaultResetsKey() {
        let defaultsSuite = "com.type4me.tests.placement.\(UUID().uuidString)"
        guard let testDefaults = UserDefaults(suiteName: defaultsSuite) else {
            XCTFail("Failed to create test user defaults")
            return
        }
        defer { testDefaults.removePersistentDomain(forName: defaultsSuite) }

        // Save custom
        let custom = FloatingBarPlacement(horizontal: .fraction(0.2), vertical: .fromTop(100))
        FloatingBarPlacementStore.save(custom, testDefaults)
        XCTAssertFalse(FloatingBarPlacementStore.load(testDefaults).isDefault)

        // Save default resets
        FloatingBarPlacementStore.save(.default, testDefaults)
        XCTAssertNil(testDefaults.string(forKey: FloatingBarPlacementStore.storageKey))
        XCTAssertTrue(FloatingBarPlacementStore.load(testDefaults).isDefault)
    }

    // MARK: - 9. 关联面板 (Ancillary Panels)

    func testCorrectionLearningPanelPositioning() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let panelSize = NSSize(width: 320, height: 160)

        // 1. Bottom anchor
        let bottomCenter = CGPoint(x: 720, y: 150)
        let bottomCapsule = FloatingBarPlacementGeometry.baseCapsuleRect(center: bottomCenter, style: .regular)
        let bottomY = bottomCapsule.maxY + TF.correctionPanelGap
        XCTAssertEqual(bottomY, bottomCapsule.maxY + 18)
        XCTAssertLessThanOrEqual(bottomY + panelSize.height, screen.maxY)

        // 2. Top anchor
        let topCenter = CGPoint(x: 720, y: 800)
        let topCapsule = FloatingBarPlacementGeometry.baseCapsuleRect(center: topCenter, style: .regular)
        let topY = topCapsule.minY - TF.correctionPanelGap - panelSize.height
        XCTAssertEqual(topY, topCapsule.minY - 18 - 160)
        XCTAssertGreaterThanOrEqual(topY, screen.minY)
    }

    func testManualInputAnchoredFrameRegressionForDefault() {
        let screen = NSRect(x: 0, y: 25, width: 1440, height: 875)
        let baseHeight = TF.barHeight
        let defaultCenter = FloatingBarPlacementGeometry.defaultCenter(visibleFrame: screen, baseHeight: baseHeight)
        let anchor = FloatingBarPlacementGeometry.verticalAnchor(center: defaultCenter, visibleFrame: screen)
        XCTAssertEqual(anchor, .bottom)

        let size = NSSize(width: 684, height: 150)
        let shadowInset: CGFloat = 32

        let frame = FloatingBarPlacementGeometry.anchoredFrame(
            size: size,
            center: defaultCenter,
            baseHeight: baseHeight,
            anchor: anchor,
            reserve: 0,
            shadowInset: shadowInset,
            visibleFrame: screen
        )

        // Original formula from ManualInputPanel:
        var originalFrame = FloatingBarPanel.bottomCenteredFrame(size: size, visibleFrame: screen)
        originalFrame.origin.y -= shadowInset - TF.floatingPanelShadowInset

        XCTAssertEqual(frame.origin.x, originalFrame.origin.x, accuracy: 0.5)
        XCTAssertEqual(frame.origin.y, originalFrame.origin.y, accuracy: 0.5)
        XCTAssertEqual(frame.size.width, originalFrame.size.width, accuracy: 0.5)
        XCTAssertEqual(frame.size.height, originalFrame.size.height, accuracy: 0.5)
    }

    // MARK: - 10. 本地化 (Localization)

    func testLocalizationOfPlacementUI() {
        let previousLang = UserDefaults.standard.string(forKey: "tf_language")
        defer {
            if let previousLang {
                UserDefaults.standard.set(previousLang, forKey: "tf_language")
            } else {
                UserDefaults.standard.removeObject(forKey: "tf_language")
            }
        }

        // Chinese
        UserDefaults.standard.set(AppLanguage.zh.rawValue, forKey: "tf_language")
        XCTAssertEqual(L("录音条位置", "Recording Bar Position"), "录音条位置")
        XCTAssertEqual(L("默认", "Default"), "默认")
        XCTAssertEqual(L("自定义", "Custom"), "自定义")
        XCTAssertEqual(L("恢复默认", "Reset to Default"), "恢复默认")
        XCTAssertEqual(L("拖动以移动录音条", "Drag to move the recording bar"), "拖动以移动录音条")
        XCTAssertEqual(L("移动录音条", "Move recording bar"), "移动录音条")

        // English
        UserDefaults.standard.set(AppLanguage.en.rawValue, forKey: "tf_language")
        XCTAssertEqual(L("录音条位置", "Recording Bar Position"), "Recording Bar Position")
        XCTAssertEqual(L("默认", "Default"), "Default")
        XCTAssertEqual(L("自定义", "Custom"), "Custom")
        XCTAssertEqual(L("恢复默认", "Reset to Default"), "Reset to Default")
        XCTAssertEqual(L("拖动以移动录音条", "Drag to move the recording bar"), "Drag to move the recording bar")
        XCTAssertEqual(L("移动录音条", "Move recording bar"), "Move recording bar")
    }

    // MARK: - 11. 边界与拖拽修复回归测试 (Review Findings Regression Tests)

    func testEdgeDragClampingUsesActualContentWidthWithoutDeadZone() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let actualContentWidth: CGFloat = 400
        let baseHeight: CGFloat = TF.barHeight
        let minWidth = max(TF.barWidthCompact, actualContentWidth)

        let clampedRight = FloatingBarPlacementGeometry.clampCenter(
            CGPoint(x: 950, y: 100),
            baseHeight: baseHeight,
            actualCapsuleHeight: baseHeight,
            anchor: .bottom,
            handleReserve: 10,
            minCapsuleWidth: minWidth,
            visibleFrame: screen
        )
        XCTAssertEqual(clampedRight.x, 800)

        let movedLeft = FloatingBarPlacementGeometry.clampCenter(
            CGPoint(x: 790, y: 100),
            baseHeight: baseHeight,
            actualCapsuleHeight: baseHeight,
            anchor: .bottom,
            handleReserve: 10,
            minCapsuleWidth: minWidth,
            visibleFrame: screen
        )
        XCTAssertEqual(movedLeft.x, 790, "Center must respond immediately without dead zone")
    }

    func testForceEndDragSavesCurrentCenterWithoutGrabOffsetReapplication() {
        let screen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        let currentCenter = CGPoint(x: 600, y: 200)
        let snapper = FloatingBarSnapper(snapped: [])

        let placement = FloatingBarPlacementGeometry.placement(
            droppedCenter: currentCenter,
            snapped: snapper.snapped,
            visibleFrame: screen
        )

        let resolved = FloatingBarPlacementGeometry.resolveCenter(placement, visibleFrame: screen, baseHeight: TF.barHeight)
        XCTAssertEqual(resolved.x, currentCenter.x, accuracy: 0.5)
        XCTAssertEqual(resolved.y, currentCenter.y, accuracy: 0.5)
    }

    func testDragSessionAdjustsCenterAndGrabOffsetWhenWideningNearEdge() {
        let screen = NSRect(x: 0, y: 0, width: 1000, height: 800)
        let baseHeight = TF.barHeight

        let initialCenter = CGPoint(x: 900, y: 200)
        let initialMouse = CGPoint(x: 900, y: 200)
        let initialGrabOffset = CGVector(dx: initialMouse.x - initialCenter.x, dy: initialMouse.y - initialCenter.y)

        let wideLayout = FloatingBarPanelLayout(
            contentSize: NSSize(width: 400, height: baseHeight),
            capsuleSize: NSSize(width: 400, height: baseHeight),
            anchorSideReserve: 10
        )

        let adjusted = FloatingBarPlacementGeometry.adjustDragSessionOnLayoutChange(
            center: initialCenter,
            grabOffset: initialGrabOffset,
            layout: wideLayout,
            baseHeight: baseHeight,
            anchor: .bottom,
            style: .regular,
            visibleFrame: screen
        )

        XCTAssertEqual(adjusted.center.x, 800, accuracy: 0.1)
        XCTAssertEqual(adjusted.grabOffset.dx, 100, accuracy: 0.1)

        let movedMouse = CGPoint(x: 850, y: 200)
        let rawMovedX = movedMouse.x - adjusted.grabOffset.dx
        let actualContentWidth: CGFloat = 400
        let clampedMoved = FloatingBarPlacementGeometry.clampCenter(
            CGPoint(x: rawMovedX, y: 200),
            baseHeight: baseHeight,
            actualCapsuleHeight: baseHeight,
            anchor: .bottom,
            handleReserve: 10,
            minCapsuleWidth: actualContentWidth,
            visibleFrame: screen
        )

        XCTAssertEqual(clampedMoved.x, 750, accuracy: 0.1, "Moving mouse inward after widening must move center immediately without dead zone")
    }

    @MainActor
    func testChromeModelResetHoverClearsHandleVisibility() {
        let chrome = FloatingBarChromeModel()
        XCTAssertFalse(chrome.isHandleVisible)

        chrome.setHovering(true)
        XCTAssertTrue(chrome.isHandleVisible)

        chrome.resetHover()
        XCTAssertFalse(chrome.isHandleVisible)

        // Dragging preserves handle visibility during resetHover
        chrome.isDragging = true
        XCTAssertTrue(chrome.isHandleVisible)
        chrome.resetHover()
        XCTAssertTrue(chrome.isHandleVisible)

        chrome.isDragging = false
        chrome.resetHover()
        XCTAssertFalse(chrome.isHandleVisible)
    }

    @MainActor
    func testFloatingBarControllerShowAndHideResetsHandleHover() {
        let appState = AppState()
        let controller = FloatingBarController(state: appState)

        controller.chrome.setHovering(true)
        XCTAssertTrue(controller.chrome.isHandleVisible)

        controller.show()
        XCTAssertFalse(controller.chrome.isHandleVisible, "Showing the panel for a new session must reset handle hover state")

        controller.chrome.setHovering(true)
        XCTAssertTrue(controller.chrome.isHandleVisible)

        controller.hide()
        XCTAssertFalse(controller.chrome.isHandleVisible, "Hiding the panel must reset handle hover state")
    }

    @MainActor
    func testHoverPersistsAcrossRecordingProcessingDonePhases() {
        let appState = AppState()
        let controller = FloatingBarController(state: appState)

        // 1. Start recording and show panel
        appState.barPhase = .preparing
        controller.show()
        XCTAssertFalse(controller.chrome.isHandleVisible, "Initial state on show must not show handle")

        appState.barPhase = .recording
        XCTAssertFalse(controller.chrome.isHandleVisible)

        // 2. User moves mouse onto capsule during recording
        controller.chrome.setHovering(true)
        XCTAssertTrue(controller.chrome.isHandleVisible, "Hovering over capsule must make handle visible during recording")

        // 3. Recording ends -> enters processing while mouse continues hovering
        appState.barPhase = .processing
        XCTAssertTrue(controller.chrome.isHandleVisible, "Handle must remain visible during processing when mouse continues hovering")

        // 4. Processing completes -> enters done while mouse continues hovering
        appState.barPhase = .done
        XCTAssertTrue(controller.chrome.isHandleVisible, "Handle must remain visible during done when mouse continues hovering")

        // 5. Session completes and panel hides
        appState.barPhase = .hidden
        controller.hide()
        XCTAssertFalse(controller.chrome.isHandleVisible, "Hiding the panel must cleanly reset handle visibility")
    }

    @MainActor
    func testNewSessionFromHiddenStateDoesNotShowHandleWithoutHover() {
        let appState = AppState()
        let controller = FloatingBarController(state: appState)

        // Simulate a previous session where user had hovered and finished
        controller.chrome.setHovering(true)
        XCTAssertTrue(controller.chrome.isHandleVisible)
        controller.hide()
        XCTAssertFalse(controller.chrome.isHandleVisible)

        // Start a brand new session from hidden state without mouse hover
        appState.barPhase = .preparing
        controller.show()
        XCTAssertFalse(controller.chrome.isHandleVisible, "Handle must be initially invisible on new session invocation")

        // Advance through phases without hover; handle must stay invisible throughout
        appState.barPhase = .recording
        XCTAssertFalse(controller.chrome.isHandleVisible, "Handle must not automatically appear during recording")

        appState.barPhase = .processing
        XCTAssertFalse(controller.chrome.isHandleVisible, "Handle must not automatically appear during processing")

        appState.barPhase = .done
        XCTAssertFalse(controller.chrome.isHandleVisible, "Handle must not automatically appear during done")
    }

    @MainActor
    func testFloatingBarControllerFirstShowMakesPanelVisibleWithoutPrearming() {
        let appState = AppState()
        let controller = FloatingBarController(state: appState)
        defer { controller.panel.orderOut(nil) }

        // Must be initially invisible before show()
        XCTAssertFalse(controller.panel.isVisible)

        // First show() with real SwiftUI contentView attached
        controller.show()

        // Must become truly visible on screen without any external manual orderFront
        XCTAssertTrue(controller.panel.isVisible, "First show() must genuinely order the panel front")
    }

    @MainActor
    func testFloatingBarControllerShowAfterCompleteHideReappears() async throws {
        let appState = AppState()
        let controller = FloatingBarController(state: appState)
        defer { controller.panel.orderOut(nil) }

        controller.show()
        XCTAssertTrue(controller.panel.isVisible)

        // Perform full hide
        controller.hide()
        // Wait for hide animation (0.25s) to complete orderOut
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertFalse(controller.panel.isVisible, "Panel must be ordered out after complete hide")

        // Secondary show after complete hide must bring panel back
        controller.show()
        XCTAssertTrue(controller.panel.isVisible, "Panel must reappear when show() is called after complete hide")
    }

    @MainActor
    func testFloatingBarControllerShowWhileHideAnimationInProgressCancelsHide() async throws {
        let appState = AppState()
        let controller = FloatingBarController(state: appState)
        defer { controller.panel.orderOut(nil) }

        controller.show()
        XCTAssertTrue(controller.panel.isVisible)

        // Trigger hide
        controller.hide()
        // Mid-flight interruption (hide takes 250ms)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(controller.panel.isVisible)

        // Call show() while fade-out is active
        controller.show()
        XCTAssertTrue(controller.panel.isVisible)

        // Wait beyond original hide deadline (350ms total)
        try await Task.sleep(for: .milliseconds(350))

        // The previous hide completion must be superseded, so the panel must remain visible and opaque
        XCTAssertTrue(controller.panel.isVisible, "Panel must remain visible and not be ordered out by stale hide completion")
        XCTAssertEqual(controller.panel.alphaValue, 1.0, accuracy: 0.05)
    }

    @MainActor
    func testFloatingBarControllerRecordingToProcessingKeepsPanelVisibleWithoutReset() async throws {
        let appState = AppState()
        let controller = FloatingBarController(state: appState)
        defer { controller.panel.orderOut(nil) }

        appState.startRecording()
        appState.markRecordingReady()
        XCTAssertEqual(appState.barPhase, .recording)

        // Panel is displayed for recording session
        controller.show()
        XCTAssertTrue(controller.panel.isVisible)
        // Wait for entrance fade-in (300ms) to settle
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertEqual(controller.panel.alphaValue, 1.0, accuracy: 0.05)

        // State transition: recording -> processing (stopRecording triggers onShowPanel)
        appState.stopRecording()
        XCTAssertEqual(appState.barPhase, .processing)

        // Panel must remain fully visible and NOT zero-reset or flash
        XCTAssertTrue(controller.panel.isVisible)
        XCTAssertEqual(controller.panel.alphaValue, 1.0, accuracy: 0.05, "Panel opacity must stay at full opacity during phase transition")
    }
}
