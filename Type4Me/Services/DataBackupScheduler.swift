import Foundation

/// Keeps checking whether a backup is due for as long as the app runs (#302).
///
/// Type4Me is a menu bar app that can stay up for weeks. Checking only at launch
/// would leave a single snapshot from the day it started, however long the app
/// then ran.
///
/// `Task.sleep(for:)` measures on the continuous clock, which keeps counting while
/// the Mac is asleep. After a night with the lid closed the pending sleep has
/// already elapsed, so a check runs as soon as the app resumes, with no need to
/// observe wake notifications.
enum DataBackupScheduler {

    /// The longest sleep between checks. Waking at least this often is what makes
    /// the schedule self-correcting: a failed backup is retried within the hour,
    /// and a clock that jumps is noticed within the hour rather than a day later.
    static let maximumSleep: TimeInterval = 60 * 60

    /// Keeps a next due time only seconds away from turning into a busy loop.
    static let minimumSleep: TimeInterval = 60

    /// How long to sleep after a check has just run.
    ///
    /// Aims for the moment the next snapshot becomes due. If it is still due right
    /// after a check, that check failed; retrying every minute would only repeat
    /// the failure and flood the log, so it waits the maximum instead.
    static func nextCheckDelay(
        lastRun: Date?,
        now: Date,
        interval: TimeInterval = DataBackupManager.minimumInterval
    ) -> TimeInterval {
        guard let lastRun else { return maximumSleep }
        let untilDue = lastRun.addingTimeInterval(interval).timeIntervalSince(now)
        guard untilDue > 0 else { return maximumSleep }
        return min(max(untilDue, minimumSleep), maximumSleep)
    }

    /// Checks, sleeps and repeats until the task is cancelled.
    ///
    /// Time, sleeping and the check itself are injected so that the loop — not
    /// just its arithmetic — can be exercised over a simulated run of several days.
    static func run(
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(for: .seconds(seconds))
        },
        check: @escaping @Sendable (Date) -> Void = { date in
            DataBackupManager.runIfNeeded(now: date)
        },
        lastRun: @escaping @Sendable () -> Date? = { DataBackupManager.lastRun() }
    ) async {
        while !Task.isCancelled {
            check(now())
            let delay = nextCheckDelay(lastRun: lastRun(), now: now())
            do {
                try await sleep(delay)
            } catch {
                return
            }
        }
    }
}
