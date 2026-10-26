import XCTest
@testable import Type4Me

final class VolcASRClientTests: XCTestCase {
    func testTranscriptAccumulatorReplacesSuccessiveRevisions() {
        var accumulator = VolcTranscriptAccumulator()
        let versions = [
            String(repeating: "a", count: 18),
            String(repeating: "b", count: 20),
            String(repeating: "c", count: 21),
        ]

        let outputs = versions.map { text in
            accumulator.apply(
                result: VolcASRResult(
                    text: text,
                    utterances: [VolcUtterance(text: text, definite: false)]
                ),
                isFinal: false
            )
        }

        XCTAssertEqual(outputs.map(\.transcript.composedText), versions)
        XCTAssertEqual(outputs.map(\.transcript.authoritativeText), versions)
        XCTAssertEqual(outputs.map { $0.transcript.composedText.count }, [18, 20, 21])
        XCTAssertEqual(outputs.map(\.transition), [.snapshot, .revision, .revision])
    }

    func testTranscriptAccumulatorHoldsSnapshotAcrossTransientBlank() {
        var accumulator = VolcTranscriptAccumulator()
        let original = makeAccumulation(text: "original", using: &accumulator)
        let blank = accumulator.apply(
            result: VolcASRResult(text: "", utterances: []),
            isFinal: false
        )
        let revised = makeAccumulation(text: "revised", using: &accumulator)

        XCTAssertEqual(blank.transcript, original.transcript)
        XCTAssertEqual(blank.transition, .blankHeld)
        XCTAssertEqual(revised.transcript.composedText, "revised")
    }

    func testTranscriptAccumulatorPreservesConfirmedPrefixAndPartialSuffix() {
        var accumulator = VolcTranscriptAccumulator()
        let accumulation = accumulator.apply(
            result: VolcASRResult(
                text: "first second",
                utterances: [
                    VolcUtterance(text: "first ", definite: true),
                    VolcUtterance(text: "second", definite: false),
                ]
            ),
            isFinal: false
        )

        XCTAssertEqual(accumulation.transcript.confirmedSegments, ["first "])
        XCTAssertEqual(accumulation.transcript.partialText, "second")
        XCTAssertEqual(accumulation.transcript.composedText, "first second")
        XCTAssertEqual(
            accumulation.transcript.composedText,
            accumulation.transcript.authoritativeText
        )
    }

    func testTranscriptAccumulatorReplacesDefiniteTextAtSameSegmentCount() {
        var accumulator = VolcTranscriptAccumulator()
        _ = accumulator.apply(
            result: VolcASRResult(
                text: "old sentence",
                utterances: [VolcUtterance(text: "old sentence", definite: true)]
            ),
            isFinal: false
        )
        let revised = accumulator.apply(
            result: VolcASRResult(
                text: "new sentence",
                utterances: [VolcUtterance(text: "new sentence", definite: true)]
            ),
            isFinal: false
        )

        XCTAssertEqual(revised.transcript.confirmedSegments, ["new sentence"])
        XCTAssertEqual(revised.transcript.composedText, "new sentence")
        XCTAssertEqual(revised.transition, .revision)
    }

    func testTranscriptAccumulatorFallsBackToUtterances() {
        var accumulator = VolcTranscriptAccumulator()
        let accumulation = accumulator.apply(
            result: VolcASRResult(
                text: "",
                utterances: [
                    VolcUtterance(text: "hello ", definite: true),
                    VolcUtterance(text: "world", definite: false),
                ]
            ),
            isFinal: false
        )

        XCTAssertEqual(accumulation.transcript.confirmedSegments, ["hello "])
        XCTAssertEqual(accumulation.transcript.partialText, "world")
        XCTAssertEqual(accumulation.transcript.authoritativeText, "hello world")
    }

    func testTranscriptAccumulatorUsesWholeSnapshotWhenConfirmedPrefixDoesNotAlign() {
        var accumulator = VolcTranscriptAccumulator()
        let accumulation = accumulator.apply(
            result: VolcASRResult(
                text: "corrected whole sentence",
                utterances: [
                    VolcUtterance(text: "stale prefix ", definite: true),
                    VolcUtterance(text: "sentence", definite: false),
                ]
            ),
            isFinal: false
        )

        XCTAssertEqual(accumulation.transcript.confirmedSegments, [])
        XCTAssertEqual(accumulation.transcript.partialText, "corrected whole sentence")
        XCTAssertEqual(accumulation.transcript.composedText, "corrected whole sentence")
    }

