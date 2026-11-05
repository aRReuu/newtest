//
//  ImFloatingButtonManager.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 1/15/26.
//

import UIKit

/// 浮动按钮位置枚举
public enum FloatingButtonPosition {
    case bottomLeft
    case bottomRight
}

/// 浮动按钮管理器
/// 负责管理全局浮动按钮的显示、隐藏和位置
class ImFloatingButtonManager {
    static let shared = ImFloatingButtonManager()

    private var floatingButton: UIButton?
    private weak var currentViewController: UIViewController?

    private init() {}

    /// 在指定视图控制器中显示浮动按钮
    /// - Parameters:
    ///   - viewController: 要显示浮动按钮的视图控制器
    ///   - position: 按钮位置，默认左下角
    func showFloatingButton(in viewController: UIViewController, position: FloatingButtonPosition = .bottomLeft) {
        hideFloatingButton()

        currentViewController = viewController

        let button = UIButton(type: .custom)
        button.setImage(UIImage(systemName: "message.circle.fill"), for: .normal)
        button.tintColor = secondaryBgColor
        button.backgroundColor = funBtnColor
        button.layer.cornerRadius = defaultSpacing * 1.5
        button.addTarget(self, action: #selector(showWebView), for: .touchUpInside)

        // 添加拖拽手势
        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePanGesture(_:)))
        button.addGestureRecognizer(panGesture)

        viewController.view.addSubview(button)
        button.translatesAutoresizingMaskIntoConstraints = false

        // 设置位置约束
        setupButtonConstraints(button, in: viewController.view, position: position)

        floatingButton = button
        button.setDefaultCorner()
    }

    /// 隐藏浮动按钮
    func hideFloatingButton() {
        floatingButton?.removeFromSuperview()
        floatingButton = nil
        currentViewController = nil
    }

    /// 更新浮动按钮位置
    /// - Parameter position: 新位置
    func updateButtonPosition(_ position: FloatingButtonPosition) {
        guard let button = floatingButton, let superview = button.superview else { return }

        // 移除现有约束
        button.removeConstraints(button.constraints)

        // 重新设置约束
        setupButtonConstraints(button, in: superview, position: position)
    }

    private func setupButtonConstraints(_ button: UIButton, in view: UIView, position: FloatingButtonPosition) {
        let spacing = defaultSpacing * 4

        switch position {
        case .bottomLeft:
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: defaultSpacing),
                button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -spacing),
                button.widthAnchor.constraint(equalToConstant: spacing),
                button.heightAnchor.constraint(equalToConstant: spacing)
            ])
        case .bottomRight:
            NSLayoutConstraint.activate([
                button.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -defaultSpacing),
                button.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -spacing * 2),
                button.widthAnchor.constraint(equalToConstant: spacing),
                button.heightAnchor.constraint(equalToConstant: spacing)
            ])
        }
    }

    @objc private func showWebView() {
        let webVC = ImWebViewController.shared
        let navVC = ImNavigationViewController(rootViewController: webVC)

        if let currentVC = currentViewController {
            currentVC.present(navVC, animated: true, completion: nil)
        }
    }

    @objc private func handlePanGesture(_ gesture: UIPanGestureRecognizer) {
        guard let button = gesture.view as? UIButton,
              let superview = button.superview else { return }

        let translation = gesture.translation(in: superview)

        switch gesture.state {
        case .changed:
            button.center = CGPoint(x: button.center.x + translation.x, y: button.center.y + translation.y)
            gesture.setTranslation(.zero, in: superview)
        case .ended:
            // 自动吸附到边缘
            let screenWidth = superview.bounds.width
            let buttonWidth = button.bounds.width
            let centerX = button.center.x

            UIView.animate(withDuration: 0.3) {
                if centerX < screenWidth / 2 {
                    // 吸附到左边
                    button.center.x = buttonWidth / 2 + defaultSpacing
                } else {
                    // 吸附到右边
                    button.center.x = screenWidth - buttonWidth / 2 - defaultSpacing
                }
            }
        default:
            break
        }
    }
}

