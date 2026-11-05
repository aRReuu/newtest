import Foundation

/// A UI-independent handshake between the Tinder card animation and the
/// durable rating transaction. At most one rating is pending per session.
public actor ReviewSessionCoordinator {
    private let items: [ReviewQueueItem]
    private let repository: any ReviewRepository
    private var position: Int = 0
    private var activeSubmission: ReviewSubmission?
    private var didFinishAnimation = false
    private var didCommit = false
    private var didFailCommit = false
    private var isCommitRunning = false
    private var currentPhase: ReviewSessionPhase

    public init(items: [ReviewQueueItem], repository: any ReviewRepository) {
        self.items = items
        self.repository = repository
        self.currentPhase = items.first.map { .question($0.cardID) } ?? .completed
    }

    public func phase() -> ReviewSessionPhase { currentPhase }

    public func revealAnswer(cardID: UUID) throws {
        guard currentPhase == .question(cardID) else { throw ReviewSessionError.invalidPhase }
        currentPhase = .answer(cardID)
    }

    /// Hiding an answer revokes permission to grade that card.
    public func hideAnswer(cardID: UUID) throws {
        guard currentPhase == .answer(cardID) else { throw ReviewSessionError.invalidPhase }
        currentPhase = .question(cardID)
    }

    /// Called when a permitted directional swipe has been recognized.
    /// The controller should disable the next rating gesture until this
    /// submission has resolved, while the existing swipe animation plays.
    public func beginSwipe(cardID: UUID, rating: ReviewRating,
                           at reviewedAt: Date, eventID: UUID = UUID()) throws -> ReviewSubmission {
        guard currentPhase == .answer(cardID) else { throw ReviewSessionError.invalidPhase }
        guard position < items.count, items[position].cardID == cardID else {
            throw ReviewSessionError.wrongCard
        }
        let submission = ReviewSubmission(
            eventID: eventID, cardID: cardID,
            expectedRevision: items[position].revision,
            rating: rating, reviewedAt: reviewedAt
        )
        activeSubmission = submission
        didCommit = false
        didFailCommit = false
        didFinishAnimation = false
        currentPhase = .submitting(cardID)
        return submission
    }

    /// May finish before or after the database commits; neither order advances
    /// the next card until BOTH acknowledgments have been received.
    @discardableResult
    public func animationDidFinish(eventID: UUID) throws -> ReviewFlowEffect {
        guard activeSubmission?.eventID == eventID else {
            throw ReviewSessionError.wrongSubmission
        }
        guard case .submitting = currentPhase else { throw ReviewSessionError.invalidPhase }
        didFinishAnimation = true
        return resolveIfReady()
    }

    /// Only this method may turn an actual repository commit into progress.
    /// A thrown repository error yields visual recovery, never a completed rating.
    @discardableResult
    public func commitPending(_ submission: ReviewSubmission) async throws -> ReviewFlowEffect {
        guard activeSubmission == submission else { throw ReviewSessionError.wrongSubmission }
        guard currentPhase == .submitting(submission.cardID) else {
            throw ReviewSessionError.invalidPhase
        }
        guard !isCommitRunning && !didCommit && !didFailCommit else {
            throw ReviewSessionError.submissionAlreadyRunning
        }
        isCommitRunning = true
        do {
            let event = try await repository.commit(submission)
            isCommitRunning = false
            guard event.eventID == submission.eventID,
                  event.cardID == submission.cardID,
                  event.before.revision == submission.expectedRevision,
                  event.after.revision == submission.expectedRevision + 1 else {
                didFailCommit = true
                return resolveIfReady()
            }
            didCommit = true
            return resolveIfReady()
        } catch {
            isCommitRunning = false
            didFailCommit = true
            return resolveIfReady()
        }
    }

    /// Called only after UIKit has restored the failed swipe visually.
    /// New input will get a NEW eventID and must still pass revision checks.
    public func recoveryDidFinish(cardID: UUID) throws {
        guard currentPhase == .recovering(cardID),
              activeSubmission?.cardID == cardID else {
            throw ReviewSessionError.invalidPhase
        }
        activeSubmission = nil
        didFinishAnimation = false
        didCommit = false
        didFailCommit = false
        currentPhase = .answer(cardID)
    }

    private func resolveIfReady() -> ReviewFlowEffect {
        guard didFinishAnimation else { return .none }
        if didFailCommit {
            guard let failedCardID = activeSubmission?.cardID else { return .none }
            currentPhase = .recovering(failedCardID)
            return .restoreCard(failedCardID)
        }
        guard didCommit else { return .none }
        position += 1
        activeSubmission = nil
        didCommit = false
        didFailCommit = false
        didFinishAnimation = false
        if position < items.count {
            currentPhase = .question(items[position].cardID)
            return .showNext(items[position].cardID)
        }
        currentPhase = .completed
        return .sessionCompleted
    }
}
