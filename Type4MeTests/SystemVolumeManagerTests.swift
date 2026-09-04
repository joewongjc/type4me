import XCTest
@testable import Type4Me

final class SystemVolumeManagerTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "SystemVolumeManagerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testMissingReductionPreferenceDoesNotLowerVolume() {
        XCTAssertEqual(SystemVolumeManager.configuredReductionPercent(defaults: defaults), -1)
    }

    func testExplicitNoReductionPreferenceIsPreserved() {
        defaults.set(-1, forKey: SystemVolumeManager.volumeReductionKey)

        XCTAssertEqual(SystemVolumeManager.configuredReductionPercent(defaults: defaults), -1)
    }

    func testExplicitMutePreferenceIsPreserved() {
        defaults.set(0, forKey: SystemVolumeManager.volumeReductionKey)

        XCTAssertEqual(SystemVolumeManager.configuredReductionPercent(defaults: defaults), 0)
    }

    func testExplicitReductionPreferenceIsPreserved() {
        defaults.set(30, forKey: SystemVolumeManager.volumeReductionKey)

        XCTAssertEqual(SystemVolumeManager.configuredReductionPercent(defaults: defaults), 30)
    }
}
