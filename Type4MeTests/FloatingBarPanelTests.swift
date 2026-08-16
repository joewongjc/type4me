import AppKit
import SwiftUI
import XCTest
@testable import Type4Me

@MainActor
final class FloatingBarPanelTests: XCTestCase {
    func testHostingViewDoesNotDrivePanelSize() throws {
        let (_, panel) = try makeControllerAndPanel()
        defer { panel.orderOut(nil) }

        let hosting = try XCTUnwrap(
            panel.contentView as? NSHostingView<FloatingBarView<AppState>>
        )

        XCTAssertEqual(hosting.sizingOptions, [])
    }

    func testLongPinnedTranscriptKeepsPanelWithinReservedSize() throws {
        let (state, controller, panel) = try makeStateControllerAndPanel()
        defer { panel.orderOut(nil) }
        let expectedSize = panel.frame.size

        state.showRecovery(
            text: String(repeating: "This is a long transcript segment. ", count: 1_000),
            message: "Recovering"
        )

        for _ in 0..<10 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            panel.contentView?.layoutSubtreeIfNeeded()
        }

        let hosting = try XCTUnwrap(
            panel.contentView as? NSHostingView<FloatingBarView<AppState>>
        )
        let fittingSize = hosting.fittingSize

        XCTAssertEqual(panel.frame.width, expectedSize.width, accuracy: 0.5)
        XCTAssertEqual(panel.frame.height, expectedSize.height, accuracy: 0.5)
        XCTAssertLessThanOrEqual(fittingSize.height, expectedSize.height)
        withExtendedLifetime(controller) {}
    }

    private func makeControllerAndPanel() throws -> (FloatingBarController, FloatingBarPanel) {
        let state = AppState()
        let (_, controller, panel) = try makeStateControllerAndPanel(state: state)
        return (controller, panel)
    }

    private func makeStateControllerAndPanel(
        state: AppState = AppState()
    ) throws -> (AppState, FloatingBarController, FloatingBarPanel) {
        _ = NSApplication.shared
        let existingWindows = Set(NSApp.windows.map(ObjectIdentifier.init))
        let controller = FloatingBarController(state: state)
        let panel = try XCTUnwrap(
            NSApp.windows
                .compactMap { $0 as? FloatingBarPanel }
                .first { !existingWindows.contains(ObjectIdentifier($0)) }
        )
        return (state, controller, panel)
    }
}
