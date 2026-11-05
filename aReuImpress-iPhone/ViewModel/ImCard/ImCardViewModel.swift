// ImCardViewModel.swift
//
//  imCardViewModel.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 4/23/25.
//

import WCDBSwift
import Combine



class ImCardViewModel: ImBaseViewModel,ImCardProtocol
{
    // MARK: - ImCardViewModelCombineProtocol
    var studyCardQueuePublisher: AnyPublisher<[ImCardModel], Never> {
        $studyCardQueue.eraseToAnyPublisher()
    }
    
    var currentCardIndexPublisher: AnyPublisher<Int, Never> {
        $currentCardIndex.eraseToAnyPublisher()
    }
    
    var actionPublisher: AnyPublisher<BaseActionResult, Never> {
        action.eraseToAnyPublisher()
    }
    
    let action = PassthroughSubject<BaseActionResult, Never>()
    
    // --- 队列管理 (修改) ---
    /// 主学习队列 (复习 + 新卡)
    @Published private(set) var studyCardQueue: [ImCardModel] = []
    
    /// The index of the card currently being displayed from the studyCardQueue.
    @Published var currentCardIndex = 0
    
    private let cardTable =  ImDBTableType.card.description
    
    /// FSRS-v4 算法的默认参数。
    private static let fsrsWeights: [Double] =
        [
            0.4, 0.6, 2.4, 5.8, // w[0..3]: S₀(1), S₀(2), S₀(3), S₀(4) -> 首次学习的初始稳定性
            4.93, 0.94, 0.86,   // w[4..6]: D_rev, S_inc, D_diff -> 难度和稳定性计算因子
            0.01, 1.49, 0.14,   // w[7..9]: S_recall, S_forget_R, D_forget -> 稳定性计算因子
            0.9, 2.18, 0.05,    // w[10..12]: S_forget_D, S_forget_S, S_forget_exp_R
            0.34, 1.26, 0.29,   // w[13..15]
            2.61                // w[16]
        ]

    /// 学习步骤间隔配置 (秒) - 默认: 1分钟 → 10分钟 → 1天
    private static let learningSteps: [TimeInterval] = [60, 600, 86400]
    
    // A struct to hold the results of the FSRS calculation for better clarity.
    private struct SchedulingInfo {
        let newDifficulty: Double
        let newStability: Double
        let newDueDate: Date
    }
}

// MARK: - 数据更新  ReviewViewModelDataProtocol
extension ImCardViewModel
{
    func getCardToSwipeCardStack(at index: Int) -> ImCardModel?
    {
        let targetStudyIndex = currentCardIndex + index
        guard studyCardQueue.indices.contains(targetStudyIndex) else {
            return nil
        }
        return studyCardQueue[targetStudyIndex]
    }
    
    
    var cardCount: Int
    {
        let remainingInStudyQueue = studyCardQueue.count - currentCardIndex
        return max(0, remainingInStudyQueue)
    }

    func getCurrentCard() -> ImCardModel?
    {
        guard studyCardQueue.indices.contains(currentCardIndex) else { return nil }
        return studyCardQueue[currentCardIndex]
    }
}


