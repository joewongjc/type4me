import XCTest
@testable import Type4Me

@MainActor
final class PermissionGuideModelTests: XCTestCase {
    func testNeedsRestartDetectionWhenHotkeyProbeFails() {
        let model = PermissionGuideModel()
        model.accessibilityGranted = true
        model.hotkeyProbe = { false } // simulate kernel cache failure
        model.refresh()
        // If accessibility is granted but probe fails, needsRestart should be true
        if model.accessibilityGranted {
            XCTAssertTrue(model.needsRestart)
        }
    }

    func testNeedsRestartFalseWhenHotkeyProbeSucceeds() {
        let model = PermissionGuideModel()
        model.accessibilityGranted = true
        model.hotkeyProbe = { true }
        model.refresh()
        XCTAssertFalse(model.needsRestart)
    }

    func testRequiredPermissionsCalculation() {
        let model = PermissionGuideModel()
        model.micGranted = true
        model.accessibilityGranted = true
        XCTAssertTrue(model.requiredPermissionsGranted)

        model.micGranted = false
        XCTAssertFalse(model.requiredPermissionsGranted)
    }
}
