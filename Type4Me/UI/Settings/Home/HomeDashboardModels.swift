import Foundation

/// Maps history rows to the current modes. Rows written before mode IDs were
/// recorded only carry the mode's name at the time, in whatever language the
/// app used then; a name that matches no current mode is not counted.
enum HomeModeUsage {

    static func resolve(modeId: String?, modeName: String?, modes: [ProcessingMode]) -> UUID? {
        if let modeId {
            guard let uuid = UUID(uuidString: modeId), modes.contains(where: { $0.id == uuid }) else { return nil }
            return uuid
        }
        guard let modeName else {
            return modes.contains(where: { $0.id == ProcessingMode.directId }) ? ProcessingMode.directId : nil
        }
        return modes.first { mode in
            mode.name == modeName
                || AppLanguage.allCases.contains { mode.localizedDisplayName(for: $0) == modeName }
        }?.id
    }

    static func counts(rows: [HistoryStore.ModeUsageRow], modes: [ProcessingMode]) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        for row in rows {
            if let id = resolve(modeId: row.modeId, modeName: row.modeName, modes: modes) {
                result[id, default: 0] += row.count
            }
        }
        return result
    }
}

/// Cumulative characters per day, from the first day of use through today,
/// plus the most recent character-count milestones on that curve. Covering
/// only the time actually used keeps a new user's chart from being mostly
/// empty and a long-time user's chart from being cut off.
struct HomeGrowthSummary: Equatable {

    struct Milestone: Equatable {
        let value: Int
        let date: Date
        /// Horizontal position on the curve, 0 at the start and 1 at today.
        let position: Double
    }

    static let milestones = [1_000, 5_000, 10_000, 20_000, 50_000, 100_000, 200_000, 500_000, 1_000_000]
    static let maxShownMilestones = 2

    let startDate: Date?
    /// Running total at the end of each day; the curve starts from zero just
    /// before the first day.
    let cumulative: [Int]
    let shownMilestones: [Milestone]

    init(
        activityDays: [HistoryStore.ActivityDay],
        today: Date = Date(),
        calendar inputCalendar: Calendar = .current
    ) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = inputCalendar.timeZone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"

        let localToday = calendar.startOfDay(for: today)
        var perDay: [Date: Int] = [:]
        for day in activityDays where day.recordCount > 0 {
            guard let date = formatter.date(from: day.dayIdentifier).map(calendar.startOfDay(for:)),
                  date <= localToday else { continue }
            perDay[date, default: 0] += day.characterCount
        }
        guard let start = perDay.keys.min() else {
            startDate = nil
            cumulative = []
            shownMilestones = []
            return
        }
        let dayCount = (calendar.dateComponents([.day], from: start, to: localToday).day ?? 0) + 1

        var totals: [Int] = []
        var reached: [(value: Int, dayIndex: Int, date: Date)] = []
        var running = 0
        for index in 0..<dayCount {
            guard let date = calendar.date(byAdding: .day, value: index, to: start) else { continue }
            let before = running
            running += perDay[date] ?? 0
            totals.append(running)
            for value in Self.milestones where value > before && value <= running {
                reached.append((value, index, date))
            }
        }

        startDate = start
        cumulative = totals
        shownMilestones = reached.suffix(Self.maxShownMilestones).map {
            Milestone(value: $0.value, date: $0.date, position: Self.position(ofDay: $0.dayIndex, dayCount: dayCount))
        }
    }

    /// Day `i` ends at (i + 1) / dayCount, so the first day rises from zero
    /// instead of starting at the left edge.
    static func position(ofDay index: Int, dayCount: Int) -> Double {
        Double(index + 1) / Double(max(dayCount, 1))
    }
}