// MARK: - 卡片核心业务逻辑协议
extension ImCardViewModel
{
    /// 获取所有需要复习的卡片队列，按优先级排序
    /// 目前每次拉取的碎片化总复习数量只有6张,3新3临期
    func fetchStudyCardQueue()
    {
        self.studyCardQueue.removeAll()
        self.currentCardIndex = 0

        let now = Date()
//        let today = Calendar.current.startOfDay(for: now)

        let group = DispatchGroup()
        var dueCards: [ImCardModel] = []

        // 获取所有到期卡片 (review, learning, lapsed状态)
        let dueStates: [CardState] = [.review, .learning, .lapsed]
        for state in dueStates {
            group.enter()
            let dueWhere = ImCardModel.Properties.state == state.rawValue && ImCardModel.Properties.dueDate <= now
            dbShare.queryFromDB(
                table: self.cardTable,
                cls: ImCardModel.self,
                where: dueWhere,
                orderBy: [ImCardModel.Properties.dueDate.asOrder(by: .ascending)],
                limit: imDueCardLimit
            ) { result in
                if case .success(let cards) = result {
                    dueCards.append(contentsOf: cards)
                    zcLog("Fetched \(cards.count) due \(state) cards.")
                }
                group.leave()
            }
        }

        // 获取新卡片 (受限量控制)
        var newCards: [ImCardModel] = []
        group.enter()
        let newWhere = ImCardModel.Properties.state == CardState.new.rawValue
        dbShare.queryFromDB(
            table: self.cardTable,
            cls: ImCardModel.self,
            where: newWhere,
            orderBy: [ImCardModel.Properties.createTime.asOrder(by: .ascending)],
            limit: imNewCardLimit
        ) { result in
            if case .success(let cards) = result {
                newCards = cards
                zcLog("Fetched \(cards.count) new cards.")
            }
            group.leave()
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }

            // 按优先级排序队列
            let sortedQueue = self.buildPrioritizedQueue(dueCards: dueCards, newCards: newCards)

            self.studyCardQueue = sortedQueue
            zcLog("Study queue built with \(self.studyCardQueue.count) cards.")

            // @Published 会自动通知UI刷新
        }
    }

    /// 构建按优先级排序的学习队列
    private func buildPrioritizedQueue(dueCards: [ImCardModel], newCards: [ImCardModel]) -> [ImCardModel] {
        var queue: [ImCardModel] = []

        // 1. 首先添加所有到期卡片，按到期时间排序
        let sortedDueCards = dueCards.sorted { ($0.dueDate ?? Date.distantPast) < ($1.dueDate ?? Date.distantPast) }
        queue.append(contentsOf: sortedDueCards)

        // 2. 然后添加新卡片
        queue.append(contentsOf: newCards)

        // 3. 轻微打乱以增加多样性（保持大致顺序）
        // 不完全shuffle，只在相邻卡片间轻微调整
        if queue.count > 1 {
            for i in 0..<queue.count - 1 {
                if Bool.random() && i % 3 == 0 { // 每3张卡片中随机交换一次
                    queue.swapAt(i, i + 1)
                }
            }
        }

        return queue
    }
    
    private func createNewCard(from model: ImCardModel) -> ImCardModel
    {
        var card = model
        card.createTime = Date()
        // --- FSRS V4 Initial State ---
        card.state = CardState.new.rawValue
        card.dueDate = Date() // For new cards, dueDate can be the creation date for sorting.
        card.difficulty = 0.0 // Not yet determined
        card.stability = 0.0  // Not yet determined
        card.reviewCount = 0
        card.lapseCount = 0
        card.relearningStep = 0
        
        // Set default card type if not specified
        if card.cardType == nil {
            card.cardType = CardType.standard.rawValue
        }
        
        return card
    }
    
    /// 公用新增卡片函数
    func insertCard(by model: ImCardModel)
    {
        guard let question = model.question, !question.isEmpty else {
            zcLog("core title is nil!");
            action.send(.errorOccurred(NSError(domain: "InsertCard", code: -1, userInfo: [NSLocalizedDescriptionKey: "问题不能为空。"])))
            return
        }

        if model.cardType == CardType.standard.rawValue || model.cardType == CardType.multipleChoice.rawValue {
            guard let answer = model.answer, !answer.isEmpty else {
                zcLog("core content is nil!");
                action.send(.errorOccurred(NSError(domain: "InsertCard", code: -1, userInfo: [NSLocalizedDescriptionKey: "答案不能为空。"])))
                return
            }
        }
        
        let card = createNewCard(from: model)
        
        dbShare.insertToDB(intoTable: cardTable,
                           with: [card]) { result in
            if case .failure(let error) = result {
                self.action.send(.errorOccurred(error))
            } else {
                // Optionally, you can add the new card to the front of the study queue
                // self.studyCardQueue.insert(card, at: 0)
                self.action.send(.success("卡片已成功创建!"))
            }
        }
    }
    
    /// 批量插入数据 fix异步操作,防止主线程堵塞
    func batchInsertCards(){}
    
    /// 更新卡片的问题和答案,重置卡片在队列的位置, 目前并没有实现Mermaid效果数据
    /// - Parameters:
    func updateQA(in card: ImCardModel)
    {
        guard let originalCard = getCurrentCard(),
              let cardIdentifier = originalCard.identifier else { return }
        //
        var updatedCardForDB = originalCard
        // fix 空值更新
        if let q = card.question, !q.isEmpty {
            updatedCardForDB.question = q
        }
        if let a = card.answer, !a.isEmpty {
            updatedCardForDB.answer = a
        }
        //
        dbShare.updateToDB(table: cardTable,
                           on: [ImCardModel.Properties.question,
                                ImCardModel.Properties.answer],
                           with: updatedCardForDB,
                           where: ImCardModel.Properties.identifier == cardIdentifier) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success():
                if self.studyCardQueue.indices.contains(self.currentCardIndex) &&
                   self.studyCardQueue[self.currentCardIndex].identifier == cardIdentifier
                {
                    // studyCardQueue
                    self.studyCardQueue[self.currentCardIndex].question = card.question
                    self.studyCardQueue[self.currentCardIndex].answer = card.answer
                }
                break
            case .failure(let error):
                self.action.send(.errorOccurred(error))
                break
            }
        }
    }
    
    /// 更新卡片到数据库
    /// - Parameter card: <#card description#>
    private func saveUpdateCard(_ card: ImCardModel)
    {
        dbShare.updateToDB(table: cardTable,
                           on: [
                            // FSRS Core
                            ImCardModel.Properties.difficulty,
                            ImCardModel.Properties.stability,
                            // Scheduling & State
                            ImCardModel.Properties.dueDate,
                            ImCardModel.Properties.state,
                            ImCardModel.Properties.lastReviewDate,
                            // Stats
                            ImCardModel.Properties.reviewCount,
                            ImCardModel.Properties.lapseCount,
                            ImCardModel.Properties.relearningStep
                           ],
                           with: card,
                           where: ImCardModel.Properties.identifier == card.identifier!) { [weak self] result in
            //
                            if let index = self?.studyCardQueue.firstIndex(where: { $0.identifier == card.identifier }) {
                                self?.studyCardQueue[index] = card
                            }
                            switch result {
                            case .failure(let error):
                                self?.action.send(.errorOccurred(error))
                            case .success():break
                            }
        }
    }
    
    private func advanceToNextCard()
    {
       currentCardIndex += 1
       // 检查是否所有卡片都已学习完毕
       if currentCardIndex >= studyCardQueue.count {
           notificationShare.rescheduleDailyReminder()
           notificationShare.ensureOneHourReminderScheduled()
           action.send(.protocolSpecific(.card(.exit)))
       }
    }
    
    
    /// Processes the user's review for the current card and advances the queue.
    /// This is the main action triggered by a user swipe/button press.
    /// 根据用户的滑动方向（评分）更新卡片状态。
    /// - Parameter direction: 用户的滑动方向，映射到具体的评分。
    func updateCard(in direction: SwipeDirection)
    {
        guard let card = getCurrentCard() else {
            let error = NSError(domain: "update card",
                                code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "当前为无效操作!"])
            action.send(.errorOccurred(error))
            return
        }
        let rating = direction.toLevel

        // 根据卡片当前状态分发处理逻辑
        switch card.state {
        case CardState.new.rawValue:
            handleNewCard(card, rating: rating)
        case CardState.learning.rawValue:
            handleLearningCard(card, rating: rating)
        case CardState.review.rawValue:
            handleReviewCard(card, rating: rating)
        case CardState.lapsed.rawValue:
            handleLapsedCard(card, rating: rating)
        default:
            zcLog("Unknown card state: \(card.state ?? -1)")
            advanceToNextCard()
        }
    }
    
    /// 删除当前卡片
    func deleteCurrentCard()
    {
        guard let cardToDelete = getCurrentCard(), let cardId = cardToDelete.identifier else {
            let error = NSError(domain: "Delete card",
                                code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "当前为无效卡片"])
            action.send(.errorOccurred(error))
            return
        }
        
        dbShare.deleteFromTable(table: cardTable,
                                where: ImCardModel.Properties.identifier == cardId) { [weak self] result in
            guard let self = self else { return }
            
            switch result {
            case .success():
                // 1. Remove the card from the active memory queue.
                if self.studyCardQueue.indices.contains(self.currentCardIndex) &&
                   self.studyCardQueue[self.currentCardIndex].identifier == cardId {
                    self.studyCardQueue.remove(at: self.currentCardIndex)
                }

                // 2. Check if the session is complete.
                if self.currentCardIndex >= self.studyCardQueue.count {
                    self.action.send(.protocolSpecific(.card(.exit)))
                    return
                }

                // Note: Don't send cardDeleted event here because
                // the queue changes will trigger UI refresh via Combine @Published publishers.
                // Sending both manual delete event and queue change refresh causes duplicated reloads and crashes.
                // self.action.send(.protocolSpecific(.card(.cardDeleted(index: 0))))
                
            case .failure(let error):
                self.action.send(.errorOccurred(error))
            }
        }
    }


    /// 处理新卡片 - 进入学习阶段
    private func handleNewCard(_ card: ImCardModel, rating: CardLevel) {
        var c = card
        c.state = CardState.learning.rawValue
        c.relearningStep = 0
        c.dueDate = Date() + ImCardViewModel.learningSteps[0] // 1分钟后

        // 应用基础统计
        applyBasicStats(to: &c, rating: rating)
        saveUpdateCard(c)
        advanceToNextCard()
    }

    /// 处理学习中卡片 - 根据评分决定前进或重置
    private func handleLearningCard(_ card: ImCardModel, rating: CardLevel) {
        var c = card
        let currentStep = card.relearningStep ?? 0

        switch rating {
        case .again:
            // 重置到第一步
            c.relearningStep = 0
            c.dueDate = Date() + ImCardViewModel.learningSteps[0]
        case .hard:
            // 停留在当前步骤，延长间隔
            let currentInterval = ImCardViewModel.learningSteps[min(currentStep, ImCardViewModel.learningSteps.count - 1)]
            c.dueDate = Date() + currentInterval * 1.2
        case .normal:
            // 前进到下一学习步骤
            let nextStep = currentStep + 1
            if nextStep >= ImCardViewModel.learningSteps.count {
                // 完成所有学习步骤，毕业到Review状态
                c.state = CardState.review.rawValue
                c.relearningStep = nil
                let schedulingInfo = calculateNextState(for: c, rating: rating)
                c = applySchedulingInfo(to: c, info: schedulingInfo, rating: rating)
                c.dueDate = schedulingInfo.newDueDate
            } else {
                c.relearningStep = nextStep
                c.dueDate = Date() + ImCardViewModel.learningSteps[nextStep]
            }
        case .easy:
            // 直接毕业到Review状态
            c.state = CardState.review.rawValue
            c.relearningStep = nil
            let schedulingInfo = calculateNextState(for: c, rating: rating)
            c = applySchedulingInfo(to: c, info: schedulingInfo, rating: rating)
            c.dueDate = schedulingInfo.newDueDate
        }

        applyBasicStats(to: &c, rating: rating)
        saveUpdateCard(c)
        advanceToNextCard()
    }

    /// 处理复习卡片 - 使用FSRS算法
    private func handleReviewCard(_ card: ImCardModel, rating: CardLevel) {
        let schedulingInfo = calculateNextState(for: card, rating: rating)
        var c = applySchedulingInfo(to: card, info: schedulingInfo, rating: rating)

        if rating == .again {
            // 忘记：进入重新学习状态
            c.state = CardState.lapsed.rawValue
            c.relearningStep = 0
            c.dueDate = Date() + ImCardViewModel.learningSteps[0] // 1分钟后重新学习
        } else {
            // 记住：保持Review状态，使用FSRS计算的间隔
            c.dueDate = schedulingInfo.newDueDate
        }

        saveUpdateCard(c)
        advanceToNextCard()
    }

    /// 处理重新学习卡片 - 类似学习阶段但更严格
    private func handleLapsedCard(_ card: ImCardModel, rating: CardLevel) {
        var c = card
        let currentStep = card.relearningStep ?? 0

        switch rating {
        case .again:
            // 重新学习：重置步骤
            c.relearningStep = 0
            c.dueDate = Date() + ImCardViewModel.learningSteps[0]
        case .hard:
            // 延长当前间隔
            let currentInterval = ImCardViewModel.learningSteps[min(currentStep, ImCardViewModel.learningSteps.count - 1)]
            c.dueDate = Date() + currentInterval * 1.5 // 重新学习更严格
        case .normal:
            // 前进步骤
            let nextStep = currentStep + 1
            if nextStep >= ImCardViewModel.learningSteps.count {
                // 重新学习完成，回到Review状态
                c.state = CardState.review.rawValue
                c.relearningStep = nil
                let schedulingInfo = calculateNextState(for: c, rating: rating)
                c = applySchedulingInfo(to: c, info: schedulingInfo, rating: rating)
                c.dueDate = schedulingInfo.newDueDate
            } else {
                c.relearningStep = nextStep
                c.dueDate = Date() + ImCardViewModel.learningSteps[nextStep]
            }
        case .easy:
            // 直接回到Review状态
            c.state = CardState.review.rawValue
            c.relearningStep = nil
            let schedulingInfo = calculateNextState(for: c, rating: rating)
            c = applySchedulingInfo(to: c, info: schedulingInfo, rating: rating)
            c.dueDate = schedulingInfo.newDueDate
        }

        applyBasicStats(to: &c, rating: rating)
        saveUpdateCard(c)
        advanceToNextCard()
    }
}


