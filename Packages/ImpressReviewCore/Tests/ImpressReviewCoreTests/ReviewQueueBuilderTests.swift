import XCTest
@testable import ImpressReviewCore

final class ReviewQueueBuilderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func candidate(_ status: ReviewCardStatus, minutesFromNow: Int,
                           suspended: Bool = false, revision: Int = 0) -> ReviewQueueCandidate {
        ReviewQueueCandidate(cardID: UUID(), revision: revision, status: status,
                             dueAt: now.addingTimeInterval(Double(minutesFromNow) * 60),
                             createdAt: now, isSuspended: suspended)
    }

    func testSwipeDirectionMappingNeverChanges() {
        XCTAssertEqual(ReviewSwipeDirection.left.rating, .hard)
        XCTAssertEqual(ReviewSwipeDirection.right.rating, .easy)
        XCTAssertEqual(ReviewSwipeDirection.up.rating, .good)
        XCTAssertEqual(ReviewSwipeDirection.down.rating, .again)
    }

    func testDueCardsWinOverNewAndCapacityIsSix() {
        let due = (0..<10).map { _ in candidate(.review, minutesFromNow: -60) }
        let new = (0..<100).map { _ in candidate(.new, minutesFromNow: 0) }
        let q = ReviewQueueBuilder.makeQueue(from: due + new, now: now)
        XCTAssertEqual(q.count, 6)
        XCTAssertTrue(Set(q.map(\.cardID)).isSubset(of: Set(due.map(\.cardID))))
    }

    func testUsesAtMostThreeNewCards() {
        let due = (0..<2).map { _ in candidate(.learning, minutesFromNow: -1) }
        let new = (0..<8).map { _ in candidate(.new, minutesFromNow: 0) }
        let q = ReviewQueueBuilder.makeQueue(from: due + new, now: now)
        XCTAssertEqual(q.count, 5)
        XCTAssertEqual(q.prefix(2).map(\.cardID).sorted(by: {$0.uuidString < $1.uuidString}), due.map(\.cardID).sorted(by: {$0.uuidString < $1.uuidString}))
    }

    func testPausedOrFutureCardsNeverCountAsDue() {
        let a = candidate(.review, minutesFromNow: 1)
        let b = candidate(.learning, minutesFromNow: -1, suspended: true)
        let c = candidate(.relearning, minutesFromNow: -1)
        let result = ReviewQueueBuilder.makeQueue(from: [a,b,c], now: now)
        XCTAssertEqual(result.map(\.cardID), [c.cardID])
    }

    func testQueueSnapshotIsStableAgainstFutureDueEvents() {
        let future = candidate(.learning, minutesFromNow: 10)
        let first = candidate(.review, minutesFromNow: -1)
        let atStart = ReviewQueueBuilder.makeQueue(from: [first,future], now: now)
        XCTAssertEqual(atStart.map(\.cardID), [first.cardID])
        let later = ReviewQueueBuilder.makeQueue(from: [first,future], now: now.addingTimeInterval(601))
        XCTAssertEqual(later.count, 2)
        XCTAssertEqual(atStart.count, 1) // The current session must not mutate retroactively.
    }
}
