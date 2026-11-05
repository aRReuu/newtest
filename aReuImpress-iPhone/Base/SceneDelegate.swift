//
//  SceneDelegate.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 12/3/22.
//

import UIKit
import IQKeyboardManagerSwift
import ImpressReviewCore

class SceneDelegate: UIResponder, UIWindowSceneDelegate
{
    var window: UIWindow?
    private var isolatedV11Fixture: Bool {
        #if DEBUG
        return ImpressV11UITestFixture.enabled
        #else
        return false
        #endif
    }

    // The restore safety gate must use exactly the same defaults domain as
    // AppDelegate's restore transaction. A disposable UI fixture must neither
    // clear the live-app guard nor bypass an interrupted fixture rollback.
    private var restoreSafetyDefaults: UserDefaults? {
        #if DEBUG
        if ImpressV11UITestFixture.requested {
            // A missing/malformed UUID must NOT use .standard as a fallback.
            // blocksDatabaseLaunch(nil) rejects the launch before WCDB opens.
            guard let fixture = ImpressV11UITestFixture.coldRestorePaths else {
                return nil
            }
            return UserDefaults(suiteName: fixture.promptsSuiteName)
        }
        #endif
        return .standard
    }

    static func blocksDatabaseLaunch(recoveryDefaults: UserDefaults?) -> Bool {
        // If the fixture suite is unavailable, fail closed rather than
        // accidentally opening a half-restored synthetic WCDB database.
        recoveryDefaults?.bool(forKey: ImpressV3BackupCoordinator.recoveryBlockKey) ?? true
    }
    
    @available(iOS 13.0, *)
    func scene(_ scene: UIScene,
               willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions)
    {
        guard let _ = (scene as? UIWindowScene) else { return }
        // Install neutral navigation tint before primary or modal bars exist.
        ImpressV3Appearance.installGlobalNavigationChrome()
//        launchDelay()
        // connectionOptions can carry a cold-start tap before the system
        // notification delegate receives its callback.
        if ImpressV3ReviewEnvironment.pilotEnabled,
           let response = connectionOptions.notificationResponse,
           ImpressV3NotificationCoordinator.isReviewTap(
                actionIdentifier: response.actionIdentifier,
                requestIdentifier: response.notification.request.identifier) {
            ImpressV3NotificationRouteInbox.shared.enqueueReview()
        }
        if let response = connectionOptions.notificationResponse,
           ImpressCalibrationReminderCoordinator.isCalibrationTap(response) {
            ImpressCalibrationNotificationRouteInbox.shared.enqueue()
        }
        #if DEBUG
        // A standalone POC bypasses live WCDB, providers and the Vault entirely.
        // It is reachable only through an explicit Simulator launch argument.
        if ProcessInfo.processInfo.arguments.contains("-ImpressChatPOC") {
            window?.rootViewController = UINavigationController(
                rootViewController: ImpressChatPOCViewController())
            window?.backgroundColor = ImpressV3Appearance.page
            window?.makeKeyAndVisible()
            initKeyboard()
            return
        }
        #endif
        // Never open SQLite if an interrupted multi-file restore still needs
        // its durable rollback. AppDelegate attempts repair before Scene startup.
        guard !Self.blocksDatabaseLaunch(recoveryDefaults: restoreSafetyDefaults) else {
            showDatabaseUnavailable()
            return
        }
        // Open only V3; the abandoned impressdata.db is not migrated,
        // opened, cleared or recreated as part of the live startup path.
        do { _ = try ImpressV3ReviewEnvironment.repository() }
        catch { showDatabaseUnavailable(); return }
        initRootVC()
        // Capture external Widget intent before normal startup routing. Apply
        // it after queued notification delivery so this explicit tap wins,
        // without erasing any pending notification or existing user draft.
        let incomingWidgetURL = connectionOptions.urlContexts.first?.url
        // Silent V3 backup check: no file picker or cloud permission prompt.
        if !isolatedV11Fixture {
            Task(priority: .utility) {
                await ImpressV3BackupCoordinator.shared.backupIfNeeded()
            }
        }
        ImpressV3NotificationRouteInbox.shared.deliverIfPossible(
            in: window?.rootViewController)
        ImpressCalibrationNotificationRouteInbox.shared.deliverIfPossible(
            in: window?.rootViewController)
        ImpressCalibrationReminderCoordinator.shared.requestReconciliation()
        if let incomingWidgetURL { openCalibrationWidgetLink(incomingWidgetURL) }
        initKeyboard()
    }
    