// MARK: - 私有实现 FSRS 机器学习优化算法 
extension ImCardViewModel
{
    /// 计算下一次复习状态 - 根据卡片状态选择合适的算法
    /// - Parameters:
    ///   - card: 当前卡片
    ///   - rating: 用户评分
    /// - Returns: 调度信息
    private func calculateNextState(for card: ImCardModel,
                                    rating: CardLevel) -> SchedulingInfo
    {
        // 只有Review状态才使用FSRS算法
        if card.state == CardState.review.rawValue {
            return calculateFSRSNextState(for: card, rating: rating)
        } else {
            // Learning和Relearning状态使用固定间隔
            return calculateFixedIntervalNextState(for: card, rating: rating)
        }
    }

    /// FSRS算法 - 只用于Review状态的卡片
    private func calculateFSRSNextState(for card: ImCardModel,
                                        rating: CardLevel) -> SchedulingInfo
    {
        let w = ImCardViewModel.fsrsWeights
        let grade = Double(rating.rawValue)
        var newDifficulty: Double
        var newStability: Double

        guard let currentDifficulty = card.difficulty, let currentStability = card.stability else {
            // Fallback for corrupted data: treat as a new card.
            let newCardInfo = calculateFixedIntervalNextState(for: createNewCard(from: ImCardModel()), rating: rating)
            return newCardInfo
        }

        let elapsedDays = Date().timeIntervalSince(card.lastReviewDate ?? card.createTime!) / 86400
        let currentRetrievability = exp(-elapsedDays / currentStability)

        // Calculate new difficulty
        newDifficulty = currentDifficulty - w[6] * (grade - 3)
        newDifficulty = min(10.0, max(1.0, newDifficulty))

        // Calculate new stability
        if rating == .again { // Forgotten
            let difficultyTerm = w[10] * pow(newDifficulty, -w[11])
            newStability = difficultyTerm * pow(currentStability, w[12]) * exp((1 - currentRetrievability) * w[13])
        } else { // Remembered
            let stabilityTerm = exp(w[7]) * (11 - newDifficulty) * pow(currentStability, -w[8])
            let retrievabilityTerm = exp((1 - currentRetrievability) * w[9]) - 1
            newStability = currentStability * (1 + stabilityTerm * retrievabilityTerm)
        }

        newStability = max(1.0, newStability)
        let newInterval = Int(newStability.rounded())
        let newDueDate = Calendar.current.date(byAdding: .day, value: newInterval, to: Date())!

        return SchedulingInfo(newDifficulty: newDifficulty, newStability: newStability, newDueDate: newDueDate)
    }

