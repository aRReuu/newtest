import Foundation
import UIKit
import UserNotifications
import ImpressReviewCore

/// The authorization UI is triggered only by an explicit user action.
/// The old daily and one-hour notification paths must not schedule in V3 mode.
final class ImpressV3NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ImpressV3NotificationCoordinator()

    private let center = UNUserNotificationCenter.current()
    private let worker = V3ReminderReconciler()
    private static let modeKey = "ImpressV3ReminderMode"

    private override init() { super.init() }

    func installDelegate() {
        center.delegate = self
        // V3 is a separate scheduling authority: retire only the two legacy
        // identifiers, not unrelated scheduled notifications.
        if ImpressV3ReviewEnvironment.pilotEnabled {
            center.removePendingNotificationRequests(withIdentifiers: [
                dailyReminderIdentifier, "miemie.oneHourReminder"
            ])
            // Reconcile on pilot activation, not only after a future rating.
            requestReconciliation()
        }
    }

    func requestPermissionFromUserAction(_ completion: @escaping (Bool) -> Void) {
        center.getNotificationSettings { [weak self] settings in
            guard let self = self else { return }
            switch settings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                DispatchQueue.main.async { completion(true) }
            case .notDetermined:
                self.center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                    DispatchQueue.main.async { completion(granted) }
                }
            default:
                DispatchQueue.main.async { completion(false) }
            }
        }
    }

    func enableSmartReminders() {
        UserDefaults.standard.set("smart", forKey: Self.modeKey)
        installDelegate()
        requestReconciliation()
    }

    func enableHabitReminders() {
        UserDefaults.standard.set("habit", forKey: Self.modeKey)
        installDelegate()
        requestReconciliation()
    }

    func disableReminders() {
        UserDefaults.standard.set("off", forKey: Self.modeKey)
        requestReconciliation()
    }

    func requestReconciliation() {
        Task { await worker.request() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Keep FSRS foreground behavior unchanged, but show calibration alerts.
        if CalibrationReminderPlan.isManaged(notification.request.identifier) {
            if #available(iOS 14.0, *) {
                completionHandler([.banner, .list, .sound])
            } else {
                completionHandler([.alert, .sound])
            }
            return
        }
        completionHandler([])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if ImpressCalibrationReminderCoordinator.isCalibrationTap(response) {
            DispatchQueue.main.async {
                ImpressCalibrationNotificationRouteInbox.shared.enqueue()
                ImpressCalibrationNotificationRouteInbox.shared.deliverUsingConnectedScenes()
                completionHandler()
            }
            return
        }
        guard Self.isReviewTap(actionIdentifier: response.actionIdentifier,
                               requestIdentifier: response.notification.request.identifier) else {
            completionHandler()
            return
        }
        DispatchQueue.main.async {
            guard ImpressV3ReviewEnvironment.pilotEnabled else {
                completionHandler()
                return
            }
            // Cold-start notification responses may precede the UIWindow.
            ImpressV3NotificationRouteInbox.shared.enqueueReview()
            ImpressV3NotificationRouteInbox.shared.deliverUsingConnectedScenes()
            completionHandler()
        }
    }

    static func isReviewTap(actionIdentifier: String, requestIdentifier: String) -> Bool {
        actionIdentifier == UNNotificationDefaultActionIdentifier &&
            ReviewReminderIdentifiers.isManaged(requestIdentifier)
    }

    fileprivate static func currentPolicy() -> ReminderPolicy {
        let mode = UserDefaults.standard.string(forKey: modeKey) ?? "off"
        switch mode {
        case "smart": return .smart(hour: 9, minute: 0)
        case "habit": return .dailyHabit(hour: 9, minute: 0)
        default: return .off
        }
    }
}

/// Resolves a notification tap to the existing V3 review controller. The
/// debug pilot can be pushed above a legacy root; popping to root is incorrect.
@MainActor
enum ImpressV3NotificationNavigator {
    /// Returns false if UIKit has not mounted a usable root or if a presented
    /// editing sheet would be lost. The inbox retains the pending route.
    @discardableResult
    static func openReview(in tab: UITabBarController) -> Bool {
        guard tab.presentedViewController == nil,
              let navigation = tab.viewControllers?.first as? UINavigationController,
              navigation.presentedViewController == nil else { return false }
        tab.selectedIndex = 0
        if let existing = navigation.viewControllers.first(where: { $0 is ImpressV3ReviewViewController }) {
            navigation.popToViewController(existing, animated: false)
        } else {
            navigation.pushViewController(ImpressV3ReviewViewController(), animated: false)
        }
        return true
    }
}

/// Transient cold-start deep-link handoff. The OS can deliver a notification
/// before UIScene makes a UIWindow; never discard that navigation intent.
@MainActor
final class ImpressV3NotificationRouteInbox {
    static let shared = ImpressV3NotificationRouteInbox()
    private(set) var hasPendingReview = false

    func enqueueReview() {
        hasPendingReview = true
    }

    @discardableResult
    func deliverIfPossible(in root: UIViewController?) -> Bool {
        guard hasPendingReview, let tab = root as? UITabBarController,
              ImpressV3NotificationNavigator.openReview(in: tab) else { return false }
        hasPendingReview = false
        return true
    }

    func deliverUsingConnectedScenes() {
        guard hasPendingReview else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for scene in scenes {
            for window in scene.windows where window.isKeyWindow {
                if deliverIfPossible(in: window.rootViewController) { return }
            }
        }
    }
}

