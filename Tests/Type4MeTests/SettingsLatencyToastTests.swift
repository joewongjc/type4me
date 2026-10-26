import XCTest
@testable import Type4Me

final class SettingsLatencyToastTests: XCTestCase {

    private var previousLanguage: String?

    override func setUp() {
        super.setUp()
        previousLanguage = UserDefaults.standard.string(forKey: "tf_language")
    }

    override func tearDown() {
        if let previousLanguage {
            UserDefaults.standard.set(previousLanguage, forKey: "tf_language")
        } else {
            UserDefaults.standard.removeObject(forKey: "tf_language")
        }
        super.tearDown()
    }

    func testFormattedLatency_usesMillisecondsBelowOneSecond() {
        XCTAssertEqual(SettingsLatencyToast(latency: .milliseconds(842)).formattedLatency, "842 ms")
        XCTAssertEqual(SettingsLatencyToast(latency: .microseconds(12_400)).formattedLatency, "12 ms")
    }

    func testFormattedLatency_usesSecondsFromOneSecond() {
        XCTAssertEqual(SettingsLatencyToast(latency: .milliseconds(1_000)).formattedLatency, "1.00 s")
        XCTAssertEqual(SettingsLatencyToast(latency: .milliseconds(1_236)).formattedLatency, "1.24 s")
    }

    func testMessage_switchesWithLanguage() {
        let toast = SettingsLatencyToast(latency: .milliseconds(320))

        UserDefaults.standard.set("zh", forKey: "tf_language")
        XCTAssertEqual(toast.message, "连接成功 · 时延 320 ms")

        UserDefaults.standard.set("en", forKey: "tf_language")
        XCTAssertEqual(toast.message, "Connected · 320 ms latency")
    }
}
