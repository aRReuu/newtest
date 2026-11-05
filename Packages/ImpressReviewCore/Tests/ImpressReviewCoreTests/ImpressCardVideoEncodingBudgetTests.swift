import Foundation
import XCTest
@testable import ImpressReviewCore

final class ImpressCardVideoEncodingBudgetTests: XCTestCase {
    private func sample(duration: Double = 600.0, start: Double = 0,
                        end: Double = 600.0, free: UInt64 = 2_000_000_000,
                        hevc: Bool = true, h264: Bool = true,
                        sound: Bool = true, preference: ImpressCardVideoEncodingBudget.Preference = .balanced,
                        width: Int = 1920, height: Int = 1080) -> ImpressCardVideoEncodingBudget.Source {
        .init(durationSeconds: duration, width: width, height: height,
              hasAudio: sound, trimStartSeconds: start, trimEndSeconds: end,
              availableTemporaryBytes: free, canEncodeHEVC: hevc,
              canEncodeH264: h264, preference: preference)
    }

    func testMalformedAVFoundationRasterMetadataRejectedBeforeIntegerConversion() throws {
        // Both portrait and landscape dimensions are allowed after transform.
        let portrait = try ImpressCardVideoEncodingBudget.validatedSourceDimensions(
            widthPixels: 1080, heightPixels: 1920)
        XCTAssertEqual(portrait.width, 1080)
        XCTAssertEqual(portrait.height, 1920)
        let fractional = try ImpressCardVideoEncodingBudget.validatedSourceDimensions(
            widthPixels: 720.49, heightPixels: 1280.49)
        XCTAssertEqual(fractional.width, 720)
        XCTAssertEqual(fractional.height, 1280)

        // Int(NaN), Int(infinity), and Int(hugeDouble) trap in Swift; reject
        // untrusted asset geometry before any conversion or export session.
        let invalid: [(Double, Double)] = [
            (.nan, 1080), (1920, .nan),
            (.infinity, 1080), (1920, -.infinity),
            (.greatestFiniteMagnitude, 1080),
            (1920, .greatestFiniteMagnitude),
            (-1, 720), (0, 1080), (63.49, 1080), (16_384.5, 1080)
        ]
        for (width, height) in invalid {
            XCTAssertThrowsError(
                try ImpressCardVideoEncodingBudget.validatedSourceDimensions(
                    widthPixels: width, heightPixels: height)
            ) {
                XCTAssertEqual($0 as? ImpressCardVideoEncodingBudget.Error, .invalidSource)
            }
        }
    }

    func testMalformedNominalFrameRateDoesNotOverflowIntegerConversion() {
        for bad in [Double.nan, .infinity, -.infinity, -1, 0] {
            XCTAssertEqual(ImpressCardVideoEncodingBudget.safeNominalFrameRate(bad), 30)
        }
        XCTAssertEqual(ImpressCardVideoEncodingBudget.safeNominalFrameRate(.greatestFiniteMagnitude), 30)
        XCTAssertEqual(ImpressCardVideoEncodingBudget.safeNominalFrameRate(120), 30)
        XCTAssertEqual(ImpressCardVideoEncodingBudget.safeNominalFrameRate(29.97), 30)
        XCTAssertEqual(ImpressCardVideoEncodingBudget.safeNominalFrameRate(23.976), 24)
        XCTAssertEqual(ImpressCardVideoEncodingBudget.safeNominalFrameRate(0.1), 1)
    }

    func testFullVideoBeyondSixtySecondsNeverSilentlyTruncated() throws {
        let plan = try ImpressCardVideoEncodingBudget.propose(sample(duration: 601.375, end: 601.375))
        XCTAssertEqual(plan.durationSeconds, 601.375)
        XCTAssertEqual(plan.trimStartSeconds, 0)
        XCTAssertEqual(plan.trimEndSeconds, 601.375)
        XCTAssertEqual(plan.codec, .hevc)
        XCTAssertTrue(plan.estimatedBytes <= ImpressCardVideoReference.maximumBytes)
    }

