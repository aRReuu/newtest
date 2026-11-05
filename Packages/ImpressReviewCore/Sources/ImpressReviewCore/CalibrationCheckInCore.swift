import Foundation

/// Four live categories. Custom and mood are retained only for old ledgers.
public enum CalibrationIndicator: String, Codable, CaseIterable, Sendable {
    case sleep, exercise, nutrition, reading
    case custom, mood // archived V1 identities, never new UI inputs
    public static let behaviorIndicators: [Self] = [.sleep, .exercise, .nutrition, .reading]
    public static let legacyBehaviorIndicators: [Self] = [.sleep, .exercise, .nutrition, .custom]
}

/// User-editable targets. The day's snapshot is preserved after any goal edit.
public struct CalibrationGoals: Codable, Equatable, Sendable {
    public var sleep: String
    public var exercise: String
    public var nutrition: String
    public var reading: String
    /// Historical caption: persisted for legacy records but no longer editable.
    public var custom: String

    public init(sleep: String = "按自己制定的作息计划休息",
                exercise: String = "完成计划中的运动",
                nutrition: String = "遵守今天的饮食安排",
                reading: String = "完成今天的阅读计划",
                custom: String = "完成今天的自定义目标") {
        self.sleep = sleep
        self.exercise = exercise
        self.nutrition = nutrition
        self.reading = reading
        self.custom = custom
    }

    private enum CodingKeys: String, CodingKey {
        case sleep, exercise, nutrition, reading, custom
    }

    /// Legacy checkins-v1.json lacks reading. Never relabel old custom targets.
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        sleep = try fields.decode(String.self, forKey: .sleep)
        exercise = try fields.decode(String.self, forKey: .exercise)
        nutrition = try fields.decode(String.self, forKey: .nutrition)
        reading = try fields.decodeIfPresent(String.self, forKey: .reading)
            ?? "完成今天的阅读计划"
        custom = try fields.decodeIfPresent(String.self, forKey: .custom)
            ?? "完成今天的自定义目标"
    }

    public func title(for kind: CalibrationIndicator) -> String {
        switch kind {
        case .sleep: return sleep
        case .exercise: return exercise
        case .nutrition: return nutrition
        case .reading: return reading
        case .custom: return custom
        case .mood: return "历史情绪（已停用）"
        }
    }

    public func validate() throws {
        for kind in CalibrationIndicator.behaviorIndicators
        where title(for: kind).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw CalibrationCheckInError.emptyGoal
        }
    }
}

public enum CalibrationCheckInError: Error, Equatable, Sendable {
    case invalidIndicator
    case invalidMood
    case emptyGoal
    case invalidManualNote
}

public struct CalibrationDayCheckIn: Codable, Equatable, Sendable {
    public let dayID: String
    public private(set) var goalsSnapshot: CalibrationGoals
    /// Four predetermined behavior assessments with stable IDs, even if the user renames goals.
    public private(set) var assessments: [CalibrationTaskAssessment]
    /// Explicit mood assessment is required to close the day, but never affects score.
    public private(set) var moodAssessed: Bool
    public private(set) var moodLevel: Int?
    /// When today's legacy item retires, keep its original outcome for audit.
    public private(set) var retiredCustomAssessment: CalibrationTaskAssessment?
    /// Zero or one manual +1 / -1, each with a concrete reason.
    public private(set) var bonusNote: String?
    public private(set) var deductionNote: String?

    public init(dayID: String, goals: CalibrationGoals) throws {
        try goals.validate()
        self.dayID = dayID
        self.goalsSnapshot = goals
        self.assessments = CalibrationIndicator.behaviorIndicators.map {
            CalibrationTaskAssessment(taskID: $0.rawValue, outcome: .unrecorded)
        }
        self.moodAssessed = false
        self.moodLevel = nil
        self.retiredCustomAssessment = nil
        self.bonusNote = nil
        self.deductionNote = nil
        _ = try CalibrationScoreCore.summarize(rawRecord)
    }

    public var isLegacyDay: Bool {
        assessments.contains { $0.taskID == CalibrationIndicator.custom.rawValue } &&
        !assessments.contains { $0.taskID == CalibrationIndicator.reading.rawValue }
    }

    public var liveIndicatorsForThisRecord: [CalibrationIndicator] {
        isLegacyDay ? CalibrationIndicator.legacyBehaviorIndicators :
            CalibrationIndicator.behaviorIndicators
    }

    /// Only today's legacy day may migrate; history stays on the old scheme.
    /// The former fourth assessment is archived, NEVER scored as reading.
    public func migratedToReading(goals: CalibrationGoals) throws -> Self {
        // A completed legacy day is durable history, even when it is today's day.
        // Converting its retired custom outcome into an unrecorded reading
        // would falsely reopen a CLOSED record that the store must reject.
        guard isLegacyDay && !isComplete else { return self }
        try goals.validate()
        var result = self
        result.goalsSnapshot.reading = goals.reading
        result.retiredCustomAssessment = assessments.first {
            $0.taskID == CalibrationIndicator.custom.rawValue
        }
        result.assessments = assessments.map {
            $0.taskID == CalibrationIndicator.custom.rawValue
            ? CalibrationTaskAssessment(taskID: CalibrationIndicator.reading.rawValue,
                                        outcome: .unrecorded)
            : $0
        }
        return result
    }