    /// 固定间隔算法 - 用于Learning和Relearning状态
    private func calculateFixedIntervalNextState(for card: ImCardModel,
                                                 rating: CardLevel) -> SchedulingInfo
    {
        let w = ImCardViewModel.fsrsWeights
        let grade = Double(rating.rawValue)

        // 对于非Review状态，使用简化的难度计算
        let newDifficulty = w[4] - w[5] * (grade - 3)
        let clampedDifficulty = min(10.0, max(1.0, newDifficulty))

        // 使用固定的稳定性值（基于评分）
        let newStability = w[Int(grade) - 1]
        let newInterval = Int(newStability.rounded())
        let newDueDate = Calendar.current.date(byAdding: .day, value: newInterval, to: Date())!

        return SchedulingInfo(newDifficulty: clampedDifficulty, newStability: newStability, newDueDate: newDueDate)
    }
    
    /// 将FSRS计算结果应用到卡片模型上
    private func applySchedulingInfo(to card: ImCardModel,
                                     info: SchedulingInfo,
                                     rating: CardLevel) -> ImCardModel
    {
        var c = card
        c.difficulty = info.newDifficulty
        c.stability = info.newStability
        c.lastReviewDate = Date()
        c.reviewCount = (card.reviewCount ?? 0) + 1
        //
        if rating == .again {
            c.lapseCount = (card.lapseCount ?? 0) + 1
        }
        return c
    }

    /// 应用基础统计信息 (reviewCount, lapseCount, lastReviewDate)
    private func applyBasicStats(to card: inout ImCardModel, rating: CardLevel) {
        card.lastReviewDate = Date()
        card.reviewCount = (card.reviewCount ?? 0) + 1
        if rating == .again {
            card.lapseCount = (card.lapseCount ?? 0) + 1
        }
    }
}
