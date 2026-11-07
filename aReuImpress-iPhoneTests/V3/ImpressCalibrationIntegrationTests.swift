import XCTest
import UIKit
import UserNotifications
import ImpressReviewCore
@testable import aReuImpress_iPhone

final class ImpressCalibrationIntegrationTests: XCTestCase {
    @MainActor
    func testThreeTabsKeepCalibrationInSettingsWithoutRewritingScores() throws {
        let root = ImTabBarViewController()
        root.loadViewIfNeeded()
        let tabs = try XCTUnwrap(root.viewControllers)
        XCTAssertEqual(tabs.count, 3)
        XCTAssertEqual(tabs.compactMap { $0.tabBarItem.title },
                       ["闪卡", "笔记", "设置"])
        XCTAssertTrue((tabs[0] as? UINavigationController)?.viewControllers.first
                      is ImpressV3ReviewViewController)
        XCTAssertTrue((tabs[1] as? UINavigationController)?.viewControllers.first
                      is ImpressNoteListTableViewController)
        XCTAssertTrue((tabs[2] as? UINavigationController)?.viewControllers.first
                      is ImpressV3SettingsHubViewController)
        let review = try XCTUnwrap((tabs[0] as? UINavigationController)?
            .viewControllers.first as? ImpressV3ReviewViewController)
        review.loadViewIfNeeded()
        XCTAssertEqual(review.navigationItem.leftBarButtonItem?.accessibilityLabel,
                       "新增卡片")
        XCTAssertEqual(review.navigationItem.rightBarButtonItems?
            .compactMap(\.accessibilityIdentifier), ["impress.review.card-collection"])
        XCTAssertFalse(review.navigationItem.rightBarButtonItems?
            .contains(where: { $0.accessibilityIdentifier == "impress.review.notes" }) ?? true)
    }

    @MainActor
    func testNotesKeepsOwnNativeRootAndReviewNavigation() throws {
        let tabs = ImTabBarViewController()
        tabs.loadViewIfNeeded()
        let cardNav = try XCTUnwrap(tabs.viewControllers?[0] as? UINavigationController)
        let notesNav = try XCTUnwrap(tabs.viewControllers?[1] as? UINavigationController)
        let review = try XCTUnwrap(cardNav.viewControllers.first as? ImpressV3ReviewViewController)
        let notes = try XCTUnwrap(notesNav.viewControllers.first as? ImpressNoteListTableViewController)
        review.loadViewIfNeeded()
        notes.loadViewIfNeeded()
        XCTAssertEqual(tabs.viewControllers?.count, 3)
        XCTAssertEqual(cardNav.viewControllers.count, 1)
        XCTAssertEqual(notesNav.viewControllers.count, 1)
    }

    @MainActor
    func testCalibrationNotificationRoutesToSettingsCalibration() throws {
        let tab = ImTabBarViewController()
        tab.loadViewIfNeeded()
        let inbox = ImpressCalibrationNotificationRouteInbox.shared
        inbox.enqueue()
        XCTAssertTrue(inbox.deliverIfPossible(in: tab))
        XCTAssertEqual(tab.selectedIndex, 2)
        let settings = try XCTUnwrap(tab.viewControllers?[2] as? UINavigationController)
        XCTAssertTrue(settings.viewControllers.first is ImpressV3SettingsHubViewController)
        XCTAssertTrue(settings.topViewController is ImpressCalibrationViewController)
        XCTAssertEqual(settings.viewControllers.count, 2)
        XCTAssertFalse(inbox.pending)
        XCTAssertFalse(inbox.deliverIfPossible(in: tab))
    }

    @MainActor
    func testReviewUsesCollapsedCalibrationDrawerAndSettingsRetainsDetailRoute() throws {
        let tabs = ImTabBarViewController()
        tabs.loadViewIfNeeded()
        let flashcardNav = try XCTUnwrap(tabs.viewControllers?[0] as? UINavigationController)
        let review = try XCTUnwrap(flashcardNav.viewControllers.first
                                   as? ImpressV3ReviewViewController)
        review.loadViewIfNeeded()
        let drawer = try XCTUnwrap(review.view.subviews.first {
            $0.accessibilityIdentifier == "impress.review.calibration-drawer"
        } as? ImpressV3CalibrationDrawerView)
        XCTAssertFalse(drawer.isExpanded)
        XCTAssertEqual(drawer.selectedPeriod, .week)
        XCTAssertEqual(flashcardNav.viewControllers.count, 1)
        let settingsNav = try XCTUnwrap(tabs.viewControllers?[2] as? UINavigationController)
        let settings = try XCTUnwrap(settingsNav.viewControllers.first
                                    as? ImpressV3SettingsHubViewController)
        settings.loadViewIfNeeded()
        settings.tableView(settings.tableView,
                           didSelectRowAt: IndexPath(row: 0, section: 1))
        XCTAssertTrue(settingsNav.topViewController is ImpressCalibrationViewController)
        XCTAssertTrue(flashcardNav.topViewController === review)
    }

