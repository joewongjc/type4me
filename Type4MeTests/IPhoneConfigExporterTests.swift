import CoreImage
import XCTest
import Type4MeTransferCore
@testable import Type4Me

/// Which Mac modes travel to the iPhone, and as what.
final class IPhoneConfigExporterTests: XCTestCase {
    private typealias Kind = Type4MeTransferPayload.Mode.Kind

    func testBuiltInModesMapToIPhoneKinds() {
        XCTAssertEqual(IPhoneConfigExporter.transferMode(for: .direct)?.kind, Kind.quick)
        XCTAssertEqual(IPhoneConfigExporter.transferMode(for: .direct)?.id, Kind.quick)
        for (mode, kind) in [
            (ProcessingMode.formalWriting, Kind.formalWriting),
            (.agentMode, Kind.agentMode),
        ] {
            let transfer = IPhoneConfigExporter.transferMode(for: mode)
            XCTAssertEqual(transfer?.kind, kind)
            XCTAssertEqual(transfer?.id, kind)
            XCTAssertNil(transfer?.prompt, "an unedited prompt keeps the iPhone's own default")
        }
    }

    func testEditedBuiltInPromptTravels() {
        var mode = ProcessingMode.formalWriting
        mode.prompt = "  只改错别字：{text}  "
        let transfer = IPhoneConfigExporter.transferMode(for: mode)
        XCTAssertEqual(transfer?.kind, Kind.formalWriting)
        XCTAssertEqual(transfer?.prompt, "只改错别字：{text}")
    }

    func testMacOnlyModesStayOnTheMac() {
        XCTAssertNil(IPhoneConfigExporter.transferMode(for: .macAction))
        XCTAssertNil(IPhoneConfigExporter.transferMode(for: .selectionAsk))
        XCTAssertNil(IPhoneConfigExporter.transferMode(for: .commandMode))
        XCTAssertNil(IPhoneConfigExporter.transferMode(for: .intelliSense))
        XCTAssertNil(IPhoneConfigExporter.transferMode(for: .promptOptimize))
        XCTAssertNil(IPhoneConfigExporter.transferMode(for: .smartDirect))
    }

    /// A mode the user made on the Mac, with a long prompt.
    private func userMode(prompt: String = ProcessingMode.formalWritingPromptTemplate) -> ProcessingMode {
        ProcessingMode(id: UUID(), name: "会议纪要", prompt: prompt, isBuiltin: false)
    }

    func testUserPromptModesTravelAsCustomWithStableIDs() throws {
        let source = userMode()
        let mode = try XCTUnwrap(IPhoneConfigExporter.transferMode(for: source))
        XCTAssertEqual(mode.kind, Kind.custom)
        XCTAssertEqual(mode.id, "mac-" + source.id.uuidString.lowercased())
        XCTAssertEqual(mode.prompt, source.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(mode.name, "会议纪要")
    }

    func testOnlyPhoneSuitedShippedModesTravel() {
        let kinds = ProcessingMode.defaults.compactMap(IPhoneConfigExporter.transferMode(for:)).map(\.kind)
        XCTAssertEqual(kinds.sorted(), [Kind.agentMode, Kind.formalWriting, Kind.quick, Kind.translation].sorted())
        XCTAssertNil(IPhoneConfigExporter.transferMode(for: .translateToChinese), "legacy translation records duplicate Translation")
    }

    func testTranslationCarriesTheMacTarget() throws {
        let japanese = try XCTUnwrap(IPhoneConfigExporter.transferMode(for: .translation(target: .japanese)))
        XCTAssertEqual(japanese.kind, Kind.translation)
        XCTAssertEqual(japanese.id, Kind.translation, "one translation mode, updated in place by later syncs")
        XCTAssertEqual(japanese.targetLanguage, "ja")
        XCTAssertNil(japanese.prompt, "the iPhone builds the prompt from the same template")
        XCTAssertEqual(IPhoneConfigExporter.transferMode(for: .translation())?.targetLanguage, "en")
    }

    func testCustomModeWithoutPromptIsSkipped() {
        XCTAssertNil(IPhoneConfigExporter.transferMode(for: userMode(prompt: "   ")))
    }

    /// Every default mode the iPhone can use, prompts included, stays within
    /// a dozen codes (about six seconds per round on the Mac).
    func testDefaultModesFitAHandfulOfCodes() throws {
        let modes = (ProcessingMode.defaults + [userMode()]).compactMap(IPhoneConfigExporter.transferMode(for:))
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
        let modes = (ProcessingMode.defaults + [userMode()]).compactMap(IPhoneConfigExporter.transferMode(for:))
        let frames = try Type4MeTransferCodec.encodeFrames(Type4MeTransferPayload(asr: nil, llm: nil, modes: modes))
        let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
        for frame in frames {
            let image = try XCTUnwrap(IPhoneExportSheet.qrImage(for: frame))
            let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let found = detector.features(in: CIImage(cgImage: cg)).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            XCTAssertEqual(found, [frame])
        }
    }
}
