//
//  ImBaseViewController.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 12/3/22.
// 

import UIKit

open class ImBaseViewController: UIViewController
{
    override init(nibName nibNameOrNil: String?,bundle nibBundleOrNil: Bundle?)
    {
        super.init(nibName: nil, bundle: nil)
    }
    
    // intent理解
    required public init?(coder: NSCoder)
    {
        fatalError("init(coder:) has not been implemented")
    }
    
    open override func viewDidDisappear(_ animated: Bool)
    {
        super.viewDidDisappear(animated)
    }
    
    open override func viewDidLoad()
    {
        super.viewDidLoad()
        view.backgroundColor = bgColor
    }
    
    open override func didReceiveMemoryWarning()
    {
        super.didReceiveMemoryWarning()
        zcLog("Memory overflow in \(self)")
    }
 
    /// 子类重载刷新页面
    /// - Parameter model: 对应页面的Model
    func updatTableViewData(model:ImNoteModel) {}

    // MARK: - Floating Button Management

    /// 显示浮动按钮
    /// - Parameter position: 按钮位置，默认左下角
    func showFloatingButton(position: FloatingButtonPosition = .bottomLeft) {
        ImFloatingButtonManager.shared.showFloatingButton(in: self, position: position)
    }

    /// 隐藏浮动按钮
    func hideFloatingButton() {
        ImFloatingButtonManager.shared.hideFloatingButton()
    }

    /// 更新浮动按钮位置
    /// - Parameter position: 新位置
    func updateFloatingButtonPosition(_ position: FloatingButtonPosition) {
        ImFloatingButtonManager.shared.updateButtonPosition(position)
    }

    /// 子类可以重写此方法来决定是否显示浮动按钮
    /// 默认返回 false，子类需要时重写返回 true
    open var shouldShowFloatingButton: Bool {
        return false
    }

    /// 子类可以重写此方法来自定义浮动按钮位置
    /// 默认返回左下角
    open var floatingButtonPosition: FloatingButtonPosition {
        return .bottomLeft
    }
}

// MARK: - View Lifecycle for Floating Button
extension ImBaseViewController {
    open override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // 移除全局浮动按钮自动显示逻辑，由子类手动控制
    }

    open override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        // 隐藏浮动按钮，避免在其他页面显示
        hideFloatingButton()
    }
}
