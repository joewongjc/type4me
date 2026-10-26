import XCTest
@testable import Type4Me

@MainActor
final class RecordingDisplayProfileStoreTests: XCTestCase {

    private var profileURL: URL!

    override func setUp() {
        super.setUp()
        profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("type4me-display-profiles-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: profileURL)
        super.tearDown()
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "Type4MeTests.RecordingDisplay.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    func testEveryBlockFieldSurvivesSaveAndLoad() throws {
        let store = RecordingDisplayProfileStore(fileURL: profileURL)
        let custom = FloatingBarPresentation(
            theme: .light,
            indicatorStyle: .compact,
            visualStyle: .chrome,
            showsLiveTranscript: false,
            enablesHoverTranscriptPreview: false,
            showsTooltips: false,
            showsCancelButton: false,
            showsFinishButton: false,
            showsModeName: false,
            showsProviderName: true,
            showsModelName: true
        )
        let inheriting = FloatingBarPresentation(
            theme: .dark,
            indicatorStyle: .regular,
            visualStyle: .aurora
        )
        let customModeID = UUID()
        let otherModeID = UUID()

        try store.save([customModeID: custom, otherModeID: inheriting])
        let loaded = store.load()

        XCTAssertEqual(loaded[customModeID], custom, "every field of the block must round-trip")
        XCTAssertEqual(loaded[otherModeID], inheriting)
        XCTAssertEqual(loaded.count, 2)
    }

    func testUnknownAndMissingKeysFallBackToDefaultsInsteadOfFailing() throws {
        let json = """
        {"theme":"solarized","indicatorStyle":"compact","visualStyle":"neon","showsTooltips":false}
        """

        let decoded = try JSONDecoder().decode(FloatingBarPresentation.self, from: Data(json.utf8))

        XCTAssertEqual(decoded.theme, .dark, "an unknown value keeps the default")
        XCTAssertEqual(decoded.visualStyle, .siri, "an unknown value keeps the default")
        XCTAssertEqual(decoded.indicatorStyle, .compact, "a known value still applies")
        XCTAssertFalse(decoded.showsTooltips)
        XCTAssertTrue(decoded.showsCancelButton, "a missing key keeps the default")
    }

    func testMissingFileLoadsNoProfiles() {
        XCTAssertTrue(RecordingDisplayProfileStore(fileURL: profileURL).load().isEmpty)
    }

    func testCorruptFileLoadsNoProfiles() throws {
        try Data("not json".utf8).write(to: profileURL)

        XCTAssertTrue(RecordingDisplayProfileStore(fileURL: profileURL).load().isEmpty)
    }

    func testAppStateKeepsOnlyProfilesOfExistingModes() throws {
        let modesURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("type4me-modes-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: modesURL) }
        let modeStorage = ModeStorage(fileURL: modesURL)
        let custom = ProcessingMode(
            id: UUID(),
            name: "Coding",
            prompt: "Do {text}",
            isBuiltin: false
        )
        try modeStorage.save(ProcessingMode.builtins + [custom])

        let store = RecordingDisplayProfileStore(fileURL: profileURL)
        let liveProfile = FloatingBarPresentation(theme: .light)
        try store.save([custom.id: liveProfile, UUID(): FloatingBarPresentation()])

        let appState = AppState(
            modeStorage: modeStorage,
            recordingDisplayStore: store,
            userDefaults: makeDefaults()
        )

        XCTAssertEqual(appState.recordingDisplayOverride(for: custom.id), liveProfile)
        XCTAssertNil(
            appState.recordingDisplayOverride(for: ProcessingMode.directId),
            "a mode without a profile follows the global settings"
        )
        XCTAssertEqual(store.load().count, 1, "the orphaned profile is pruned on disk")
    }
}
