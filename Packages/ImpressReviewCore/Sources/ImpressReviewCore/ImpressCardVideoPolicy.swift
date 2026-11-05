import Foundation

/// Immutable identity and bounded metadata for a card-local video. No movie pixels,
/// Photos identifiers, user-supplied paths, or source file URLs enter WCDB/JSON.
public struct ImpressCardVideoReference: Codable, Equatable, Sendable {
    public enum Codec: String, Codable, Sendable { case hevc, h264 }
    public enum ValidationError: Error, Equatable {
        case invalidTimeline, invalidIdentity, invalidDigest, invalidSize, invalidArchive
    }

    /// Provisional engineering limits; device storage and ZIP testing must confirm them.
    public static let preferredBytes: UInt64 = 32 * 1_048_576
    public static let maximumBytes: UInt64 = 160 * 1_048_576
    public static let maximumCoverBytes: UInt64 = 1_048_576

    public let version: Int
    public let mediaID: UUID
    public let cardID: UUID
    public let contentRevision: Int
    public let durationSeconds: Double
    public let trimStartSeconds: Double
    public let trimEndSeconds: Double
    public let codec: Codec
    public let videoBytes: UInt64
    public let videoSHA256: String
    public let coverBytes: UInt64
    public let coverSHA256: String

    public init(mediaID: UUID, cardID: UUID, contentRevision: Int,
                durationSeconds: Double, trimStartSeconds: Double, trimEndSeconds: Double,
                codec: Codec, videoBytes: UInt64, videoSHA256: String,
                coverBytes: UInt64, coverSHA256: String) throws {
        guard contentRevision >= 0 else { throw ValidationError.invalidIdentity }
        guard durationSeconds.isFinite, trimStartSeconds.isFinite, trimEndSeconds.isFinite,
              durationSeconds > 0, trimStartSeconds >= 0,
              trimEndSeconds > trimStartSeconds, trimEndSeconds <= durationSeconds else {
            throw ValidationError.invalidTimeline
        }
        guard (1...Self.maximumBytes).contains(videoBytes),
              (1...Self.maximumCoverBytes).contains(coverBytes) else {
            throw ValidationError.invalidSize
        }
        guard Self.isSHA256(videoSHA256), Self.isSHA256(coverSHA256) else {
            throw ValidationError.invalidDigest
        }
        version = 1
        self.mediaID = mediaID
        self.cardID = cardID
        self.contentRevision = contentRevision
        self.durationSeconds = durationSeconds
        self.trimStartSeconds = trimStartSeconds
        self.trimEndSeconds = trimEndSeconds
        self.codec = codec
        self.videoBytes = videoBytes
        self.videoSHA256 = videoSHA256
        self.coverBytes = coverBytes
        self.coverSHA256 = coverSHA256
    }

    public var isFullLength: Bool {
        trimStartSeconds == 0 && trimEndSeconds == durationSeconds
    }

    /// Caller never supplies a file name: derive it solely from validated UUIDs.
    // Both media files live in one immutable directory. A same-volume
    // directory rename installs the pair atomically before the WCDB CAS.
    public var mediaDirectoryRelativePath: String {
        "CardVideo/\(cardID.uuidString.lowercased())/\(mediaID.uuidString.lowercased())"
    }
    public var videoRelativePath: String { mediaDirectoryRelativePath + "/video.mp4" }
    public var coverRelativePath: String { mediaDirectoryRelativePath + "/cover.jpg" }

    public func belongs(to cardID: UUID, revision: Int) -> Bool {
        self.cardID == cardID && contentRevision == revision
    }

    /// Replaying a historical version gives it a new CAS revision but reuses the
    /// identical immutable file. Never mutate the archived version's identity.
    public func rebound(to revision: Int) throws -> Self {
        try .init(mediaID: mediaID, cardID: cardID, contentRevision: revision,
                  durationSeconds: durationSeconds, trimStartSeconds: trimStartSeconds,
                  trimEndSeconds: trimEndSeconds, codec: codec, videoBytes: videoBytes,
                  videoSHA256: videoSHA256, coverBytes: coverBytes, coverSHA256: coverSHA256)
    }