    @MainActor
    func testSettingsDailyCalibrationUsesSameFullDetailClass() throws {
        let tabs = ImTabBarViewController()
        tabs.loadViewIfNeeded()
        let settingsNav = try XCTUnwrap(tabs.viewControllers?[2] as? UINavigationController)
        let hub = try XCTUnwrap(settingsNav.viewControllers.first
                                as? ImpressV3SettingsHubViewController)
        hub.loadViewIfNeeded()
        hub.tableView(hub.tableView,
                      didSelectRowAt: IndexPath(row: 0, section: 1))
        XCTAssertTrue(settingsNav.topViewController is ImpressCalibrationViewController)
        XCTAssertEqual(tabs.selectedIndex, 0) // no forced primary navigation
        XCTAssertTrue(settingsNav.viewControllers.first === hub)
    }

    @MainActor
    func testCalibrationEntryIsAvailableUnderLearningRhythm() throws {
        let tabs = ImTabBarViewController()
        tabs.loadViewIfNeeded()
        let settings = try XCTUnwrap(tabs.viewControllers?[2] as? UINavigationController)
        let hub = try XCTUnwrap(settings.viewControllers.first as? ImpressV3SettingsHubViewController)
        hub.loadViewIfNeeded()
        let cell = hub.tableView(hub.tableView,
                                 cellForRowAt: IndexPath(row: 0, section: 1))
        let title = (cell.contentConfiguration as? UIListContentConfiguration)?.text
        XCTAssertEqual(title, "每日校准")
    }

    @MainActor
    func testCalibrationDrawerPeriodAndExpansionDoNotIntroduceReviewActions() throws {
        let drawer = ImpressV3CalibrationDrawerView(
            frame: CGRect(x: 0, y: 0, width: 350, height: 148))
        var expansion: [Bool] = []
        drawer.onExpansionRequest = { expansion.append($0) }
        let handle = try XCTUnwrap(drawer.subviews.compactMap {
            $0 as? UIButton
        }.first(where: {
            $0.accessibilityIdentifier == "impress.review.calibration-drawer-handle"
        }))
        handle.sendActions(for: .touchUpInside)
        XCTAssertEqual(expansion, [true])
        drawer.setExpanded(true)
        XCTAssertTrue(drawer.isExpanded)
        XCTAssertEqual(drawer.selectedPeriod, .week)
        let period = try XCTUnwrap(drawer.subviews.compactMap {
            $0 as? UISegmentedControl
        }.first(where: {
            $0.accessibilityIdentifier == "impress.review.calibration-drawer-period"
        }))
        XCTAssertEqual(period.numberOfSegments, 3)
        period.selectedSegmentIndex = 2
        XCTAssertEqual(drawer.selectedPeriod, .year)
        handle.sendActions(for: .touchUpInside)
        XCTAssertEqual(expansion, [true, false])
        // Only the drawer's own controls are touched; no FSRS session or
        // SwipeCardStack review-submission callback is installed here.
    }

    @MainActor
    func testCompactPlotProjectionMatchesCanonical7_30_12Gaps() throws {
        let records: [CalibrationDailyRecord] = []
        let weekly = try ImpressCalibrationChartProjector.project(
            records: records, period: .week)
        let monthly = try ImpressCalibrationChartProjector.project(
            records: records, period: .month)
        let yearly = try ImpressCalibrationChartProjector.project(
            records: records, period: .year)
        XCTAssertEqual(weekly.values.count, 7)
        XCTAssertEqual(monthly.values.count, 30)
        XCTAssertEqual(yearly.values.count, 12)
        XCTAssertTrue(weekly.values.allSatisfy { $0 == nil })
        XCTAssertTrue(monthly.values.allSatisfy { $0 == nil })
        XCTAssertTrue(yearly.values.allSatisfy { $0 == nil })
        XCTAssertEqual(weekly.values, weekly.smooth)
        XCTAssertEqual(monthly.values, monthly.smooth)
        XCTAssertEqual(yearly.values, yearly.smooth)
    }