    func testTranscriptAccumulatorFinalizesLatestOrHeldSnapshot() {
        var accumulator = VolcTranscriptAccumulator()
        _ = makeAccumulation(text: "streaming", using: &accumulator)
        let heldFinal = accumulator.apply(
            result: VolcASRResult(text: "", utterances: []),
            isFinal: true
        )
        let authoritativeFinal = accumulator.apply(
            result: VolcASRResult(
                text: "final text",
                utterances: [VolcUtterance(text: "final text", definite: true)]
            ),
            isFinal: true
        )

        XCTAssertEqual(heldFinal.transcript.confirmedSegments, ["streaming"])
        XCTAssertEqual(heldFinal.transcript.partialText, "")
        XCTAssertEqual(heldFinal.transcript.authoritativeText, "streaming")
        XCTAssertTrue(heldFinal.transcript.isFinal)
        XCTAssertEqual(heldFinal.transition, .final)

        XCTAssertEqual(authoritativeFinal.transcript.confirmedSegments, ["final text"])
        XCTAssertEqual(authoritativeFinal.transcript.composedText, "final text")
        XCTAssertEqual(authoritativeFinal.transition, .final)
    }

    func testTranscriptAccumulatorResetDropsPreviousSession() {
        var accumulator = VolcTranscriptAccumulator()
        _ = makeAccumulation(text: "previous session", using: &accumulator)
        accumulator.reset()

        let blank = accumulator.apply(
            result: VolcASRResult(text: "", utterances: []),
            isFinal: false
        )

        XCTAssertEqual(blank.transcript, .empty)
        XCTAssertEqual(blank.transition, .snapshot)
    }

    func testAuthHeadersUseSingleAPIKey() {
        let headers = VolcProtocol.authHeaders(
            authentication: .apiKey("my-api-key"),
            resourceId: VolcanoASRConfig.resourceIdSeedASR,
            connectId: "connect-123"
        )

        XCTAssertEqual(headers["X-Api-Key"], "my-api-key")
        XCTAssertEqual(headers["X-Api-Resource-Id"], VolcanoASRConfig.resourceIdSeedASR)
        XCTAssertEqual(headers["X-Api-Connect-Id"], "connect-123")
    }

    func testAPIKeyHeadersOmitLegacyCredentialHeaders() {
        let headers = VolcProtocol.authHeaders(
            authentication: .apiKey("my-api-key"),
            resourceId: VolcanoASRConfig.resourceIdSeedASR,
            connectId: "connect-123"
        )

        XCTAssertNil(headers["X-Api-App-Key"])
        XCTAssertNil(headers["X-Api-Access-Key"])
        XCTAssertEqual(headers.count, 3)
    }

    func testLegacyAuthHeadersUseAppIDAndAccessToken() {
        let headers = VolcProtocol.authHeaders(
            authentication: .legacy(appKey: "my-app-id", accessKey: "my-access-token"),
            resourceId: VolcanoASRConfig.resourceIdSeedASR,
            connectId: "connect-123"
        )

        XCTAssertNil(headers["X-Api-Key"])
        XCTAssertEqual(headers["X-Api-App-Key"], "my-app-id")
        XCTAssertEqual(headers["X-Api-Access-Key"], "my-access-token")
        XCTAssertEqual(headers.count, 4)
    }

    func testConfigInfersLegacyAuthForExistingCredentials() throws {
        let config = try XCTUnwrap(VolcanoASRConfig(credentials: [
            "appKey": "my-app-id",
            "accessKey": "my-access-token",
            "resourceId": VolcanoASRConfig.resourceIdSeedASR,
        ]))

        XCTAssertEqual(config.authMode, VolcanoASRConfig.authModeLegacy)
        XCTAssertEqual(config.appKey, "my-app-id")
        XCTAssertEqual(config.accessKey, "my-access-token")
        XCTAssertNil(config.apiKey)
    }

    func testExplicitAPIKeyModeWinsWhenBothCredentialSetsExist() throws {
        let config = try XCTUnwrap(VolcanoASRConfig(credentials: [
            "authMode": VolcanoASRConfig.authModeAPIKey,
            "apiKey": "my-api-key",
            "appKey": "my-app-id",
            "accessKey": "my-access-token",
        ]))

        XCTAssertEqual(config.authMode, VolcanoASRConfig.authModeAPIKey)
        XCTAssertEqual(config.apiKey, "my-api-key")
        XCTAssertNil(config.appKey)
        XCTAssertNil(config.accessKey)
    }

    func testWebSocketUpgradeProbeMessageIsIgnored() {
        let message = #"Bad Request("error", "cannot upgrade to websocket: websocket: the client is not using the websocket protocol: 'upgrade' token not found in 'Connection' header")"#

        XCTAssertTrue(VolcASRError.isWebSocketUpgradeProbeMessage(message))
    }

    func testNormalVendorErrorIsNotIgnored() {
        XCTAssertFalse(VolcASRError.isWebSocketUpgradeProbeMessage("invalid access key"))
    }

    private func makeAccumulation(
        text: String,
        using accumulator: inout VolcTranscriptAccumulator
    ) -> VolcTranscriptAccumulation {
        accumulator.apply(
            result: VolcASRResult(
                text: text,
                utterances: [VolcUtterance(text: text, definite: false)]
            ),
            isFinal: false
        )
    }
}
