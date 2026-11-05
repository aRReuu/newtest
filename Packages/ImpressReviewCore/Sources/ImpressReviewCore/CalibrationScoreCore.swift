import Foundation

/// Self-reported behavior outcomes. No entry means unknown, never a failure.
public enum CalibrationTaskOutcome: String, Codable, CaseIterable, Sendable {
    case completed
    case missed
    case excused       // Rest days / explicitly waived tasks: neither +1 nor -1.
    case unrecorded    // Scheduled but not yet assessed: do not finalize the day.
}

public struct CalibrationTaskAssessment: Codable, Equatable, Sendable {
    public let taskID: String
    public let outcome: CalibrationTaskOutcome

    public init(taskID: String, outcome: CalibrationTaskOutcome) {
        self.taskID = taskID
        self.outcome = outcome
    }
}

public enum CalibrationAdjustment: Int, Codable, Sendable {
    case addOne = 1
    case subtractOne = -1
}

/// Explicit, unscheduled behavior: at most one +1 and one -1 per day.
/// A distinct eventKey avoids counting a planned task for a second time.
public struct CalibrationExtraEvent: Codable, Equatable, Sendable {
    public let eventKey: String
    public let adjustment: CalibrationAdjustment

    public init(eventKey: String, adjustment: CalibrationAdjustment) {
        self.eventKey = eventKey
        self.adjustment = adjustment
    }
}

/// A local Gregorian civil day (yyyy-MM-dd), never an inferred UTC instant.
/// Mood (1...5) is observational and NEVER contributes to the task score.
public struct CalibrationDailyRecord: Codable, Equatable, Sendable {
    public let dayID: String
    public let assessments: [CalibrationTaskAssessment]
    public let extraEvents: [CalibrationExtraEvent]
    public let moodLevel: Int?

    public init(dayID: String, assessments: [CalibrationTaskAssessment],
                extraEvents: [CalibrationExtraEvent] = [], moodLevel: Int? = nil) {
        self.dayID = dayID
        self.assessments = assessments
        self.extraEvents = extraEvents
        self.moodLevel = moodLevel
    }
}

public struct CalibrationDailySummary: Equatable, Sendable {
    public let dayID: String
    /// Nil if some planned tasks are unrecorded or there are no assessed events.
    public let netScore: Int?
    public let plannedCount: Int
    public let completedCount: Int
    public let missedCount: Int
    public let unrecordedCount: Int
    public let extraScore: Int
    /// Planned-task completion balance; excludes extras and excused tasks.
    /// Nil until every planned task has an explicit outcome.
    public let taskBalance: Double?
    public let moodLevel: Int?
}

public struct CalibrationDayPoint: Equatable, Sendable {
    public let dayID: String
    public let netScore: Int?
    /// Mean of recorded, finalized days within the trailing 7 calendar days.
    /// Missing days are not zeros. Nil if this date itself is missing.
    public let trailingSevenDayMean: Double?
}

public struct CalibrationMonthPoint: Equatable, Sendable {
    public let year: Int
    public let month: Int
    /// Average daily net score, NOT sum of points across the month.
    public let averageDailyScore: Double?
    public let recordedDays: Int
}

public enum CalibrationScoreError: Error, Equatable, Sendable {
    case invalidDay
    case invalidRange
    case invalidMood
    case emptyIdentifier
    case duplicateTask
    case duplicateExtra
    case extraOverlapsTask
    case excessiveExtraAdjustments
    case duplicateDay
}

/// Pure calculator: no persistence, notifications, network, FSRS state or UI.
public enum CalibrationScoreCore {
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    public static func summarize(_ record: CalibrationDailyRecord) throws -> CalibrationDailySummary {
        _ = try date(for: record.dayID)
        if let mood = record.moodLevel, !(1...5).contains(mood) {
            throw CalibrationScoreError.invalidMood
        }
        var taskIDs = Set<String>()
        for task in record.assessments {
            let id = task.taskID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { throw CalibrationScoreError.emptyIdentifier }
            guard taskIDs.insert(id).inserted else { throw CalibrationScoreError.duplicateTask }
        }
        var eventIDs = Set<String>()
        var positive = 0
        var negative = 0
        for event in record.extraEvents {
            let id = event.eventKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { throw CalibrationScoreError.emptyIdentifier }
            guard eventIDs.insert(id).inserted else { throw CalibrationScoreError.duplicateExtra }
            guard !taskIDs.contains(id) else { throw CalibrationScoreError.extraOverlapsTask }
            switch event.adjustment {
            case .addOne: positive += 1
            case .subtractOne: negative += 1
            }
        }
        guard positive <= 1 && negative <= 1 else {
            throw CalibrationScoreError.excessiveExtraAdjustments
        }

        let completed = record.assessments.filter { $0.outcome == .completed }.count
        let missed = record.assessments.filter { $0.outcome == .missed }.count
        let unrecorded = record.assessments.filter { $0.outcome == .unrecorded }.count
        let planned = completed + missed + unrecorded
        let extraScore = positive - negative
        let finalized = unrecorded == 0 && (completed + missed + positive + negative > 0)
        return CalibrationDailySummary(
            dayID: record.dayID,
            netScore: finalized ? completed - missed + extraScore : nil,
            plannedCount: planned,
            completedCount: completed,
            missedCount: missed,
            unrecordedCount: unrecorded,
            extraScore: extraScore,
            taskBalance: finalized && planned > 0 ? Double(completed - missed) / Double(planned) : nil,
            moodLevel: record.moodLevel
        )
    }

