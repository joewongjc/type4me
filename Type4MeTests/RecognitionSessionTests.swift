import XCTest
@testable import Type4Me

final class RecognitionSessionTests: XCTestCase {
    override func tearDown() {
        KeychainService.selectedASRProvider = .volcano
    }

    func testInitialStateIsIdle() async {
        let session = RecognitionSession()
        let state = await session.state
        XCTAssertEqual(state, .idle)
    }

    func testSetState() async {
        let session = RecognitionSession()
        await session.setState(.recording)
        let state = await session.state
        XCTAssertEqual(state, .recording)
        await session.setState(.idle)
    }

    func testCanStartRecordingOnlyWhenIdle() async {
        let session = RecognitionSession()
        var canStart = await session.canStartRecording
        XCTAssertTrue(canStart)

        await session.setState(.recording)
        canStart = await session.canStartRecording
        XCTAssertFalse(canStart)
        await session.setState(.idle)
    }

    func testSwitchModeAppliesToDirect() async {
        KeychainService.selectedASRProvider = .volcano
        let session = RecognitionSession()

        await session.switchMode(to: .direct)

        let mode = await session.currentModeForTesting()
        XCTAssertEqual(mode.id, ProcessingMode.directId)
    }

    func testSwitchModeDirectWorksForSoniox() async {
        KeychainService.selectedASRProvider = .soniox
        let session = RecognitionSession()

        await session.switchMode(to: .direct)

        let mode = await session.currentModeForTesting()
        XCTAssertEqual(mode.id, ProcessingMode.directId)
    }
}
