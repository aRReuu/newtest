import XCTest
@testable import ImpressReviewCore

final class CalibrationCheckInCoreTests: XCTestCase {
    private func newDay(_ day: String = "2026-10-18") throws -> CalibrationDayCheckIn {
        try CalibrationDayCheckIn(dayID: day, goals: CalibrationGoals())
    }

    func testFourFixedInputsFinalizeWithoutMood() throws {
        var review = try newDay()
        XCTAssertEqual(review.pendingIndicators.count, 4)
        XCTAssertEqual(CalibrationIndicator.behaviorIndicators,
                       [.sleep, .exercise, .nutrition, .reading])
        for kind in CalibrationIndicator.behaviorIndicators {
            try review.setOutcome(.completed, for: kind)
        }
        XCTAssertTrue(review.isComplete)
        XCTAssertEqual(try review.finalizedScore().netScore, 4)
        XCTAssertThrowsError(try review.setOutcome(.completed, for: .custom))
    }

    func testAllFourExcusedAreCompletedWithoutFakeZeroScore() throws {
        var review = try newDay()
        for kind in CalibrationIndicator.behaviorIndicators {
            try review.setOutcome(.excused, for: kind)
        }
        XCTAssertTrue(review.isComplete)
        XCTAssertNil(try review.finalizedScore().netScore)
    }

    func testUnrecordedDayCannotObtainAFinalScore() throws {
        var review = try newDay()
        try review.setOutcome(.completed, for: .sleep)
        XCTAssertFalse(review.isComplete)
        XCTAssertNil(try review.finalizedScore().netScore)
        XCTAssertEqual(review.pendingIndicators.count, 3)
    }

