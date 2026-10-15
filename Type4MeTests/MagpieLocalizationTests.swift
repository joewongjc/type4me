import XCTest
@testable import Type4Me

final class MagpieLocalizationTests: XCTestCase {

    func testProviderDisplayNameLocalization() {
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: "tf_language")
        defer {
            if let original {
                defaults.set(original, forKey: "tf_language")
            } else {
                defaults.removeObject(forKey: "tf_language")
            }
        }
        defaults.set("zh", forKey: "tf_language")
        XCTAssertEqual(LLMProvider.magpie.displayName, "Magpie（本机模型网关）")

        defaults.set("en", forKey: "tf_language")
        XCTAssertEqual(LLMProvider.magpie.displayName, "Magpie (Local Gateway)")
    }

    func testErrorDescriptionsLocalized() {
        let defaults = UserDefaults.standard
        let original = defaults.string(forKey: "tf_language")
        defer {
            if let original {
                defaults.set(original, forKey: "tf_language")
            } else {
                defaults.removeObject(forKey: "tf_language")
            }
        }
        defaults.set("zh", forKey: "tf_language")
        XCTAssertEqual(LLMError.magpieUnavailable.errorDescription, "Magpie 未运行，请打开 Magpie")
        XCTAssertEqual(LLMError.magpieRejected(401).errorDescription, "Magpie 拒绝了请求，请在 Magpie 中检查 Type4Me 的接入")
        XCTAssertEqual(LLMError.magpieModelMissing.errorDescription, "请先在 Type4Me 中为 Magpie 选择模型")

        defaults.set("en", forKey: "tf_language")
        XCTAssertEqual(LLMError.magpieUnavailable.errorDescription, "Magpie isn't running. Open Magpie and try again.")
        XCTAssertEqual(LLMError.magpieRejected(401).errorDescription, "Magpie refused the request. Check Type4Me's connection in Magpie.")
        XCTAssertEqual(LLMError.magpieModelMissing.errorDescription, "Pick a Magpie model in Type4Me first")
    }
}
