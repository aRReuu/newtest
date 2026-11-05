import XCTest
import UIKit
import UserNotifications
import ImpressReviewCore
@testable import aReuImpress_iPhone

private enum FixtureNotificationError: Swift.Error { case unavailable }

/// No authorization dialog or actual notification delivery: an actor-backed
/// fake verifies the production coordinator's add/remove/reconcile behavior.
private actor FixtureNotificationScheduler: V3ReminderScheduling {
    private var scheduled: [String: UNNotificationRequest] = [:]
    private let granted: Bool

    init(granted: Bool = true, existing: [UNNotificationRequest] = []) {
        self.granted = granted
        for request in existing { scheduled[request.identifier] = request }
    }
    func isAuthorized() async -> Bool { granted }
    func pendingRequests() async -> [UNNotificationRequest] { Array(scheduled.values) }
    func schedule(_ request: UNNotificationRequest) async throws {
        scheduled[request.identifier] = request
    }
    func removePending(_ identifiers: [String]) async {
        for id in identifiers { scheduled.removeValue(forKey: id) }
    }
    func identifiers() -> [String] { scheduled.keys.sorted() }
}

final class ImpressV3NotificationIntegrationTests: XCTestCase {
    private func request(_ id: String) -> UNNotificationRequest {
        UNNotificationRequest(
            identifier: id,
            content: UNMutableNotificationContent(),
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false)
        )
    }

    private func overdueRepository(now: Date) async throws -> ReviewWCDBRepository {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("V3Notifications-" + UUID().uuidString, isDirectory: true)
            .appendingPathComponent("cards.sqlite").path
        let calc = FSRS6ReviewCalculator()
        let repo = try ReviewWCDBRepository(databasePath: path, calculator: calc)
        let cardID = UUID()
        let past = now.addingTimeInterval(-3600)
        try await repo.insertNewCard(
            WCDBV3CardInput(cardID: cardID, question: "Test", answerText: "Answer"),
            initial: try calc.newCardSnapshot(id: cardID, now: past),
            now: past)
        _ = try await repo.commit(ReviewSubmission(
            eventID: UUID(), cardID: cardID, expectedRevision: 0, rating: .good,
            reviewedAt: past))
        return repo
    }

    func testReconcileRemovesOldIDsKeepsUnrelatedAndAvoidsDuplicates() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let repo = try await overdueRepository(now: now)
        let scheduler = FixtureNotificationScheduler(existing: [
            request("impress.smart.123"),
            request("impress.v3.smart.456"),
            request("unrelated.app.789")
        ])
        let reconciler = V3ReminderReconciler(
            scheduler: scheduler,
            loadCandidates: { try await repo.fetchQueueCandidates() },
            isPilotEnabled: { true },
            reminderPolicy: { .smart(hour: 9, minute: 0) },
            currentTime: { now }
        )
        try await reconciler.reconcileNow()
        let ids = await scheduler.identifiers()
        XCTAssertEqual(ids.filter { $0.hasPrefix(ReviewReminderIdentifiers.smartPrefix) }.count, 1)
        XCTAssertTrue(ids.contains("unrelated.app.789"))
        XCTAssertFalse(ids.contains("impress.smart.123"))
        XCTAssertFalse(ids.contains("impress.v3.smart.456"))
        try await reconciler.reconcileNow()
        let twice = await scheduler.identifiers()
        XCTAssertEqual(twice, ids)
    }

    func testOffRemovesLegacyAndV3WithoutReadingDatabase() async throws {
        let scheduler = FixtureNotificationScheduler(existing: [
            request("impress.smart.123"),
            request("impress.v3.smart.456"),
            request(ReviewReminderIdentifiers.habit),
            request("unrelated.app.1")
        ])
        let reconciler = V3ReminderReconciler(
            scheduler: scheduler,
            loadCandidates: { throw FixtureNotificationError.unavailable },
            isPilotEnabled: { true },
            reminderPolicy: { .off }
        )
        try await reconciler.reconcileNow()
        let remaining = await scheduler.identifiers()
        XCTAssertEqual(remaining, ["unrelated.app.1"])
    }

    func testDeniedPermissionAndDisabledPilotCancelPendingV3() async throws {
        for (granted, enabled) in [(false, true), (true, false)] {
            let scheduler = FixtureNotificationScheduler(
                granted: granted, existing: [request("impress.v3.smart.456")])
            let reconciler = V3ReminderReconciler(
                scheduler: scheduler,
                loadCandidates: { throw FixtureNotificationError.unavailable },
                isPilotEnabled: { enabled },
                reminderPolicy: { .smart(hour: 9, minute: 0) }
            )
            try await reconciler.reconcileNow()
            let ids = await scheduler.identifiers()
            XCTAssertTrue(ids.isEmpty)
        }
    }

    func testNewCardInventoryDoesNotTriggerSmartButHabitRepeats() async throws {
        let scheduler = FixtureNotificationScheduler()
        let core = V3ReminderReconciler(
            scheduler: scheduler,
            loadCandidates: { [] },
            isPilotEnabled: { true },
            reminderPolicy: { .smart(hour: 9, minute: 0) }
        )
        try await core.reconcileNow()
        let noSmart = await scheduler.identifiers()
        XCTAssertTrue(noSmart.isEmpty)
        let habit = V3ReminderReconciler(
            scheduler: scheduler,
            loadCandidates: { [] },
            isPilotEnabled: { true },
            reminderPolicy: { .dailyHabit(hour: 9, minute: 0) }
        )
        try await habit.reconcileNow()
        let ids = await scheduler.identifiers()
        XCTAssertEqual(ids, [ReviewReminderIdentifiers.habit])
    }

    func testOnlyDefaultV3ManagedTapIsRouted() {
        XCTAssertTrue(ImpressV3NotificationCoordinator.isReviewTap(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            requestIdentifier: ReviewReminderIdentifiers.smart(
                for: Date(timeIntervalSince1970: 1_800_000_000))))
        XCTAssertTrue(ImpressV3NotificationCoordinator.isReviewTap(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            requestIdentifier: ReviewReminderIdentifiers.habit))
        XCTAssertFalse(ImpressV3NotificationCoordinator.isReviewTap(
            actionIdentifier: UNNotificationDismissActionIdentifier,
            requestIdentifier: ReviewReminderIdentifiers.habit))
        XCTAssertFalse(ImpressV3NotificationCoordinator.isReviewTap(
            actionIdentifier: UNNotificationDefaultActionIdentifier,
            requestIdentifier: "third.party.notification"))
    }

    @MainActor
    func testColdLaunchTapIsRetainedUntilTabRootAppears() {
        let inbox = ImpressV3NotificationRouteInbox()
        inbox.enqueueReview()
        XCTAssertTrue(inbox.hasPendingReview)
        XCTAssertFalse(inbox.deliverIfPossible(in: nil))
        let tab = UITabBarController()
        let nav = UINavigationController(rootViewController: UIViewController())
        tab.viewControllers = [nav]
        XCTAssertTrue(inbox.deliverIfPossible(in: tab))
        XCTAssertFalse(inbox.hasPendingReview)
        XCTAssertTrue(nav.topViewController is ImpressV3ReviewViewController)
        XCTAssertFalse(inbox.deliverIfPossible(in: tab))
        XCTAssertEqual(nav.viewControllers.filter { $0 is ImpressV3ReviewViewController }.count, 1)
    }

    @MainActor
    func testPendingTapSurvivesUnavailableRoot() {
        let inbox = ImpressV3NotificationRouteInbox()
        inbox.enqueueReview()
        XCTAssertFalse(inbox.deliverIfPossible(in: UIViewController()))
        XCTAssertTrue(inbox.hasPendingReview)
        let tab = UITabBarController()
        let nav = UINavigationController(rootViewController: UIViewController())
        tab.viewControllers = [nav]
        XCTAssertTrue(inbox.deliverIfPossible(in: tab))
        XCTAssertFalse(inbox.hasPendingReview)
    }

    @MainActor
    func testNotificationNavigatorReusesPilotInsteadOfReturningToLegacyRoot() {
        let tab = UITabBarController()
        let nav = UINavigationController(rootViewController: UIViewController())
        tab.viewControllers = [nav]
        ImpressV3NotificationNavigator.openReview(in: tab)
        XCTAssertEqual(tab.selectedIndex, 0)
        XCTAssertTrue(nav.topViewController is ImpressV3ReviewViewController)
        ImpressV3NotificationNavigator.openReview(in: tab)
        XCTAssertEqual(nav.viewControllers.filter { $0 is ImpressV3ReviewViewController }.count, 1)
    }
}
