import XCTest
@testable import Type4Me

final class ASRCustomizationStorageTests: XCTestCase {

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "tf_asrBiasSettings")
        UserDefaults.standard.removeObject(forKey: "tf_asrUID")
        super.tearDown()
    }

    func testBiasSettingsDefaultsAreEmpty() {
        UserDefaults.standard.removeObject(forKey: "tf_asrBiasSettings")

        let settings = ASRBiasSettingsStorage.load()

        XCTAssertEqual(settings.boostingTableID, "")
        XCTAssertEqual(settings.contextHistoryLength, 0)
    }

    func testBiasSettingsAreSanitizedOnSave() {
        ASRBiasSettingsStorage.save(
            ASRBiasSettings(
                boostingTableID: "  boost-123  ",
                contextHistoryLength: -3
            )
        )

        let settings = ASRBiasSettingsStorage.load()

        XCTAssertEqual(settings.boostingTableID, "boost-123")
        XCTAssertEqual(settings.contextHistoryLength, 0)
    }

    func testIdentityStorePersistsGeneratedUID() {
        let first = ASRIdentityStore.loadOrCreateUID()
        let second = ASRIdentityStore.loadOrCreateUID()

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.hasPrefix("type4me-"))
    }
}
