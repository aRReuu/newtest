//
//  Constants.swift
//  CBDemo
//
//  Created by aReu on 2018/11/26.
//  Copyright © 2018年 aReu. All rights reserved.
//  常规配置文件

import UIKit

// MARK: - Home
let convertToCardDes = "生成卡片"

// MARK: - NotesController
//"主动+反复"
let imNotesTitle = "Obsidian"
let imNotesStructureTitle = "结构化"
let impressPageForNotesSearchBarDes = "笔记标题搜索..."
/// 统一删除文案
let impressCellDelDes = "删除"
let deleteReviewMissionWarning = "请二次思考数据价值!"
// nut
let uploadSuccessDes = "数据上传成功!"
let downSuccessDes = "数据下载成功!"
// 笔记内容至少长度
let noteMDLenght = 100

/// 忽略进行读写的文件夹
let ignoreDirectory: Set<String> = ["copilot-conversations", "copilot-custom-prompts","UnuseToMiemie"]


// MARK: - MissionContreller
/// 艾宾浩斯
let ebBingHausBodyTips = "注意: - 高难度!"



// MARK: - CardController
let imOneInsert = "插入卡片"
let imBatchInsertDes = "插入批量卡片(从粘贴板)"
let imCardTitle = "效率卡片"
/// 获取新卡限制数量
let imNewCardLimit = 3
/// 获取临期卡限制数量
let imDueCardLimit = 3

/// 复习间隔小时
let imReviewIntervalHour: Int = 6

// MARK: - ExtracController
let imExtractTitle = "摘录"
let imSearchTitle = "搜索"



// MARK: - 统一通用
// MARK: - 通知相关时间设置
/// 每天指定推送时间
let dailyNotifyHour = 9
let dailyReminderIdentifier = "IM_DAILY_REMINDER"
/// 三天限制
let spacedRepitionHour: TimeInterval = 72



/// 动画参数配置
struct ImAnimationConfig
{
    static let translationX = -ImScreenWidth / 3.0
    
    /// 淡入淡出动画时长 最短效果
    static let fadeAnimationDuration: TimeInterval = 0.3
    /// 最短效果
    static let cellMiniDuration: TimeInterval = 0.1
    /// 中度效果时长
    static let cellMiddleDuration: TimeInterval = 0.8
    /// 最长动画效果时长
    static let cellHighDuration: TimeInterval = 1.0
    // review
    static let generateDelay:TimeInterval = 3.0
}

/// 网络请求:文本符合的最少长度
#if DEBUG
let atleastStringLength = 1
#else
let atleastStringLength = 12
#endif

/// cell高度
let baseCellRowHeight: CGFloat = 44.0
/// cell圆角
let cellCorner: CGFloat = 16.0

/// 全局默认距离
let defaultSpacing: CGFloat = 16.0

/// cell/textview内置话术边距
let textDefaultContainerInset: CGFloat = 15.0
/// 统一弹窗提示话术
let alertDescription = ["取消","确定"]
let alertCancelDescription = ["取消"]
let alertWarning = "警告"
let alertTips = "提示"
/// Screen
let ImScreenWidth     = UIScreen.main.bounds.size.width
let ImScreenHeight    = UIScreen.main.bounds.size.height
/// 鼓励语
let inspireDes = "Big 2 Small, Hard 2 Easy!"

/// 存放数据文件路径
let originDocumentPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first!
let musicPath = originDocumentPath + "/ImMusic"
let documentPath = originDocumentPath + "/ImpressDB"


/// OB文件夹路径
let ObsidianFolderName = "ImpressVault"
let dbName = "impressdata.db"

/// 最低判断长度
let pasteboardLength = 100

/// 请求接口可替换标识
let imReplaceContentIdentifier = "{replace}"
let imReplaceQuestionIdentifier = "{question}"



// MARK: 为什么会采取返回而不是block的实现,发现在函数里面多重block嵌套会导致排版很差,阅读成本提高了
/// 数据返回处理
typealias ImHandlerResult<T> = Result<T,Error>

/// 加载共享
let loadShare = ImLoading.share
let dbShare = ImDBHandler.share
let notificationShare = ImNotificationHandler.share



// MARK: - 通用Function集合
/// 日志输出
public func zcLog<T> (_ message: T, fileName: String = #file, funcName: String = #function, lineNum: Int = #line)
{
    
    #if DEBUG
    let file = (fileName as NSString).lastPathComponent
    print("-\(file) \(funcName)-[\(lineNum)]: \(message)")
    #endif
}

/// 打开白名单APP
func openApp(appName:String)
{
    let appURL = URL.init(string: appName)!
    guard canOpen(appURL) else {return}
    //有效已安装的情况才打开
    UIApplication.shared.open(appURL, options:[UIApplication.OpenExternalURLOptionsKey.universalLinksOnly : false], completionHandler: nil)
}

func canOpen(_ appURL:URL) -> Bool
{
    guard  UIApplication.shared.canOpenURL(appURL) else {
        ImAlertController.warningAlert("failed for URL: \(appURL) - error: This app is not allowed to query for scheme.")
        return false
    }
    return true
}

func idleSet(_ flag:Bool)
{
    UIApplication.shared.isIdleTimerDisabled = flag
}


func getKeyWindow() -> UIWindow?
{
    if #available(iOS 13.0, *) {
        let winScene = UIApplication.shared.connectedScenes.first
        let sd =  winScene?.delegate as! SceneDelegate
        return sd.window!
    }else{
        if let keyWindow = UIApplication.shared.keyWindow {
            return keyWindow
        }
    }
    return nil
}


/// 实现Date秒数级比较,不涉及毫秒及再小单位
/// - Parameter date: <#date description#>
/// - Returns: <#description#>
func trimToSecond(_ date: Date) -> Date
{
    let calendar = Calendar.current
    let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
    return calendar.date(from: comps)!
}


private extension DateFormatter
{
  /// 复用格式化器，避免频繁创建
  static let yyyyMMddHHmm: DateFormatter = {
    let df = DateFormatter()
    df.dateFormat = "yyyy-MM-dd HH:mm"
    df.locale = Locale(identifier: "en_US_POSIX") // 稳定解析/格式化
    df.timeZone = TimeZone.current
    return df
  }()
}

extension Date
{
    func dateToString() -> String
    {
        return DateFormatter.yyyyMMddHHmm.string(from: self)
    }
}
