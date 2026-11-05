import Foundation

/// The exact same net-score coordinate data as the existing in-App calibration
/// trend (7/30 civil days, trailing 7-day mean, 12 monthly means and 3-month
/// smoothing). Widget B behavior coverage is the *primary textual metric*;
/// this chart is supporting evidence, NEVER a replacement for assessment state.
public struct CalibrationWidgetCartesianPlot: Equatable, Sendable {
    public let values: [Double?]
    public let smooth: [Double?]
    public let tickLabels: [String]
}

public extension CalibrationWidgetProjection {
    /// Deterministic projection from already validated, privacy-reduced journal
    /// snapshots; missing/partial/excused-only assessments MUST remain gaps.
    static func cartesianPlot(from snapshot: CalibrationWidgetSnapshot,
                              period: CalibrationWidgetPeriod,
                              at now: Date = Date(),
                              calendar: Calendar = .current)
        -> CalibrationWidgetCartesianPlot? {
        guard let overview = overview(from: snapshot, at: now, calendar: calendar) else {
            return nil
        }
        if period == .year {
            let year = calendar.component(.year, from: now)
            // A valid-looking but stale/corrupt App Group snapshot may contain
            // future entries. Only elapsed local civil days can contribute.
            let lastElapsedDay = CalibrationDayCheckIn.dayID(for: now, calendar: calendar)
            let scores: [[Int]] = (1...12).map { month in
                let prefix = String(format: "%04d-%02d-", year, month)
                return snapshot.days.compactMap { day -> Int? in
                    day.dayID.hasPrefix(prefix) && day.dayID <= lastElapsedDay
                        ? day.netScore : nil
                }
            }
            let values: [Double?] = scores.map { items in
                items.isEmpty ? nil : Double(items.reduce(0, +)) / Double(items.count)
            }
            let smooth: [Double?] = values.indices.map { index in
                guard values[index] != nil else { return nil }
                let trailing = values[max(0, index - 2)...index].compactMap { $0 }
                return trailing.reduce(0, +) / Double(trailing.count)
            }
            return CalibrationWidgetCartesianPlot(
                values: values, smooth: smooth,
                tickLabels: (1...12).map { "\($0)月" })
        }

        let days = period == .week ? overview.weekDays : overview.monthDays
        let byID = Dictionary(uniqueKeysWithValues: snapshot.days.map { ($0.dayID, $0) })
        let values: [Double?] = days.map { $0.netScore.map(Double.init) }
        let smooth: [Double?] = days.map { day -> Double? in
            // The existing App mean is nil when THIS civil day has no real score.
            guard day.netScore != nil else { return nil }
            let parts = day.dayID.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let civilDate = calendar.date(from: DateComponents(
                    year: parts[0], month: parts[1], day: parts[2], hour: 12))
            else { return nil }
            let lastSeven: [Int] = (0..<7).compactMap { lookback in
                guard let previous = calendar.date(
                    byAdding: .day, value: -lookback, to: civilDate) else { return nil }
                let key = CalibrationDayCheckIn.dayID(for: previous, calendar: calendar)
                return byID[key]?.netScore
            }
            guard !lastSeven.isEmpty else { return nil }
            return Double(lastSeven.reduce(0, +)) / Double(lastSeven.count)
        }
        return CalibrationWidgetCartesianPlot(
            values: values, smooth: smooth,
            tickLabels: days.map { String($0.dayID.suffix(5)) })
    }
}
