import XCTest
@testable import Type4Me

final class LocalizationAlphabeticalSortTests: XCTestCase {

    func testPinyinSortingKey_transcribesChineseCharacters() {
        XCTAssertEqual("阿里云百炼".pinyinSortingKey, "a li yun bai lian")
        XCTAssertEqual("百度智能云".pinyinSortingKey, "bai du zhi neng yun")
        XCTAssertEqual("阶跃星辰".pinyinSortingKey, "jie yue xing chen")
        XCTAssertEqual("小米 MiMo".pinyinSortingKey, "xiao mi mimo")
        XCTAssertEqual("AssemblyAI".pinyinSortingKey, "assemblyai")
    }

    func testLocalizedAlphabeticalCompare_ordersMixedChineseAndEnglishCorrectly() {
        let providersChinese = [
            "OpenAI",
            "Deepgram",
            "Cartesia",
            "AssemblyAI",
            "ElevenLabs",
            "Gemini",
            "Grok",
            "阿里云百炼",
            "百度智能云",
            "小米 MiMo",
            "阶跃星辰"
        ]

        let sortedChinese = providersChinese.sorted { $0.localizedAlphabeticalCompare($1) == .orderedAscending }

        let expectedChinese = [
            "阿里云百炼",
            "AssemblyAI",
            "百度智能云",
            "Cartesia",
            "Deepgram",
            "ElevenLabs",
            "Gemini",
            "Grok",
            "阶跃星辰",
            "OpenAI",
            "小米 MiMo"
        ]

        XCTAssertEqual(sortedChinese, expectedChinese)
    }

    func testLocalizedAlphabeticalCompare_ordersEnglishDisplayNamesCorrectly() {
        let providersEnglish = [
            "OpenAI",
            "Deepgram",
            "Cartesia",
            "AssemblyAI",
            "ElevenLabs",
            "Gemini",
            "Grok",
            "Alibaba Cloud Bailian",
            "Baidu AI Cloud",
            "Xiaomi MiMo",
            "StepFun"
        ]

        let sortedEnglish = providersEnglish.sorted { $0.localizedAlphabeticalCompare($1) == .orderedAscending }

        let expectedEnglish = [
            "Alibaba Cloud Bailian",
            "AssemblyAI",
            "Baidu AI Cloud",
            "Cartesia",
            "Deepgram",
            "ElevenLabs",
            "Gemini",
            "Grok",
            "OpenAI",
            "StepFun",
            "Xiaomi MiMo"
        ]

        XCTAssertEqual(sortedEnglish, expectedEnglish)
    }
}
