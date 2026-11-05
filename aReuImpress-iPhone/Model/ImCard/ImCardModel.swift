//
//  ImCardModel.swift
//  aReuImpress-iPhone
//
//  Created by aReu on 3/16/25.
//

import WCDBSwift

/// 卡片难度等级
public enum CardLevel: Int, CaseIterable
{
    case easy = 4
    case normal = 3
    case hard = 2
    case again = 1
    
    var title: String{
        switch self {
        case .easy: return "容易"
        case .normal: return "普通"
        case .hard: return "困难"
        case .again: return "重来"
        }
    }
}

public enum CardState: Int,CaseIterable
{
    case new = 0
    case learning = 1
    case review = 2
    case lapsed = 3
    case suspended = 4
}

public enum CardType: Int, CaseIterable, Codable {
    case standard = 0 // Standard Q&A
    case multipleChoice = 2
    case image = 3

    var description: String {
        switch self {
        case .standard: return "问答卡片"
        case .multipleChoice: return "选择题"
        case .image: return "图片卡片"
        }
    }
}


struct ImCardModel: TableCodable, ImSubmitConfigureProtocol
{
    /// 主键
    var identifier: Int?
    /// 外键，关联Note ID
    var noteID: Int?
    
    /// 问题
    var question: String?
    /// 答案
    var answer: String?
    /// 卡片创建时间
    var createTime: Date?
    
    /// 已归档对话网页链接
    var chatLink: String?

    // MARK: - 卡片类型
    /// 卡片类型, 默认0
    var cardType: Int?
    
    // --- Properties for Multiple Choice ---
    /// 选项 (e.g., JSON string ["Option A", "Option B", "Option C"])
    var choices: String?
    /// 正确答案的索引,以逗号分隔，例如 "0,2"
    var correctAnswerIndices: String?

    // --- Properties for Image ---
    /// 图片数据
    var imageData: Data?

    // --- Properties for Chat Session ---
    /// 关联的聊天会话ID，用于会话历史的跳转
    var chatSessionId: Int?

    // MARK: - FSRS 核心状态属性 (Core FSRS State Properties)
    /// 记忆难度 (Difficulty): 卡片的内在学习难度。FSRS会根据复习历史进行调整。
    /// 这是FSRS的核心参数之一，取代了旧的easeFactor。
    var difficulty: Double?
    /// 记忆稳定性 (Stability): 记忆能持续多久（单位：天）。每次成功复习后会增加。
    /// 这是FSRS的另一个核心参数。
    var stability: Double?

    // MARK: - 调度与状态属性 (Scheduling & State Properties)
    /// 上次复习日期: 计算下一次到期日的基础。
    var lastReviewDate: Date?
    /// 卡片当前状态 (例如: 新卡, 学习中, 复习, 已暂停)
    /// 这个字段至关重要，决定了卡片进入哪个队列。
    /// 枚举CardState:   New, Learning, Review, Lapsed, Suspended
    var state: Int?
    /// 到期日: 这是最重要的调度字段，由 FSRS 计算得出并存储。
    /// 对于复习卡，精确到天；对于学习中卡片，精确到秒。
    var dueDate: Date?
    /// 总复习次数
    var reviewCount: Int?
    /// 总答错次数
    var lapseCount: Int?
    
    /// 新增：用于追踪卡片在“重新学习”队列中的步骤。
    /// 0 代表第一步，1 代表第二步，以此类推。
    /// 对于非Lapsed状态的卡片，此值为0或nil。
    var relearningStep: Int?

    
    enum CodingKeys: String, CodingTableKey {
        typealias Root = ImCardModel
        static let objectRelationalMapping = TableBinding(CodingKeys.self)
        case identifier = "id"
        case noteID = "note_id"
        case question
        case answer = "answer"
        case createTime = "create_time"
        case stability
        case state
        case reviewCount = "review_count"
        case lapseCount = "lapse_count"
        case dueDate = "due_date"
        case difficulty
        case lastReviewDate = "last_review_date"
        case relearningStep = "relearning_step"
        case chatLink = "chat_link"
        
        case cardType = "card_type"
        case choices
        case correctAnswerIndices = "correct_answer_indices"
        case imageData = "image_data"
        case chatSessionId = "chat_session_id"


        static var columnConstraintBindings: [CodingKeys: ColumnConstraintBinding]? {
            return [
                .identifier: ColumnConstraintBinding(isPrimary: true, isAutoIncrement: true)
            ]
        }
    }
    
    
    // 关注点分离（Separation of Concerns）
    // 以下为代理实现方法,不要乱用
    var submitQuestion: String?
    {
        get{self.question}
        set{self.question = newValue}
    }
    
    var submitAnswer: String?
    {
        get{self.answer}
        set{self.answer = newValue}
    }
    
    var submitNoteID: Int?
    {
        get{self.noteID}
        set{self.noteID = newValue}
    }

    var submitType: ImSubmitType
    {
        get { return (self.question != nil) ? .cardEdit : .card}
    }
}
