//
//  ImpressRoute.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 3/3/23.
//  后续进行其他优化


class ImpressRoute
{
    public static func pushToCardViewController()
    {
        guard let rootVC = getKeyWindow()?.rootViewController else {
            zcLog("rootViewController is nil!"); return
        }
        
        // 创建卡片控制器，并传入推送关联的卡片数据
        // 这里一定是模态最好的,为了方便后续在不同控制器下都可以跳转
        let cardVC = ImCardViewController()
        let navVC = ImNavigationViewController.init(rootViewController: cardVC)
        rootVC.present(navVC, animated: true)
    }
}
