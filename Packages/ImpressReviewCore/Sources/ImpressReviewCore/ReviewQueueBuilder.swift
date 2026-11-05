import Foundation

public enum ReviewSwipeDirection: String, Codable, CaseIterable, Sendable {
    case left, right, up, down

    public var rating: ReviewRating {
        switch self {
        case .left: return .hard
        case .right: return .easy
        case .up: return .good
        case .down: return .again
        }
    }
}

public enum ReviewCardStatus: Int, Codable, Sendable {
    case new = 0, learning = 1, review = 2, relearning = 3
}

/// This is a *metadata-only* record: building the queue never reads image BLOBs.
public struct ReviewQueueCandidate: Hashable, Sendable {
    public let cardID: UUID
    public let revision: Int
    public let status: ReviewCardStatus
    public let dueAt: Date
    public let createdAt: Date
    public let isSuspended: Bool

    public init(cardID: UUID, revision: Int, status: ReviewCardStatus,
                dueAt: Date, createdAt: Date, isSuspended: Bool = false) {
        self.cardID = cardID
        self.revision = revision
        self.status = status
        self.dueAt = dueAt
        self.createdAt = createdAt
        self.isSuspended = isSuspended
    }
}

public enum ReviewQueueBuilder {
    /// Limit each short session to six cards, prioritizing due learning/review
    /// cards. New cards fill at most three remaining slots.
    public static func makeQueue(from candidates: [ReviewQueueCandidate],
                                 now: Date, capacity: Int = 6, newCardLimit: Int = 3) -> [ReviewQueueItem] {
        guard capacity > 0 else { return [] }
        let usable = candidates.filter { !$0.isSuspended }
        let due = usable.filter { $0.status != .new && $0.dueAt <= now }
            .sorted { a, b in
                if a.dueAt != b.dueAt { return a.dueAt < b.dueAt }
                return a.cardID.uuidString < b.cardID.uuidString
            }
        let dueSelection = Array(due.prefix(capacity))
        let slots = max(0, min(newCardLimit, capacity - dueSelection.count))
        let newSelection = usable.filter { $0.status == .new }
            .sorted { a, b in
                if a.createdAt != b.createdAt { return a.createdAt < b.createdAt }
                return a.cardID.uuidString < b.cardID.uuidString
            }
            .prefix(slots)
        return (dueSelection + newSelection).map { ReviewQueueItem(cardID: $0.cardID, revision: $0.revision) }
    }
}
