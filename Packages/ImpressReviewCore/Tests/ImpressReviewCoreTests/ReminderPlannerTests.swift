import XCTest
@testable import ImpressReviewCore

final class ReminderPlannerTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func card(_ due: Date, status: ReviewCardStatus = .review,
                      suspended: Bool = false) -> ReviewQueueCandidate {
        ReviewQueueCandidate(cardID: UUID(), revision: 0, status: status, dueAt: due,
                             createdAt: due, isSuspended: suspended)
    }

    func testSameDayEventsMerge() {
        let now = date(15, 7)
        let candidates = [card(date(15, 8)), card(date(15, 8, 30))]
        let plan = ReminderPlanner.makePlan(candidates: candidates,
                                            policy: .smart(hour: 9, minute: 0),
                                            now: now, calendar: calendar)
        XCTAssertEqual(plan.smartReminders.count, 1)
        XCTAssertEqual(plan.smartReminders[0].fireAt, date(15, 9))
    }

    func testDueAfterDailyTimeSchedulesNextDay() {
        let plan = ReminderPlanner.makePlan(candidates: [card(date(15, 14))],
                                            policy: .smart(hour: 9, minute: 0),
                                            now: date(15, 8), calendar: calendar)
        XCTAssertEqual(plan.smartReminders.first?.fireAt, date(16, 9))
    }

    func testNewCardsDoNotTriggerSmartReminder() {
        let plan = ReminderPlanner.makePlan(candidates: [card(date(15, 7), status: .new)],
                                            policy: .smart(hour: 9, minute: 0),
                                            now: date(15, 8), calendar: calendar)
        XCTAssertTrue(plan.smartReminders.isEmpty)
    }

    func testPausedCardsExcluded() {
        let plan = ReminderPlanner.makePlan(candidates: [card(date(15, 8), suspended: true)],
                                            policy: .smart(hour: 9, minute: 0),
                                            now: date(15, 7), calendar: calendar)
        XCTAssertTrue(plan.smartReminders.isEmpty)
    }

    func testSmartRemindersRespectSeventyTwoHourCooldown() {
        let candidates = (15...24).map { card(date($0, 8)) }
        let plan = ReminderPlanner.makePlan(candidates: candidates,
                                            policy: .smart(hour: 9, minute: 0),
                                            now: date(15, 7), calendar: calendar)
        XCTAssertEqual(plan.smartReminders.map(\.fireAt), [date(15,9),date(18,9),date(21,9),date(24,9)])
    }

    func testFarFutureEventsNotLimitedToFourteenDays() {
        let far = date(30, 10)
        let plan = ReminderPlanner.makePlan(candidates: [card(far)],
                                            policy: .smart(hour: 9, minute: 0),
                                            now: date(15, 7), calendar: calendar)
        XCTAssertEqual(plan.smartReminders.first?.fireAt, date(31, 9))
    }

    func testNotificationBudget() {
        let candidates = (15...30).map { card(date($0, 7)) }
        let plan = ReminderPlanner.makePlan(candidates: candidates,
                                            policy: .smart(hour: 9, minute: 0, minimumSpacing: 0),
                                            now: date(15, 6), calendar: calendar,
                                            maxSmartReminders: 12)
        XCTAssertEqual(plan.smartReminders.count, 12)
    }

    func testV3SmartIDIsStableRoutableAndOldIDsAreManagedForCleanup() {
        let reminder = ReminderPlanner.makePlan(
            candidates: [card(date(15, 8))],
            policy: .smart(hour: 9, minute: 0),
            now: date(15, 7),
            calendar: calendar
        ).smartReminders.first!
        XCTAssertEqual(reminder.identifier, ReviewReminderIdentifiers.smart(for: date(15, 9)))
        XCTAssertTrue(reminder.identifier.hasPrefix(ReviewReminderIdentifiers.namespace))
        XCTAssertTrue(ReviewReminderIdentifiers.isManaged(reminder.identifier))
        XCTAssertTrue(ReviewReminderIdentifiers.isManaged("impress.smart.1700000000"))
        XCTAssertTrue(ReviewReminderIdentifiers.isManaged(ReviewReminderIdentifiers.habit))
        XCTAssertFalse(ReviewReminderIdentifiers.isManaged("thirdparty.reminder"))
    }

    func testHabitAndOffAreMutuallyExclusive() {
        let c = [card(date(15, 8))]
        let habit = ReminderPlanner.makePlan(candidates: c,
                                             policy: .dailyHabit(hour: 20, minute: 30),
                                             now: date(15, 7), calendar: calendar)
        XCTAssertEqual(habit.dailyHabitTime?.hour, 20)
        XCTAssertEqual(habit.dailyHabitTime?.minute, 30)
        XCTAssertTrue(habit.smartReminders.isEmpty)
        let off = ReminderPlanner.makePlan(candidates: c, policy: .off,
                                           now: date(15, 7), calendar: calendar)
        XCTAssertNil(off.dailyHabitTime)
        XCTAssertTrue(off.smartReminders.isEmpty)
    }
}
