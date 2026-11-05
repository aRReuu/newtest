#if os(iOS)
import XCTest
import Foundation
import CryptoKit
@testable import ImpressReviewCore

/// Synthetic bytes exercise private installation and SHA/CAS identity, not playback.
final class ImpressCardVideoPrivateStoreTests: XCTestCase {
    private let card = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
    private let media = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func fixture() throws -> (ImpressCardVideoPrivateStore, URL, URL, URL, ImpressCardVideoReference) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("impress-video-store-test-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        let sourceMovie = dir.appendingPathComponent("synthetic.mp4")
        let sourceCover = dir.appendingPathComponent("synthetic.jpg")
        let movie = Data(repeating: 0x51, count: 12_345)
        let cover = Data(repeating: 0xC3, count: 812)
        try movie.write(to: sourceMovie)
        try cover.write(to: sourceCover)
        let reference = try ImpressCardVideoReference(
            mediaID: media, cardID: card, contentRevision: 7,
            durationSeconds: 192.375, trimStartSeconds: 0, trimEndSeconds: 192.375,
            codec: .h264, videoBytes: UInt64(movie.count), videoSHA256: digest(movie),
            coverBytes: UInt64(cover.count), coverSHA256: digest(cover))
        let store = try ImpressCardVideoPrivateStore(rootURL: dir.appendingPathComponent("store"))
        return (store, dir, sourceMovie, sourceCover, reference)
    }

    func testAtomicPairInstallIsIdempotentAndRejectsWrongRevision() throws {
        let (store, dir, sourceMovie, sourceCover, ref) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let installed = try store.install(reference: ref, movie: sourceMovie, cover: sourceCover,
                                          cardID: card, expectedContentRevision: 7)
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.movieURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: installed.coverURL.path))
        XCTAssertNoThrow(try store.verifiedPlayback(cardID: card, contentRevision: 7, reference: ref))
        XCTAssertThrowsError(try store.verifiedPlayback(cardID: card, contentRevision: 8, reference: ref))
        XCTAssertThrowsError(try store.verifiedPlayback(cardID: UUID(), contentRevision: 7, reference: ref))
        // Immutable SHA-identical files are idempotent for CAS retries.
        let retried = try store.install(reference: ref, movie: sourceMovie, cover: sourceCover,
                                        cardID: card, expectedContentRevision: 7)
        XCTAssertEqual(retried.movieURL, installed.movieURL)
        XCTAssertEqual(retried.coverURL, installed.coverURL)
    }

    func testPostInstallTamperAndReferenceAuditFailClosed() throws {
        let (store, dir, sourceMovie, sourceCover, ref) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let installed = try store.install(reference: ref, movie: sourceMovie, cover: sourceCover,
                                          cardID: card, expectedContentRevision: 7)
        XCTAssertThrowsError(try store.removeAfterReferenceAudit(ref,
            stillReferencedMediaIDs: [media]))
        try Data(repeating: 0x00, count: 12_345).write(to: installed.movieURL, options: .atomic)
        XCTAssertThrowsError(try store.verifiedPlayback(cardID: card, contentRevision: 7, reference: ref))
        try store.removeAfterReferenceAudit(ref, stillReferencedMediaIDs: [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: installed.movieURL.path))
    }

    func testBadSourceDigestDoesNotInstallOrModifySavedCard() throws {
        let (store, dir, sourceMovie, sourceCover, ref) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(repeating: 0, count: 12_345).write(to: sourceMovie, options: .atomic)
        XCTAssertThrowsError(try store.install(reference: ref, movie: sourceMovie, cover: sourceCover,
                                               cardID: card, expectedContentRevision: 7))
        XCTAssertThrowsError(try store.verifiedPlayback(cardID: card, contentRevision: 7, reference: ref))
    }

    func testSymlinkedMediaRootCannotRedirectInstallation() throws {
        let (store, dir, sourceMovie, sourceCover, ref) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outside = dir.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        try FileManager.default.createSymbolicLink(
            at: dir.appendingPathComponent("store/CardVideo", isDirectory: true),
            withDestinationURL: outside)
        XCTAssertThrowsError(try store.install(reference: ref, movie: sourceMovie, cover: sourceCover,
                                               cardID: card, expectedContentRevision: 7))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: outside.appendingPathComponent(card.uuidString.lowercased()).path))
    }

    func testSymlinkedParentRejectsPlaybackAndAuditedRemoval() throws {
        let (store, dir, sourceMovie, sourceCover, ref) = try fixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let installed = try store.install(reference: ref, movie: sourceMovie, cover: sourceCover,
                                          cardID: card, expectedContentRevision: 7)
        let mediaRoot = dir.appendingPathComponent("store/CardVideo", isDirectory: true)
        let relocated = dir.appendingPathComponent("relocated", isDirectory: true)
        try FileManager.default.moveItem(at: mediaRoot, to: relocated)
        try FileManager.default.createSymbolicLink(at: mediaRoot, withDestinationURL: relocated)
        XCTAssertThrowsError(try store.verifiedPlayback(cardID: card, contentRevision: 7,
                                                        reference: ref))
        XCTAssertThrowsError(try store.removeAfterReferenceAudit(ref, stillReferencedMediaIDs: []))
        XCTAssertTrue(FileManager.default.fileExists(atPath: relocated.appendingPathComponent(
            card.uuidString.lowercased()).appendingPathComponent(
            media.uuidString.lowercased()).appendingPathComponent("video.mp4").path))
        XCTAssertTrue(installed.movieURL.path.hasSuffix("video.mp4"))
    }
}
#endif
