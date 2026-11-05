//
//  ImNotificationHandler.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 12/8/22.
//  负责请求推送/接收推送的事件处理

import Foundation
import UserNotifications
import WCDBSwift

/// 推送目录类型
enum CategoryType: String
{
    case custom //自定义类型
    case ebBingHaus //艾宾浩斯
}

class ImNotificationHandler: NSObject
{
    static let share = ImNotificationHandler()
    
    private let ntCenter = UNUserNotificationCenter.current()

    /// 一小时后进行推送标识
    private var oneHourReminderIdentifier = "miemie.oneHourReminder"
}


// MARK: - 注册
extension ImNotificationHandler
{
    
    /// 本地推送权限开通
    public func requestAuthorization()
    {
        ntCenter.requestAuthorization(options: [.alert, .badge, .sound]) {(granted, error) in
            zcLog("授予状态:\(granted)")
            if let e = error {zcLog(e)}
        }
        ntCenter.delegate = self
    }
}


// MARK: - 冷/热启动接收消息推送
extension ImNotificationHandler: UNUserNotificationCenterDelegate
{
    /// 前台接收推送通知处理
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void)
    {
        handlerNotify(notification)
        let options:UNNotificationPresentationOptions = [.sound]
        completionHandler(options)
    }
    
    /// 启动APP通知处理
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void)
    {
        handlerNotify(response.notification)
        completionHandler()
    }
    
    /// 前台或启动APP后处理接收数据
    /// - Parameters:
    ///   - notification: <#notification description#>
    private func handlerNotify(_ notification: UNNotification)
    {
        DispatchQueue.main.async {
            ImpressRoute.pushToCardViewController()
        }
    }
}

// MARK: - 常规通知消息获取与测试推送功能
extension ImNotificationHandler
{
    /// 获取已设定推送数据
    /// - Parameter handleResult: <#handleResult description#>
    public func getRequests(handleResult:@escaping (([String]?)->Void))
    {
        var datas:[String] = []
        //
        let group = DispatchGroup()
        group.enter()
        ntCenter.getPendingNotificationRequests { (requests) in
            for re in requests {
                let identifier = re.identifier
//                let category = re.content.categoryIdentifier
//                let title = re.content.title
                // 提取触发时间
                var triggerTime: String = "Unknown"
                if let calendarTrigger = re.trigger as? UNCalendarNotificationTrigger {
                    let dateComponents = calendarTrigger.dateComponents
                    // 提取时、分
                    if let hour = dateComponents.hour,
                       let minute = dateComponents.minute {
                        triggerTime = String(format: "%02d:%02d", hour, minute)
                    }
                } else if let intervalTrigger = re.trigger as? UNTimeIntervalNotificationTrigger {
                    let fireDate = Date(timeIntervalSinceNow: intervalTrigger.timeInterval)
                    let formatter = DateFormatter()
                    formatter.dateFormat = "yyyy-MM-dd HH:mm"
                    triggerTime = formatter.string(from: fireDate)
                }
                
                let combination = "T:\(triggerTime) - \(identifier)"
                datas.append(combination)
            }
            group.leave()
        }
        group.notify(queue: .main) {
            handleResult(datas)
        }
    }
    
    public func testNotificaiton()
    {
        let dueCount: Int = 10
        self.ntCenter.removePendingNotificationRequests(withIdentifiers: [dailyReminderIdentifier])
        // 创建通知内容
        let content = UNMutableNotificationContent()
        content.title = "学习时间到了！"
        content.body = "今天有 \(dueCount) 张卡片需进行复习。"
        content.sound = .default
        content.badge = NSNumber(value: dueCount)

        var dateComponents = DateComponents()
        dateComponents.hour = 9
        dateComponents.minute = 0
        
        let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)

        let request = UNNotificationRequest(identifier: dailyReminderIdentifier, content: content, trigger: trigger)
        
        self.ntCenter.add(request) { error in
            if let error = error {
                zcLog("Error scheduling daily reminder: \(error.localizedDescription)")
            } else {
                zcLog("Successfully scheduled daily reminder for \(dueCount) cards.")
            }
        }
    }
    
}