    func testReadingIDAndLegacyCustomAreDistinctAndMigratedOnlyExplicitly() throws {
        var current = try CalibrationDayCheckIn(dayID: "2026-10-22",
            goals: CalibrationGoals(reading: "今日阅读一章"))
        for indicator in [CalibrationIndicator.sleep, .exercise, .nutrition] {
            try current.setOutcome(.excused, for: indicator)
        }
        try current.setOutcome(.completed, for: .reading)
        XCTAssertFalse(current.isLegacyDay)
        XCTAssertEqual(Set(current.assessments.map(\.taskID)).count, 4)
        let data = try JSONEncoder().encode(current)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any])
        var rows = try XCTUnwrap(object["assessments"] as? [[String: Any]])
        let idx = try XCTUnwrap(rows.firstIndex(where: {
            ($0["taskID"] as? String) == "reading"
        }))
        rows[idx]["taskID"] = "custom"
        object["assessments"] = rows
        var goals = try XCTUnwrap(object["goalsSnapshot"] as? [String: Any])
        goals.removeValue(forKey: "reading")
        goals["custom"] = "旧自定义目标"
        object["goalsSnapshot"] = goals
        object["moodAssessed"] = true
        let legacy = try JSONDecoder().decode(CalibrationDayCheckIn.self,
            from: JSONSerialization.data(withJSONObject: object))
        XCTAssertTrue(legacy.isLegacyDay)
        XCTAssertEqual(legacy.goalsSnapshot.custom, "旧自定义目标")
        XCTAssertEqual(legacy.outcome(for: .custom), .completed)
        XCTAssertTrue(legacy.isComplete)
        XCTAssertEqual(try legacy.finalizedScore().netScore, 1)
        let stillClosed = try legacy.migratedToReading(
            goals: CalibrationGoals(reading: "新阅读目标"))
        XCTAssertEqual(stillClosed, legacy,
            "Already CLOSED legacy assessments remain historical facts")

        // An unfinished legacy day may migrate to the new fourth input.
        // Mood was previously part of the legacy closeout gate; without an
        // assessed mood the old day is OPEN even when its four tasks are set.
        var unfinishedJSON = object
        unfinishedJSON["moodAssessed"] = false
        let unfinished = try JSONDecoder().decode(CalibrationDayCheckIn.self,
            from: JSONSerialization.data(withJSONObject: unfinishedJSON))
        XCTAssertFalse(unfinished.isComplete)
        let converted = try unfinished.migratedToReading(
            goals: CalibrationGoals(reading: "新阅读目标"))
        XCTAssertFalse(converted.isLegacyDay)
        XCTAssertEqual(converted.outcome(for: .reading), .unrecorded)
        XCTAssertEqual(converted.retiredCustomAssessment?.outcome, .completed)
        XCTAssertEqual(converted.goalsSnapshot.reading, "新阅读目标")
        XCTAssertNil(try converted.finalizedScore().netScore)
    }

    func testBonusAndPenaltyRequireSpecificReasonAndRemainBounded() throws {
        var review = try newDay()
        for kind in CalibrationIndicator.behaviorIndicators {
            try review.setOutcome(.missed, for: kind)
        }
        try review.setMood(2)
        try review.setManualAdjustment(positive: true, reason: "  帮助别人解决问题 ")
        try review.setManualAdjustment(positive: false, reason: "多吃了不在计划内的零食")
        XCTAssertEqual(review.bonusNote, "帮助别人解决问题")
        XCTAssertEqual(try review.finalizedScore().netScore, -4) // -4 + 1 - 1
        try review.setManualAdjustment(positive: true, reason: nil)
        XCTAssertEqual(try review.finalizedScore().netScore, -5)
        XCTAssertThrowsError(try review.setManualAdjustment(
            positive: true, reason: String(repeating: "a", count: 121)))
    }

    func testReminderPlanStopsForDoneTodayButContinuesTomorrow() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let comps = DateComponents(timeZone: cal.timeZone, year: 2026, month: 10, day: 18, hour: 19, minute: 0)
        let now = cal.date(from: comps)!
        let today = CalibrationDayCheckIn.dayID(for: now, calendar: cal)
        let all = CalibrationReminderPlan.make(now: now, calendar: cal, horizonDays: 14)
        XCTAssertEqual(all.count, 28)
        XCTAssertEqual(all.filter { $0.dayID == today }.count, 2)
        let afterDone = CalibrationReminderPlan.make(now: now, calendar: cal,
                                                     completedDays: [today], horizonDays: 14)
        XCTAssertEqual(afterDone.count, 26)
        XCTAssertFalse(afterDone.contains(where: { $0.dayID == today }))
        XCTAssertEqual(afterDone.filter { $0.dayID == "2026-10-19" }.count, 2)
    }

    func testReminderPlanDoesNotScheduleExpiredTimesOrExceedCapacity() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 18, hour: 21))!
        let future = CalibrationReminderPlan.make(now: now, calendar: cal, horizonDays: 14)
        XCTAssertEqual(future.count, 27)
        XCTAssertTrue(future.allSatisfy { $0.fireAt > now })
        XCTAssertEqual(Set(future.map(\.identifier)).count, future.count)
        XCTAssertEqual(CalibrationReminderPlan.make(now: now, horizonDays: 100).count, 0)
        XCTAssertTrue(CalibrationReminderPlan.isManaged(future[0].identifier))
        XCTAssertFalse(CalibrationReminderPlan.isManaged("impress.v3.smart.123"))
    }

    func testChangingOpenDayGoalInvalidatesOnlyChangedItem() throws {
        var review = try newDay()
        try review.setOutcome(.completed, for: .sleep)
        try review.setOutcome(.missed, for: .reading)
        try review.replaceGoalsForOpenDay(
            CalibrationGoals(reading: "完成一次明确的阅读计划"))
        XCTAssertEqual(review.outcome(for: .sleep), .completed)
        XCTAssertEqual(review.outcome(for: .reading), .unrecorded)
        XCTAssertFalse(review.isComplete)
        XCTAssertEqual(review.goalsSnapshot.reading, "完成一次明确的阅读计划")
    }

    func testCompletedDayGoalSnapshotCannotBeRewritten() throws {
        var review = try newDay()
        for kind in CalibrationIndicator.behaviorIndicators {
            try review.setOutcome(.completed, for: kind)
        }
        try review.setMood(3)
        let previous = review.goalsSnapshot
        try review.replaceGoalsForOpenDay(
            CalibrationGoals(reading: "尝试覆盖历史目标"))
        XCTAssertEqual(review.goalsSnapshot, previous)
        XCTAssertEqual(try review.finalizedScore().netScore, 4)
    }

    func testInvalidMoodOrEmptyGoalsAreRejected() throws {
        var review = try newDay()
        XCTAssertThrowsError(try review.setMood(7))
        XCTAssertThrowsError(try review.setOutcome(.completed, for: .mood))
        XCTAssertThrowsError(try CalibrationDayCheckIn(dayID: "2026-10-18",
                            goals: CalibrationGoals(reading: "   ")))
    }
}
