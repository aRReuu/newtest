import Foundation

/// A signed WidgetKit timeline process writes this score-free receipt to prove
/// that the extension decoded one exact generation of the shared snapshot.
public struct CalibrationWidgetReadReceipt: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public let version: Int
    public let period: CalibrationWidgetPeriod
    public let snapshotGeneratedAt: Date
    public let observedAt: Date

    public init(period: CalibrationWidgetPeriod, snapshotGeneratedAt: Date,
                observedAt: Date) {
        self.version = Self.currentVersion
        self.period = period
        self.snapshotGeneratedAt = snapshotGeneratedAt
        self.observedAt = observedAt
    }

    public var fileName: String {
        "calibration-widget-\(period.rawValue)-readback-v1.json"
    }

    public func verifies(snapshot: CalibrationWidgetSnapshot,
                         period: CalibrationWidgetPeriod, at now: Date) -> Bool {
        version == Self.currentVersion && self.period == period && snapshot.isValid &&
        snapshotGeneratedAt == snapshot.generatedAt &&
        observedAt.timeIntervalSince1970.isFinite &&
        observedAt >= snapshot.generatedAt.addingTimeInterval(-120) &&
        observedAt <= now.addingTimeInterval(120)
    }
}

/// A privacy-reduced projection of the existing CalibrationDayCheckIn journal.
/// Widgets must never infer assessment coverage from nullable net scores.
public enum CalibrationWidgetPeriod: String, Codable, Sendable, CaseIterable {
    case week, month, year
}

public enum CalibrationWidgetDayState: String, Codable, Sendable {
    case unrecorded, partial, finalized
}

public struct CalibrationWidgetDay: Codable, Equatable, Sendable, Identifiable {
    public let dayID: String
    public let assessedCount: Int
    public let state: CalibrationWidgetDayState
    public let netScore: Int?

    public var id: String { dayID }
    public var hasAssessment: Bool { assessedCount > 0 }
}

public struct CalibrationWidgetSnapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 2
    public let schemaVersion: Int
    public let generatedAt: Date
    public let timeZoneID: String
    public let calendarID: String
    public let days: [CalibrationWidgetDay]

    /// Defensive validation at the widget boundary; a malformed shared cache is never repaired.
    public var isValid: Bool {
        guard schemaVersion == Self.currentVersion, days.count <= 431 else { return false }
        var seen = Set<String>()
        for day in days {
            let parts = day.dayID.split(separator: "-", omittingEmptySubsequences: false)
            // Validate the actual Gregorian civil date, not merely yyyy-mm-dd syntax.
            // Corrupted shared cache input must fail closed before it reaches a Widget.
            guard parts.count == 3, parts[0].count == 4, parts[1].count == 2,
                  parts[2].count == 2, day.dayID.utf8.allSatisfy({
                      $0 == 45 || (48...57).contains($0)
                  }), let year = Int(parts[0]), let month = Int(parts[1]),
                  let dayOfMonth = Int(parts[2]),
                  (1...9999).contains(year), (1...12).contains(month),
                  (1...31).contains(dayOfMonth),
                  seen.insert(day.dayID).inserted,
                  (0...4).contains(day.assessedCount),
                  day.netScore.map({ (-5...5).contains($0) }) ?? true else {
                return false
            }
            var gregorian = Calendar(identifier: .gregorian)
            gregorian.timeZone = TimeZone(secondsFromGMT: 0)!
            guard let date = gregorian.date(from: DateComponents(
                      year: year, month: month, day: dayOfMonth)) else { return false }
            let actual = gregorian.dateComponents([.year, .month, .day], from: date)
            guard actual.year == year, actual.month == month,
                  actual.day == dayOfMonth else { return false }
            switch day.state {
            case .unrecorded:
                guard day.assessedCount == 0, day.netScore == nil else { return false }
            case .partial:
                guard (1...3).contains(day.assessedCount), day.netScore == nil else {
                    return false
                }
            case .finalized:
                guard day.assessedCount == 4 else { return false }
                // Explicitly excused days can be finalized without a numeric score.
            }
        }
        return true
    }
}

public struct CalibrationWidgetMonth: Equatable, Sendable, Identifiable {
    public let month: Int
    public let elapsedDays: Int
    public let assessedDays: Int
    public let finalizedDays: Int
    public let partialDays: Int

    public var id: Int { month }
}

public struct CalibrationWidgetOverview: Equatable, Sendable {
    /// Oldest-to-newest seven local civil days, including today.
    public let weekDays: [CalibrationWidgetDay]
    /// Oldest-to-newest thirty local civil days, including today.
    public let monthDays: [CalibrationWidgetDay]
    /// January through December of the current local year; no future-day denominators.
    public let yearMonths: [CalibrationWidgetMonth]
    public let generatedAt: Date

    public static func assessedDays(_ days: [CalibrationWidgetDay]) -> Int {
        days.filter(\.hasAssessment).count
    }