    /// For week/month charts: one point per local civil day, including missing days as gaps.
    /// The mean uses the last 7 calendar days, rather than the last 7 recorded entries.
    public static func dailyTrend(_ records: [CalibrationDailyRecord],
                                  from firstDay: String, through lastDay: String) throws -> [CalibrationDayPoint] {
        let start = try date(for: firstDay)
        let end = try date(for: lastDay)
        let count = utcCalendar.dateComponents([.day], from: start, to: end).day ?? -1
        guard (0...366).contains(count) else { throw CalibrationScoreError.invalidRange }
        let summaries = try uniqueSummaries(records)
        let scored = summaries.compactMap { summary -> (Date, Int)? in
            guard let score = summary.netScore, let when = try? date(for: summary.dayID) else { return nil }
            return (when, score)
        }
        let byDay = Dictionary(uniqueKeysWithValues: summaries.map { ($0.dayID, $0) })
        return (0...count).compactMap { offset -> CalibrationDayPoint? in
            guard let current = utcCalendar.date(byAdding: .day, value: offset, to: start) else { return nil }
            let key = key(for: current)
            let dailyScore = byDay[key]?.netScore
            guard let dailyScore else {
                return CalibrationDayPoint(dayID: key, netScore: nil, trailingSevenDayMean: nil)
            }
            let sevenDayStart = utcCalendar.date(byAdding: .day, value: -6, to: current)!
            let values = scored.compactMap { time, value -> Int? in
                (sevenDayStart...current).contains(time) ? value : nil
            }
            let mean = Double(values.reduce(0, +)) / Double(values.count)
            return CalibrationDayPoint(dayID: key, netScore: dailyScore,
                                       trailingSevenDayMean: mean)
        }
    }

    /// The home-screen overview is the current LOCAL Monday–Sunday week, not
    /// a rolling 7-day range. Missing, unfinished, excused-only and future
    /// civil days are nil (never 0). Uses the existing scoring authority;
    /// no chart code is allowed to recompute or normalize net scores.
    public static func mondayWeekTrend(_ records: [CalibrationDailyRecord],
                                       now: Date = Date(),
                                       calendar: Calendar = .current) throws -> [CalibrationDayPoint] {
        var weekCalendar = calendar
        weekCalendar.firstWeekday = 2 // Monday regardless of device's default first weekday
        weekCalendar.minimumDaysInFirstWeek = 4
        guard let start = weekCalendar.dateInterval(of: .weekOfYear, for: now)?.start,
              let last = weekCalendar.date(byAdding: .day, value: 6, to: start) else {
            throw CalibrationScoreError.invalidRange
        }
        let firstKey = CalibrationDayCheckIn.dayID(for: start, calendar: weekCalendar)
        let lastKey = CalibrationDayCheckIn.dayID(for: last, calendar: weekCalendar)
        let todayKey = CalibrationDayCheckIn.dayID(for: now, calendar: weekCalendar)
        return try dailyTrend(records, from: firstKey, through: lastKey).map { point in
            guard point.dayID <= todayKey else {
                return CalibrationDayPoint(dayID: point.dayID, netScore: nil,
                                           trailingSevenDayMean: nil)
            }
            return point
        }
    }

    /// For the year chart: compare months using means of finalized daily scores.
    /// Months with no usable entries remain gaps, rather than invented zeroes.
    public static func monthlyTrend(_ records: [CalibrationDailyRecord], year: Int) throws -> [CalibrationMonthPoint] {
        guard (1...9999).contains(year) else { throw CalibrationScoreError.invalidRange }
        let summaries = try uniqueSummaries(records)
        return (1...12).map { month in
            let prefix = String(format: "%04d-%02d-", year, month)
            let values = summaries.filter { $0.dayID.hasPrefix(prefix) }.compactMap(\.netScore)
            return CalibrationMonthPoint(year: year, month: month,
                                         averageDailyScore: values.isEmpty ? nil : Double(values.reduce(0, +)) / Double(values.count),
                                         recordedDays: values.count)
        }
    }

    private static func uniqueSummaries(_ records: [CalibrationDailyRecord]) throws -> [CalibrationDailySummary] {
        var seen = Set<String>()
        return try records.map { record in
            guard seen.insert(record.dayID).inserted else { throw CalibrationScoreError.duplicateDay }
            return try summarize(record)
        }
    }

    private static func date(for value: String) throws -> Date {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              value.utf8.allSatisfy({ $0 == 45 || (48...57).contains($0) }),
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              let date = utcCalendar.date(from: DateComponents(year: year, month: month, day: day))
        else { throw CalibrationScoreError.invalidDay }
        let result = utcCalendar.dateComponents([.year, .month, .day], from: date)
        guard result.year == year, result.month == month, result.day == day else {
            throw CalibrationScoreError.invalidDay
        }
        return date
    }

    private static func key(for date: Date) -> String {
        let result = utcCalendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", result.year!, result.month!, result.day!)
    }
}
