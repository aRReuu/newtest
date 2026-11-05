//
//  ImSubmitProtocol.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 8/22/25.
//


/// 不同模式对应话术类型
enum ImSubmitType
{
    /// 卡片新增
    case card
    /// 卡片修改
    case cardEdit
    /// 摘录页面
    case extract
    
    var itemTitle: String {
        switch self {
        case .card: return "新增卡片"
        case .cardEdit: return "修改卡片"
        case .extract: return "碎片化摘录"
        }
    }
    
    var sectionTitle: [String] {
        switch self {
        case .card: return ["新增标题","新增答案"]
        case .cardEdit: return ["编辑标题","编辑答案"]
        case .extract: return ["摘录标题","摘录内容"]
        }
    }
}

/// 提交页面数据基础协议,包含所有场景都需要的核心功能
protocol ImSubmitBasicProtocol
{
    /// 问题
    var submitQuestion: String? {get set}

    /// 答案
    var submitAnswer: String? {get set}

    /// 对象的关联ID
    var submitNoteID: Int? {get set}

    /// 跳转类型 (非空)
    var submitType: ImSubmitType {get}
}

/// 提交页面完整协议,继承基础协议并扩展聊天摘录功能
protocol ImSubmitConfigureProtocol: ImSubmitBasicProtocol
{
    /// 摘录文本数组 (仅聊天模式需要)
    var submitExtractedTexts: [String]? {get set}
}

// MARK: - 默认实现扩展
extension ImSubmitBasicProtocol {
    /// 为非聊天场景提供默认空实现
    var submitExtractedTexts: [String]? {
        get { return nil }
        set { /* 不做任何处理 */ }
    }
}
