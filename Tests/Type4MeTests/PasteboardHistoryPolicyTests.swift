import AppKit
import XCTest
@testable import Type4Me

final class PasteboardHistoryPolicyTests: XCTestCase {
    func testTemporaryItemAlreadyContainsMarkerWhenPublished() {
        var writeCount = 0
        let result = PasteboardHistoryPolicy.publishText("dictation", transient: true) { item in
            writeCount += 1
            XCTAssertEqual(item.string(forType: .string), "dictation")
            XCTAssertEqual(item.data(forType: PasteboardHistoryPolicy.transientType), Data())
            return false
        }
        XCTAssertEqual(writeCount, 1)
        XCTAssertFalse(result)
    }

    func testTemporaryAndRegularCopiesPublishTheExpectedPasteboardItem() throws {
        let pasteboard = NSPasteboard(name: .init("Type4MeTests.copy.\(UUID().uuidString)"))
        let engine = TextInjectionEngine()

        XCTAssertTrue(engine.copyToClipboard("temporary dictation", transient: true, pasteboard: pasteboard))
        let temporary = try XCTUnwrap(pasteboard.pasteboardItems?.first)
        XCTAssertEqual(temporary.string(forType: .string), "temporary dictation")
        XCTAssertEqual(temporary.data(forType: PasteboardHistoryPolicy.transientType), Data())

        XCTAssertTrue(engine.copyToClipboard("retained dictation", pasteboard: pasteboard))
        let retained = try XCTUnwrap(pasteboard.pasteboardItems?.first)
        XCTAssertEqual(retained.string(forType: .string), "retained dictation")
        XCTAssertFalse(retained.types.contains(PasteboardHistoryPolicy.transientType))
    }

    func testRestoredClipboardIsMarkedTransientAndPreservesAllItems() throws {
        let pasteboard = NSPasteboard(name: .init("Type4MeTests.restore.\(UUID().uuidString)"))
        pasteboard.clearContents()

        let first = NSPasteboardItem()
        first.setString("first", forType: .string)
        let second = NSPasteboardItem()
        second.setString("second", forType: .string)
        XCTAssertTrue(pasteboard.writeObjects([first, second]))

        let snapshot = TextInjectionEngine.ClipboardSnapshot.capture(from: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString("temporary injection", forType: .string)
        let expectedChangeCount = pasteboard.changeCount

        snapshot.restore(to: pasteboard, expectedChangeCount: expectedChangeCount)

        let restoredItems = try XCTUnwrap(pasteboard.pasteboardItems)
        XCTAssertEqual(restoredItems.compactMap { $0.string(forType: .string) }, ["first", "second"])
        XCTAssertTrue(restoredItems.allSatisfy {
            $0.types.contains(PasteboardHistoryPolicy.transientType)
        })
    }

    func testEmptySnapshotClearsTemporaryInjection() {
        let pasteboard = NSPasteboard(name: .init("Type4MeTests.empty.\(UUID().uuidString)"))
        pasteboard.clearContents()
        let snapshot = TextInjectionEngine.ClipboardSnapshot.capture(from: pasteboard)

        pasteboard.setString("temporary injection", forType: .string)
        snapshot.restore(to: pasteboard, expectedChangeCount: pasteboard.changeCount)

        XCTAssertTrue(pasteboard.pasteboardItems?.isEmpty ?? true)
    }

    func testRestoreDoesNotOverwriteConcurrentClipboardChange() {
        let pasteboard = NSPasteboard(name: .init("Type4MeTests.race.\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let snapshot = TextInjectionEngine.ClipboardSnapshot.capture(from: pasteboard)

        pasteboard.clearContents()
        pasteboard.setString("temporary injection", forType: .string)
        let staleExpectedChangeCount = pasteboard.changeCount
        pasteboard.clearContents()
        pasteboard.setString("user copied this", forType: .string)

        snapshot.restore(to: pasteboard, expectedChangeCount: staleExpectedChangeCount)

        XCTAssertEqual(pasteboard.string(forType: .string), "user copied this")
    }

    func testTemporaryCopyNoOpDoesNotNeedRestoration() {
        XCTAssertFalse(PasteboardHistoryPolicy.shouldRestoreTemporaryCopy(
            previousChangeCount: 10,
            currentChangeCount: 10
        ))
        XCTAssertTrue(PasteboardHistoryPolicy.shouldRestoreTemporaryCopy(
            previousChangeCount: 10,
            currentChangeCount: 11
        ))
    }
}
