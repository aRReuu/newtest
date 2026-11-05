import Foundation
import UIKit
import UserNotifications
import ImpressReviewCore

/// iOS does not allow a permanently undismissable notification.
/// Keep a persistent pending state inside the app and schedule bounded,
/// cancellable follow-up local alerts. Never request permission on launch.
@MainActor
final class ImpressCalibrationReminderCoordinator {
    static let shared = ImpressCalibrationReminderCoordinator()
    private static let enabledKey = "ImpressCalibrationNotificationsEnabled"
    private let reconciler = ImpressCalibrationReminderReconciler()
    private init() {}

    var isEnabled: Bool { UserDefaults.standard.bool(forKey: Self.enabledKey) }

    func requestAuthorizationFromUserAction() async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings: UNNotificationSettings = await withCheckedContinuation { continuation in
            center.getNotificationSettings { continuation.resume(returning: $0) }
        }
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, _ in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: Self.enabledKey)
        requestReconciliation()
    }

    func requestReconciliation() {
        Task { await reconciler.request() }
    }

    nonisolated static func isCalibrationTap(_ response: UNNotificationResponse) -> Bool {
        response.actionIdentifier == UNNotificationDefaultActionIdentifier &&
            CalibrationReminderPlan.isManaged(response.notification.request.identifier)
    }
}

@MainActor
final class ImpressCalibrationNotificationRouteInbox {
    static let shared = ImpressCalibrationNotificationRouteInbox()
    private(set) var pending = false

    func enqueue() { pending = true }

    @discardableResult
    func deliverIfPossible(in root: UIViewController?) -> Bool {
        guard pending, let tabs = root as? UITabBarController,
              tabs.presentedViewController == nil,
              // Resolve the actual destination by controller type, never by an
              // index belonging to an older Tab configuration.
              let nav = tabs.viewControllers?.compactMap({ $0 as? UINavigationController })
                .first(where: { $0.viewControllers.first is ImpressCalibrationViewController }),
              nav.presentedViewController == nil else { return false }
        tabs.selectedViewController = nav
        if let calibration = nav.viewControllers.first(where: {
            $0 is ImpressCalibrationViewController
        }) {
            nav.popToViewController(calibration, animated: false)
        } else {
            return false
        }
        pending = false
        return true
    }

    func deliverUsingConnectedScenes() {
        guard pending else { return }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows where window.isKeyWindow {
                if deliverIfPossible(in: window.rootViewController) { return }
            }
        }
    }
}

/// Isolated scheduler: leaves all FSRS identifiers and policies untouched.
actor ImpressCalibrationReminderReconciler {
    private var generation: UInt64 = 0
    private var running = false
    private let center = UNUserNotificationCenter.current()

    func request() {
        generation &+= 1
        guard !running else { return }
        running = true
        Task { await drain() }
    }

    private func drain() async {
        while true {
            let observed = generation
            do { try await reconcile() }
            catch { NSLog("Calibration reminder reconciliation failed: %@", error.localizedDescription) }
            if observed == generation { break }
        }
        running = false
    }

    func reconcile() async throws {
        let now = Date()
        let existing: [UNNotificationRequest] = await withCheckedContinuation { continuation in
            center.getPendingNotificationRequests { continuation.resume(returning: $0) }
        }
        let managed = existing.filter { CalibrationReminderPlan.isManaged($0.identifier) }
        let settings: UNNotificationSettings = await withCheckedContinuation { continuation in
            center.getNotificationSettings { continuation.resume(returning: $0) }
        }
        let enabled = UserDefaults.standard.bool(forKey: "ImpressCalibrationNotificationsEnabled")
        let authorized = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
        var desired = [String: CalibrationReminderSlot]()
        let completed: Set<String>
        if enabled && authorized {
            completed = try await ImpressCalibrationLocalStore.shared.completedDayIDs()
            // Reserve capacity for up to 12 FSRS reminders and other native alerts.
            let nonCalibration = existing.count - managed.count
            let capacity = max(0, min(28, 60 - nonCalibration))
            let slots = CalibrationReminderPlan.make(
                now: now, calendar: Calendar.current, completedDays: completed)
            for slot in slots.prefix(capacity) { desired[slot.identifier] = slot }
        } else {
            completed = []
        }

        let calendar = Calendar.current
        let obsolete = managed.filter { request in
            guard let expected = desired[request.identifier],
                  let trigger = request.trigger as? UNCalendarNotificationTrigger else {
                return true
            }
            return trigger.repeats ||
                trigger.dateComponents != calendar.dateComponents(
                    [.year, .month, .day, .hour, .minute], from: expected.fireAt)
        }
        if !obsolete.isEmpty {
            center.removePendingNotificationRequests(
                withIdentifiers: obsolete.map(\.identifier))
        }
        let existingIDs = Set(managed.map(\.identifier)).subtracting(obsolete.map(\.identifier))
        for key in desired.keys.sorted() where !existingIDs.contains(key) {
            guard let slot = desired[key] else { continue }
            let content = UNMutableNotificationContent()
            content.title = V3L("今日校准尚未完成")
            content.body = V3L("还有每日指标待评估。完成全部五项后，今天的后续提醒会停止。")
            content.sound = .default
            content.badge = 1
            content.threadIdentifier = "impress.calibration"
            content.userInfo = ["calibrationRoute": "v1"]
            let components = calendar.dateComponents(
                [.year, .month, .day, .hour, .minute], from: slot.fireAt)
            let request = UNNotificationRequest(
                identifier: slot.identifier,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Swift.Error>) in
                center.add(request) { error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }

        // Clearing a reviewed day never cancels tomorrow's already planned alerts.
        let todayID = CalibrationDayCheckIn.dayID(for: now, calendar: calendar)
        let todayDone = (try? await ImpressCalibrationLocalStore.shared
            .checkIn(on: now, calendar: calendar).isComplete) ?? false
        if todayDone {
            center.removeDeliveredNotifications(withIdentifiers: [20, 22].map {
                CalibrationReminderPlan.identifierPrefix + todayID +
                    "." + String(format: "%02d", $0)
            })
        }
        if authorized {
            let badge = (enabled && !todayDone) ? 1 : 0
            if #available(iOS 16.0, *) {
                try? await center.setBadgeCount(badge)
            } else {
                await MainActor.run { UIApplication.shared.applicationIconBadgeNumber = badge }
            }
        }
    }
}
