import Foundation
import NaturalLanguage

struct ChineseTokenSpan: Equatable, Sendable {
    enum Source: String, Codable, Sendable {
        case jiebaAccurate
        case jiebaSearch
        case naturalLanguage
        case userDictionary
    }

    let range: Range<String.Index>
    let source: Source
}

protocol ChineseWordSegmenting: Sendable {
    func tokenSpans(in text: String) async -> [ChineseTokenSpan]
}

actor NaturalLanguageChineseWordSegmenter: ChineseWordSegmenting {
    func tokenSpans(in text: String) -> [ChineseTokenSpan] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.string = text
        tokenizer.setLanguage(.simplifiedChinese)
        var spans: [ChineseTokenSpan] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            spans.append(ChineseTokenSpan(range: range, source: .naturalLanguage))
            return true
        }
        return spans
    }
}

actor HybridChineseWordSegmenter: ChineseWordSegmenting {
    static let shared = HybridChineseWordSegmenter()

    private let native = NaturalLanguageChineseWordSegmenter()
#if HAS_CPPJIEBA
    private let jieba = JiebaChineseWordSegmenter()
#endif

    func tokenSpans(in text: String) async -> [ChineseTokenSpan] {
        let nativeSpans = await native.tokenSpans(in: text)
#if HAS_CPPJIEBA
        guard JiebaChineseWordSegmenter.isExperimentEnabled else {
            await jieba.releaseForDisabledExperiment()
            return nativeSpans
        }
        return await jieba.tokenSpans(in: text) + nativeSpans
#else
        return nativeSpans
#endif
    }

    func insertConfirmedUserWord(_ word: String) async {
#if HAS_CPPJIEBA
        guard JiebaChineseWordSegmenter.isExperimentEnabled else {
            await jieba.releaseForDisabledExperiment()
            return
        }
        await jieba.insertConfirmedUserWord(word)
#endif
    }
}
