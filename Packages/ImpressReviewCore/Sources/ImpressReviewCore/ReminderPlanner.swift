import Foundation

/// Only the requested notification policy; never affects FSRS due dates.
public enum ReminderPolicy: Sendable, Equatable {
    case off
    case smart(hour: Int, minute: Int, minimumSpacing: TimeInterval = 72 * 3600)
    case dailyHabit(hour: Int, minute: Int)
}

public struct PlannedReminder: Equatable, Sendable {
    public let identifier: String
    public let fireAt: Date

    public init(identifier: String, fireAt: Date) {
        self.identifier = identifier
        self.fireAt = fireAt
    }
}

public struct ReminderPlan: Equatable, Sendable {
    /// One-shot notifications to submit to UNUserNotificationCenter.
    public let smartReminders: [PlannedReminder]
    /// For daily habit mode: matching DateComponents for a repeating calendar trigger.
    public let dailyHabitTime: DateComponents?

    public init(smartReminders: [PlannedReminder], dailyHabitTime: DateComponents?) {
        self.smartReminders = smartReminders
        self.dailyHabitTime = dailyHabitTime
    }
}

public enum ReminderPlanner {
    /// A pure plan: no badge guesses, no UIApplication, no notification requests.
    /// The iOS adapter must reconcile this plan against currently scheduled IDs.
    public static func makePlan(
        candidates: [ReviewQueueCandidate],
        policy: ReminderPolicy,
        now: Date,
        calendar: Calendar = .current,
        maxSmartReminders: Int = 12
    ) -> ReminderPlan {
        switch policy {
        case .off:
            return ReminderPlan(smartReminders: [], dailyHabitTime: nil)
        case let .dailyHabit(hour, minute):
            guard validClock(hour: hour, minute: minute) else {
                return ReminderPlan(smartReminders: [], dailyHabitTime: nil)
            }
            return ReminderPlan(smartReminders: [], dailyHabitTime: DateComponents(hour: hour, minute: minute))
        case let .smart(hour, minute, minimumSpacing):
            guard validClock(hour: hour, minute: minute), maxSmartReminders > 0 else {
                return ReminderPlan(smartReminders: [], dailyHabitTime: nil)
            }
            let clock = DateComponents(hour: hour, minute: minute)
            // New cards are inventory, not FSRS-scheduled due reviews.
            let dueDates = candidates.filter { !$0.isSuspended && $0.status != .new }
                .compactMap { candidate -> Date? in
                    let threshold = max(candidate.dueAt, now)
                    return calendar.nextDate(
                        after: threshold.addingTimeInterval(-0.001),
                        matching: clock,
                        matchingPolicy: .nextTime,
                        repeatedTimePolicy: .first,
                        direction: .forward
                    )
                }
                .sorted()
            var reminders: [PlannedReminder] = []
            for date in dueDates {
                if let last = reminders.last?.fireAt,
                   date.timeIntervalSince(last) < max(0, minimumSpacing) { continue }
                // Date-based IDs also allow repeatable reconciliation.
                let id = ReviewReminderIdentifiers.smart(for: date)
                if !reminders.contains(where: { $0.identifier == id }) {
                    reminders.append(PlannedReminder(identifier: id, fireAt: date))
                    if reminders.count >= maxSmartReminders { break }
                }
            }
            return ReminderPlan(smartReminders: reminders, dailyHabitTime: nil)
        }
    }

    private static func validClock(hour: Int, minute: Int) -> Bool {
        (0...23).contains(hour) && (0...59).contains(minute)
    }
}
