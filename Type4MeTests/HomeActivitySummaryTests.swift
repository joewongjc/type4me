import XCTest
@testable import Type4Me

final class HomeActivitySummaryTests: XCTestCase {
    func testGrowthStartsAtFirstUseAndRunsThroughToday() {
        let fixture = makeFixture()
        let days = [
            activityDay(-3, calendar: fixture.calendar, today: fixture.today, characters: 300),
            activityDay(-1, calendar: fixture.calendar, today: fixture.today, characters: 200),
        ]

        let summary = HomeGrowthSummary(activityDays: days, today: fixture.today, calendar: fixture.calendar)

        XCTAssertEqual(summary.cumulative, [300, 300, 500, 500])
        XCTAssertEqual(summary.startDate, fixture.calendar.date(byAdding: .day, value: -3, to: fixture.calendar.startOfDay(for: fixture.today)))
    }

    func testGrowthShowsLatestTwoMilestonesOnTheCurve() {
        let fixture = makeFixture()
        let days = [
            activityDay(-9, calendar: fixture.calendar, today: fixture.today, characters: 1_500),
            activityDay(-5, calendar: fixture.calendar, today: fixture.today, characters: 4_000),
            activityDay(0, calendar: fixture.calendar, today: fixture.today, characters: 6_000),
        ]

        let summary = HomeGrowthSummary(activityDays: days, today: fixture.today, calendar: fixture.calendar)

        XCTAssertEqual(summary.shownMilestones.map(\.value), [5_000, 10_000])
        XCTAssertEqual(summary.shownMilestones.first?.position ?? 0, 5.0 / 10.0, accuracy: 0.0001)
        XCTAssertEqual(summary.shownMilestones.last?.position ?? 0, 1, accuracy: 0.0001)
    }

    func testGrowthIsEmptyWithoutActivity() {
        let summary = HomeGrowthSummary(activityDays: [])

        XCTAssertNil(summary.startDate)
        XCTAssertTrue(summary.cumulative.isEmpty)
    }

    func testSummarizesActiveAndLongestStreaks() {
        let fixture = makeFixture()
        let days = [
            activityDay(-8, calendar: fixture.calendar, today: fixture.today),
            activityDay(-7, calendar: fixture.calendar, today: fixture.today),
            activityDay(-3, calendar: fixture.calendar, today: fixture.today),
            activityDay(-2, calendar: fixture.calendar, today: fixture.today),
            activityDay(-1, calendar: fixture.calendar, today: fixture.today),
            activityDay(0, calendar: fixture.calendar, today: fixture.today),
        ]

        let summary = HomeActivitySummary(
            activityDays: days,
            today: fixture.today,
            calendar: fixture.calendar
        )

        XCTAssertEqual(summary.activeDays, 6)
        XCTAssertEqual(summary.currentStreak, 4)
        XCTAssertEqual(summary.longestStreak, 4)
    }

    func testYesterdayKeepsCurrentStreakUntilTodayHasActivity() {
        let fixture = makeFixture()
        let days = [
            activityDay(-3, calendar: fixture.calendar, today: fixture.today),
            activityDay(-2, calendar: fixture.calendar, today: fixture.today),
            activityDay(-1, calendar: fixture.calendar, today: fixture.today),
        ]

        let summary = HomeActivitySummary(
            activityDays: days,
            today: fixture.today,
            calendar: fixture.calendar
        )

        XCTAssertEqual(summary.currentStreak, 3)
        XCTAssertEqual(summary.longestStreak, 3)
    }

    func testInactiveRecentDaysResetCurrentStreak() {
        let fixture = makeFixture()
        let summary = HomeActivitySummary(
            activityDays: [
                activityDay(-4, calendar: fixture.calendar, today: fixture.today),
                activityDay(-3, calendar: fixture.calendar, today: fixture.today),
            ],
            today: fixture.today,
            calendar: fixture.calendar
        )

        XCTAssertEqual(summary.currentStreak, 0)
        XCTAssertEqual(summary.longestStreak, 2)
    }

    func testStreakCalculationWithNonGregorianSystemCalendar() {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let today = gregorian.date(from: DateComponents(
            year: 2026, month: 8, day: 25, hour: 12
        ))!

        var buddhistCalendar = Calendar(identifier: .buddhist)
        buddhistCalendar.timeZone = gregorian.timeZone

        let days = [
            HistoryStore.ActivityDay(dayIdentifier: "2026-08-23", recordCount: 1),
            HistoryStore.ActivityDay(dayIdentifier: "2026-08-24", recordCount: 2),
            HistoryStore.ActivityDay(dayIdentifier: "2026-08-25", recordCount: 1),
        ]

        let summary = HomeActivitySummary(
            activityDays: days,
            today: today,
            calendar: buddhistCalendar
        )

        XCTAssertEqual(summary.activeDays, 3)
        XCTAssertEqual(summary.currentStreak, 3)
        XCTAssertEqual(summary.longestStreak, 3)
    }

    private func makeFixture() -> (calendar: Calendar, today: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 60 * 60)!
        let today = calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 25, hour: 12
        ))!
        return (calendar, today)
    }

    private func activityDay(
        _ offset: Int,
        calendar: Calendar,
        today: Date,
        characters: Int = 0
    ) -> HistoryStore.ActivityDay {
        let date = calendar.date(byAdding: .day, value: offset, to: today)!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return HistoryStore.ActivityDay(
            dayIdentifier: formatter.string(from: date),
            recordCount: 1,
            characterCount: characters
        )
    }
}
