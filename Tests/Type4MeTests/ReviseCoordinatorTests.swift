import XCTest
@testable import Type4Me
import Type4MeReviseCore

final class ReviseCoordinatorTests: XCTestCase {
    private var dummyElement: AXUIElement!
    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        dummyElement = AXUIElementCreateSystemWide()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "ReviseCoordinatorTests_\(UUID().uuidString)"
        )
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    func testTargetRegistrationAndPreparation() async throws {
        let initial = "明天下午三点和 Jerry 开会。"
        let fakeAX = FakeReviseAccessibilityClient(
            element: dummyElement,
            initialValue: initial
        )
        let settingsFile = tempDirectory.appendingPathComponent("revise-settings.json")
        let settingsStore = ReviseSettingsStore(fileURL: settingsFile, userDefaultsSuiteName: UUID().uuidString)
        let coordinator = ReviseCoordinator(
            accessibilityClient: fakeAX,
            settingsStore: settingsStore
        )

        let context = TrackedInjectionContext(
            element: dummyElement,
            processIdentifier: 1234,
            bundleIdentifier: "com.apple.TextEdit",
            baselineValue: initial,
            injectedRange: NSRange(location: 0, length: (initial as NSString).length),
            beforeSelectedRange: nil,
            afterSelectedRange: nil,
            placeholderCandidates: [],
            sourceText: initial,
            injectedText: initial,
            sourceRecordID: "rec_1",
            modeID: UUID()
        )

        await coordinator.registerTarget(context: context, sourceModeKind: .direct)

        let prepResult = await coordinator.prepareForRecording()
        guard case .success(let prepared) = prepResult else {
            XCTFail("Expected prepare success, got \(prepResult)")
            return
        }

        XCTAssertEqual(prepared.currentText, initial)
        XCTAssertEqual(prepared.targetGeneration, 0)

        // Attempting another prepare while busy returns busy
        let secondPrep = await coordinator.prepareForRecording()
        guard case .failure(let err) = secondPrep else {
            XCTFail("Expected failure for concurrent prepare")
            return
        }
        XCTAssertEqual(err, .busy)

        // Cancel the transaction
        await coordinator.cancel(transactionID: prepared.transactionID)

        // Can prepare again
        let thirdPrep = await coordinator.prepareForRecording()
        guard case .success = thirdPrep else {
            XCTFail("Expected prepare success after cancel")
            return
        }
    }

    func testCommitAndUndoFlow() async throws {
        let initial = "明天下午三点和 Jerry 开会。"
        let fakeAX = FakeReviseAccessibilityClient(
            element: dummyElement,
            initialValue: initial
        )
        let settingsFile = tempDirectory.appendingPathComponent("revise-settings.json")
        let settingsStore = ReviseSettingsStore(fileURL: settingsFile, userDefaultsSuiteName: UUID().uuidString)
        let coordinator = ReviseCoordinator(
            accessibilityClient: fakeAX,
            settingsStore: settingsStore
        )

        let context = TrackedInjectionContext(
            element: dummyElement,
            processIdentifier: 1234,
            bundleIdentifier: "com.apple.TextEdit",
            baselineValue: initial,
            injectedRange: NSRange(location: 0, length: (initial as NSString).length),
            beforeSelectedRange: nil,
            afterSelectedRange: nil,
            placeholderCandidates: [],
            sourceText: initial,
            injectedText: initial,
            sourceRecordID: "rec_1",
            modeID: UUID()
        )

        await coordinator.registerTarget(context: context, sourceModeKind: .direct)

        let prepResult = await coordinator.prepareForRecording()
        guard case .success(let prepared) = prepResult else {
            XCTFail("Expected prepare success")
            return
        }

        let updated = "明天下午四点和 Jerry 开会。"
        let commitResult = await coordinator.commit(
            transactionID: prepared.transactionID,
            candidate: updated
        )
        guard case .success(let success) = commitResult else {
            XCTFail("Expected commit success, got \(commitResult)")
            return
        }

        XCTAssertEqual(success.afterFullValue, updated)
        XCTAssertEqual(fakeAX.currentValue, updated)

        // Test Undo
        let undoResult = await coordinator.undo()
        guard case .success(let restored) = undoResult else {
            XCTFail("Expected undo success, got \(undoResult)")
            return
        }
        XCTAssertEqual(restored, initial)
        XCTAssertEqual(fakeAX.currentValue, initial)

        // After undo, can prepare again immediately without being blocked by busy
        let nextPrep = await coordinator.prepareForRecording()
        guard case .success = nextPrep else {
            XCTFail("Expected prepare success after undo")
            return
        }
    }

    func testUndoDuringActiveTransactionClearsTransaction() async throws {
        let initial = "明天开会。"
        let fakeAX = FakeReviseAccessibilityClient(element: dummyElement, initialValue: initial)
        let settingsFile = tempDirectory.appendingPathComponent("revise-settings.json")
        let settingsStore = ReviseSettingsStore(fileURL: settingsFile, userDefaultsSuiteName: UUID().uuidString)
        let coordinator = ReviseCoordinator(accessibilityClient: fakeAX, settingsStore: settingsStore)

        let context = TrackedInjectionContext(
            element: dummyElement,
            processIdentifier: 1234,
            bundleIdentifier: "com.apple.TextEdit",
            baselineValue: initial,
            injectedRange: NSRange(location: 0, length: (initial as NSString).length),
            beforeSelectedRange: nil,
            afterSelectedRange: nil,
            placeholderCandidates: [],
            sourceText: initial,
            injectedText: initial,
            sourceRecordID: "rec_1",
            modeID: UUID()
        )
        await coordinator.registerTarget(context: context, sourceModeKind: .direct)

        let prepResult1 = await coordinator.prepareForRecording()
        guard case .success(let prep1) = prepResult1 else {
            XCTFail("Expected prep1 success")
            return
        }
        _ = await coordinator.commit(transactionID: prep1.transactionID, candidate: "明天不开会。")

        // Prepare second revision (e.g. user says "改回去")
        let prepResult2 = await coordinator.prepareForRecording()
        guard case .success = prepResult2 else {
            XCTFail("Expected prep2 success")
            return
        }

        // Performing undo clears prep2 transaction and restores initial text
        let undoResult = await coordinator.undo()
        guard case .success(let restored) = undoResult else {
            XCTFail("Expected undo success")
            return
        }
        XCTAssertEqual(restored, initial)

        // Subsequent prepare must succeed without being stuck in .busy
        let prep3 = await coordinator.prepareForRecording()
        guard case .success = prep3 else {
            XCTFail("Expected prepare3 to succeed, coordinator was stuck in .busy!")
            return
        }
    }

    func testClearTargetPreventsStaleCrossAppPreparation() async throws {
        let initial = "上一轮可跟踪文本"
        let fakeAX = FakeReviseAccessibilityClient(element: dummyElement, initialValue: initial)
        let settingsFile = tempDirectory.appendingPathComponent("revise-settings.json")
        let settingsStore = ReviseSettingsStore(fileURL: settingsFile, userDefaultsSuiteName: UUID().uuidString)
        let coordinator = ReviseCoordinator(accessibilityClient: fakeAX, settingsStore: settingsStore)
        let context = TrackedInjectionContext(
            element: dummyElement,
            processIdentifier: 1234,
            bundleIdentifier: "com.apple.TextEdit",
            baselineValue: initial,
            injectedRange: NSRange(location: 0, length: (initial as NSString).length),
            beforeSelectedRange: nil,
            afterSelectedRange: nil,
            placeholderCandidates: [],
            sourceText: initial,
            injectedText: initial,
            sourceRecordID: "rec_stale",
            modeID: UUID()
        )
        await coordinator.registerTarget(context: context, sourceModeKind: .direct)

        await coordinator.clearTarget()

        let result = await coordinator.prepareForRecording()
        XCTAssertEqual(result.failure, .noTarget)
    }
}

private extension Result {
    var failure: Failure? {
        guard case .failure(let error) = self else { return nil }
        return error
    }
}
