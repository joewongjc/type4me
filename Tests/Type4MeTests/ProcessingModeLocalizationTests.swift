import XCTest
@testable import Type4Me

final class ProcessingModeLocalizationTests: XCTestCase {

    func testSystemModeNameChangesLanguageWithoutMutatingPersistedName() {
        let persistedChineseMode = ProcessingMode(
            id: ProcessingMode.directId,
            name: "快速模式",
            description: "",
            prompt: "",
            isBuiltin: true
        )

        XCTAssertEqual(persistedChineseMode.name, "快速模式")
        XCTAssertEqual(persistedChineseMode.localizedDisplayName(for: .zh), "快速模式")
        XCTAssertEqual(persistedChineseMode.localizedDisplayName(for: .en), "Quick Mode")
        XCTAssertEqual(persistedChineseMode.name, "快速模式")
    }

    func testUserDefinedModeNameIsNeverAutoTranslated() {
        let customMode = ProcessingMode(
            id: UUID(),
            name: "会议记录",
            description: "",
            prompt: "",
            isBuiltin: false
        )

        XCTAssertEqual(customMode.localizedDisplayName(for: .zh), "会议记录")
        XCTAssertEqual(customMode.localizedDisplayName(for: .en), "会议记录")
    }

    func testSystemModeDescriptionChangesLanguageWithoutMutatingPersistedCopy() {
        let persistedEnglishMode = ProcessingMode(
            id: ProcessingMode.directId,
            name: "Quick Mode",
            description: "Fast transcription without post-processing",
            prompt: "",
            isBuiltin: true
        )

        XCTAssertEqual(
            persistedEnglishMode.localizedDisplayDescription(for: .zh),
            "快速转写，不进行后处理"
        )
        XCTAssertEqual(
            persistedEnglishMode.localizedDisplayDescription(for: .en),
            "Fast transcription without post-processing"
        )
        XCTAssertEqual(persistedEnglishMode.description, "Fast transcription without post-processing")
    }

    func testRenamedSystemModeNameIsNeverAutoTranslated() {
        let renamedMode = ProcessingMode(
            id: ProcessingMode.directId,
            name: "My fast dictation",
            description: "",
            prompt: "",
            isBuiltin: true
        )

        XCTAssertEqual(renamedMode.localizedDisplayName(for: .zh), "My fast dictation")
        XCTAssertEqual(renamedMode.localizedDisplayName(for: .en), "My fast dictation")
    }
}
