import XCTest
@testable import ImpressReviewCore

private enum MockFailure: Error { case injected }

private actor MockReviewRepository: ReviewRepository {
    var revisionByCard: [UUID: Int]
    var events: [UUID: ReviewEvent] = [:]
    var failNext = false
    var commitCount = 0

    init(items: [ReviewQueueItem]) {
        revisionByCard = Dictionary(uniqueKeysWithValues: items.map { ($0.cardID, $0.revision) })
    }

    func setFailNext(_ flag: Bool) { failNext = flag }
    func eventCount() -> Int { events.count }

    func commit(_ s: ReviewSubmission) async throws -> ReviewEvent {
        if let previous = events[s.eventID] { return previous } // Idempotent retry.
        if failNext { failNext = false; throw MockFailure.injected }
        guard revisionByCard[s.cardID] == s.expectedRevision else { throw MockFailure.injected }
        let before = ReviewScheduleSnapshot(cardID: s.cardID, revision: s.expectedRevision,
                                            dueAt: s.reviewedAt, lastReviewedAt: nil,
                                            schedulerPayload: Data())
        let after = ReviewScheduleSnapshot(cardID: s.cardID, revision: s.expectedRevision + 1,
                                           dueAt: s.reviewedAt.addingTimeInterval(600),
                                           lastReviewedAt: s.reviewedAt, schedulerPayload: Data())
        let event = ReviewEvent(eventID: s.eventID, cardID: s.cardID,
                                rating: s.rating, reviewedAt: s.reviewedAt,
                                before: before, after: after,
                                algorithmIdentifier: "fixture-FSRS-6")
        revisionByCard[s.cardID] = s.expectedRevision + 1
        events[s.eventID] = event
        commitCount += 1
        return event
    }
}

final class ReviewSessionCoordinatorTests: XCTestCase {
    private func fixture(_ count: Int = 2) -> ([ReviewQueueItem], MockReviewRepository, ReviewSessionCoordinator) {
        let cards = (0..<count).map { _ in ReviewQueueItem(cardID: UUID(), revision: 0) }
        let repo = MockReviewRepository(items: cards)
        return (cards, repo, ReviewSessionCoordinator(items: cards, repository: repo))
    }

    func testCannotSwipeUntilAnswerIsRevealed() async throws {
        let (cards, _, session) = fixture()
        let id = cards[0].cardID
        do {
            _ = try await session.beginSwipe(cardID: id, rating: .good, at: Date())
            XCTFail("Should reject unrevealed answers")
        } catch ReviewSessionError.invalidPhase { }
        try await session.revealAnswer(cardID: id)
        try await session.hideAnswer(cardID: id)
        do {
            _ = try await session.beginSwipe(cardID: id, rating: .easy, at: Date())
            XCTFail("Should reject hidden answers")
        } catch ReviewSessionError.invalidPhase { }
    }

    func testAnimationBeforeCommitWaitsThenAdvances() async throws {
        let (cards, repo, session) = fixture()
        try await session.revealAnswer(cardID: cards[0].cardID)
        let submission = try await session.beginSwipe(cardID: cards[0].cardID, rating: .good, at: Date())
        let early = try await session.animationDidFinish(eventID: submission.eventID)
        XCTAssertEqual(early, .none)
        let pendingPhase = await session.phase()
        XCTAssertEqual(pendingPhase, .submitting(cards[0].cardID))
        let done = try await session.commitPending(submission)
        XCTAssertEqual(done, .showNext(cards[1].cardID))
        let nextPhase = await session.phase()
        XCTAssertEqual(nextPhase, .question(cards[1].cardID))
        let count = await repo.eventCount()
        XCTAssertEqual(count, 1)
    }

    func testCommitBeforeAnimationWaitsThenAdvances() async throws {
        let (cards, repo, session) = fixture()
        try await session.revealAnswer(cardID: cards[0].cardID)
        let submission = try await session.beginSwipe(cardID: cards[0].cardID, rating: .again, at: Date())
        let early = try await session.commitPending(submission)
        XCTAssertEqual(early, .none)
        let done = try await session.animationDidFinish(eventID: submission.eventID)
        XCTAssertEqual(done, .showNext(cards[1].cardID))
        let count = await repo.eventCount()
        XCTAssertEqual(count, 1)
    }

