//
//  ImAlertController.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 12/8/22.
//  Copyright © 2022 aReu. All rights reserved.
//

import UIKit

enum AlertActionResult
{
    case cancel
    case ok
    // 当前业务上非必要枚举参数
//    case failure
//    case custom(String) // 用于扩展其他自定义操作
}


class ImAlertController
{
    
    static let shared = ImAlertController()

    
    // MARK: - Functions
    private func topMostController() -> UIViewController?
    {
        var presentedVC = getKeyWindow()?.rootViewController
        while let pVC = presentedVC?.presentedViewController
        {
            presentedVC = pVC
        }
        if presentedVC == nil {
            zcLog("ImAlertController Error: You don't have any views set. You may be calling in viewdidload. Try viewdidappear.")
        }
        return presentedVC
    }

    /// 通用弹窗函数
    @discardableResult
    open class func alert(message: String? = nil,
                          buttons:[String]? = nil,
                          _ tapBlock: ((AlertActionResult) -> Void)? = nil) -> UIAlertController
    {
        return alert(message: message, in: nil, buttons: buttons, tapBlock)
    }
    
    /// 通用弹窗函数 - 支持指定控制器
    @discardableResult
    open class func alert(message: String? = nil,
                          in controller: UIViewController? = nil,
                          buttons:[String]? = nil,
                          _ tapBlock: ((AlertActionResult) -> Void)? = nil) -> UIAlertController
    {
        let alert = UIAlertController(title: alertTips,
                                      message: message,
                                      preferredStyle: .alert,
                                      buttons: buttons,
                                      tapBlock: {(action,index) in
                                        guard let btns = buttons else {
                                            tapBlock?(.ok)
                                            return
                                        }
                                        switch btns.count{
                                        case 1:
                                            tapBlock?(.ok)
                                            break
                                        case 2:
                                            tapBlock?( index == 0 ? .cancel : .ok)
                                            break
                                        default:break
                                        }
                                      })
        
        // 优先使用指定的控制器，否则使用顶层控制器
        if let targetController = controller ?? shared.topMostController() {
            targetController.present(alert, animated: true, completion: nil)
        }
        
        return alert
    }
    
    
    /// 成功/失败函数
    @discardableResult
    open class func warningAlert(_ message: String) -> UIAlertController
    {
        let alert = UIAlertController(title: alertWarning,
                                      message: message,
                                      preferredStyle: .alert,
                                      buttons: nil,
                                      tapBlock: nil)
        shared.topMostController()?.present(alert, animated: true, completion: nil)
        return alert
    }
    
    
    // MARK: - alertActionSheet
    @discardableResult
    open class func actionSheet(_ title: String, message: String, sourceView: UIView, actions: [UIAlertAction]) -> UIAlertController
    {
        let alert = UIAlertController(title: title, message: message, preferredStyle: UIAlertController.Style.actionSheet)
        for action in actions {
            alert.addAction(action)
        }
        alert.popoverPresentationController?.sourceView = sourceView
        alert.popoverPresentationController?.sourceRect = sourceView.bounds
        shared.topMostController()?.present(alert, animated: true, completion: nil)
        return alert
    }

    @discardableResult
    open class func actionSheet(_ title: String, message: String, sourceView: UIView, buttons:[String], tapBlock:((UIAlertAction,Int) -> Void)?) -> UIAlertController{
        let alert = UIAlertController(title: title, message: message, preferredStyle: .actionSheet, buttons: buttons, tapBlock: tapBlock)
        alert.popoverPresentationController?.sourceView = sourceView
        alert.popoverPresentationController?.sourceRect = sourceView.bounds
        shared.topMostController()?.present(alert, animated: true, completion: nil)
        return alert
    }
}



// MARK: - UIAlertController Extension
private extension UIAlertController
{
    convenience init(title: String?,
                     message: String?,
                     preferredStyle: UIAlertController.Style,
                     buttons:[String]?,
                     tapBlock:((UIAlertAction,Int) -> Void)?)
    {
        self.init(title: title, message: message, preferredStyle:preferredStyle)
        guard let buttons = buttons else {
            // fix取消按钮
            self.addAction(UIAlertAction(title: alertDescription.last!, style: .cancel))
            return
        }
        var buttonIndex = 0
        for buttonTitle in buttons {
            let action = UIAlertAction(title: buttonTitle,
                                       preferredStyle: .default,
                                       buttonIndex: buttonIndex,
                                       tapBlock: tapBlock)
            buttonIndex += 1
            self.addAction(action)
        }
    }
}



private extension UIAlertAction
{
    convenience init(title: String?,
                     preferredStyle: UIAlertAction.Style,
                     buttonIndex:Int,
                     tapBlock:((UIAlertAction,Int) -> Void)?)
    {
        self.init(title: title, style: preferredStyle) { (action:UIAlertAction) in
            if let block = tapBlock {
                block(action,buttonIndex)
            }
        }
    }
}

