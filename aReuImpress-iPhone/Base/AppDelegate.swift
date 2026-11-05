//
//  AppDelegate.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 12/3/22.
//  不忘初心,永远也要记得当初为什么要写这个App

import UIKit
import Security


@main
class AppDelegate: UIResponder, UIApplicationDelegate
{
    var window: UIWindow?
    
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool
    {
        #if DEBUG
        // An invalid explicit test fixture must not clean live settings,
        // open real storage or attempt the production restore transaction.
        // SceneDelegate will present database-unavailable (fail closed).
        if ImpressV11UITestFixture.requested && !ImpressV11UITestFixture.enabled {
            NSLog("Rejected invalid synthetic fixture launch before live storage access")
            return true
        }
        #endif
        // Retired local model and GitHub backup credentials must never survive an upgrade.
        ImRetiredCredentialCleanup.eraseLegacyBackupToken()
        for key in ["kIsAutoGenerateEnabled", "kAutoGenerateIntervalHours", "kLastAutoGenerateFetchDate",
                    "kSystemPrompt", "kSystemPromptMigrated"] {
            UserDefaults.standard.removeObject(forKey: key)
        }
        // Apply a previously confirmed recovery only before WCDB opens.
        // A Debug E2E fixture uses the real restore transaction against
        // UUID-scoped temporary targets, never the application's real Support,
        // Documents, calibration ledger or prompts domain.
        do {
            #if DEBUG
            if ImpressV11UITestFixture.requested {
                guard let fixture = ImpressV11UITestFixture.coldRestorePaths,
                      let isolatedPrompts = UserDefaults(
                    suiteName: fixture.promptsSuiteName) else {
                    throw ImpressV3BackupFailure.notAuthorized
                }
                try ImpressV3BackupCoordinator.testApplyPendingAtColdLaunch(
                    root: fixture.support, documents: fixture.documents,
                    calibration: fixture.calibration, prompts: isolatedPrompts)
            } else {
                try ImpressV3BackupCoordinator.applyPendingAtColdLaunch()
            }
            #else
            try ImpressV3BackupCoordinator.applyPendingAtColdLaunch()
            #endif
        } catch {
            // Synthetic cold-start errors belong to the same disposable suite
            // as the restore journal, never the user's normal Settings state.
            #if DEBUG
            let failureDefaults: UserDefaults?
            if ImpressV11UITestFixture.requested {
                failureDefaults = ImpressV11UITestFixture.coldRestorePaths
                    .flatMap { UserDefaults(suiteName: $0.promptsSuiteName) }
            } else {
                failureDefaults = .standard
            }
            #else
            let failureDefaults: UserDefaults? = .standard
            #endif
            // Never write a malformed fixture's startup error to live settings.
            failureDefaults?.set(
                "恢复未完成：" + error.localizedDescription,
                forKey: ImpressV3BackupCoordinator.failureKey)
        }
        // V3 alone handles notification routing; no retired reminder policy.
        ImpressV3NotificationCoordinator.shared.installDelegate()
        return true
    }

    // MARK: UISceneSession Lifecycle
    @available(iOS 13.0, *)
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration
    {
        let sceneConfiguration = UISceneConfiguration(name: "Default Configuration",
                                                      sessionRole: connectingSceneSession.role)
        sceneConfiguration.delegateClass = SceneDelegate.self
        return sceneConfiguration
    }
}

/// Only this retired application's own GitHub-backup Keychain item is targeted.
/// It does not touch iCloud, Obsidian permissions or any third-party login.
private enum ImRetiredCredentialCleanup {
    static func eraseLegacyBackupToken() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.impress.github.token",
            kSecAttrAccount as String: "github_token"
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            NSLog("Legacy backup credential cleanup returned OSStatus %d", status)
        }
    }
}
