import XCTest
@testable import Type4Me

final class AudioStartTimingTests: XCTestCase {
    func testFormattedLineWithAllFieldsPresent() {
        let timing = AudioStartTiming(
            awaitIdle: .milliseconds(3),
            sessionEntry: .milliseconds(5),
            captureStartBegin: .milliseconds(8),
            deviceInput: .milliseconds(12),
            startRunning: .milliseconds(19),
            prepared: "hit",
            firstSample: .milliseconds(31),
            ready: .milliseconds(118),
            device: "builtIn"
        )

        let line = timing.formattedLine()
        let expected = "audio start timing awaitIdle=3ms sessionEntry=5ms captureStartBegin=8ms deviceInput=12ms startRunning=19ms prepared=hit firstSample=31ms ready=118ms device=builtIn"
        XCTAssertEqual(line, expected)
    }

    func testFormattedLineWithMissingFieldsUsesDash() {
        let timing = AudioStartTiming(
            awaitIdle: .milliseconds(2),
            sessionEntry: nil,
            captureStartBegin: .milliseconds(7),
            deviceInput: nil, // Prepared hit has no device input cost
            startRunning: .milliseconds(15),
            prepared: "hit",
            firstSample: nil,
            ready: .milliseconds(80),
            device: nil
        )

        let line = timing.formattedLine()
        let expected = "audio start timing awaitIdle=2ms sessionEntry=- captureStartBegin=7ms deviceInput=- startRunning=15ms prepared=hit firstSample=- ready=80ms device=-"
        XCTAssertEqual(line, expected)
    }

    func testDurationConversionRounding() {
        XCTAssertEqual(AudioStartTiming.formatDuration(nil), "-")
        XCTAssertEqual(AudioStartTiming.formatDuration(.zero), "0ms")
        XCTAssertEqual(AudioStartTiming.formatDuration(.milliseconds(100)), "100ms")
        XCTAssertEqual(AudioStartTiming.formatDuration(.seconds(1)), "1000ms")
    }
}
