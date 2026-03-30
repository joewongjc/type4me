import XCTest
@testable import Type4Me

final class PermissionManagerTests: XCTestCase {

    func testSpeechPermissionHelpersExist() {
        let currentStatus: Bool = PermissionManager.hasSpeechRecognitionPermission
        let requestPermission: () async -> Bool = PermissionManager.requestSpeechRecognitionPermission

        _ = currentStatus
        _ = requestPermission
    }
}