    func testArbitraryFractionalTrimPreservesExactSelectedRange() throws {
        let plan = try ImpressCardVideoEncodingBudget.propose(
            sample(duration: 1600.625, start: 40.125, end: 901.375))
        XCTAssertEqual(plan.durationSeconds, 861.25)
        XCTAssertEqual(plan.trimStartSeconds, 40.125)
        XCTAssertEqual(plan.trimEndSeconds, 901.375)
    }

    func testHEVCFallsBackToH264WhenNotAvailable() throws {
        let plan = try ImpressCardVideoEncodingBudget.propose(sample(hevc: false))
        XCTAssertEqual(plan.codec, .h264)
        XCTAssertEqual(plan.audioBitrate, 64_000)
        XCTAssertEqual(plan.targetWidth % 2, 0)
        XCTAssertEqual(plan.targetHeight % 2, 0)
    }

    func testNoSupportedCodecFailsClosed() throws {
        XCTAssertThrowsError(try ImpressCardVideoEncodingBudget.propose(
            sample(hevc: false, h264: false))) {
                XCTAssertEqual($0 as? ImpressCardVideoEncodingBudget.Error, .codecUnavailable)
            }
    }

    func testUnsupportedSourceAndTrimFailClosed() throws {
        XCTAssertThrowsError(try ImpressCardVideoEncodingBudget.propose(
            sample(width: 0)))
        XCTAssertThrowsError(try ImpressCardVideoEncodingBudget.propose(
            sample(duration: .nan)))
        XCTAssertThrowsError(try ImpressCardVideoEncodingBudget.propose(
            sample(start: 100, end: 99)))
        XCTAssertThrowsError(try ImpressCardVideoEncodingBudget.propose(
            sample(start: -1)))
        XCTAssertThrowsError(try ImpressCardVideoEncodingBudget.propose(
            sample(end: 601)))
    }

    func testLongVideoFailsWithActionableLimitInsteadOfAutoTruncation() throws {
        XCTAssertThrowsError(try ImpressCardVideoEncodingBudget.propose(
            sample(duration: 20 * 3600, end: 20 * 3600))) {
                XCTAssertEqual($0 as? ImpressCardVideoEncodingBudget.Error,
                               .needsShorterClipOrLowerQuality)
            }
    }

    func testAvailableSpaceProtectsDoubleTempAndCancellation() throws {
        let plan = try ImpressCardVideoEncodingBudget.propose(sample())
        XCTAssertGreaterThan(plan.requiredTemporaryBytes, 16 * 1_048_576)
        XCTAssertThrowsError(try ImpressCardVideoEncodingBudget.propose(
            sample(free: plan.requiredTemporaryBytes - 1))) {
                XCTAssertEqual($0 as? ImpressCardVideoEncodingBudget.Error,
                               .notEnoughTemporarySpace)
            }
        XCTAssertNoThrow(try ImpressCardVideoEncodingBudget.propose(
            sample(free: plan.requiredTemporaryBytes)))
    }

    func testCompactPreferenceDownscalesWithoutChangingDuration() throws {
        let original = try ImpressCardVideoEncodingBudget.propose(sample(duration: 200, end: 200))
        let compact = try ImpressCardVideoEncodingBudget.propose(
            sample(duration: 200, end: 200, preference: .compact))
        XCTAssertLessThanOrEqual(compact.targetWidth, original.targetWidth)
        XCTAssertLessThan(compact.targetHeight, original.targetHeight)
        XCTAssertEqual(compact.durationSeconds, original.durationSeconds)
    }

    func testSilentSourceDoesNotInventAudioTrack() throws {
        let plan = try ImpressCardVideoEncodingBudget.propose(sample(sound: false))
        XCTAssertEqual(plan.audioBitrate, 0)
    }
}
