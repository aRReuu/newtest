import Foundation

/// This rating alone changes memory scheduling; answering multiple-choice questions does not.
public enum ReviewRating: Int, Codable, CaseIterable, Sendable {
    case again = 1, hard = 2, good = 3, easy = 4
}

/// The stable identity and revision captured when a session starts.
public struct ReviewQueueItem: Hashable, Sendable {
    public let cardID: UUID
    public let revision: Int

    public init(cardID: UUID, revision: Int) {
        self.cardID = cardID
        self.revision = revision
    }
}

/// FSRS state is serialized separately from text/image/multiple-choice content.
/// The database adapter owns validation and interpretation of the scheduler payload.
public struct ReviewScheduleSnapshot: Codable, Hashable, Sendable {
    public let cardID: UUID
    public let revision: Int
    public let dueAt: Date
    public let lastReviewedAt: Date?
    public let schedulerPayload: Data

    public init(cardID: UUID, revision: Int, dueAt: Date,
                lastReviewedAt: Date?, schedulerPayload: Data) {
        self.cardID = cardID
        self.revision = revision
        self.dueAt = dueAt
        self.lastReviewedAt = lastReviewedAt
        self.schedulerPayload = schedulerPayload
    }
}

/// A rating request is tied to a card and an expected database revision.
/// The event identifier provides idempotence across retries of the same submission.
public struct ReviewSubmission: Hashable, Sendable {
    public let eventID: UUID
    public let cardID: UUID
    public let expectedRevision: Int
    public let rating: ReviewRating
    public let reviewedAt: Date

    public init(eventID: UUID, cardID: UUID, expectedRevision: Int,
                rating: ReviewRating, reviewedAt: Date) {
        self.eventID = eventID
        self.cardID = cardID
        self.expectedRevision = expectedRevision
        self.rating = rating
        self.reviewedAt = reviewedAt
    }
}

/// Persist full FSRS state snapshots, never the card's answer or image in an event.
public struct ReviewEvent: Codable, Hashable, Sendable {
    public let eventID: UUID
    public let cardID: UUID
    public let rating: ReviewRating
    public let reviewedAt: Date
    public let before: ReviewScheduleSnapshot
    public let after: ReviewScheduleSnapshot
    public let algorithmIdentifier: String

    public init(eventID: UUID, cardID: UUID, rating: ReviewRating,
                reviewedAt: Date, before: ReviewScheduleSnapshot,
                after: ReviewScheduleSnapshot, algorithmIdentifier: String) {
        self.eventID = eventID
        self.cardID = cardID
        self.rating = rating
        self.reviewedAt = reviewedAt
        self.before = before
        self.after = after
        self.algorithmIdentifier = algorithmIdentifier
    }
}

/// Implementations MUST check the revision, update the card and insert its event
/// atomically, and return the prior event for repeated eventIDs without re-scoring.
/// An error MUST mean that the repository did not commit the rating, or that
/// it has verified the event's definitive outcome before reporting failure.
public protocol ReviewRepository: Sendable {
    func commit(_ submission: ReviewSubmission) async throws -> ReviewEvent
}

public enum ReviewSessionError: Error, Equatable, Sendable {
    case invalidPhase
    case wrongCard
    case wrongSubmission
    case submissionAlreadyRunning
}

/// Actions for the UIKit controller. `.none` means the other half of the
/// animation/persistence handshake is still pending.
public enum ReviewFlowEffect: Equatable, Sendable {
    case none
    case showNext(UUID)
    case sessionCompleted
    case restoreCard(UUID)
}

public enum ReviewSessionPhase: Equatable, Sendable {
    case question(UUID)
    case answer(UUID)
    case submitting(UUID)
    case recovering(UUID)
    case completed
}
