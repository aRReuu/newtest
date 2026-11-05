import XCTest
@testable import ImpressReviewCore

final class CalibrationScoreCoreTests: XCTestCase {
    private func task(_ id: String, _ outcome: CalibrationTaskOutcome) -> CalibrationTaskAssessment {
        CalibrationTaskAssessment(taskID: id, outcome: outcome)
    }

    private func day(_ day: String, _ tasks: [CalibrationTaskAssessment],
                     extra: [CalibrationExtraEvent] = [], mood: Int? = nil) -> CalibrationDailyRecord {
        CalibrationDailyRecord(dayID: day, assessments: tasks, extraEvents: extra, moodLevel: mood)
    }

    func testCompletedMissedAndManualAdjustment() throws {
        let record = day("2026-10-18", [task("sleep", .completed), task("exercise", .missed),
                                        task("food", .completed)],
                         extra: [CalibrationExtraEvent(eventKey: "unplanned_snacking", adjustment: .subtractOne)], mood: 2)
        let result = try CalibrationScoreCore.summarize(record)
        XCTAssertEqual(result.netScore, 0) // +1 -1 +1 -1
        XCTAssertEqual(result.plannedCount, 3)
        XCTAssertEqual(result.taskBalance!, 1.0 / 3.0, accuracy: 0.00001)
        XCTAssertEqual(result.moodLevel, 2)
    }

    func testMoodDoesNotPunishOrReward() throws {
        let tasks = [task("sleep", .completed)]
        let poor = try CalibrationScoreCore.summarize(day("2026-10-18", tasks, mood: 1))
        let good = try CalibrationScoreCore.summarize(day("2026-10-18", tasks, mood: 5))
        XCTAssertEqual(poor.netScore, good.netScore)
        XCTAssertEqual(poor.netScore, 1)
    }

    func testUnrecordedDoesNotBecomeMinusOneOrZero() throws {
        let result = try CalibrationScoreCore.summarize(day("2026-10-18", [task("sleep", .completed), task("exercise", .unrecorded)]))
        XCTAssertNil(result.netScore)
        XCTAssertNil(result.taskBalance)
        XCTAssertEqual(result.unrecordedCount, 1)
        XCTAssertEqual(result.completedCount, 1)
    }

    func testExcusedAndEmptyHaveNoPenalty() throws {
        XCTAssertNil(try CalibrationScoreCore.summarize(day("2026-10-18", [task("exercise", .excused)])).netScore)
        XCTAssertEqual(try CalibrationScoreCore.summarize(day("2026-10-18", [task("sleep", .completed), task("exercise", .excused)])).netScore, 1)
        XCTAssertNil(try CalibrationScoreCore.summarize(day("2026-10-18", [], mood: 4)).netScore)
    }

    func testExtrasAllowedOnlyOneEachAndNotForScheduledTask() throws {
        let oneOfEach = day("2026-10-18", [], extra: [
            CalibrationExtraEvent(eventKey: "helped_colleague", adjustment: .addOne),
            CalibrationExtraEvent(eventKey: "unplanned_snack", adjustment: .subtractOne)])
        XCTAssertEqual(try CalibrationScoreCore.summarize(oneOfEach).netScore, 0)

        let duplicateSign = day("2026-10-18", [], extra: [
            CalibrationExtraEvent(eventKey: "a", adjustment: .addOne),
            CalibrationExtraEvent(eventKey: "b", adjustment: .addOne)])
        XCTAssertThrowsError(try CalibrationScoreCore.summarize(duplicateSign)) { error in
            XCTAssertEqual(error as? CalibrationScoreError, .excessiveExtraAdjustments)
        }

        let overlapping = day("2026-10-18", [task("food", .missed)], extra: [
            CalibrationExtraEvent(eventKey: "food", adjustment: .subtractOne)])
        XCTAssertThrowsError(try CalibrationScoreCore.summarize(overlapping)) { error in
            XCTAssertEqual(error as? CalibrationScoreError, .extraOverlapsTask)
        }
    }