    public static func isSHA256(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 64 && bytes.allSatisfy {
            (48...57).contains($0) || (97...102).contains($0)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case version, mediaID, cardID, contentRevision, durationSeconds
        case trimStartSeconds, trimEndSeconds, codec, videoBytes
        case videoSHA256, coverBytes, coverSHA256
    }

    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        guard try box.decode(Int.self, forKey: .version) == 1 else {
            throw ValidationError.invalidIdentity
        }
        try self.init(
            mediaID: box.decode(UUID.self, forKey: .mediaID),
            cardID: box.decode(UUID.self, forKey: .cardID),
            contentRevision: box.decode(Int.self, forKey: .contentRevision),
            durationSeconds: box.decode(Double.self, forKey: .durationSeconds),
            trimStartSeconds: box.decode(Double.self, forKey: .trimStartSeconds),
            trimEndSeconds: box.decode(Double.self, forKey: .trimEndSeconds),
            codec: box.decode(Codec.self, forKey: .codec),
            videoBytes: box.decode(UInt64.self, forKey: .videoBytes),
            videoSHA256: box.decode(String.self, forKey: .videoSHA256),
            coverBytes: box.decode(UInt64.self, forKey: .coverBytes),
            coverSHA256: box.decode(String.self, forKey: .coverSHA256))
    }
}

/// Deterministic backup allowlist. It represents *referenced* current and historical
/// revisions; the archive builder must compare each actual file's streamed digest.
public struct ImpressCardVideoArchiveIndex: Codable, Equatable, Sendable {
    public struct File: Codable, Hashable, Sendable {
        public let name: String
        public let bytes: UInt64
        public let sha256: String
        /// App-level ZIP coordinator must construct validated size/digest receipts.
        public init(name: String, bytes: UInt64, sha256: String) {
            self.name = name
            self.bytes = bytes
            self.sha256 = sha256
        }
    }
    public let version: Int
    public let references: [ImpressCardVideoReference]

    public init(references: [ImpressCardVideoReference]) throws {
        guard references.count <= 128 else {
            throw ImpressCardVideoReference.ValidationError.invalidArchive
        }
        var owners = [UUID: ImpressCardVideoReference]()
        var revisions = Set<String>()
        var total: UInt64 = 0
        for ref in references {
            let revisionKey = ref.cardID.uuidString + ":" + String(ref.contentRevision)
            guard revisions.insert(revisionKey).inserted else {
                throw ImpressCardVideoReference.ValidationError.invalidArchive
            }
            if let known = owners[ref.mediaID] {
                // Content history can reuse an immutable video across revisions.
                // A UUID collision with different bytes or another card is unsafe.
                guard known.cardID == ref.cardID,
                      // A media UUID names one immutable encoded pair and its
                      // source interval. History may change the CAS revision,
                      // never silently rewrite clip provenance or playback time.
                      known.durationSeconds == ref.durationSeconds,
                      known.trimStartSeconds == ref.trimStartSeconds,
                      known.trimEndSeconds == ref.trimEndSeconds,
                      known.videoBytes == ref.videoBytes,
                      known.coverBytes == ref.coverBytes,
                      known.videoSHA256 == ref.videoSHA256,
                      known.coverSHA256 == ref.coverSHA256,
                      known.codec == ref.codec else {
                    throw ImpressCardVideoReference.ValidationError.invalidArchive
                }
                continue
            }
            owners[ref.mediaID] = ref
            let (sum, overflow) = total.addingReportingOverflow(ref.videoBytes + ref.coverBytes)
            guard !overflow, sum <= 2 * 1_073_741_824 else {
                throw ImpressCardVideoReference.ValidationError.invalidSize
            }
            total = sum
        }
        version = 1
        self.references = references.sorted {
            ($0.mediaID.uuidString, $0.contentRevision) <
            ($1.mediaID.uuidString, $1.contentRevision)
        }
    }

    public var files: [File] {
        var seen = Set<UUID>()
        return references.filter { seen.insert($0.mediaID).inserted }.flatMap { ref in
            [File(name: ref.videoRelativePath, bytes: ref.videoBytes, sha256: ref.videoSHA256),
             File(name: ref.coverRelativePath, bytes: ref.coverBytes, sha256: ref.coverSHA256)]
        }
    }

    public func validateExtractedFiles(_ actual: [File]) throws {
        let expected = files
        guard actual.count == expected.count,
              Set(actual.map(\.name)).count == actual.count,
              Set(actual) == Set(expected) else {
            throw ImpressCardVideoReference.ValidationError.invalidArchive
        }
    }

    private enum CodingKeys: String, CodingKey { case version, references }
    public init(from decoder: Decoder) throws {
        let box = try decoder.container(keyedBy: CodingKeys.self)
        guard try box.decode(Int.self, forKey: .version) == 1 else {
            throw ImpressCardVideoReference.ValidationError.invalidArchive
        }
        try self.init(references: box.decode([ImpressCardVideoReference].self, forKey: .references))
    }
}
