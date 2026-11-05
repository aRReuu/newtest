//
//  ImCardViewModelProtocol.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 5/7/25.
//
import Combine

typealias ImCardProtocol =
    CardViewModelDataProtocol &
    CardViewModelActionProtocol &
    CardFetchProtocol &
    ImCardViewModelCombineProtocol


// MARK: - Combine Publisher 协议
protocol ImCardViewModelCombineProtocol
{
    /// 主学习队列 (`studyCardQueue`) 的发布者
    var studyCardQueuePublisher: AnyPublisher<[ImCardModel], Never> { get }
    
    /// `currentCardIndex` 的发布者
    var currentCardIndexPublisher: AnyPublisher<Int, Never> { get }
    
    /// 一次性事件的发布者
    var actionPublisher: AnyPublisher<BaseActionResult, Never> { get }
}


// MARK: - UI显示数据获取协议
protocol CardViewModelDataProtocol
{
    var cardCount:Int {get}
    
    /// 获取当前卡片的下标数
    var currentCardIndex:Int {get}
}

// MARK: - UI操作数据协议
protocol CardViewModelActionProtocol
{
    /// 获取当前显示的卡片模型对象
    func getCurrentCard() -> ImCardModel?
    
    /// 获取对应的卡片数据源返回给卡片视图栈
    /// - Parameter index: <#index description#>
    func getCardToSwipeCardStack(at index:Int) -> ImCardModel?
    
    /// 删除当前卡片数据
    func deleteCurrentCard()
    
    /// 获取新建/复习卡片队列的卡片集
    func fetchStudyCardQueue()
    
    /// 按照Anki做题机制更新对象的属性
    func updateCard(in direction: SwipeDirection)

    /// 更新卡片的问题和答案
    func updateQA(in card: ImCardModel)
}

/// 公用协议
protocol CardFetchProtocol
{
    /// 更新提取话术
    func insertCard(by model: ImCardModel)

    /// 批量插入卡片数据
    func batchInsertCards()
}


enum CardActionResult
{
    case exit
    case cardDeleted(index: Int)
    case concluded
}
