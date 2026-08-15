import AppKit
import XCTest
@testable import Type4Me

@MainActor
final class FloatingBarHoverTests: XCTestCase {
    func testPreviewRemainsVisibleWhenStreamingCorrectionShrinksText() {
        var state = TranscriptHoverState()
        state.setHovering(true, transcriptNeedsExpansion: true)

        state.updateTranscript(needsExpansion: false)

        XCTAssertTrue(state.isHovering)
        XCTAssertTrue(state.isPopupVisible)
    }

    func testPreviewOpensWhenTranscriptGrowsDuringHover() {
        var state = TranscriptHoverState()
        state.setHovering(true, transcriptNeedsExpansion: false)

        state.updateTranscript(needsExpansion: true)

        XCTAssertTrue(state.isPopupVisible)
    }

    func testLeavingPreviewRegionHidesPopup() {
        var state = TranscriptHoverState()
        state.setHovering(true, transcriptNeedsExpansion: true)

        state.setHovering(false, transcriptNeedsExpansion: true)

        XCTAssertFalse(state.isHovering)
        XCTAssertFalse(state.isPopupVisible)
    }

    func testTranscriptChangesOutsideHoverDoNotOpenPreview() {
        var state = TranscriptHoverState()

        state.updateTranscript(needsExpansion: true)

        XCTAssertFalse(state.isPopupVisible)
    }

    func testTrackingAreaRemainsStableAcrossLayoutUpdates() {
        let view = HoverTrackingNSView(frame: NSRect(x: 0, y: 0, width: 400, height: 44))

        view.updateTrackingAreas()
        XCTAssertEqual(view.trackingAreas.count, 1)
        let originalTrackingArea = view.trackingAreas[0]

        view.setFrameSize(NSSize(width: 400, height: 160))
        view.updateTrackingAreas()

        XCTAssertEqual(view.trackingAreas.count, 1)
        XCTAssertTrue(
            view.trackingAreas[0] === originalTrackingArea,
            "Layout changes must not replace the active tracking area while the pointer is hovering."
        )
    }
}
