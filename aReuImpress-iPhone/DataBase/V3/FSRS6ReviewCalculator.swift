//
//  FSRS6ReviewCalculator.swift
//  Impress V3 -- staged adapter for swift-fsrs pinned revision:
//
//  open-spaced-repetition/swift-fsrs
//  4fbaf20184d62f82a9f44f343337c61a2c5483e9
//
//  Not added to the legacy Xcode target until SPM and WCDB builds are verified.
//

import Foundation
import FSRS
import ImpressReviewCore

/// Uses the upstream scheduler, including learning/relearning transitions.
/// No ad-hoc stability or due-date formulas are implemented in Impress.
public struct FSRS6ReviewCalculator: WCDBReviewCalculating {
    private let engine: FSRS

    public init() {
        let parameters = FSRSParameters(
            requestRetention: 0.90,
            w: FSRSDefaults.defaultWv6,
            enableFuzz: false,
            enableShortTerm: true,
            learningSteps: ["1m", "10m"],
            relearningSteps: ["10m"]
        )
        engine = FSRS(parameters: parameters)
    }

    /// New V3 cards start with a standard empty FSRS Card.
    /// FSRS Card's initializer is public; FSRSDefaults.createEmptyCard is
    /// internal in the inspected upstream revision and cannot be called here.
    public func newCardSnapshot(id: UUID, now: Date) throws -> ReviewScheduleSnapshot {
        let card = Card(due: now)
        return ReviewScheduleSnapshot(
            cardID: id, revision: 0, dueAt: card.due,
            lastReviewedAt: nil, schedulerPayload: try JSONEncoder().encode(card)
        )
    }

    public func next(before: ReviewScheduleSnapshot,
                     status: ReviewCardStatus,
                     submission: ReviewSubmission) throws -> WCDBCalculatedReview {
        guard before.cardID == submission.cardID,
              before.revision == submission.expectedRevision else {
            throw ReviewWCDBError.revisionConflict
        }
        let card = try JSONDecoder().decode(Card.self, from: before.schedulerPayload)
        // WCDB and JSONDecoder may round Date's fractional seconds slightly
        // differently. Do not reject a valid review for a sub-millisecond
        // serialization difference; still reject any meaningful clock skew.
        let dueDelta = abs(card.due.timeIntervalSince(before.dueAt))
        let lastReviewMatches: Bool
        switch (card.lastReview, before.lastReviewedAt) {
        case (nil, nil):
            lastReviewMatches = true
        case let (.some(encoded), .some(persisted)):
            lastReviewMatches = abs(encoded.timeIntervalSince(persisted)) < 0.002
        default:
            lastReviewMatches = false
        }
        guard dueDelta < 0.002, lastReviewMatches,
              card.state.rawValue == status.rawValue else {
            #if DEBUG
            NSLog("Impress V3 FSRS decoding mismatch: due delta %.9f, last review match %d, state match %d",
                  dueDelta, lastReviewMatches ? 1 : 0, card.state.rawValue == status.rawValue ? 1 : 0)
            #endif
            throw ReviewWCDBError.corruptRecord
        }

        let grade: Rating
        switch submission.rating {
        case .again: grade = .again
        case .hard: grade = .hard
        case .good: grade = .good
        case .easy: grade = .easy
        }
        let afterCard = try engine.next(
            card: card, now: submission.reviewedAt, grade: grade).card

        guard afterCard.due.timeIntervalSince1970.isFinite,
              afterCard.difficulty.isFinite,
              afterCard.stability.isFinite,
              afterCard.stability > 0 else {
            throw ReviewWCDBError.invalidSchedulerOutput
        }
        guard let nextStatus = ReviewCardStatus(rawValue: afterCard.state.rawValue) else {
            throw ReviewWCDBError.invalidSchedulerOutput
        }
        let snapshot = ReviewScheduleSnapshot(
            cardID: submission.cardID,
            revision: submission.expectedRevision + 1,
            dueAt: afterCard.due,
            lastReviewedAt: afterCard.lastReview,
            schedulerPayload: try JSONEncoder().encode(afterCard)
        )
        return WCDBCalculatedReview(snapshot: snapshot, status: nextStatus)
    }
}
