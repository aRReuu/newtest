import Foundation
import XCTest
@testable import ImpressReviewCore

final class ImpressCardVideoPolicyTests: XCTestCase {
    private let card = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let media = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
    private let digest = String(repeating: "a", count: 64)

    private func reference(duration: Double = 1800.125, start: Double = 0,
                           end: Double = 1800.125, videoBytes: UInt64 = 100_000,
                           coverBytes: UInt64 = 2_000) throws -> ImpressCardVideoReference {
        try .init(mediaID: media, cardID: card, contentRevision: 7,
                  durationSeconds: duration, trimStartSeconds: start, trimEndSeconds: end,
                  codec: .hevc, videoBytes: videoBytes, videoSHA256: digest,
                  coverBytes: coverBytes, coverSHA256: digest)
    }

    func testFullLengthBeyondSixtySecondsAndFractionalDuration() throws {
        let ref = try reference()
        XCTAssertTrue(ref.isFullLength)
        XCTAssertEqual(ref.durationSeconds, 1800.125)
        XCTAssertEqual(ref.trimEndSeconds, 1800.125)
    }

    func testTwoEndedTrimPreservesNonIntegerBoundsAndIdentity() throws {
        let ref = try reference(start: 60.375, end: 1290.625)
        XCTAssertFalse(ref.isFullLength)
        XCTAssertEqual(ref.trimStartSeconds, 60.375)
        XCTAssertEqual(ref.trimEndSeconds, 1290.625)
        XCTAssertTrue(ref.belongs(to: card, revision: 7))
        XCTAssertFalse(ref.belongs(to: UUID(), revision: 7))
        XCTAssertFalse(ref.belongs(to: card, revision: 8))
    }

    func testTimelineInvalidBoundsNeverClampSilently() throws {
        for (d, a, b) in [(0.0, 0.0, 0.0), (180.0, -1.0, 50.0),
                          (180.0, 80.0, 80.0), (180.0, 140.0, 110.0),
                          (180.0, 0.0, 181.0), (.infinity, 0.0, 1.0),
                          (180.0, .nan, 20.0)] {
            XCTAssertThrowsError(try reference(duration: d, start: a, end: b))
        }
    }

    func testPrivatePathsAreDerivedNotProvidedByPicker() throws {
        let ref = try reference()
        XCTAssertEqual(ref.videoRelativePath,
                       "CardVideo/11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222/video.mp4")
        XCTAssertEqual(ref.coverRelativePath,
                       "CardVideo/11111111-1111-4111-8111-111111111111/22222222-2222-4222-8222-222222222222/cover.jpg")
        XCTAssertFalse(ref.videoRelativePath.contains(".."))
    }

    func testProvisionalSizeLimitsRejectOversizedMediaAndCover() throws {
        XCTAssertNoThrow(try reference(videoBytes: ImpressCardVideoReference.maximumBytes))
        XCTAssertThrowsError(try reference(videoBytes: ImpressCardVideoReference.maximumBytes + 1))
        XCTAssertThrowsError(try reference(videoBytes: 0))
        XCTAssertThrowsError(try reference(coverBytes: ImpressCardVideoReference.maximumCoverBytes + 1))
    }

    func testSHA256AndDecoderCannotBypassValidation() throws {
        let ref = try reference()
        let encoded = try JSONEncoder().encode(ref)
        XCTAssertEqual(try JSONDecoder().decode(ImpressCardVideoReference.self, from: encoded), ref)
        XCTAssertFalse(ImpressCardVideoReference.isSHA256(String(repeating: "A", count: 64)))
        XCTAssertFalse(ImpressCardVideoReference.isSHA256("../secret.mov"))
        let corrupt = String(data: encoded, encoding: .utf8)!
            .replacingOccurrences(of: digest, with: "../secret.mov")
        XCTAssertThrowsError(try JSONDecoder().decode(ImpressCardVideoReference.self,
                                                      from: Data(corrupt.utf8)))
    }

    func testArchiveContainsOnlyExactReferencedPairAndRejectsDuplicate() throws {
        let ref = try reference()
        let index = try ImpressCardVideoArchiveIndex(references: [ref])
        XCTAssertEqual(index.files.count, 2)
        XCTAssertNoThrow(try index.validateExtractedFiles(index.files))
        XCTAssertThrowsError(try index.validateExtractedFiles(
            index.files + [.init(name: "../escape.mp4", bytes: 1, sha256: digest)]))
        XCTAssertThrowsError(try index.validateExtractedFiles(Array(index.files.prefix(1))))
        XCTAssertThrowsError(try ImpressCardVideoArchiveIndex(references: [ref, ref]))
    }

    func testHistoricalRestorationReusesOneImmutableMediaPair() throws {
        let original = try reference()
        let replay = try original.rebound(to: 9)
        XCTAssertTrue(replay.belongs(to: card, revision: 9))
        let index = try ImpressCardVideoArchiveIndex(references: [original, replay])
        XCTAssertEqual(index.references.count, 2)
        XCTAssertEqual(index.files.count, 2)
        XCTAssertNoThrow(try index.validateExtractedFiles(index.files))
        XCTAssertThrowsError(try ImpressCardVideoArchiveIndex(references: [original, original]))
    }

    func testMediaUUIDCollisionWithDifferentDigestRejected() throws {
        let original = try reference()
        let collided = try ImpressCardVideoReference(
            mediaID: media, cardID: card, contentRevision: 8,
            durationSeconds: 1800.125, trimStartSeconds: 0, trimEndSeconds: 1800.125,
            codec: .hevc, videoBytes: 100_000,
            videoSHA256: String(repeating: "b", count: 64),
            coverBytes: 2_000, coverSHA256: digest)
        XCTAssertThrowsError(try ImpressCardVideoArchiveIndex(references: [original, collided]))
    }

    func testMediaUUIDCollisionWithChangedTimelineRejected() throws {
        let original = try reference()
        // Same pair of file digests is not enough: a historical revision must
        // not forge new duration or clip endpoints for an existing media UUID.
        for (duration, start, end) in [
            (1900.125, 0.0, 1800.125),
            (1800.125, 30.0, 1800.125),
            (1800.125, 0.0, 1799.875)
        ] {
            let forged = try ImpressCardVideoReference(
                mediaID: media, cardID: card, contentRevision: 8,
                durationSeconds: duration, trimStartSeconds: start,
                trimEndSeconds: end, codec: .hevc,
                videoBytes: original.videoBytes, videoSHA256: original.videoSHA256,
                coverBytes: original.coverBytes, coverSHA256: original.coverSHA256)
            XCTAssertThrowsError(try ImpressCardVideoArchiveIndex(
                references: [original, forged]))
        }
        // A legitimate CAS replay changes the revision but nothing else.
        XCTAssertNoThrow(try ImpressCardVideoArchiveIndex(
            references: [original, original.rebound(to: 8)]))
    }

    func testOldCardMissingVideoFieldDecodesAsNil() throws {
        struct Legacy: Codable { let question: String; let video: ImpressCardVideoReference? }
        let old = try JSONDecoder().decode(Legacy.self,
            from: Data(#"{"question":"legacy image"}"#.utf8))
        XCTAssertNil(old.video)
    }
}