    /// Changing a still-open day reopens only goals that actually changed.
    /// Completed days retain their earlier goal snapshots.
    public mutating func replaceGoalsForOpenDay(_ next: CalibrationGoals) throws {
        try next.validate()
        guard !isComplete else { return }
        for kind in liveIndicatorsForThisRecord
        where goalsSnapshot.title(for: kind) != next.title(for: kind) {
            try setOutcome(.unrecorded, for: kind)
        }
        goalsSnapshot = next
    }

    public var pendingIndicators: [CalibrationIndicator] {
        var pending = liveIndicatorsForThisRecord.filter {
            outcome(for: $0) == .unrecorded
        }
        // Legacy dates preserve their original completion status and score.
        if isLegacyDay && !moodAssessed { pending.append(.mood) }
        return pending
    }

    public var isComplete: Bool { pendingIndicators.isEmpty }

    public func outcome(for kind: CalibrationIndicator) -> CalibrationTaskOutcome {
        assessments.first(where: { $0.taskID == kind.rawValue })?.outcome ?? .unrecorded
    }

    public mutating func setOutcome(_ outcome: CalibrationTaskOutcome,
                                    for kind: CalibrationIndicator) throws {
        guard kind != .mood,
              let index = assessments.firstIndex(where: { $0.taskID == kind.rawValue })
        else { throw CalibrationCheckInError.invalidIndicator }
        assessments[index] = CalibrationTaskAssessment(taskID: kind.rawValue, outcome: outcome)
    }

    /// nil with assessed=true is an explicit skip; assessed=false is still pending.
    public mutating func setMood(_ level: Int?, assessed: Bool = true) throws {
        if let level, !(1...5).contains(level) { throw CalibrationCheckInError.invalidMood }
        moodLevel = assessed ? level : nil
        moodAssessed = assessed
    }

    public mutating func setManualAdjustment(positive: Bool, reason: String?) throws {
        let trimmed = reason?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, trimmed.count > 120 { throw CalibrationCheckInError.invalidManualNote }
        if positive { bonusNote = trimmed?.isEmpty == true ? nil : trimmed }
        else { deductionNote = trimmed?.isEmpty == true ? nil : trimmed }
    }

    public var rawRecord: CalibrationDailyRecord {
        var extra = [CalibrationExtraEvent]()
        if bonusNote != nil {
            extra.append(CalibrationExtraEvent(eventKey: "bonus.unscheduled",
                                               adjustment: .addOne))
        }
        if deductionNote != nil {
            extra.append(CalibrationExtraEvent(eventKey: "deduction.unscheduled",
                                               adjustment: .subtractOne))
        }
        return CalibrationDailyRecord(dayID: dayID, assessments: assessments,
                                      extraEvents: extra, moodLevel: moodLevel)
    }

    /// Four live inputs; archived V1 days retain their five-field closeout.
    /// Fully excused days are completed but may have no score; they are not failures.
    public func finalizedScore() throws -> CalibrationDailySummary {
        let summary = try CalibrationScoreCore.summarize(rawRecord)
        guard !isComplete else { return summary }
        return CalibrationDailySummary(dayID: dayID, netScore: nil,
                                       plannedCount: summary.plannedCount,
                                       completedCount: summary.completedCount,
                                       missedCount: summary.missedCount,
                                       unrecordedCount: summary.unrecordedCount,
                                       extraScore: summary.extraScore,
                                       taskBalance: nil, moodLevel: summary.moodLevel)
    }

    /// Common calendar is selected by the caller. No UTC day inference.
    public static func dayID(for date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }
}

/// Pure notification planning; iOS presentation and authorization happen in the app adapter.
/// At most 2 non-repeating alerts/day for 14 days (28 slots), leaving room for FSRS.
public struct CalibrationReminderSlot: Equatable, Sendable {
    public let identifier: String
    public let dayID: String
    public let fireAt: Date
}

public enum CalibrationReminderPlan {
    public static let identifierPrefix = "impress.calibration.v1."
    public static func isManaged(_ id: String) -> Bool { id.hasPrefix(identifierPrefix) }

    public static func make(now: Date, calendar: Calendar = .current,
                            completedDays: Set<String> = [], horizonDays: Int = 14,
                            hours: [Int] = [20, 22]) -> [CalibrationReminderSlot] {
        guard (1...28).contains(horizonDays), !hours.isEmpty,
              hours.allSatisfy({ (0...23).contains($0) }) else { return [] }
        let first = calendar.startOfDay(for: now)
        var result = [CalibrationReminderSlot]()
        for dayOffset in 0..<horizonDays {
            guard let start = calendar.date(byAdding: .day, value: dayOffset, to: first) else { continue }
            let key = CalibrationDayCheckIn.dayID(for: start, calendar: calendar)
            if completedDays.contains(key) { continue }
            for hour in hours.sorted() {
                guard let target = calendar.date(bySettingHour: hour, minute: 0,
                                                 second: 0, of: start),
                      target > now else { continue }
                let id = identifierPrefix + key + "." + String(format: "%02d", hour)
                result.append(CalibrationReminderSlot(identifier: id, dayID: key, fireAt: target))
            }
        }
        return result
    }
}
