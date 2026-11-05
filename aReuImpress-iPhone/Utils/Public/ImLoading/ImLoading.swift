//
//  ImLoading.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 3/20/25.
//

import UIKit

class ImLoading
{
    static let share = ImLoading()
    ///
    private var loadingView: UIView?
    ///
    private var activityIndicator: UIActivityIndicatorView?
    
    
    /// 加载视图
    /// - Parameters:
    ///   - view: <#view description#>
    ///   - timeout: 默认为40秒
    func show(timeout: TimeInterval = 40)
    {
        guard let keyView = getKeyWindow() else {return}
        if loadingView != nil { return }
        // 屏幕常亮
        idleSet(true)
        loadingView = UIView(frame:keyView.bounds)
        loadingView?.backgroundColor = bgColor.withAlphaComponent(highlightAlpha)
        loadingView?.center = keyView.center
        
        activityIndicator = UIActivityIndicatorView(style: .large)
        activityIndicator?.center = loadingView!.center
        activityIndicator?.startAnimating()
        
        loadingView?.addSubview(activityIndicator!)
        keyView.addSubview(loadingView!)
        
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {[weak self]  in
            self?.hide()
        }
    }
    
    func hide()
    {
        idleSet(false)
        activityIndicator?.stopAnimating()
        loadingView?.removeFromSuperview()
        loadingView = nil
        activityIndicator = nil
    }
}
