#if os(iOS)
import Foundation
import CryptoKit

/// Private, immutable card video/cover pair. The store NEVER writes a card row:
/// caller must do WCDB content CAS and post-write readback before acknowledging
/// a save. A CAS failure leaves only an unreferenced pair for safe cleanup.
public final class ImpressCardVideoPrivateStore {
    public enum Failure: Swift.Error {
        case invalidRoot, wrongCardOrRevision, missingFile, symlinkOrNonFile
        case digestMismatch, invalidSize, alreadyExists, stillReferenced
    }

    public struct Installed: Sendable {
        public let reference: ImpressCardVideoReference
        public let movieURL: URL
        public let coverURL: URL
    }

    private let fm: FileManager
    private let root: URL

    public static func applicationSupportStore() throws -> ImpressCardVideoPrivateStore {
        #if DEBUG
        // A deliberately requested playback UI fixture must never deposit
        // synthetic video into the app's actual Application Support directory.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("-ImpressV11VideoPlaybackFixture") {
            guard arguments.contains("-ImpressV11SyntheticVault"),
                  let rawID = ProcessInfo.processInfo.environment["IMPRESS_V11_FIXTURE_ID"],
                  let fixtureID = UUID(uuidString: rawID) else {
                throw Failure.invalidRoot
            }
            let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent(
                "ImpressV11-" + fixtureID.uuidString, isDirectory: true)
            return try ImpressCardVideoPrivateStore(rootURL: sandbox
                .appendingPathComponent("Support/ImpressCardMedia", isDirectory: true))
        }
        #endif
        let support = try FileManager.default.url(for: .applicationSupportDirectory,
                                                   in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
        return try ImpressCardVideoPrivateStore(rootURL: support.appendingPathComponent(
            "ImpressCardMedia", isDirectory: true))
    }

    /// Injection is reserved for isolated XCTest temporary roots.
    public init(rootURL: URL, fileManager: FileManager = .default) throws {
        guard rootURL.isFileURL else { throw Failure.invalidRoot }
        self.fm = fileManager
        self.root = rootURL.standardizedFileURL
        try fm.createDirectory(at: root, withIntermediateDirectories: true,
                               attributes: [.protectionKey:
                                   FileProtectionType.completeUntilFirstUserAuthentication])
        try ensureDirectory(root)
        var values = URLResourceValues()
        // App-specific verified ZIP handles media independently; never leak it
        // into automatic cloud backup/Photos/Provider or Chat.
        values.isExcludedFromBackup = true
        var mutable = root
        try mutable.setResourceValues(values)
    }

    /// Exporter outputs are untrusted until both files pass streamed SHA/size.
    /// A new immutable pair is installed with one same-volume directory rename.
    public func install(_ staged: ImpressCardVideoAVFoundationExporter.Staged,
                        cardID: UUID, expectedContentRevision: Int) throws -> Installed {
        try install(reference: staged.reference, movie: staged.movieURL,
                    cover: staged.coverURL, cardID: cardID,
                    expectedContentRevision: expectedContentRevision)
    }

