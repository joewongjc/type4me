import XCTest
@testable import Type4Me

/// Review on #304: backups were only checked at launch, so a menu bar app left
/// running for weeks kept a single snapshot. Every test uses a temporary root and
/// its own defaults suite, never the user's real data.
final class DataBackupSchedulerTests: XCTestCase {

    private var root: URL!
    private let day: TimeInterval = 24 * 60 * 60
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("t4m-scheduler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "t4m-scheduler-\(UUID().uuidString)")!
    }

    // MARK: - Next check delay

    func testSleepsUntilTheNextSnapshotIsDue() {
        let now = start.addingTimeInterval(day - 30 * 60)
        XCTAssertEqual(
            DataBackupScheduler.nextCheckDelay(lastRun: start, now: now), 30 * 60, accuracy: 0.001
        )
    }

    func testNeverSleepsLongerThanTheMaximumSoTheScheduleSelfCorrects() {
        XCTAssertEqual(
            DataBackupScheduler.nextCheckDelay(lastRun: start, now: start),
            DataBackupScheduler.maximumSleep
        )
    }

    func testDoesNotSpinWhenTheNextSnapshotIsSecondsAway() {
        XCTAssertEqual(
            DataBackupScheduler.nextCheckDelay(lastRun: start, now: start.addingTimeInterval(day - 5)),
            DataBackupScheduler.minimumSleep
        )
    }

    /// The delay is computed right after a check. Still being due at that point
    /// means the check failed; retrying every minute would only repeat the failure.
    func testAFailedCheckIsRetriedWithinTheHourNotEveryMinute() {
        XCTAssertEqual(
            DataBackupScheduler.nextCheckDelay(lastRun: nil, now: start),
            DataBackupScheduler.maximumSleep
        )
        XCTAssertEqual(
            DataBackupScheduler.nextCheckDelay(lastRun: start, now: start.addingTimeInterval(3 * day)),
            DataBackupScheduler.maximumSleep
        )
    }

    /// Moving the clock backwards leaves a last-run time in the future. Trusting it
    /// would suspend backups until real time caught up.
    func testALastRunInTheFutureDoesNotSuspendBackups() {
        let defaults = isolatedDefaults()
        defaults.set(start.addingTimeInterval(365 * day).timeIntervalSince1970, forKey: "tf_lastDataBackupAt")
        XCTAssertTrue(DataBackupManager.isDue(now: start, defaults: defaults))
    }

    // MARK: - The loop

    /// Drives the real loop and the real backup against a fake clock for three
    /// simulated days without a relaunch. Proving the check fires again after 24
    /// hours of continuous running is the point, not just that `isDue()` is correct.
    func testContinuousRunKeepsTakingDailySnapshotsWithoutARelaunch() async throws {
        let data = root.appendingPathComponent("data", isDirectory: true)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let file = data.appendingPathComponent("modes.json")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let backups = root.appendingPathComponent("backups", isDirectory: true)

        nonisolated(unsafe) let defaults = isolatedDefaults()
        let clock = FakeClock(start)
        let checks = Counter()
        let day = self.day
        let start = self.start
        let horizon = start.addingTimeInterval(3 * day + 60)

        await DataBackupScheduler.run(
            now: { clock.now },
            sleep: { seconds in
                let before = clock.now
                clock.advance(by: seconds)
                let after = clock.now
                guard after < horizon else { throw CancellationError() }
                // The data changes once per simulated day, so every due check has
                // something new to copy.
                let dayBefore = Int(before.timeIntervalSince(start) / day)
                let dayAfter = Int(after.timeIntervalSince(start) / day)
                if dayAfter != dayBefore {
                    try String(repeating: "x", count: dayAfter + 1)
                        .write(to: file, atomically: true, encoding: .utf8)
                }
            },
            check: { date in
                checks.increment()
                DataBackupManager.runIfNeeded(now: date, defaults: defaults, source: data, root: backups)
            },
            lastRun: { DataBackupManager.lastRun(defaults: defaults) }
        )

        XCTAssertEqual(
            DataBackupManager.snapshots(in: backups).map(\.lastPathComponent),
            (0...3).map { DataBackupManager.name(for: start.addingTimeInterval(Double($0) * day)) },
            "expected the launch snapshot plus one for each simulated day"
        )
        XCTAssertLessThanOrEqual(
            checks.value, 3 * 24 + 2,
            "the loop should wake about hourly, not spin"
        )
    }

    func testStopsWhenCancelled() async {
        let task = Task {
            await DataBackupScheduler.run(check: { _ in }, lastRun: { nil })
        }
        task.cancel()
        await task.value
    }

    // MARK: - Helpers

    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date
        init(_ start: Date) { current = start }
        var now: Date { lock.lock(); defer { lock.unlock() }; return current }
        func advance(by seconds: TimeInterval) {
            lock.lock(); defer { lock.unlock() }
            current = current.addingTimeInterval(seconds)
        }
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.lock(); defer { lock.unlock() }; return count }
        func increment() { lock.lock(); defer { lock.unlock() }; count += 1 }
    }
}