    func testStorePersistsDayGoalsAndNeverRewritesHistory() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("calibration-test-" + UUID().uuidString)
            .appendingPathComponent("private.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = ImpressCalibrationLocalStore(storageURL: url)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let timestamp = calendar.date(from: DateComponents(year: 2025, month: 10, day: 18))!
        var first = try await store.checkIn(on: timestamp, calendar: calendar)
        try first.setOutcome(.completed, for: .sleep)
        try await store.save(first)
        let original = try await store.checkIn(on: timestamp, calendar: calendar)
        XCTAssertEqual(original.outcome(for: .sleep), .completed)
        try await store.setGoals(CalibrationGoals(reading: "新的阅读目标"))
        let reload = try await store.checkIn(on: timestamp, calendar: calendar)
        XCTAssertEqual(reload.goalsSnapshot.reading, first.goalsSnapshot.reading)
        XCTAssertEqual(reload.outcome(for: .sleep), .completed)
        let all = try await store.history()
        XCTAssertEqual(all.count, 1)
    }

    func testEditingOpenTodayResetsOnlyChangedGoalAssessments() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("calibration-edit-today-" + UUID().uuidString,
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = ImpressCalibrationLocalStore(
            storageURL: folder.appendingPathComponent("checkins.json"))
        let today = Date()
        var day = try await store.checkIn(on: today)
        try day.setOutcome(.completed, for: .sleep)
        try day.setOutcome(.missed, for: .reading)
        try await store.save(day)
        try await store.setGoals(CalibrationGoals(reading: "更新后需要重新确认的阅读计划"))
        let updated = try await store.checkIn(on: today)
        XCTAssertEqual(updated.goalsSnapshot.reading, "更新后需要重新确认的阅读计划")
        XCTAssertEqual(updated.outcome(for: .sleep), .completed,
                       "An unchanged confirmed goal must be retained")
        XCTAssertEqual(updated.outcome(for: .reading), .unrecorded,
                       "The changed goal must be reassessed")
        XCTAssertFalse(updated.isComplete)
        XCTAssertNil(try updated.finalizedScore().netScore)
        let history = try await store.history()
        XCTAssertEqual(history.count, 1)
    }