    @available(iOS 13.0, *)
    func scene(_ scene: UIScene, openURLContexts URLContexts: Set<UIOpenURLContext>) {
        if let url = URLContexts.first?.url { openCalibrationWidgetLink(url) }
    }

    /// Route by controller identity, not a fixed Tab index or new calibration store.
    private func openCalibrationWidgetLink(_ url: URL) {
        guard url.scheme == "impress", url.host == "calibration",
              url.query == nil, url.fragment == nil,
              url.pathComponents.count == 2,
              let key = url.pathComponents.last,
              let period = CalibrationWidgetPeriod(rawValue: key),
              let tabs = window?.rootViewController as? ImTabBarViewController,
              let controllers = tabs.viewControllers,
              let index = controllers.firstIndex(where: {
                  ($0 as? UINavigationController)?.viewControllers.first is
                      ImpressCalibrationViewController
              }),
              let nav = controllers[index] as? UINavigationController,
              let calibration = nav.viewControllers.first as? ImpressCalibrationViewController
        else { return }
        tabs.selectedIndex = index
        nav.popToRootViewController(animated: false)
        calibration.selectWidgetPeriod(period)
    }

    @available(iOS 13.0, *)
    func sceneDidDisconnect(_ scene: UIScene)
    {
        // Do not close WCDB while async operations may still be executing.
        // The thread-safe database handle pool owns its connection lifetime.
    }

    @available(iOS 13.0, *)
    func sceneDidEnterBackground(_ scene: UIScene) {
        NotificationCenter.default.post(name: .appDidEnterBackground, object: nil)
        // Best-effort only: iOS may suspend this work.
        if !isolatedV11Fixture {
            Task(priority: .utility) {
                await ImpressV3BackupCoordinator.shared.backupIfNeeded()
            }
        }
    }
    
    @available(iOS 13.0, *)
    func sceneWillEnterForeground(_ scene: UIScene) {}
    
    @available(iOS 13.0, *)
    func sceneDidBecomeActive(_ scene: UIScene)
    {
        // Foreground resumes are new uses even without a cold launch.
        // The coordinator avoids redundant copies when nothing changed.
        if !isolatedV11Fixture {
            Task(priority: .utility) {
                await ImpressV3BackupCoordinator.shared.backupIfNeeded()
            }
        }
        ImpressV3NotificationRouteInbox.shared.deliverIfPossible(
            in: window?.rootViewController)
        ImpressCalibrationNotificationRouteInbox.shared.deliverIfPossible(
            in: window?.rootViewController)
        ImpressV3NotificationCoordinator.shared.requestReconciliation()
        ImpressCalibrationReminderCoordinator.shared.requestReconciliation()
        // Includes a successful cold-start backup restore and local date/time-zone changes.
        if !isolatedV11Fixture {
            Task(priority: .utility) {
                await ImpressCalibrationWidgetExporter.publishFromAuthoritativeStore()
            }
        }
    }
}


// MARK: - initSetting
extension SceneDelegate
{
    func initRootVC()
    {
        let tabBarVC = ImTabBarViewController()
        window?.rootViewController = tabBarVC
        window?.backgroundColor = ImpressV3Appearance.page
        ImpressV3Appearance.applyAppearance(to: window)
        window?.makeKeyAndVisible()
    }
    
    private func showDatabaseUnavailable() {
        let unavailableVC = UIViewController()
        unavailableVC.view.backgroundColor = .systemBackground
        let message = UILabel()
        message.text = "数据库初始化失败，请重新启动应用后重试。"
        message.numberOfLines = 0
        message.textAlignment = .center
        message.textColor = .label
        message.translatesAutoresizingMaskIntoConstraints = false
        unavailableVC.view.addSubview(message)
        NSLayoutConstraint.activate([
            message.leadingAnchor.constraint(equalTo: unavailableVC.view.leadingAnchor, constant: 24),
            message.trailingAnchor.constraint(equalTo: unavailableVC.view.trailingAnchor, constant: -24),
            message.centerYAnchor.constraint(equalTo: unavailableVC.view.centerYAnchor)
        ])
        window?.rootViewController = unavailableVC
        ImpressV3Appearance.applyAppearance(to: window)
        window?.makeKeyAndVisible()
    }

    /// 初始化键盘配置
    private func initKeyboard()
    {
        let keyboard = IQKeyboardManager.shared
        keyboard.enable = true
        keyboard.enableAutoToolbar = false
        keyboard.shouldResignOnTouchOutside = true
        keyboard.overrideKeyboardAppearance = true
        // 添加全局配置，确保不会被局部设置覆盖
        keyboard.layoutIfNeededOnUpdate = false
        keyboard.keyboardDistanceFromTextField = defaultSpacing
    }


}