    func testDuplicateEntriesAndInvalidDaysAreRejected() throws {
        XCTAssertThrowsError(try CalibrationScoreCore.summarize(day("2026-02-30", [task("sleep", .completed)])))
        XCTAssertThrowsError(try CalibrationScoreCore.summarize(day("2026-10-18", [task("sleep", .completed), task("sleep", .missed)])))
        XCTAssertThrowsError(try CalibrationScoreCore.summarize(day("2026-10-18", [], mood: 6)))
        let records = [day("2026-10-18", [task("sleep", .completed)]), day("2026-10-18", [task("food", .completed)])]
        XCTAssertThrowsError(try CalibrationScoreCore.dailyTrend(records, from: "2026-10-18", through: "2026-10-19")) { error in
            XCTAssertEqual(error as? CalibrationScoreError, .duplicateDay)
        }
    }

    func testSevenDayTrendUsesCalendarDaysNotRecordedRows() throws {
        let records = [
            day("2026-10-01", [task("sleep", .completed)]),
            day("2026-10-02", [task("sleep", .missed)]),
            day("2026-10-09", [task("sleep", .completed)])
        ]
        let data = try CalibrationScoreCore.dailyTrend(records, from: "2026-10-01", through: "2026-10-09")
        XCTAssertEqual(data.count, 9)
        XCTAssertNil(data[3].netScore)
        XCTAssertNil(data[3].trailingSevenDayMean)
        XCTAssertEqual(data[1].trailingSevenDayMean!, 0, accuracy: 0.00001)
        XCTAssertEqual(data[8].trailingSevenDayMean!, 1, accuracy: 0.00001) // Oct 1–2 outside last 7 dates
    }

    func testMondayWeekAcrossYearNeverInventsMissingOrFutureScores() throws {
        var local = Calendar(identifier: .gregorian)
        local.timeZone = TimeZone(identifier: "America/Phoenix")!
        local.firstWeekday = 1 // Explicitly NOT Monday: home must override this.
        let friday = try XCTUnwrap(local.date(from:
            DateComponents(year: 2027, month: 1, day: 1, hour: 12)))
        let records = [
            day("2026-12-28", [task("sleep", .completed)]),
            day("2026-12-29", [task("exercise", .missed)]),
            day("2026-12-30", [task("sleep", .unrecorded)]),
            day("2026-12-31", [task("sleep", .excused)]),
            day("2027-01-01", [task("sleep", .completed),
                               task("exercise", .missed)]),
            day("2027-01-02", [task("sleep", .completed)]) // FUTURE
        ]
        let week = try CalibrationScoreCore.mondayWeekTrend(
            records, now: friday, calendar: local)
        XCTAssertEqual(week.map(\.dayID), [
            "2026-12-28", "2026-12-29", "2026-12-30", "2026-12-31",
            "2027-01-01", "2027-01-02", "2027-01-03"
        ])
        XCTAssertEqual(week.map(\.netScore), [1, -1, nil, nil, 0, nil, nil])
        XCTAssertNil(week[2].netScore)
        XCTAssertNil(week[3].netScore)
        XCTAssertNil(week[5].netScore)
        XCTAssertNil(week[6].netScore)
    }

    func testMonthMeansDoNotAccumulateAndMissingMonthsAreNil() throws {
        let records = [
            day("2026-01-10", [task("sleep", .completed)]),
            day("2026-01-11", [task("sleep", .completed), task("exercise", .completed)]),
            day("2026-03-01", [task("sleep", .missed)])
        ]
        let trend = try CalibrationScoreCore.monthlyTrend(records, year: 2026)
        XCTAssertEqual(trend.count, 12)
        XCTAssertEqual(trend[0].recordedDays, 2)
        XCTAssertEqual(trend[0].averageDailyScore!, 1.5, accuracy: 0.00001)
        XCTAssertNil(trend[1].averageDailyScore)
        XCTAssertEqual(trend[2].averageDailyScore!, -1, accuracy: 0.00001)
    }
}