// MARK: - ANkI间隔重复本地通知核心业务
extension ImNotificationHandler
{
    /// 获取到期卡片数量,跟CardVC初始化时保持一致 (包括new cards)
    private func fetchTotalDueCount(completion: @escaping (Int) -> Void)
    {
        let today = Calendar.current.startOfDay(for: Date())
        let dueReviewQuery = (ImCardModel.Properties.state == CardState.review.rawValue || ImCardModel.Properties.state == CardState.lapsed.rawValue) &&
                             (ImCardModel.Properties.dueDate <= today)
        let newQuery = ImCardModel.Properties.state == CardState.new.rawValue
        
        let group = DispatchGroup()
        var dueReviewCount = 0
        var newCount = 0
        
        group.enter()
        dbShare.getRows(table: ImDBTableType.card.description, where: dueReviewQuery) { result in
            if case .success(let count) = result {
                dueReviewCount = Int(count)
            }
            group.leave()
        }
        
        group.enter()
        dbShare.getRows(table: ImDBTableType.card.description, where: newQuery) { result in
            if case .success(let count) = result {
                newCount = Int(count)
            }
            group.leave()
        }
        
        group.notify(queue: .main) {
            let totalDue = dueReviewCount + newCount
            completion(totalDue)
        }
    }
    
    /// 清除已设定推送任务
    private func clearDeliveredNotifications()
    {
        ntCenter.removeAllDeliveredNotifications()
    }
    
    /// 重新调度下一次的提醒
    func rescheduleDailyReminder()
    {
        clearDeliveredNotifications()
        fetchTotalDueCount { [weak self] totalDue in
            guard let self = self else { return }
            // 没有需要复习的卡片，则清除徽章并取消任何已安排的通知。
            // 新的通知将在第二天卡片到期时，通过下一次后台刷新或App启动时重新安排。
            guard totalDue > 0 else {
                self.ntCenter.removePendingNotificationRequests(withIdentifiers: [dailyReminderIdentifier])
                DispatchQueue.main.async {
                    UIApplication.shared.applicationIconBadgeNumber = 0
                }
                zcLog("No cards due. Daily reminder cancelled and badge cleared.")
                return
            }

            let badgeNum = totalDue

            // fix 桌面减法提示,即在当天没有本地消息推送的情况下,依然能够通过桌面的badge显示当天尚未完成的任务
            DispatchQueue.main.async {
                UIApplication.shared.applicationIconBadgeNumber = badgeNum
            }

            // 创建通知内容
            let content = UNMutableNotificationContent()
            content.title = "闪卡时间"
            content.body = "今天有 \(badgeNum) 张卡片等待你复习噢😁~"
            content.sound = .default
            content.badge = NSNumber(value: badgeNum)

            var dateComponents = DateComponents()
            dateComponents.hour = dailyNotifyHour
            dateComponents.minute = 0

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)

            let request = UNNotificationRequest(identifier: dailyReminderIdentifier, content: content, trigger: trigger)

            self.ntCenter.add(request) { error in
                if let error = error {
                    zcLog("Error scheduling daily reminder: \(error.localizedDescription)")
                } else {
                    zcLog("Successfully scheduled daily reminder for \(badgeNum) cards.")
                }
            }
        }
    }

    func ensureOneHourReminderScheduled()
    {
        // 先查询是否已存在该 identifier 的 pending request
        ntCenter.getPendingNotificationRequests { [weak self] requests in
            guard let self = self else { return }
            let exists = requests.contains { $0.identifier == self.oneHourReminderIdentifier }
            if exists {
                zcLog("One-hour reminder already scheduled; no action taken.")
                return
            }

            // 从UserDefaults读取提醒间隔分钟数，默认为30分钟，确保在10-1440范围
            let minutes = UserDefaults.standard.integer(forKey: "kReminderMinutes")
            let validMinutes = max(10, min(1440, minutes)) + 1 // +1 确保有默认值，如果UserDefaults没有则为1分钟+1=2，但下面会用max(30)

            // 确保至少30分钟（避免过于频繁），至多24小时
            let reminderMinutes = max(30, min(1440, validMinutes))

            // 计算指定分钟后的触发时间
            let triggerDate = Date().addingTimeInterval(TimeInterval(reminderMinutes * 60))
            let calendar = Calendar.current
            let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: triggerDate)

            let content = UNMutableNotificationContent()
            content.title = "闪卡提醒"
            content.body = "下一站 ---> 中大."
            content.sound = .default

            let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
            let request = UNNotificationRequest(identifier: self.oneHourReminderIdentifier, content: content, trigger: trigger)

            self.ntCenter.add(request) { error in
                if let error = error {
                    zcLog("Error scheduling one-hour reminder: \(error.localizedDescription)")
                } else {
                    zcLog("Successfully scheduled reminder for \(reminderMinutes) minutes from now.")
                }
            }
        }
    }
}