/// Minimal scheduling boundary. Simulator tests exercise the production
/// reconciliation algorithm without touching real permissions or device alerts.
protocol V3ReminderScheduling: Sendable {
    func isAuthorized() async -> Bool
    func pendingRequests() async -> [UNNotificationRequest]
    func schedule(_ request: UNNotificationRequest) async throws
    func removePending(_ identifiers: [String]) async
}

private final class V3SystemReminderScheduler: V3ReminderScheduling, @unchecked Sendable {
    private let center = UNUserNotificationCenter.current()

    func isAuthorized() async -> Bool {
        let settings: UNNotificationSettings = await withCheckedContinuation { continuation in
            center.getNotificationSettings { continuation.resume(returning: $0) }
        }
        return settings.authorizationStatus == .authorized ||
            settings.authorizationStatus == .provisional ||
            settings.authorizationStatus == .ephemeral
    }

    func pendingRequests() async -> [UNNotificationRequest] {
        await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { continuation.resume(returning: $0) }
        }
    }

    func schedule(_ request: UNNotificationRequest) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            center.add(request) { error in
                if let error = error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
    }

    func removePending(_ identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }
}

/// Serial desired-state reconciliation after ratings, launches, policy changes.
/// Existing old "impress.smart.*" IDs are included solely for cancellation.
/// The unit tests use the same actor with an isolated in-memory scheduler.
actor V3ReminderReconciler {
    private let scheduler: any V3ReminderScheduling
    private let loadCandidates: @Sendable () async throws -> [ReviewQueueCandidate]
    private let isPilotEnabled: @Sendable () -> Bool
    private let reminderPolicy: @Sendable () -> ReminderPolicy
    private let currentTime: @Sendable () -> Date
    private var generation: UInt64 = 0
    private var isRunning = false

    init(
        scheduler: any V3ReminderScheduling = V3SystemReminderScheduler(),
        loadCandidates: @escaping @Sendable () async throws -> [ReviewQueueCandidate] = {
            let repo = try ImpressV3ReviewEnvironment.repository()
            return try await repo.fetchQueueCandidates()
        },
        isPilotEnabled: @escaping @Sendable () -> Bool = {
            ImpressV3ReviewEnvironment.pilotEnabled
        },
        reminderPolicy: @escaping @Sendable () -> ReminderPolicy = {
            ImpressV3NotificationCoordinator.currentPolicy()
        },
        currentTime: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.scheduler = scheduler
        self.loadCandidates = loadCandidates
        self.isPilotEnabled = isPilotEnabled
        self.reminderPolicy = reminderPolicy
        self.currentTime = currentTime
    }

    func request() {
        generation &+= 1
        guard !isRunning else { return }
        isRunning = true
        Task { await drain() }
    }

    private func drain() async {
        while true {
            let observed = generation
            do { try await reconcileNow() }
            catch { NSLog("Impress V3 reminder reconciliation failed: %@", error.localizedDescription) }
            if generation == observed { break }
        }
        isRunning = false
    }

    /// Also called directly by deterministic iOS XCTest fixtures.
    func reconcileNow() async throws {
        let policy = reminderPolicy()
        let existing = await scheduler.pendingRequests()
        let managed = existing.filter { ReviewReminderIdentifiers.isManaged($0.identifier) }
        let authorized = await scheduler.isAuthorized()

        var planned: [String: UNNotificationRequest] = [:]
        // Even if the V3 SQLite database fails to open, Off must retire pending
        // V3 and old pilot smart notifications without touching unrelated IDs.
        if authorized && isPilotEnabled() && policy != .off {
            let candidates = try await loadCandidates()
            let calendar = Calendar.current
            let plan = ReminderPlanner.makePlan(candidates: candidates,
                                                policy: policy, now: currentTime(), calendar: calendar)
            for entry in plan.smartReminders {
                let components = calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute, .second], from: entry.fireAt)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                planned[entry.identifier] = makeRequest(id: entry.identifier, trigger: trigger)
            }
            if let clock = plan.dailyHabitTime {
                let trigger = UNCalendarNotificationTrigger(dateMatching: clock, repeats: true)
                planned[ReviewReminderIdentifiers.habit] = makeRequest(
                    id: ReviewReminderIdentifiers.habit, trigger: trigger)
            }
        }

        let obsolete = managed.filter { current in
            guard let desired = planned[current.identifier] else { return true }
            guard let currentTrigger = current.trigger as? UNCalendarNotificationTrigger,
                  let desiredTrigger = desired.trigger as? UNCalendarNotificationTrigger else {
                return true
            }
            return currentTrigger.repeats != desiredTrigger.repeats ||
                currentTrigger.dateComponents != desiredTrigger.dateComponents
        }
        if !obsolete.isEmpty {
            await scheduler.removePending(obsolete.map { $0.identifier })
        }
        let currentIDs = Set(managed.map { $0.identifier })
            .subtracting(obsolete.map { $0.identifier })
        for id in planned.keys.sorted() where !currentIDs.contains(id) {
            if let request = planned[id] { try await scheduler.schedule(request) }
        }
    }

    private func makeRequest(id: String, trigger: UNNotificationTrigger) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = "闪卡复习"
        content.body = "有复习内容已经到期，方便时可以巩固一下。"
        content.sound = .default
        content.threadIdentifier = "impress.v3.review"
        content.userInfo = ["reviewRoute": "v3"]
        return UNNotificationRequest(identifier: id, content: content, trigger: trigger)
    }
}