    /// A legacy CLOSED day remains closed even when read on the same local
    /// date after the four-item reading migration. Its stored bytes are not
    /// silently replaced by a new pending reading assessment.
    func testClosedLegacyTodayRemainsClosedWhileOpenLegacyMigratesSafely() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cal-legacy-closed-" + UUID().uuidString,
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder,
                                                withIntermediateDirectories: true)
        let today = Date()
        let dayID = CalibrationDayCheckIn.dayID(for: today)
        var day = try CalibrationDayCheckIn(dayID: dayID, goals: CalibrationGoals())
        for kind in CalibrationIndicator.behaviorIndicators {
            try day.setOutcome(.completed, for: kind)
        }
        try day.setMood(nil, assessed: true)

        var oldDay = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(day)) as? [String: Any])
        var tasks = try XCTUnwrap(oldDay["assessments"] as? [[String: Any]])
        let fourth = try XCTUnwrap(tasks.firstIndex {
            ($0["taskID"] as? String) == CalibrationIndicator.reading.rawValue
        })
        tasks[fourth]["taskID"] = CalibrationIndicator.custom.rawValue
        oldDay["assessments"] = tasks
        var oldTargets = try XCTUnwrap(oldDay["goalsSnapshot"] as? [String: Any])
        oldTargets.removeValue(forKey: "reading")
        oldTargets["custom"] = "曾经批准的自定义目标"
        oldDay["goalsSnapshot"] = oldTargets

        let activeGoals = CalibrationGoals(reading: "今天的新阅读目标")
        let goalsJSON = try XCTUnwrap(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(activeGoals)) as? [String: Any])
        func archive(_ entry: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: [
                "version": 1, "goals": goalsJSON, "days": [dayID: entry]
            ], options: [.sortedKeys])
        }

        let storageURL = folder.appendingPathComponent("closed.json")
        let original = try archive(oldDay)
        try original.write(to: storageURL, options: .atomic)
        let closedStore = ImpressCalibrationLocalStore(storageURL: storageURL)
        let closed = try await closedStore.checkIn(on: today)
        XCTAssertTrue(closed.isLegacyDay)
        XCTAssertTrue(closed.isComplete,
            "A CLOSED legacy day must never reopen as an unrecorded reading")
        XCTAssertEqual(closed.outcome(for: .custom), .completed)
        XCTAssertTrue(closed.pendingIndicators.isEmpty)
        XCTAssertEqual(try closed.finalizedScore().netScore, 4)
        XCTAssertEqual(closed.goalsSnapshot.custom, "曾经批准的自定义目标")

        try await closedStore.save(closed) // Idempotent, never rewrites bytes.
        let afterRetry = try await closedStore.archiveData()
        XCTAssertEqual(afterRetry, original)
        var attemptedOverwrite = closed
        try attemptedOverwrite.setOutcome(.missed, for: .custom)
        do {
            try await closedStore.save(attemptedOverwrite)
            XCTFail("No changed value may overwrite a CLOSED legacy day")
        } catch ImpressCalibrationStoreError.closedDayImmutable {
            // Expected.
        }
        let finalClosed = try await closedStore.archiveData()
        XCTAssertEqual(finalClosed, original)

        // The distinct old OPEN state is still eligible for the supported
        // today's-day migration. Do not solve CLOSED by disabling migration.
        var oldOpenDay = oldDay
        oldOpenDay["moodAssessed"] = false
        let openURL = folder.appendingPathComponent("open.json")
        try archive(oldOpenDay).write(to: openURL, options: .atomic)
        let openStore = ImpressCalibrationLocalStore(storageURL: openURL)
        let migrated = try await openStore.checkIn(on: today)
        XCTAssertFalse(migrated.isLegacyDay)
        XCTAssertFalse(migrated.isComplete)
        XCTAssertEqual(migrated.goalsSnapshot.reading, "今天的新阅读目标")
        XCTAssertEqual(migrated.outcome(for: .reading), .unrecorded)
        XCTAssertEqual(migrated.retiredCustomAssessment?.outcome, .completed)
        try await openStore.save(migrated)
        let persisted = try await openStore.checkIn(on: today)
        XCTAssertEqual(persisted, migrated)
    }

    func testClosedDayRejectsDifferentLedgerWritesAndPreservesDurability() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cal-closed-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = ImpressCalibrationLocalStore(
            storageURL: directory.appendingPathComponent("ledger.json"))
        var day = try await ledger.checkIn()
        for kind in CalibrationIndicator.behaviorIndicators {
            try day.setOutcome(.completed, for: kind)
        }
        try day.setManualAdjustment(positive: true, reason: "计划外运动")
        try await ledger.save(day)
        XCTAssertTrue(day.isComplete)
        let before = try await ledger.archiveData()
        // Repeated button taps are truly idempotent, not a second write.
        try await ledger.save(day)
        let retriedBytes = try await ledger.archiveData()
        XCTAssertEqual(before, retriedBytes)

        var changed = day
        try changed.setOutcome(.missed, for: .reading)
        do {
            try await ledger.save(changed)
            XCTFail("CLOSED daily record must reject direct actor overwrite")
        } catch ImpressCalibrationStoreError.closedDayImmutable {
            // Expected.
        }
        var changedExtra = day
        try changedExtra.setManualAdjustment(positive: false, reason: "冲动修改")
        do {
            try await ledger.save(changedExtra)
            XCTFail("CLOSED extra score must be immutable")
        } catch ImpressCalibrationStoreError.closedDayImmutable {
            // Expected.
        }
        let finalBytes = try await ledger.archiveData()
        let finalHistory = try await ledger.history()
        XCTAssertEqual(before, finalBytes)
        XCTAssertEqual(finalHistory, [day])
    }

    func testSimultaneousClosedDayCommitsSerializeWithoutLastWriterWins() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cal-concurrent-" + UUID().uuidString,
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = ImpressCalibrationLocalStore(
            storageURL: directory.appendingPathComponent("checkins.json"))
        var first = try await ledger.checkIn()
        for kind in CalibrationIndicator.behaviorIndicators {
            try first.setOutcome(.completed, for: kind)
        }
        var second = first
        try second.setOutcome(.missed, for: .reading)
        XCTAssertTrue(first.isComplete && second.isComplete)
        let candidateOne = first
        let candidateTwo = second
        let successes = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do { try await ledger.save(candidateOne); return true }
                catch { return false }
            }
            group.addTask {
                do { try await ledger.save(candidateTwo); return true }
                catch { return false }
            }
            var values = [Bool]()
            for await value in group { values.append(value) }
            return values.filter { $0 }.count
        }
        XCTAssertEqual(successes, 1,
            "An actor must accept one CLOSED record, never silently overwrite it")
        let recorded = try await ledger.checkIn()
        XCTAssertTrue(recorded == first || recorded == second)
        let original = try await ledger.archiveData()
        try await ledger.save(recorded)
        let repeated = try await ledger.archiveData()
        XCTAssertEqual(repeated, original,
            "Idempotent CLOSED retries must not issue a second durable write")
        var rejected = recorded
        try rejected.setManualAdjustment(positive: true,
                                         reason: "Do not change a closed score")
        do {
            try await ledger.save(rejected)
            XCTFail("CLOSED cannot be mutated even by another concurrent writer")
        } catch ImpressCalibrationStoreError.closedDayImmutable {
            let unchanged = try await ledger.archiveData()
            XCTAssertEqual(unchanged, original)
        }
    }

    func testFailedDurableWriteLeavesPreviousClosedLedgerIntact() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cal-failure-" + UUID().uuidString,
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("storage", isDirectory: true)
        let dataPath = dir.appendingPathComponent("checkins.json")
        let ledger = ImpressCalibrationLocalStore(storageURL: dataPath)
        var day = try await ledger.checkIn()
        try day.setOutcome(.completed, for: .sleep)
        try await ledger.save(day)
        let saved = try await ledger.archiveData()

        // Deterministic filesystem failure: retain the saved directory as a
        // sibling while replacing its parent path with a regular file. No user
        // documents or App Group storage are involved.
        let moved = root.appendingPathComponent("original", isDirectory: true)
        try FileManager.default.moveItem(at: dir, to: moved)
        try Data("not-a-directory".utf8).write(to: dir)
        var changed = day
        try changed.setOutcome(.missed, for: .nutrition)
        do {
            try await ledger.save(changed)
            XCTFail("Persisting through a non-directory path must fail closed")
        } catch {
            XCTAssertFalse(error is ImpressCalibrationStoreError,
                "The filesystem, not a prior CLOSED guard, must reject this save")
        }
        try FileManager.default.removeItem(at: dir)
        try FileManager.default.moveItem(at: moved, to: dir)
        let restored = try await ledger.checkIn()
        XCTAssertEqual(restored, day)
        let restoredBytes = try await ledger.archiveData()
        XCTAssertEqual(restoredBytes, saved)
    }

    func testCalibrationArchiveRoundTripAndCorruptionRejection() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("cal-archive-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = ImpressCalibrationLocalStore(
            storageURL: folder.appendingPathComponent("original.json"))
        var day = try await original.checkIn()
        for kind in CalibrationIndicator.behaviorIndicators {
            try day.setOutcome(.completed, for: kind)
        }
        try day.setMood(1)
        try day.setManualAdjustment(positive: false, reason: "额外自评")
        try await original.save(day)
        let bytes = try await original.archiveData()
        XCTAssertEqual(try ImpressCalibrationLocalStore.validateArchiveData(bytes), 1)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let restoredURL = folder.appendingPathComponent("restored.json")
        try bytes.write(to: restoredURL, options: .atomic)
        let restored = ImpressCalibrationLocalStore(storageURL: restoredURL)
        let all = try await restored.history()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(try all[0].finalizedScore().netScore, 3)
        XCTAssertThrowsError(try ImpressCalibrationLocalStore.validateArchiveData(
            Data("damaged".utf8)))
    }


    /// W13: a +2 point must remain at exactly the same pixel position even
    /// if some other day later reaches +5. Both App/Widget share this painter.
    /// The same shared source summary must not pronounce absent points as 0.
    @MainActor
    func testCartesianFixedFivePointAxisAndVoiceOverFacts() throws {
        let size = CGSize(width: 168, height: 100)
        let labels = ["10-15", "10-16", "10-17", "10-18",
                      "10-19", "10-20", "10-21"]
        let sparse: [Double?] = [nil, nil, 2, nil, nil, nil, nil]
        let withFive: [Double?] = [nil, nil, 2, nil, nil, nil, 5]
        let gaps = Array<Double?>(repeating: nil, count: labels.count)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            func image(_ values: [Double?]) -> UIImage {
                CalibrationCartesianTrendRenderer.image(
                    size: size, values: values, smooth: gaps,
                    tickLabels: labels, palette: .semantic,
                    font: UIFont.systemFont(ofSize: 9),
                    traitCollection: traits)
            }
            let left = image(sparse)
            let right = image(withFive)
            let leftCG = try XCTUnwrap(left.cgImage)
            let rightCG = try XCTUnwrap(right.cgImage)
            let scale = left.scale
            // Isolate only the x=2/6 score column. The added +5 is far away
            // and cannot affect the screenshot unless the y-axis auto-scales.
            let crop = CGRect(x: 66 * scale, y: 12 * scale,
                              width: 17 * scale, height: 65 * scale)
            let first = try XCTUnwrap(leftCG.cropping(to: crop))
            let second = try XCTUnwrap(rightCG.cropping(to: crop))
            XCTAssertEqual(UIImage(cgImage: first).pngData(),
                           UIImage(cgImage: second).pngData(),
                           "W13 fixed -5/0/+5 axis must never rescale +2")
        }
        let summary = CalibrationCartesianTrendRenderer.accessibilitySummary(
            values: [nil, 2, nil, -1], smooth: [nil, 1, nil, 0.5],
            tickLabels: ["10-15", "10-16", "10-17", "10-18"],
            scoreWord: "有效记录", averageWord: "最近均线",
            emptyWord: "暂无有效记录")
        XCTAssertEqual(summary, "有效记录 2/4；10-18 -1.0；最近均线 +0.5")
        let none = CalibrationCartesianTrendRenderer.accessibilitySummary(
            values: [nil, nil], smooth: [nil, nil],
            tickLabels: ["10-15", "10-16"],
            scoreWord: "有效记录", averageWord: "最近均线",
            emptyWord: "暂无有效记录")
        XCTAssertEqual(none, "暂无有效记录",
            "A missing day must never be announced as score zero")
    }

    /// Both presentation hosts invoke exactly the same CoreGraphics painter.
    /// Snapshot parity is proven here; SpringBoard placement and device scale
    /// still require a separate WidgetKit/physical-device acceptance record.
    @MainActor
    func testCartesianRendererHasIdenticalUIKitAndWidgetImagePaths() throws {
        let size = CGSize(width: 168, height: 94)
        let values: [Double?] = [nil, 2, nil, -1, nil, 0, 1]
        let average: [Double?] = [nil, 2, nil, 0.5, nil, 0.3, 0.5]
        let dates = ["10-15", "10-16", "10-17", "10-18", "10-19", "10-20", "10-21"]
        let font = ImpressV3Appearance.Typography.micro
        let palette = CalibrationCartesianPalette(
            axis: ImpressV3Appearance.divider,
            secondary: ImpressV3Appearance.secondaryText,
            accent: ImpressV3Appearance.accent)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let widgetBitmap = CalibrationCartesianTrendRenderer.image(
                size: size, values: values, smooth: average,
                tickLabels: dates, palette: palette, font: font,
                traitCollection: traits)
            let nativeBitmap = UIGraphicsImageRenderer(size: size).image { canvas in
                CalibrationCartesianTrendRenderer.draw(
                    in: CGRect(origin: .zero, size: size),
                    context: canvas.cgContext,
                    values: values, smooth: average, tickLabels: dates,
                    palette: palette, font: font, traitCollection: traits)
            }
            XCTAssertEqual(widgetBitmap.size, nativeBitmap.size)
            XCTAssertEqual(widgetBitmap.pngData(), nativeBitmap.pngData(),
                "Identical render inputs must have identical pixel geometry")
            let emptyImage = CalibrationCartesianTrendRenderer.image(
                size: size, values: Array(repeating: nil, count: 7),
                smooth: Array(repeating: nil, count: 7),
                tickLabels: dates, palette: palette, font: font,
                traitCollection: traits)
            XCTAssertNotEqual(widgetBitmap.pngData(), emptyImage.pngData(),
                "A real scored point must be visible; missing points stay empty")
            let proof = XCTAttachment(image: widgetBitmap)
            proof.name = style == .light
                ? "Calibration-Shared-Cartesian-Light-168x94"
                : "Calibration-Shared-Cartesian-Dark-168x94"
            proof.lifetime = .keepAlways
            add(proof)
        }
    }



    /// CoreGraphics screenshot evidence, not physical SpringBoard Widget QA.
    /// Anchors lock the scale: a missing isolated point cannot hide behind
    /// a merely changed y-axis when comparing rendered bitmaps.
    @MainActor
    func testCartesianGappedMultiIsolatesAreVisibleInSixWidgetCanvases() throws {
        let cases: [(String, Int, CGSize)] = [
            ("week-small", 7, CGSize(width: 142, height: 76)),
            ("week-medium", 7, CGSize(width: 300, height: 104)),
            ("month-small", 30, CGSize(width: 142, height: 76)),
            ("month-medium", 30, CGSize(width: 300, height: 104)),
            ("year-small", 12, CGSize(width: 142, height: 76)),
            ("year-medium", 12, CGSize(width: 300, height: 104))
        ]
        for (name, count, size) in cases {
            var scores = Array<Double?>(repeating: nil, count: count)
            scores[1] = 2
            scores[count / 2] = -1
            scores[count - 2] = 1
            var means = Array<Double?>(repeating: nil, count: count)
            means[1] = 1
            means[count / 2] = 0.5
            means[count - 2] = 0
            let gaps = Array<Double?>(repeating: nil, count: count)
            var anchor = gaps
            anchor[0] = 2
            anchor[1] = 2
            let labels = (0..<count).map { String($0) }
            for style in [UIUserInterfaceStyle.light, .dark] {
                let traits = UITraitCollection(userInterfaceStyle: style)
                func render(_ values: [Double?], _ smooth: [Double?]) -> UIImage {
                    CalibrationCartesianTrendRenderer.image(
                        size: size, values: values, smooth: smooth,
                        tickLabels: labels, palette: .semantic,
                        font: UIFont.preferredFont(forTextStyle: .caption2),
                        traitCollection: traits)
                }
                let grayBaseline = render(gaps, anchor)
                let blueBaseline = render(anchor, gaps)
                let grayIsolates = render(scores, anchor)
                let blueIsolates = render(anchor, means)
                XCTAssertNotEqual(grayIsolates.pngData(), grayBaseline.pngData(),
                    "\(name): separated gray score points must be visible")
                XCTAssertNotEqual(blueIsolates.pngData(), blueBaseline.pngData(),
                    "\(name): separated blue mean points must be visible")
                let joined = render(scores, means)
                let native = UIGraphicsImageRenderer(size: size).image { canvas in
                    CalibrationCartesianTrendRenderer.draw(
                        in: CGRect(origin: .zero, size: size),
                        context: canvas.cgContext, values: scores, smooth: means,
                        tickLabels: labels, palette: .semantic,
                        font: UIFont.preferredFont(forTextStyle: .caption2),
                        traitCollection: traits)
                }
                XCTAssertEqual(joined.pngData(), native.pngData(),
                    "\(name): App and Widget must share pixel geometry")
                let proof = XCTAttachment(image: joined)
                proof.name = "Calibration-Cartesian-Canvas-\(name)-\(style == .dark ? "dark" : "light")"
                proof.lifetime = .keepAlways
                add(proof)
            }
        }
    }

    // Localized production-owned copy only; no user goals or Vault text.
    // The preexisting five-indicator legacy translations remain for old data.
    @MainActor
    func testCalibrationFourGoalCopyUsesCentralThreeLanguageTranslations() {
        let keys: [String] = [
            "今日尚未完成四项评估",
            "今日待评估 %d / 4 项",
            "四项固定行为；未评估不会自动扣分。",
            "四项均已处理 · 本日提醒可停止 · 不代表个人价值",
            "桌面组件无法访问共享存储。请检查 App 与 Widget 的签名均包含 App Group，然后重新打开校准器。",
            "桌面组件快照尚未生成。请确认共享权限，并重新进入校准器同步。",
            "桌面组件的共享记录过期或无效。检查时区及共享权限后重新打开应用。",
            "今日四项 · 点击进行评估",
            "额外行为修正 · 已结算（只读）",
            "睡眠",
            "阅读",
            "有效记录",
            "最近均线",
            "暂无有效记录",
            "睡眠、运动、饮食、阅读：完成 +1，未完成 -1，休息或豁免 0。",
            "当日 CLOSED：不得修改评分与额外修正。",
            "经系统授权后，在 20:00、22:00 提醒；完成当日四项后撤销剩余提醒。iOS 允许用户清除系统通知，无法创建永久置顶通知。",
        ]
        for key in keys {
            let english = ImpressV3Language.text(key, language: .english)
            let traditional = ImpressV3Language.text(key, language: .traditional)
            XCTAssertNotEqual(english, key, "English must not fall back to Simplified: \(key)")
            XCTAssertFalse(traditional.isEmpty)
            XCTAssertFalse(english.unicodeScalars.contains(where: {
                (0x4E00...0x9FFF).contains($0.value)
            }), "English copy must not contain unlocalized Han text: \(key)")
        }
        XCTAssertEqual(
            String(format: ImpressV3Language.text(
                "今日待评估 %d / 4 项", language: .english), 3),
            "Assessments Pending: 3 / 4")
        XCTAssertEqual(ImpressV3Language.text("睡眠", language: .english), "Sleep")
        XCTAssertEqual(ImpressV3Language.text("阅读", language: .english), "Reading")
    }

    /// Test the actual signed Simulator App Group. A plist declaration alone
    /// cannot prove that the installed app has permission to open it.
    func testWidgetSignedAppGroupContainerRoundTrip() throws {
        #if targetEnvironment(simulator)
        let fm = FileManager.default
        let root = try XCTUnwrap(fm.containerURL(
            forSecurityApplicationGroupIdentifier: "group.areu.impress"),
            "Signed Simulator app cannot open the shared App Group")
        let url = root.appendingPathComponent(
            ".impress-widget-signing-probe-" + UUID().uuidString)
        defer { try? fm.removeItem(at: url) }
        let marker = Data(("synthetic-widget-qa-" + UUID().uuidString).utf8)
        try marker.write(to: url, options: .atomic)
        XCTAssertEqual(try Data(contentsOf: url), marker)
        XCTAssertTrue(ImVaultGuardedWrite.productionWriteEnabled)
        #endif
    }

    // W13/UI-04: the calibration tableHeaderView used fixed 290/330 heights,
    // which clipped the shared chart and signing diagnostics at large type.
    @MainActor
    func testCalibrationHeaderFitsThreeLanguagesLargeTypeAndWidgetDiagnostics() throws {
        let calibration = ImpressCalibrationViewController()
        calibration.loadViewIfNeeded()
        calibration.view.frame = CGRect(x: 0, y: 0, width: 320, height: 700)
        let header = try XCTUnwrap(calibration.tableView.tableHeaderView)
        let stack = try XCTUnwrap(header.subviews.compactMap { $0 as? UIStackView }.first)
        let labels = stack.arrangedSubviews.compactMap { $0 as? UILabel }
        XCTAssertGreaterThanOrEqual(labels.count, 3)
        let traits = UITraitCollection(
            preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let headline = labels[0], detail = labels[1], diagnostic = labels[2]
        headline.font = UIFont.preferredFont(forTextStyle: .largeTitle,
                                            compatibleWith: traits)
        detail.font = UIFont.preferredFont(forTextStyle: .body,
                                          compatibleWith: traits)
        diagnostic.font = UIFont.preferredFont(forTextStyle: .body,
                                              compatibleWith: traits)
        let fixtures = [
            ("今日待评估：睡眠、运动、饮食、阅读。",
             "未评估的项目不会自动扣分。",
             "共享 App Group 快照不可用，请检查应用与扩展签名。"),
            ("今日待評估：睡眠、運動、飲食、閱讀。",
             "尚未評估的項目不會自動扣分。",
             "共用 App Group 快照無法使用，請檢查應用程式與擴充的簽署。"),
            ("Today: assess sleep, exercise, nutrition and reading.",
             "Missing assessments do not count as failed tasks.",
             "Shared widget snapshot unavailable. Check App Group signatures.")
        ]
        for (title, description, warning) in fixtures {
            headline.text = String(repeating: title, count: 2)
            detail.text = String(repeating: description, count: 2)
            diagnostic.text = String(repeating: warning, count: 2)
            diagnostic.isHidden = false
            calibration.viewDidLayoutSubviews()
            let expanded = try XCTUnwrap(calibration.tableView.tableHeaderView?.frame.height)
            XCTAssertEqual(headline.numberOfLines, 0)
            XCTAssertEqual(detail.numberOfLines, 0)
            XCTAssertGreaterThan(expanded, 330,
                "Header must grow beyond the old fixed height: \(title)")
            diagnostic.isHidden = true
            calibration.viewDidLayoutSubviews()
            let collapsed = try XCTUnwrap(calibration.tableView.tableHeaderView?.frame.height)
            XCTAssertLessThan(collapsed, expanded,
                "Hiding a diagnostic must release its height: \(title)")
        }
    }
}
