import CoreImage
import XCTest
import Type4MeTransferCore
@testable import Type4Me

/// Which Mac modes travel to the iPhone, and as what.
final class MobileConfigExporterTests: XCTestCase {
    private typealias Kind = Type4MeTransferPayload.Mode.Kind

    func testBuiltInModesMapToIPhoneKinds() {
        XCTAssertEqual(MobileConfigExporter.transferMode(for: .direct)?.kind, Kind.quick)
        XCTAssertEqual(MobileConfigExporter.transferMode(for: .direct)?.id, Kind.quick)
        for (mode, kind) in [
            (ProcessingMode.formalWriting, Kind.formalWriting),
            (.agentMode, Kind.agentMode),
        ] {
            let transfer = MobileConfigExporter.transferMode(for: mode)
            XCTAssertEqual(transfer?.kind, kind)
            XCTAssertEqual(transfer?.id, kind)
            XCTAssertNil(transfer?.prompt, "an unedited prompt keeps the iPhone's own default")
        }
    }

    func testEditedBuiltInPromptTravels() {
        var mode = ProcessingMode.formalWriting
        mode.prompt = "  只改错别字：{text}  "
        let transfer = MobileConfigExporter.transferMode(for: mode)
        XCTAssertEqual(transfer?.kind, Kind.formalWriting)
        XCTAssertEqual(transfer?.prompt, "只改错别字：{text}")
    }

    func testIntelliSenseTravelsAsItsKindOnly() throws {
        let transfer = try XCTUnwrap(MobileConfigExporter.transferMode(for: .intelliSense))
        XCTAssertEqual(transfer.kind, Kind.intelliSense)
        XCTAssertEqual(transfer.id, Kind.intelliSense)
        XCTAssertNil(transfer.prompt, "the iPhone builds the Intelli Sense prompt itself")
    }

    func testMacOnlyModesStayOnTheMac() {
        XCTAssertNil(MobileConfigExporter.transferMode(for: .macAction))
        XCTAssertNil(MobileConfigExporter.transferMode(for: .selectionAsk))
        XCTAssertNil(MobileConfigExporter.transferMode(for: .commandMode))
        XCTAssertNil(MobileConfigExporter.transferMode(for: .promptOptimize))
        XCTAssertNil(MobileConfigExporter.transferMode(for: .smartDirect))
    }

    /// A mode the user made on the Mac, with a long prompt.
    private func userMode(prompt: String = ProcessingMode.formalWritingPromptTemplate) -> ProcessingMode {
        ProcessingMode(id: UUID(), name: "会议纪要", prompt: prompt, isBuiltin: false)
    }

    func testUserPromptModesTravelAsCustomWithStableIDs() throws {
        let source = userMode()
        let mode = try XCTUnwrap(MobileConfigExporter.transferMode(for: source))
        XCTAssertEqual(mode.kind, Kind.custom)
        XCTAssertEqual(mode.id, "mac-" + source.id.uuidString.lowercased())
        XCTAssertEqual(mode.prompt, source.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(mode.name, "会议纪要")
    }

    func testOnlyPhoneSuitedShippedModesTravel() {
        let kinds = ProcessingMode.defaults.compactMap(MobileConfigExporter.transferMode(for:)).map(\.kind)
        XCTAssertEqual(kinds.sorted(), [Kind.agentMode, Kind.formalWriting, Kind.intelliSense, Kind.quick, Kind.translation].sorted())
        XCTAssertNil(MobileConfigExporter.transferMode(for: .translateToChinese), "legacy translation records duplicate Translation")
    }

    func testTranslationCarriesTheMacTarget() throws {
        let japanese = try XCTUnwrap(MobileConfigExporter.transferMode(for: .translation(target: .japanese)))
        XCTAssertEqual(japanese.kind, Kind.translation)
        XCTAssertEqual(japanese.id, Kind.translation, "one translation mode, updated in place by later syncs")
        XCTAssertEqual(japanese.targetLanguage, "ja")
        XCTAssertNil(japanese.prompt, "the iPhone builds the prompt from the same template")
        XCTAssertEqual(MobileConfigExporter.transferMode(for: .translation())?.targetLanguage, "en")
    }

    func testCustomModeWithoutPromptIsSkipped() {
        XCTAssertNil(MobileConfigExporter.transferMode(for: userMode(prompt: "   ")))
    }

    /// Every default mode the iPhone can use, prompts included, stays within
    /// a dozen codes (about six seconds per round on the Mac).
    func testDefaultModesFitAHandfulOfCodes() throws {
        let modes = (ProcessingMode.defaults + [userMode()]).compactMap(MobileConfigExporter.transferMode(for:))
        XCTAssertFalse(modes.isEmpty)
        let payload = Type4MeTransferPayload(asr: nil, llm: nil, modes: modes)
        let frames = try Type4MeTransferCodec.encodeFrames(payload)
        XCTAssertLessThanOrEqual(frames.count, 12)
        var assembler = Type4MeTransferAssembler()
        var result: Type4MeTransferPayload?
        for frame in frames.reversed() {
            if case .complete(let decoded) = assembler.add(frame) { result = decoded }
        }
        XCTAssertEqual(result?.modes, modes)
    }

    /// The codes the export sheet draws decode back to the same text, at the
    /// size used for the largest parts.
    func testRenderedCodesDecode() throws {
        let modes = (ProcessingMode.defaults + [userMode()]).compactMap(MobileConfigExporter.transferMode(for:))
        let frames = try Type4MeTransferCodec.encodeFrames(Type4MeTransferPayload(asr: nil, llm: nil, modes: modes))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        for frame in frames {
            let image = try XCTUnwrap(MobileSyncPanel.qrImage(for: frame))
            let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let found = detector.features(in: CIImage(cgImage: cg)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            XCTAssertEqual(found, [frame])
        }
    }

    func testHotwordsDropBlanksAndRepeats() {
        XCTAssertEqual(
            MobileConfigExporter.hotwords(from: [" Claude ", "", "claude", "Type4Me", "  "]),
            ["Claude", "Type4Me"]
        )
    }

    func testSnippetsKeepOrderAndDropBlankTriggers() {
        let snippets = MobileConfigExporter.snippets(from: [
            (trigger: " cloud code ", value: "Claude Code"),
            (trigger: " ", value: "ignored"),
            (trigger: "jason", value: "JSON"),
        ])
        XCTAssertEqual(snippets, [
            .init(trigger: "cloud code", replacement: "Claude Code"),
            .init(trigger: "jason", replacement: "JSON"),
        ])
    }

    func testVocabularyOnlyPayload() throws {
        let payload = try XCTUnwrap(MobileConfigExporter.makePayload(
            asrs: [], defaultASR: nil, llms: [], defaultLLM: nil, modes: [],
            hotwords: ["Type4Me"], snippets: []
        ))
        XCTAssertEqual(payload.hotwords, ["Type4Me"])
        XCTAssertNil(payload.snippets)
        XCTAssertNil(MobileConfigExporter.makePayload(asrs: [], defaultASR: nil, llms: [], defaultLLM: nil, modes: []))
    }
}