    public static func finalizedDays(_ days: [CalibrationWidgetDay]) -> Int {
        days.filter { $0.state == .finalized }.count
    }

    public static func partialDays(_ days: [CalibrationWidgetDay]) -> Int {
        days.filter { $0.state == .partial }.count
    }
}

/// One deterministic, portable calculator shared by the App and WidgetKit extension.
/// It NEVER mutates the source ledger, FSRS, goals, reminders or backup data.
public enum CalibrationWidgetProjection {
    /// Keep just enough status history to render the current year and rolling windows.
    /// No goal descriptions, mood values, event reasons or original note bytes leave the App.
    public static func snapshot(from entries: [CalibrationDayCheckIn],
                                at now: Date = Date(),
                                calendar: Calendar = .current) -> CalibrationWidgetSnapshot {
        let today = calendar.startOfDay(for: now)
        let oldest = calendar.date(byAdding: .day, value: -430, to: today) ?? today
        let firstKey = CalibrationDayCheckIn.dayID(for: oldest, calendar: calendar)
        let lastKey = CalibrationDayCheckIn.dayID(for: today, calendar: calendar)
        var byDay = [String: CalibrationWidgetDay]()
        for entry in entries where entry.dayID >= firstKey && entry.dayID <= lastKey {
            // Only four scored behaviors contribute to B-scheme coverage.
            let explicit = entry.assessments.filter {
                $0.outcome != .unrecorded
            }.count
            // B-scheme coverage is independent from historic V1 mood closeout.
            // Four explicit behaviors count as assessed; historic numeric scores
            // remain nil unless the ORIGINAL legacy day was finalized.
            let state: CalibrationWidgetDayState =
                explicit == CalibrationIndicator.behaviorIndicators.count ? .finalized
                : (explicit > 0 ? .partial : .unrecorded)
            let score = entry.isComplete ? (try? entry.finalizedScore())?.netScore : nil
            byDay[entry.dayID] = CalibrationWidgetDay(
                dayID: entry.dayID, assessedCount: explicit,
                state: state, netScore: score)
        }
        return CalibrationWidgetSnapshot(
            schemaVersion: CalibrationWidgetSnapshot.currentVersion,
            generatedAt: now, timeZoneID: calendar.timeZone.identifier,
            calendarID: String(describing: calendar.identifier),
            days: byDay.values.sorted { $0.dayID < $1.dayID })
    }

    /// A nil result is an explicit safety state: absent/corrupt/stale-zone data stays unavailable.
    public static func overview(from snapshot: CalibrationWidgetSnapshot,
                                at now: Date = Date(),
                                calendar: Calendar = .current) -> CalibrationWidgetOverview? {
        guard snapshot.isValid,
              snapshot.timeZoneID == calendar.timeZone.identifier,
              snapshot.calendarID == String(describing: calendar.identifier),
              snapshot.generatedAt <= now.addingTimeInterval(3600) else { return nil }
        let today = calendar.startOfDay(for: now)
        let byID = Dictionary(uniqueKeysWithValues: snapshot.days.map { ($0.dayID, $0) })
        func day(_ value: Date) -> CalibrationWidgetDay {
            let key = CalibrationDayCheckIn.dayID(for: value, calendar: calendar)
            return byID[key] ?? CalibrationWidgetDay(
                dayID: key, assessedCount: 0, state: .unrecorded, netScore: nil)
        }
        func rolling(_ count: Int) -> [CalibrationWidgetDay] {
            (0..<count).compactMap { index in
                let offset = index - (count - 1)
                guard let value = calendar.date(byAdding: .day, value: offset, to: today)
                else { return nil }
                return day(value)
            }
        }
        let year = calendar.component(.year, from: today)
        guard let yearStart = calendar.date(from: DateComponents(year: year, month: 1, day: 1)),
              let elapsed = calendar.dateComponents([.day], from: yearStart, to: today).day,
              (0...366).contains(elapsed) else { return nil }
        var monthCounts = Array(repeating: (elapsed: 0, assessed: 0, final: 0, partial: 0),
                                count: 12)
        for offset in 0...elapsed {
            guard let civilDay = calendar.date(byAdding: .day, value: offset, to: yearStart)
            else { return nil }
            let month = calendar.component(.month, from: civilDay) - 1
            guard (0..<12).contains(month) else { return nil }
            let info = day(civilDay)
            monthCounts[month].elapsed += 1
            if info.hasAssessment { monthCounts[month].assessed += 1 }
            if info.state == .finalized { monthCounts[month].final += 1 }
            if info.state == .partial { monthCounts[month].partial += 1 }
        }
        return CalibrationWidgetOverview(
            weekDays: rolling(7), monthDays: rolling(30),
            yearMonths: monthCounts.enumerated().map { index, count in
                CalibrationWidgetMonth(
                    month: index + 1, elapsedDays: count.elapsed,
                    assessedDays: count.assessed, finalizedDays: count.final,
                    partialDays: count.partial)
            },
            generatedAt: snapshot.generatedAt)
    }
}
