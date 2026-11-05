//
//  ImTabBarViewController.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 12/24/22.
//

import UIKit

class ImTabBarViewController: UITabBarController
{
    override func viewDidLoad()
    {
        super.viewDidLoad()
        tabBarSetting()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshLanguage),
            name: ImpressV3Language.didChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func refreshLanguage() {
        guard let navigation = viewControllers?.compactMap({ $0 as? UINavigationController }),
              navigation.count == 4 else { return }
        let keys = ["闪卡", "笔记", "校准器", "设置"]
        for (index, item) in navigation.enumerated() {
            item.tabBarItem.title = V3L(keys[index])
        }
    }

    override func viewDidAppear(_ animated: Bool)
    {
        super.viewDidAppear(animated)
        // 备份逻辑已迁移到APP冷启动时执行
    }

    private func tabBarSetting()
    {
        let cardVC = ImpressV3ReviewViewController()
        let cardNav = ImNavigationViewController(rootViewController: cardVC)
        cardNav.tabBarItem.title = V3L("闪卡")
        cardNav.tabBarItem.image = UIImage(systemName: "square.stack.3d.up")
        cardNav.tabBarItem.selectedImage = UIImage(systemName: "square.stack.3d.up.fill")
        
        // The existing Vault reader is now a primary, independent destination.
        // It keeps the same permission, search and Markdown controller.
        let notesVC = ImpressNoteListTableViewController()
        let notesNav = ImNavigationViewController(rootViewController: notesVC)
        notesNav.tabBarItem.title = V3L("笔记")
        notesNav.tabBarItem.image = UIImage(systemName: "text.book.closed")
        notesNav.tabBarItem.selectedImage = UIImage(systemName: "text.book.closed.fill")

        // The existing calibration screen and shared store are a primary route.
        // Keeping its previous Settings entry preserves an alternate route, not data.
        let calibrationVC = ImpressCalibrationViewController()
        let calibrationNav = ImNavigationViewController(rootViewController: calibrationVC)
        calibrationNav.tabBarItem.title = V3L("校准器")
        calibrationNav.tabBarItem.image = UIImage(systemName: "chart.xyaxis.line")
        calibrationNav.tabBarItem.selectedImage = UIImage(systemName: "chart.xyaxis.line")

        let settingsVC = ImpressV3SettingsHubViewController()
        let settingsNav = ImNavigationViewController(rootViewController: settingsVC)
        settingsNav.tabBarItem.title = V3L("设置")
        settingsNav.tabBarItem.image = UIImage(systemName: "gearshape")
        settingsNav.tabBarItem.selectedImage = UIImage(systemName: "gearshape.fill")

        self.viewControllers = [cardNav, notesNav, calibrationNav, settingsNav]
        // Page extends underneath the native floating bar; no fake glass.
        view.backgroundColor = ImpressV3Appearance.page
        ImpressV3Appearance.styleTabBar(tabBar)
        if #available(iOS 26.0, *) {
            // Keep primary navigation stationary while reading or reviewing.
            tabBarMinimizeBehavior = .never
        }
    }
}