    /// Also usable for a ZIP restore *after* allowlist and archive validation.
    /// Never pass a Photos asset URL or an unapproved external Vault path.
    public func install(reference: ImpressCardVideoReference,
                        movie: URL, cover: URL,
                        cardID: UUID, expectedContentRevision: Int) throws -> Installed {
        guard reference.belongs(to: cardID, revision: expectedContentRevision) else {
            throw Failure.wrongCardOrRevision
        }
        try verifyFile(movie, bytes: reference.videoBytes, digest: reference.videoSHA256)
        try verifyFile(cover, bytes: reference.coverBytes, digest: reference.coverSHA256)

        // Check every ancestor before descending into a private media path.
        guard let cardDir = try checkedCardDirectory(cardID: cardID, create: true) else {
            throw Failure.invalidRoot
        }
        let finalDir = cardDir.appendingPathComponent(reference.mediaID.uuidString.lowercased(),
                                                       isDirectory: true)
        if fm.fileExists(atPath: finalDir.path) {
            // A previous CAS retry may already have installed this immutable
            // UUID. Only exact SHA/length identity is idempotent; never overwrite.
            try ensureDirectory(finalDir)
            let existingMovie = finalDir.appendingPathComponent("video.mp4")
            let existingCover = finalDir.appendingPathComponent("cover.jpg")
            try verifyFile(existingMovie, bytes: reference.videoBytes,
                           digest: reference.videoSHA256)
            try verifyFile(existingCover, bytes: reference.coverBytes,
                           digest: reference.coverSHA256)
            return Installed(reference: reference, movieURL: existingMovie, coverURL: existingCover)
        }

        let staging = cardDir.appendingPathComponent(".partial-\(UUID().uuidString)",
                                                      isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                               attributes: [.protectionKey:
                                   FileProtectionType.completeUntilFirstUserAuthentication])
        var installed = false
        defer { if !installed { try? fm.removeItem(at: staging) } }
        let tempMovie = staging.appendingPathComponent("video.mp4")
        let tempCover = staging.appendingPathComponent("cover.jpg")
        try fm.copyItem(at: movie, to: tempMovie)
        try fm.copyItem(at: cover, to: tempCover)
        for file in [tempMovie, tempCover] {
            try fm.setAttributes([.protectionKey:
                FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: file.path)
        }
        // Verify the actual bytes that will be installed, not only a Photos/
        // exporter file that might have changed since the first digest.
        try verifyFile(tempMovie, bytes: reference.videoBytes, digest: reference.videoSHA256)
        try verifyFile(tempCover, bytes: reference.coverBytes, digest: reference.coverSHA256)
        try fm.moveItem(at: staging, to: finalDir)
        installed = true
        return Installed(reference: reference, movieURL: finalDir.appendingPathComponent("video.mp4"),
                         coverURL: finalDir.appendingPathComponent("cover.jpg"))
    }

    /// Only call off the main thread: hashes the entire local movie before use.
    /// Neither missing/corrupt media nor another card's UUID yields playback.
    public func verifiedPlayback(cardID: UUID, contentRevision: Int,
                                 reference: ImpressCardVideoReference) throws -> Installed {
        guard reference.belongs(to: cardID, revision: contentRevision) else {
            throw Failure.wrongCardOrRevision
        }
        guard let cardDir = try checkedCardDirectory(cardID: cardID, create: false) else {
            throw Failure.missingFile
        }
        let mediaDir = cardDir.appendingPathComponent(
            reference.mediaID.uuidString.lowercased(), isDirectory: true)
        try ensureDirectory(mediaDir)
        let movie = mediaDir.appendingPathComponent("video.mp4")
        let cover = mediaDir.appendingPathComponent("cover.jpg")
        try verifyFile(movie, bytes: reference.videoBytes, digest: reference.videoSHA256)
        try verifyFile(cover, bytes: reference.coverBytes, digest: reference.coverSHA256)
        return Installed(reference: reference, movieURL: movie, coverURL: cover)
    }

    /// Must be called only after the repository atomically certifies there are
    /// no *current or historical/undo/backup* references to this mediaID.
    /// This method cannot determine reference counts on its own.
    public func removeAfterReferenceAudit(_ reference: ImpressCardVideoReference,
                                          stillReferencedMediaIDs: Set<UUID>) throws {
        guard !stillReferencedMediaIDs.contains(reference.mediaID) else {
            throw Failure.stillReferenced
        }
        guard let cardDir = try checkedCardDirectory(
            cardID: reference.cardID, create: false) else { return }
        let mediaDir = cardDir.appendingPathComponent(
            reference.mediaID.uuidString.lowercased(), isDirectory: true)
        guard fm.fileExists(atPath: mediaDir.path) else { return }
        try ensureDirectory(mediaDir)
        try fm.removeItem(at: mediaDir)
    }

    /// A leaf-only check is insufficient: a symlinked CardVideo/card directory
    /// could redirect media writes, reads and audited deletes outside the root.
    private func checkedCardDirectory(cardID: UUID, create: Bool) throws -> URL? {
        try ensureDirectory(root)
        let mediaRoot = root.appendingPathComponent("CardVideo", isDirectory: true)
        if create {
            try fm.createDirectory(at: mediaRoot, withIntermediateDirectories: true,
                attributes: [.protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication])
        } else if !fm.fileExists(atPath: mediaRoot.path) {
            return nil
        }
        try ensureDirectory(mediaRoot)
        let cardDir = mediaRoot.appendingPathComponent(
            cardID.uuidString.lowercased(), isDirectory: true)
        if create {
            try fm.createDirectory(at: cardDir, withIntermediateDirectories: true,
                attributes: [.protectionKey:
                    FileProtectionType.completeUntilFirstUserAuthentication])
        } else if !fm.fileExists(atPath: cardDir.path) {
            return nil
        }
        try ensureDirectory(cardDir)
        return cardDir
    }

    private func ensureDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values.isSymbolicLink != true, values.isDirectory == true else {
            throw Failure.symlinkOrNonFile
        }
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard (attributes[.type] as? FileAttributeType) == .typeDirectory else {
            throw Failure.symlinkOrNonFile
        }
    }

    private func verifyFile(_ url: URL, bytes: UInt64, digest: String) throws {
        guard url.isFileURL, bytes > 0, digest.count == 64 else { throw Failure.invalidSize }
        let attributes: [FileAttributeKey: Any]
        do { attributes = try fm.attributesOfItem(atPath: url.path) }
        catch { throw Failure.missingFile }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true,
              (attributes[.type] as? FileAttributeType) == .typeRegular else {
            throw Failure.symlinkOrNonFile
        }
        guard let actualBytes = (attributes[.size] as? NSNumber)?.uint64Value,
              actualBytes == bytes else { throw Failure.invalidSize }
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }
        var sha = SHA256()
        var counted: UInt64 = 0
        while true {
            let block = handle.readData(ofLength: 256 * 1024)
            if block.isEmpty { break }
            let (sum, overflow) = counted.addingReportingOverflow(UInt64(block.count))
            guard !overflow, sum <= bytes else { throw Failure.invalidSize }
            counted = sum
            sha.update(data: block)
        }
        let actualHash = sha.finalize().map { String(format: "%02x", $0) }.joined()
        guard counted == bytes, actualHash == digest else { throw Failure.digestMismatch }
    }
}
#endif