    func testDuplicateSwipeRejectedWhilePending() async throws {
        let (cards, _, session) = fixture()
        try await session.revealAnswer(cardID: cards[0].cardID)
        _ = try await session.beginSwipe(cardID: cards[0].cardID, rating: .good, at: Date())
        do {
            _ = try await session.beginSwipe(cardID: cards[0].cardID, rating: .hard, at: Date())
            XCTFail("Must permit at most one active grading request")
        } catch ReviewSessionError.invalidPhase { }
    }

    func testFailureRestoresOriginalCardAndCanRetry() async throws {
        let (cards, repo, session) = fixture()
        let id = cards[0].cardID
        await repo.setFailNext(true)
        try await session.revealAnswer(cardID: id)
        let first = try await session.beginSwipe(cardID: id, rating: .good, at: Date())
        let failed = try await session.commitPending(first)
        XCTAssertEqual(failed, .none) // Wait for the animation before restoring.
        let restore = try await session.animationDidFinish(eventID: first.eventID)
        XCTAssertEqual(restore, .restoreCard(id))
        let phase = await session.phase()
        XCTAssertEqual(phase, .recovering(id))
        let eventsBefore = await repo.eventCount()
        XCTAssertEqual(eventsBefore, 0)
        try await session.recoveryDidFinish(cardID: id)
        let retry = try await session.beginSwipe(cardID: id, rating: .good, at: Date())
        XCTAssertNotEqual(first.eventID, retry.eventID)
        let ack = try await session.commitPending(retry)
        XCTAssertEqual(ack, .none)
        let result = try await session.animationDidFinish(eventID: retry.eventID)
        XCTAssertEqual(result, .showNext(cards[1].cardID))
        let eventsAfter = await repo.eventCount()
        XCTAssertEqual(eventsAfter, 1)
    }

    func testFailureAfterAnimationRestoresImmediately() async throws {
        let (cards, repo, session) = fixture(1)
        let id = cards[0].cardID
        await repo.setFailNext(true)
        try await session.revealAnswer(cardID: id)
        let req = try await session.beginSwipe(cardID: id, rating: .hard, at: Date())
        let animation = try await session.animationDidFinish(eventID: req.eventID)
        XCTAssertEqual(animation, .none)
        let failed = try await session.commitPending(req)
        XCTAssertEqual(failed, .restoreCard(id))
        let state = await session.phase()
        XCTAssertEqual(state, .recovering(id))
    }

    func testLastCardDoesNotCompleteBeforeBothAcks() async throws {
        let (cards, _, session) = fixture(1)
        let id = cards[0].cardID
        try await session.revealAnswer(cardID: id)
        let req = try await session.beginSwipe(cardID: id, rating: .easy, at: Date())
        let early = try await session.animationDidFinish(eventID: req.eventID)
        XCTAssertEqual(early, .none)
        let pending = await session.phase()
        XCTAssertEqual(pending, .submitting(id))
        let done = try await session.commitPending(req)
        XCTAssertEqual(done, .sessionCompleted)
        let finished = await session.phase()
        XCTAssertEqual(finished, .completed)
    }

    func testEmptySessionIsComplete() async throws {
        let (_, _, session) = fixture(0)
        let state = await session.phase()
        XCTAssertEqual(state, .completed)
    }

    func testRepositoryRevisionBlocksSecondDistinctEvent() async throws {
        let (cards, repo, _) = fixture(1)
        let now = Date()
        let first = ReviewSubmission(eventID: UUID(), cardID: cards[0].cardID,
                                     expectedRevision: 0, rating: .good, reviewedAt: now)
        let one = try await repo.commit(first)
        let replay = try await repo.commit(first)
        XCTAssertEqual(one, replay)
        do {
            _ = try await repo.commit(ReviewSubmission(eventID: UUID(), cardID: cards[0].cardID,
                                                         expectedRevision: 0, rating: .easy, reviewedAt: now))
            XCTFail("Revision must reject a distinct stale event")
        } catch MockFailure.injected { }
        let count = await repo.eventCount()
        XCTAssertEqual(count, 1)
    }
}
