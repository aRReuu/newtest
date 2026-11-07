//
//  ReviewWCDBRepository.swift
//  Impress V3 -- staged iOS integration adapter (WCDB.swift 1.1.0).
//
//  This file deliberately is not added to the legacy Xcode target yet.
//  Link the ImpressReviewCore Swift package before target integration.
//

import Foundation
import CryptoKit
import FSRS
import WCDBSwift
import ImpressReviewCore

public enum ReviewWCDBError: Swift.Error {
    case missingCard
    case suspendedCard
    case revisionConflict
    case contentConflict
    case eventIdentifierCollision
    case corruptRecord
    case invalidSchedulerOutput
    case duplicateCard
    case duplicateContent
}

/// Opaque FSRS result; the scheduler owns mathematics, WCDB owns durability.
public struct WCDBCalculatedReview: Sendable {
    public let snapshot: ReviewScheduleSnapshot
    public let status: ReviewCardStatus

    public init(snapshot: ReviewScheduleSnapshot, status: ReviewCardStatus) {
        self.snapshot = snapshot
        self.status = status
    }
}

/// The actual FSRS-6 adapter is supplied separately and pinned to a tested SHA.
public protocol WCDBReviewCalculating: Sendable {
    func next(before: ReviewScheduleSnapshot,
              status: ReviewCardStatus,
              submission: ReviewSubmission) throws -> WCDBCalculatedReview
}

/// WCDB does not load picture BLOBs to construct the review queue.
private struct WCDBV3CardRow: TableCodable {
    var cardID: String?
    var question: String?
    var answerText: String?
    var choices: String?
    var correctIndices: String?
    var cardType: Int?
    var imageData: Data?
    /// Small metadata only; movies always remain private Application Support files.
    var videoReferenceJSON: Data?
    var sourceNotePath: String?
    var createdAt: Date?
    var updatedAt: Date?
    var revision: Int?
    var contentRevision: Int?
    var isSuspended: Int?
    var state: Int?
    var dueAt: Date?
    var lastReviewedAt: Date?
    var schedulerPayload: Data?
    var schemaVersion: Int?

    enum CodingKeys: String, CodingTableKey {
        typealias Root = WCDBV3CardRow
        static let objectRelationalMapping = TableBinding(CodingKeys.self)
        case cardID = "card_id"
        case question
        case answerText = "answer_text"
        case choices
        case correctIndices = "correct_indices"
        case cardType = "card_type"
        case imageData = "image_data"
        case videoReferenceJSON = "video_reference"
        case sourceNotePath = "source_note_path"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case revision
        case contentRevision = "content_revision"
        case isSuspended = "is_suspended"
        case state
        case dueAt = "due_at"
        case lastReviewedAt = "last_reviewed_at"
        case schedulerPayload = "scheduler_payload"
        case schemaVersion = "schema_version"

        static var columnConstraintBindings: [CodingKeys: ColumnConstraintBinding]? {
            return [
                .cardID: ColumnConstraintBinding(isPrimary: true, isNotNull: true)
            ]
        }

        static var indexBindings: [IndexBinding.Subfix: IndexBinding]? {
            return [
                "_due": IndexBinding(indexesBy: dueAt),
                "_review_lookup": IndexBinding(indexesBy: isSuspended, state, dueAt)
            ]
        }
    }
}


private struct WCDBV3LegacyNoteRow: TableCodable {
    var legacyID: Int?
    var title: String?
    var markdown: String?
    var folder: String?
    var createdAt: Date?
    var modifiedAt: Date?

    enum CodingKeys: String, CodingTableKey {
        typealias Root = WCDBV3LegacyNoteRow
        static let objectRelationalMapping = TableBinding(CodingKeys.self)
        case legacyID = "legacy_id"
        case title, markdown, folder
        case createdAt = "created_at"
        case modifiedAt = "modified_at"
        static var columnConstraintBindings: [CodingKeys: ColumnConstraintBinding]? {
            [.legacyID: ColumnConstraintBinding(isPrimary: true, isNotNull: true)]
        }
    }
}

/// The original legacy scheduling numbers and card-to-note relation stay
/// inspectable even if current FSRS-6 needs a different canonical state.
private struct WCDBV3LegacyCardOriginRow: TableCodable {
    var legacyID: Int?
    var cardID: String?
    var metadataJSON: Data?
    enum CodingKeys: String, CodingTableKey {
        typealias Root = WCDBV3LegacyCardOriginRow
        static let objectRelationalMapping = TableBinding(CodingKeys.self)
        case legacyID = "legacy_id"
        case cardID = "card_id"
        case metadataJSON = "metadata_json"
        static var columnConstraintBindings: [CodingKeys: ColumnConstraintBinding]? {
            [.legacyID: ColumnConstraintBinding(isPrimary: true, isNotNull: true)]
        }
    }
}

/// A durable database marker, not UserDefaults: a user-requested older
/// backup restore replays the marker and imported rows together.
private struct WCDBV3LegacyMigrationRow: TableCodable {
    var sourceKey: String?
    var completedAt: Date?
    var cards: Int?
    var notes: Int?
    enum CodingKeys: String, CodingTableKey {
        typealias Root = WCDBV3LegacyMigrationRow
        static let objectRelationalMapping = TableBinding(CodingKeys.self)
        case sourceKey = "source_key"
        case completedAt = "completed_at"
        case cards, notes
        static var columnConstraintBindings: [CodingKeys: ColumnConstraintBinding]? {
            [.sourceKey: ColumnConstraintBinding(isPrimary: true, isNotNull: true)]
        }
    }
}

public struct WCDBV3RecoveredNote: Sendable {
    public let legacyID: Int
    public let title: String
    public let markdown: String
    public let folder: String?
    public let createdAt: Date?
}

/// Immutable content snapshots are separate from ReviewEvent/FSRS scheduling.
/// A stable (cardID, contentRevision) ID prevents duplicate history on retries.
private struct WCDBV3ContentVersionRow: TableCodable {
    var versionID: String?
    var cardID: String?
    var contentRevision: Int?
    var recordedAt: Date?
    var snapshot: Data?

    enum CodingKeys: String, CodingTableKey {
        typealias Root = WCDBV3ContentVersionRow
        static let objectRelationalMapping = TableBinding(CodingKeys.self)
        case versionID = "version_id"
        case cardID = "card_id"
        case contentRevision = "content_revision"
        case recordedAt = "recorded_at"
        case snapshot

        static var columnConstraintBindings: [CodingKeys: ColumnConstraintBinding]? {
            [.versionID: ColumnConstraintBinding(isPrimary: true, isNotNull: true)]
        }
        static var indexBindings: [IndexBinding.Subfix: IndexBinding]? {
            ["_by_card": IndexBinding(indexesBy: cardID, contentRevision)]
        }
    }
}

/// Auxiliary chat storage shares the existing encrypted-by-device-protection
/// backup boundary (ReviewV3.sqlite), not the flashcard or FSRS tables.
private struct WCDBV3ChatSessionRow: TableCodable {
    var sessionID: String?
    var sourceIdentity: String?
    var updatedAt: Date?
    var record: Data?

    enum CodingKeys: String, CodingTableKey {
        typealias Root = WCDBV3ChatSessionRow
        static let objectRelationalMapping = TableBinding(CodingKeys.self)
        case sessionID = "session_id"
        case sourceIdentity = "source_identity"
        case updatedAt = "updated_at"
        case record

        static var columnConstraintBindings: [CodingKeys: ColumnConstraintBinding]? {
            [.sessionID: ColumnConstraintBinding(isPrimary: true, isNotNull: true)]
        }
        static var indexBindings: [IndexBinding.Subfix: IndexBinding]? {
            ["_source": IndexBinding(indexesBy: sourceIdentity, updatedAt)]
        }
    }
}

private struct WCDBV3EventRow: TableCodable {
    var eventID: String?
    var cardID: String?
    var reviewedAt: Date?
    var eventPayload: Data?
    var schemaVersion: Int?

    enum CodingKeys: String, CodingTableKey {
        typealias Root = WCDBV3EventRow
        static let objectRelationalMapping = TableBinding(CodingKeys.self)
        case eventID = "event_id"
        case cardID = "card_id"
        case reviewedAt = "reviewed_at"
        case eventPayload = "event_payload"
        case schemaVersion = "schema_version"

        static var columnConstraintBindings: [CodingKeys: ColumnConstraintBinding]? {
            return [
                .eventID: ColumnConstraintBinding(isPrimary: true, isNotNull: true)
            ]
        }

        static var indexBindings: [IndexBinding.Subfix: IndexBinding]? {
            return ["_history": IndexBinding(indexesBy: cardID, reviewedAt)]
        }
    }
}

public struct WCDBV3CardInput: Sendable {
    public let cardID: UUID
    public let question: String
    public let answerText: String?
    public let choices: String?
    public let correctIndices: String?
    public let cardType: Int
    public let imageData: Data?
    public let sourceNotePath: String?

    public init(cardID: UUID = UUID(), question: String, answerText: String? = nil,
                choices: String? = nil, correctIndices: String? = nil,
                cardType: Int = 0, imageData: Data? = nil,
                sourceNotePath: String? = nil) {
        self.cardID = cardID
        self.question = question
        self.answerText = answerText
        self.choices = choices
        self.correctIndices = correctIndices
        self.cardType = cardType
        self.imageData = imageData
        self.sourceNotePath = sourceNotePath
    }
}

/// Lightweight, BLOB-free projection for the native V3 card collection.
public struct WCDBV3ManagedCard: Sendable {
    public let cardID: UUID
    public let question: String
    public let answerText: String?
    public let cardType: Int
    public let sourceNotePath: String?
    public let isSuspended: Bool
    public let revision: Int
    public let updatedAt: Date
}

/// Explicit media intent when editing an existing card; ordinary text edits
/// preserve its immutable video only when the cover and card type are unchanged.
public enum WCDBV3CardVideoMutation: Sendable {
    case automatic
    case remove
    case replace(ImpressCardVideoReference)
}

public struct WCDBV3CardContent: Sendable {
    public let cardID: UUID
    public let question: String
    public let answerText: String?
    public let choices: String?
    public let correctIndices: String?
    public let cardType: Int
    public let imageData: Data?
    public let videoReference: ImpressCardVideoReference?
    public let sourceNotePath: String?
    /// Independent of FSRS review revision. Incremented only by content edits.
    public let contentRevision: Int
}

/// The exact fields that were effective at a particular content revision.
/// Existing cards only gain history from the first version actually observed:
/// we NEVER synthesize the inaccessible revisions of an old installation.
public enum WCDBV3ContentVersionOrigin: String, Codable, Sendable {
    case manual, approvedAI, restored, observedBaseline
}

public struct WCDBV3ContentVersion: Codable, Equatable, Sendable {
    public let cardID: UUID
    public let contentRevision: Int
    public let recordedAt: Date
    public let origin: WCDBV3ContentVersionOrigin
    public let question: String
    public let answerText: String?
    public let choices: String?
    public let correctIndices: String?
    public let cardType: Int
    public let imageData: Data?
    public let videoReference: ImpressCardVideoReference?
    public let sourceNotePath: String?
}

/// Stable chat source identities are assembled only from verified cardIDs or
/// authorized Vault document IDs; a matching title is never an identity.
public enum WCDBV3ChatMessageRole: String, Codable, Sendable {
    case user, assistant
}
public enum WCDBV3ChatMessageStatus: String, Codable, Sendable {
    case pending, completed, failed, cancelled
}
/// Receipt of explicit image approval; not proof of remote model perception.
/// Never stores image bytes, local paths or provider authentication.
public struct WCDBV3ChatImageApproval: Codable, Equatable, Sendable {
    public let name: String
    public let jpegBytes: Int
    public init(name: String, jpegBytes: Int) {
        self.name = name
        self.jpegBytes = jpegBytes
    }
}

public struct WCDBV3ChatMessage: Codable, Equatable, Sendable {
    public let messageID: UUID
    public var role: WCDBV3ChatMessageRole
    public var text: String
    public var status: WCDBV3ChatMessageStatus
    public let createdAt: Date
    /// A snapshot of the actual request configuration, not a live global
    /// preference and NEVER an API Key or authorization token.
    public var providerID: UUID?
    public var modelIdentifier: String?
    public var promptSnapshot: String?
    /// Optional for legacy WCDB JSON. Only human-approved image metadata.
    /// Images are not auto-included in subsequent remote history windows.
    public var approvedImages: [WCDBV3ChatImageApproval]?

    public init(messageID: UUID = UUID(), role: WCDBV3ChatMessageRole,
                text: String, status: WCDBV3ChatMessageStatus,
                createdAt: Date = Date(),
                providerID: UUID? = nil, modelIdentifier: String? = nil,
                promptSnapshot: String? = nil,
                approvedImages: [WCDBV3ChatImageApproval]? = nil) {
        self.messageID = messageID
        self.role = role
        self.text = text
        self.status = status
        self.createdAt = createdAt
        self.providerID = providerID
        self.modelIdentifier = modelIdentifier
        self.promptSnapshot = promptSnapshot
        self.approvedImages = approvedImages
    }
}

public struct WCDBV3ChatContextReference: Codable, Equatable, Sendable {
    public let stableIdentity: String
    public let sourceRevision: String
    public let excerpt: String
    /// Present only for V1.1 structural selection; nil for old Chat JSON.
    /// These are original UTF-8 byte offsets, not UTF-16 or rendered indices.
    public let sourceStartUTF8: Int?
    public let sourceEndUTF8: Int?
    public let sourceFormat: String?
    /// Explicit node IDs chosen in a visual Canvas. Never inferred from
    /// filename, coordinates or any unselected node in the document.
    public let selectedCanvasNodeIDs: [String]?
    public init(stableIdentity: String, sourceRevision: String, excerpt: String,
                sourceStartUTF8: Int? = nil, sourceEndUTF8: Int? = nil,
                sourceFormat: String? = nil, selectedCanvasNodeIDs: [String]? = nil) {
        self.stableIdentity = stableIdentity
        self.sourceRevision = sourceRevision
        self.excerpt = excerpt
        self.sourceStartUTF8 = sourceStartUTF8
        self.sourceEndUTF8 = sourceEndUTF8
        self.sourceFormat = sourceFormat
        self.selectedCanvasNodeIDs = selectedCanvasNodeIDs
    }
}

public enum WCDBV3ProposalStatus: String, Codable, Sendable {
    case draft, awaitingConfirmation, applying, applied, conflict, failed, cancelled
}
public enum WCDBV3ProposalOperation: String, Codable, Sendable {
    case cardFieldUpdate, noteReplaceRange, noteCreate
}

/// Persistence does NOT grant write authority; the downstream guarded executor
/// must verify permissions, full preview, identity and expected revision again.
public struct WCDBV3EditProposal: Codable, Equatable, Sendable {
    public let proposalID: UUID
    public let idempotencyID: UUID
    public let targetIdentity: String
    public let expectedVersion: String
    public let operation: WCDBV3ProposalOperation
    public var preview: String
    public var status: WCDBV3ProposalStatus
    public var resultReceipt: String?
}

/// This record contains NO entire Vault Markdown. The exact source bytes and
/// edited private draft remain in ImVaultPrivateStore with separate protection.
/// The card fields, original content revision and independent receipts survive
/// process termination inside the existing WCDB-backed Chat session/backup.
public struct WCDBV3DuplexProposal: Codable, Equatable, Sendable {
    public let proposalID: UUID
    public let sourceMessageID: UUID?
    public let noteIdentity: ImVaultFileIdentity?
    public let noteBaseDigest: String?
    public let noteEditedDigest: String?
    public let cardID: UUID?
    public let cardReviewRevision: Int?
    public let cardContentRevision: Int?
    public let cardBaseQuestion: String?
    public let cardBaseAnswer: String?
    public let cardEditedQuestion: String?
    public let cardEditedAnswer: String?
    public var state: ImDuplexApprovalState
    public var noteReceipt: String?
    public var cardReceipt: String?
    public init(proposalID: UUID = UUID(), sourceMessageID: UUID?,
                noteIdentity: ImVaultFileIdentity?, noteBaseDigest: String?,
                noteEditedDigest: String?, cardID: UUID?, cardReviewRevision: Int?,
                cardContentRevision: Int?, cardBaseQuestion: String?,
                cardBaseAnswer: String?, cardEditedQuestion: String?,
                cardEditedAnswer: String?, state: ImDuplexApprovalState) {
        self.proposalID = proposalID
        self.sourceMessageID = sourceMessageID
        self.noteIdentity = noteIdentity
        self.noteBaseDigest = noteBaseDigest
        self.noteEditedDigest = noteEditedDigest
        self.cardID = cardID
        self.cardReviewRevision = cardReviewRevision
        self.cardContentRevision = cardContentRevision
        self.cardBaseQuestion = cardBaseQuestion
        self.cardBaseAnswer = cardBaseAnswer
        self.cardEditedQuestion = cardEditedQuestion
        self.cardEditedAnswer = cardEditedAnswer
        self.state = state
        self.noteReceipt = nil
        self.cardReceipt = nil
    }
}

public struct WCDBV3ChatSession: Codable, Equatable, Sendable {
    public let sessionID: UUID
    public let sourceIdentity: String
    /// Display-only local history hint, never a source authority.
    /// Optional to preserve existing serialized session rows.
    public var sourceDisplayName: String?
    public let createdAt: Date
    public var updatedAt: Date
    /// Optimistic locking token; increment once per durable edit.
    public var revision: Int
    public var messages: [WCDBV3ChatMessage]
    public var inputDraft: String
    public var contextReferences: [WCDBV3ChatContextReference]
    public var pendingProposal: WCDBV3EditProposal?
    /// Nil when decoding historic Chat rows. Does not automatically replay.
    public var pendingDuplex: WCDBV3DuplexProposal?
    /// Previously confirmed proposals and their independently verified
    /// receipts survive later edits. Optional for backwards-compatible reads.
    public var duplexHistory: [WCDBV3DuplexProposal]?
    public var requestError: String?
    /// Optional per-discussion prompt; legacy rows decode to nil.
    public var promptOverride: String?
    /// Per-session model even without a completed AI message; nil in old rows.
    public var selectedChatModelID: UUID?
    /// Nil on historical rows: conservatively re-confirm before sending source context.
    public var contextConsentGranted: Bool?
    /// Nil on legacy JSON. A deletion tombstone prevents a delayed request,
    /// draft save or backup replay from creating a new visible discussion.
    public var isDeleted: Bool?

    public init(sessionID: UUID = UUID(), sourceIdentity: String,
                createdAt: Date = Date()) {
        self.sessionID = sessionID
        self.sourceIdentity = sourceIdentity
        self.sourceDisplayName = nil
        self.createdAt = createdAt
        self.updatedAt = createdAt
        self.revision = 0
        self.messages = []
        self.inputDraft = ""
        self.contextReferences = []
        self.pendingProposal = nil
        self.pendingDuplex = nil
        self.duplexHistory = []
        self.requestError = nil
        self.promptOverride = nil
        self.selectedChatModelID = nil
        self.contextConsentGranted = false
        self.isDeleted = false
    }
}

public enum WCDBV3ChatStorageError: Swift.Error, Equatable {
    case conflict, invalidRecord, tooLarge, unsafeDeletion
}

/// An actor serializes the review transactions. The underlying WCDB connection
/// pool is thread-safe; every transaction is synchronous and has no await.
public actor ReviewWCDBRepository: ReviewRepository {
    private static let cardsTable = "impress_v3_memory_card"
    private static let eventsTable = "impress_v3_review_event"
    private static let contentVersionsTable = "impress_v3_content_version"
    private static let chatSessionsTable = "impress_v3_chat_session"
    private static let schema = 1
    private static let legacyNotesTable = "impress_v3_legacy_note"
    private static let legacyCardOriginsTable = "impress_v3_legacy_card_origin"
    private static let legacyMigrationTable = "impress_v3_legacy_migration"

    private let database: Database
    private let calculator: any WCDBReviewCalculating
    private let algorithmIdentifier: String

    /// Use an isolated V3 file, NOT the legacy impressdata.db.
    /// Schema creation failures are thrown, never swallowed.
    public init(databasePath: String, calculator: any WCDBReviewCalculating,
                algorithmIdentifier: String = "FSRS-6-default-v1") throws {
        let fileURL = URL(fileURLWithPath: databasePath)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        // A device already running V3 may have the pre-R04.2 card table
        // without content_revision. Upgrade that table in-place before WCDB
        // prepares ORM bindings; never discard the live database or events.
        try Self.migrateContentRevisionIfNeeded(at: databasePath)
        let db = Database(withPath: databasePath)
        try db.run(transaction: {
            try db.create(table: Self.cardsTable, of: WCDBV3CardRow.self)
            try db.create(table: Self.eventsTable, of: WCDBV3EventRow.self)
            try db.create(table: Self.contentVersionsTable, of: WCDBV3ContentVersionRow.self)
            try db.create(table: Self.chatSessionsTable, of: WCDBV3ChatSessionRow.self)
            try db.create(table: Self.legacyNotesTable, of: WCDBV3LegacyNoteRow.self)
            try db.create(table: Self.legacyCardOriginsTable, of: WCDBV3LegacyCardOriginRow.self)
            try db.create(table: Self.legacyMigrationTable, of: WCDBV3LegacyMigrationRow.self)
        })
        do {
            try Self.importLegacyIfPresent(on: db, path: databasePath)
        } catch {
            // A malformed legacy source must never make the current V3 store
            // inaccessible. The old file is untouched and migration can retry.
            UserDefaults.standard.set("旧版数据尚未全部恢复：" + error.localizedDescription,
                forKey: "ImpressLegacyRecoveryError")
        }
        database = db
        self.calculator = calculator
        self.algorithmIdentifier = algorithmIdentifier
    }


    /// Idempotent, transactionally adds the R04.2 content CAS column to the
    /// existing V3 table. A fresh install remains owned by WCDB's ORM create.
    /// SQLite ALTER TABLE retains all original rows, blobs, and FSRS events.
    private static func migrateContentRevisionIfNeeded(at path: String) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        var connection: OpaquePointer?
        let openResult = path.withCString {
            sqlite3_open_v2($0, &connection, SQLITE_OPEN_READWRITE, nil)
        }
        guard openResult == SQLITE_OK, let db = connection else {
            if let connection { sqlite3_close(connection) }
            throw ReviewWCDBError.corruptRecord
        }
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db,
            "PRAGMA table_info(impress_v3_memory_card);", -1,
            &statement, nil) == SQLITE_OK, let query = statement else {
            if let statement { sqlite3_finalize(statement) }
            throw ReviewWCDBError.corruptRecord
        }
        var hasTable = false
        var hasContentColumn = false
        var hasVideoColumn = false
        var result = sqlite3_step(query)
        while result == SQLITE_ROW {
            hasTable = true
            if let name = sqlite3_column_text(query, 1) {
                let key = String(cString: UnsafeRawPointer(name)
                    .assumingMemoryBound(to: CChar.self))
                hasContentColumn = hasContentColumn || key == "content_revision"
                hasVideoColumn = hasVideoColumn || key == "video_reference"
            }
            result = sqlite3_step(query)
        }
        sqlite3_finalize(query)
        guard result == SQLITE_DONE else { throw ReviewWCDBError.corruptRecord }
        guard hasTable && (!hasContentColumn || !hasVideoColumn) else { return }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE;", nil, nil, nil) == SQLITE_OK else {
            throw ReviewWCDBError.corruptRecord
        }
        do {
            // Existing V3 images and FSRS rows survive both additive migrations.
            if !hasContentColumn {
                guard sqlite3_exec(db,
                    "ALTER TABLE impress_v3_memory_card " +
                    "ADD COLUMN content_revision INTEGER NOT NULL DEFAULT 0;",
                    nil, nil, nil) == SQLITE_OK else { throw ReviewWCDBError.corruptRecord }
            }
            if !hasVideoColumn {
                guard sqlite3_exec(db,
                    "ALTER TABLE impress_v3_memory_card " +
                    "ADD COLUMN video_reference BLOB;",
                    nil, nil, nil) == SQLITE_OK else { throw ReviewWCDBError.corruptRecord }
            }
            guard sqlite3_exec(db, "COMMIT;", nil, nil, nil) == SQLITE_OK else {
                throw ReviewWCDBError.corruptRecord
            }
        } catch {
            _ = sqlite3_exec(db, "ROLLBACK;", nil, nil, nil)
            throw error
        }
    }


    private struct LegacyCard {
        var id: Int
        var noteID: Int?
        var question: String
        var answer: String?
        var cardType: Int
        var choices: String?
        var correctIndices: String?
        var imageData: Data?
        var createdAt: Date
        var lastReview: Date?
        var due: Date?
        var state: Int
        var difficulty: Double
        var stability: Double
        var reviewCount: Int
        var lapseCount: Int
        var relearningStep: Int
        var chatLink: String?
        var chatSessionID: Int?
    }

    private struct LegacyNote {
        var id: Int
        var title: String
        var markdown: String
        var folder: String?
        var createdAt: Date?
        var modifiedAt: Date?
    }

    private struct LegacyScheduleMetadata: Codable {
        let sourceID: Int
        let sourceNoteID: Int?
        let oldState: Int
        let oldDue: Date?
        let oldLastReview: Date?
        let difficulty: Double
        let stability: Double
        let reviewCount: Int
        let lapseCount: Int
        let relearningStep: Int
        let chatLink: String?
        let chatSessionID: Int?
    }

    /// This reader never opens the old WCDB handle with CREATE or READWRITE.
    /// WCDB's Date columns in the old database are seconds since Unix epoch.
    private struct LegacyColumns {
        let statement: OpaquePointer
        let fields: [String: Int32]
        init(_ statement: OpaquePointer) {
            self.statement = statement
            var fields: [String: Int32] = [:]
            for index in 0..<sqlite3_column_count(statement) {
                if let column = sqlite3_column_name(statement, index) {
                    fields[String(cString: column).lowercased()] = index
                }
            }
            self.fields = fields
        }
        private func index(_ key: String) -> Int32? {
            guard let value = fields[key.lowercased()],
                  sqlite3_column_type(statement, value) != SQLITE_NULL else { return nil }
            return value
        }
        func integer(_ name: String) -> Int? {
            guard let at = index(name) else { return nil }
            return Int(sqlite3_column_int64(statement, at))
        }
        func real(_ name: String) -> Double? {
            guard let at = index(name) else { return nil }
            let value = sqlite3_column_double(statement, at)
            return value.isFinite ? value : nil
        }
        func date(_ name: String) -> Date? {
            guard let value = real(name) else { return nil }
            return Date(timeIntervalSince1970: value)
        }
        func text(_ name: String) -> String? {
            guard let at = index(name),
                  let bytes = sqlite3_column_text(statement, at) else { return nil }
            return String(cString: UnsafeRawPointer(bytes)
                .assumingMemoryBound(to: CChar.self))
        }
        func blob(_ name: String) -> Data? {
            guard let at = index(name) else { return nil }
            let length = Int(sqlite3_column_bytes(statement, at))
            guard length > 0, let ptr = sqlite3_column_blob(statement, at) else { return nil }
            return Data(bytes: ptr, count: length)
        }
    }

    private static func readLegacyRows<T>(
        connection: OpaquePointer, table: String,
        make: (LegacyColumns) throws -> T) throws -> [T] {
        // Table names come only from the two fixed legacy schema contracts.
        guard table == "impress_card" || table == "impress_notes" else {
            throw ReviewWCDBError.corruptRecord
        }
        var exists: OpaquePointer?
        let lookup = "SELECT name FROM sqlite_master WHERE type='table' AND name='" +
            table + "' LIMIT 1;"
        guard sqlite3_prepare_v2(connection, lookup, -1, &exists, nil) == SQLITE_OK,
              let probe = exists else {
            if let exists { sqlite3_finalize(exists) }
            throw ReviewWCDBError.corruptRecord
        }
        let tableStatus = sqlite3_step(probe)
        sqlite3_finalize(probe)
        if tableStatus == SQLITE_DONE { return [] }
        guard tableStatus == SQLITE_ROW else { throw ReviewWCDBError.corruptRecord }

        var statement: OpaquePointer?
        let sql = "SELECT * FROM " + table + " ORDER BY id;"
        guard sqlite3_prepare_v2(connection, sql, -1, &statement, nil) == SQLITE_OK,
              let query = statement else {
            if let statement { sqlite3_finalize(statement) }
            throw ReviewWCDBError.corruptRecord
        }
        defer { sqlite3_finalize(query) }
        let columns = LegacyColumns(query)
        var rows: [T] = []
        var status = sqlite3_step(query)
        while status == SQLITE_ROW {
            guard rows.count < 500_000 else { throw ReviewWCDBError.corruptRecord }
            rows.append(try make(columns))
            status = sqlite3_step(query)
        }
        guard status == SQLITE_DONE else { throw ReviewWCDBError.corruptRecord }
        return rows
    }

    private static func readLegacyDatabase(at url: URL) throws
        -> (cards: [LegacyCard], notes: [LegacyNote]) {
        var connection: OpaquePointer?
        let opened = url.path.withCString {
            sqlite3_open_v2($0, &connection, SQLITE_OPEN_READONLY, nil)
        }
        guard opened == SQLITE_OK, let db = connection else {
            if let connection { sqlite3_close(connection) }
            throw ReviewWCDBError.corruptRecord
        }
        defer { sqlite3_close(db) }
        let cards = try readLegacyRows(connection: db, table: "impress_card") { row in
            guard let id = row.integer("id"), id > 0,
                  let question = row.text("question"), !question.trimmingCharacters(
                    in: .whitespacesAndNewlines).isEmpty,
                  [0, 2, 3].contains(row.integer("card_type") ?? 0) else {
                throw ReviewWCDBError.corruptRecord
            }
            return LegacyCard(id: id, noteID: row.integer("note_id"),
                question: question, answer: row.text("answer"),
                cardType: row.integer("card_type") ?? 0,
                choices: row.text("choices"),
                correctIndices: row.text("correct_answer_indices"),
                imageData: row.blob("image_data"),
                createdAt: row.date("create_time") ?? Date(),
                lastReview: row.date("last_review_date"),
                due: row.date("due_date"), state: row.integer("state") ?? 0,
                difficulty: row.real("difficulty") ?? 0,
                stability: row.real("stability") ?? 0,
                reviewCount: row.integer("review_count") ?? 0,
                lapseCount: row.integer("lapse_count") ?? 0,
                relearningStep: row.integer("relearning_step") ?? 0,
                chatLink: row.text("chat_link"),
                chatSessionID: row.integer("chat_session_id"))
        }
        let notes = try readLegacyRows(connection: db, table: "impress_notes") { row in
            guard let id = row.integer("id"), id > 0 else {
                throw ReviewWCDBError.corruptRecord
            }
            return LegacyNote(id: id,
                title: row.text("mainTitle") ?? "旧版笔记 #\(id)",
                markdown: row.text("markdownText") ?? "",
                folder: row.text("directory_path"),
                createdAt: row.date("createTime"),
                modifiedAt: row.date("modify_date"))
        }
        return (cards, notes)
    }

    private static func stableLegacyUUID(_ legacyID: Int) -> UUID {
        var bytes = Array(SHA256.hash(data:
            Data("Impress-legacy-card:impressdata.db:\(legacyID)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    /// All source reads finish before one destination transaction begins.
    /// A failure never half-imports a card collection or a notes collection.
    private static func importLegacyIfPresent(on db: Database, path: String) throws {
        let documents = FileManager.default.urls(
            for: .documentDirectory, in: .userDomainMask)[0]
        let expected = documents.appendingPathComponent("ImpressV3/ReviewV3.sqlite")
        guard URL(fileURLWithPath: path).standardizedFileURL ==
                expected.standardizedFileURL else { return } // DEBUG fixtures
        let legacy = documents.appendingPathComponent("ImpressDB/impressdata.db")
        guard FileManager.default.fileExists(atPath: legacy.path) else { return }
        let sourceKey = "impressdata.db/v1"
        let marker: WCDBV3LegacyMigrationRow? = try db.getObject(
            fromTable: legacyMigrationTable,
            where: WCDBV3LegacyMigrationRow.Properties.sourceKey == sourceKey)
        if marker != nil { return }
        let original = try readLegacyDatabase(at: legacy)
        let now = Date()
        let transaction = try db.getTransaction()
        try transaction.run(transaction: {
            for originalCard in original.cards {
                let cardID = stableLegacyUUID(originalCard.id)
                let cardKey = cardID.uuidString
                let duplicate: WCDBV3CardRow? = try transaction.getObject(
                    fromTable: cardsTable,
                    where: WCDBV3CardRow.Properties.cardID == cardKey)
                let priorOrigin: WCDBV3LegacyCardOriginRow? = try transaction.getObject(
                    fromTable: legacyCardOriginsTable,
                    where: WCDBV3LegacyCardOriginRow.Properties.legacyID ==
                        originalCard.id)
                if priorOrigin != nil { continue }
                if duplicate != nil {
                    // UUID collisions are extraordinarily unlikely but must
                    // never silently drop a legacy record or overwrite a V3 card.
                    throw ReviewWCDBError.duplicateCard
                }
                let oldCode = originalCard.state
                let candidateState = [1, 2, 3].contains(oldCode) ? oldCode : 0
                // A pre-FSRS6 row with incomplete stability/difficulty cannot
                // safely be continued as a review card. It remains recoverable
                // as a new card with full legacy metrics held in provenance.
                let stateCode = candidateState == 2 &&
                    (originalCard.stability <= 0 || originalCard.difficulty <= 0)
                    ? 0 : candidateState
                let lastReview = stateCode == 0 ? nil : originalCard.lastReview
                let fsrs = Card(
                    due: originalCard.due ?? now,
                    stability: max(0, originalCard.stability),
                    difficulty: max(0, originalCard.difficulty),
                    elapsedDays: max(0, lastReview.map {
                        now.timeIntervalSince($0) / 86_400
                    } ?? 0),
                    scheduledDays: max(0, lastReview.map {
                        (originalCard.due ?? now).timeIntervalSince($0) / 86_400
                    } ?? 0),
                    learningSteps: max(0, originalCard.relearningStep),
                    reps: max(0, originalCard.reviewCount),
                    lapses: max(0, originalCard.lapseCount),
                    state: stateCode == 1 ? .learning :
                           (stateCode == 2 ? .review :
                            (stateCode == 3 ? .relearning : .new)),
                    lastReview: lastReview)
                var card = WCDBV3CardRow()
                card.cardID = cardKey
                card.question = originalCard.question
                card.answerText = originalCard.answer
                card.choices = originalCard.choices
                card.correctIndices = originalCard.correctIndices
                card.cardType = originalCard.cardType
                card.imageData = originalCard.imageData
                card.sourceNotePath = originalCard.noteID.map {
                    "legacy-note:" + String($0)
                }
                card.createdAt = originalCard.createdAt
                card.updatedAt = now
                card.revision = 0
                card.contentRevision = 0
                card.isSuspended = originalCard.state == 4 ? 1 : 0
                card.state = fsrs.state.rawValue
                card.dueAt = fsrs.due
                card.lastReviewedAt = fsrs.lastReview
                card.schedulerPayload = try JSONEncoder().encode(fsrs)
                card.schemaVersion = schema
                try transaction.insert(objects: [card], intoTable: cardsTable)
                let version = try makeContentVersionRow(card,
                    origin: .restored, recordedAt: now)
                try transaction.insert(objects: [version],
                    intoTable: contentVersionsTable)
                let metadata = LegacyScheduleMetadata(
                    sourceID: originalCard.id, sourceNoteID: originalCard.noteID,
                    oldState: originalCard.state, oldDue: originalCard.due,
                    oldLastReview: originalCard.lastReview,
                    difficulty: originalCard.difficulty,
                    stability: originalCard.stability,
                    reviewCount: originalCard.reviewCount,
                    lapseCount: originalCard.lapseCount,
                    relearningStep: originalCard.relearningStep,
                    chatLink: originalCard.chatLink,
                    chatSessionID: originalCard.chatSessionID)
                var provenance = WCDBV3LegacyCardOriginRow()
                provenance.legacyID = originalCard.id
                provenance.cardID = cardKey
                provenance.metadataJSON = try JSONEncoder().encode(metadata)
                try transaction.insert(objects: [provenance],
                    intoTable: legacyCardOriginsTable)
            }
            for old in original.notes {
                let duplicate: WCDBV3LegacyNoteRow? = try transaction.getObject(
                    fromTable: legacyNotesTable,
                    where: WCDBV3LegacyNoteRow.Properties.legacyID == old.id)
                if duplicate != nil { continue }
                var note = WCDBV3LegacyNoteRow()
                note.legacyID = old.id
                note.title = old.title
                note.markdown = old.markdown
                note.folder = old.folder
                note.createdAt = old.createdAt
                note.modifiedAt = old.modifiedAt
                try transaction.insert(objects: [note], intoTable: legacyNotesTable)
            }
            var completion = WCDBV3LegacyMigrationRow()
            completion.sourceKey = sourceKey
            completion.completedAt = now
            completion.cards = original.cards.count
            completion.notes = original.notes.count
            try transaction.insert(objects: [completion],
                intoTable: legacyMigrationTable)
        })
        // Only the verified committed V3 snapshot enters iCloud backup.
        if !original.cards.isEmpty || !original.notes.isEmpty {
            ImpressV3BackupCoordinator.markDataChanged()
        }
        UserDefaults.standard.removeObject(forKey: "ImpressLegacyRecoveryError")
    }

    /// Read-only, local presentation of original WCDB notes. Obsidian is never
    /// modified or treated as the owner of notes imported from another store.
    public func recoveredLegacyNotes() throws -> [WCDBV3RecoveredNote] {
        let rows: [WCDBV3LegacyNoteRow] = try database.getObjects(
            fromTable: Self.legacyNotesTable,
            orderBy: [WCDBV3LegacyNoteRow.Properties.legacyID.asOrder(by: .ascending)])
        return try rows.map { row in
            guard let id = row.legacyID, let title = row.title,
                  let markdown = row.markdown else { throw ReviewWCDBError.corruptRecord }
            return WCDBV3RecoveredNote(legacyID: id, title: title,
                markdown: markdown, folder: row.folder, createdAt: row.createdAt)
        }
    }

    #if DEBUG
    /// Creates a disposable legacy V3 fixture with the application's existing
    /// SQLCipher-compatible SQLite import. Never called during normal startup.
    static func seedPreR042FixtureForTesting(at path: String, cardID: UUID) throws {
        // SQLite OPEN_CREATE creates a file, not its enclosing directory.
        // This fixture is an isolated pre-R04.2 V3 database, never user data.
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        var pointer: OpaquePointer?
        let result = path.withCString {
            sqlite3_open_v2($0, &pointer,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        }
        guard result == SQLITE_OK, let db = pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw ReviewWCDBError.corruptRecord
        }
        defer { sqlite3_close(db) }
        func execute(_ sql: String) throws {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw ReviewWCDBError.corruptRecord
            }
        }
        try execute("""
            CREATE TABLE impress_v3_memory_card (
                card_id TEXT PRIMARY KEY, question TEXT, answer_text TEXT,
                choices TEXT, correct_indices TEXT, card_type INTEGER,
                image_data BLOB, source_note_path TEXT, created_at REAL,
                updated_at REAL, revision INTEGER, is_suspended INTEGER,
                state INTEGER, due_at REAL, last_reviewed_at REAL,
                scheduler_payload BLOB, schema_version INTEGER
            );
            """)
        try execute("""
            CREATE TABLE impress_v3_review_event (
                event_id TEXT PRIMARY KEY, card_id TEXT, reviewed_at REAL,
                event_payload BLOB, schema_version INTEGER
            );
            """)
        try execute("""
            INSERT INTO impress_v3_memory_card
                (card_id, question, answer_text, card_type, revision,
                 is_suspended, state, due_at, created_at, updated_at,
                 scheduler_payload, schema_version)
            VALUES ('\(cardID.uuidString)', 'Original saved V3',
                    'Do not discard', 0, 0, 0, 0, 1720000000,
                    1720000000, 1720000000, X'0102', 1);
            """)
    }
    #endif

    /// Creates a new card with a full, explicitly encoded FSRS-6 initial state.
    public func insertNewCard(_ input: WCDBV3CardInput,
                              initial: ReviewScheduleSnapshot,
                              now: Date,
                              videoReference: ImpressCardVideoReference? = nil) throws {
        let row = try Self.makeNewCardRow(input, initial: initial, now: now,
                                          videoReference: videoReference)
        let tx = try database.getTransaction()
        try tx.run(transaction: {
            try tx.insert(objects: [row], intoTable: Self.cardsTable)
            let version = try Self.makeContentVersionRow(
                row, origin: .manual, recordedAt: now)
            try tx.insert(objects: [version], intoTable: Self.contentVersionsTable)
        })
        ImpressV3BackupCoordinator.markDataChanged()
    }

    /// Save a local export through a SINGLE owner for both card collection
    /// and the revealed-card editor. A staged movie is never a WCDB BLOB.
    /// Installation precedes the content CAS, and readback follows it.
    public func commitCardVideo(_ input: WCDBV3CardInput,
                                staged: ImpressCardVideoAVFoundationExporter.Staged,
                                expectedReviewRevision: Int? = nil,
                                expectedContentRevision: Int? = nil) async throws {
        let reference = staged.reference
        guard reference.cardID == input.cardID,
              input.cardType == 3, input.imageData != nil else {
            throw ReviewWCDBError.contentConflict
        }
        try await Task.detached(priority: .userInitiated) {
            let store = try ImpressCardVideoPrivateStore.applicationSupportStore()
            _ = try store.install(staged, cardID: input.cardID,
                                  expectedContentRevision: reference.contentRevision)
        }.value
        do {
            if let expectedReviewRevision, let expectedContentRevision {
                guard expectedContentRevision >= 0,
                      expectedContentRevision < Int.max,
                      reference.contentRevision == expectedContentRevision + 1 else {
                    throw ReviewWCDBError.contentConflict
                }
                try updateManagedCard(input, expectedRevision: expectedReviewRevision,
                                      expectedContentRevision: expectedContentRevision,
                                      videoMutation: .replace(reference))
            } else {
                guard expectedReviewRevision == nil, expectedContentRevision == nil,
                      reference.contentRevision == 0 else {
                    throw ReviewWCDBError.contentConflict
                }
                let now = Date()
                let initial = try FSRS6ReviewCalculator().newCardSnapshot(
                    id: input.cardID, now: now)
                try insertNewCard(input, initial: initial, now: now,
                                  videoReference: reference)
            }
            guard try videoReference(for: input.cardID,
                                     contentRevision: reference.contentRevision) == reference else {
                throw ReviewWCDBError.corruptRecord
            }
        } catch {
            // A CAS failure cannot remove a winner's movie or historical media.
            // If this actor cannot audit references safely, retain the files.
            if let retained = try? retainedMediaIDs(),
               !retained.contains(reference.mediaID) {
                try? await Task.detached(priority: .utility) {
                    let store = try ImpressCardVideoPrivateStore.applicationSupportStore()
                    try store.removeAfterReferenceAudit(reference,
                        stillReferencedMediaIDs: retained)
                }.value
            }
            throw error
        }
    }

    /// One WCDB transaction for the entire reviewed batch. A collision or any
    /// failed insertion rolls back even rows inserted earlier in this loop.
    /// The actor serializes this against review events and ordinary card inserts.
    public func insertBatchCards(
        _ entries: [(input: WCDBV3CardInput, initial: ReviewScheduleSnapshot)],
        now: Date
    ) throws -> Int {
        guard !entries.isEmpty, entries.count <= 500 else {
            throw ReviewWCDBError.invalidSchedulerOutput
        }
        let rows = try entries.map {
            try Self.makeNewCardRow($0.input, initial: $0.initial, now: now)
        }
        var ids = Set<String>()
        var content = Set<String>()
        for row in rows {
            guard let id = row.cardID, ids.insert(id).inserted else {
                throw ReviewWCDBError.duplicateCard
            }
            guard content.insert(Self.duplicateKey(row)).inserted else {
                throw ReviewWCDBError.duplicateContent
            }
        }
        let transaction = try database.getTransaction()
        try transaction.run(transaction: {
            // Look up old content *inside* the transaction, never from a
            // possibly stale earlier preview. Never mutate user cards.
            let prior: [WCDBV3CardRow] = try transaction.getObjects(
                on: [WCDBV3CardRow.Properties.question,
                     WCDBV3CardRow.Properties.sourceNotePath],
                fromTable: Self.cardsTable
            )
            let existingContent = Set(prior.map(Self.duplicateKey))
            for row in rows {
                guard !existingContent.contains(Self.duplicateKey(row)) else {
                    throw ReviewWCDBError.duplicateContent
                }
                let priorID: WCDBV3CardRow? = try transaction.getObject(
                    fromTable: Self.cardsTable,
                    where: WCDBV3CardRow.Properties.cardID == row.cardID!
                )
                guard priorID == nil else { throw ReviewWCDBError.duplicateCard }
                try transaction.insert(objects: [row], intoTable: Self.cardsTable)
                let version = try Self.makeContentVersionRow(
                    row, origin: .manual, recordedAt: now)
                try transaction.insert(objects: [version], intoTable: Self.contentVersionsTable)
            }
        })
        ImpressV3BackupCoordinator.markDataChanged()
        return rows.count
    }

    private static func duplicateKey(_ row: WCDBV3CardRow) -> String {
        let question = (row.question ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        return (row.sourceNotePath ?? "") + "\u{001F}" + question
    }

    private static func makeNewCardRow(_ input: WCDBV3CardInput,
                                       initial: ReviewScheduleSnapshot,
                                       now: Date,
                                       videoReference: ImpressCardVideoReference? = nil) throws -> WCDBV3CardRow {
        guard !input.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              initial.cardID == input.cardID,
              initial.revision == 0,
              initial.lastReviewedAt == nil,
              !initial.schedulerPayload.isEmpty,
              initial.dueAt.timeIntervalSince1970.isFinite,
              [0, 2, 3].contains(input.cardType),
              (input.cardType != 0 || !(input.answerText ?? "").isEmpty),
              (input.cardType != 2 || (!(input.choices ?? "").isEmpty && !(input.correctIndices ?? "").isEmpty)),
              (input.cardType != 3 || input.imageData != nil) else {
            throw ReviewWCDBError.invalidSchedulerOutput
        }
        var row = WCDBV3CardRow()
        row.cardID = input.cardID.uuidString
        row.question = input.question
        row.answerText = input.answerText
        row.choices = input.choices
        row.correctIndices = input.correctIndices
        row.cardType = input.cardType
        row.imageData = input.imageData
        row.videoReferenceJSON = try Self.encodeCardVideo(videoReference,
            cardID: input.cardID, revision: 0)
        row.sourceNotePath = input.sourceNotePath
        row.createdAt = now
        row.updatedAt = now
        row.revision = 0
        row.contentRevision = 0
        row.isSuspended = 0
        row.state = ReviewCardStatus.new.rawValue
        row.dueAt = initial.dueAt
        row.schedulerPayload = initial.schedulerPayload
        row.schemaVersion = Self.schema
        return row
    }

    /// SQL-backed, BLOB-free sorted pagination for normal queries.
    /// Literal SQL LIKE wildcards use a bounded fallback scan so searching for
    /// "%" or "_" cannot broaden matches and never allocates the entire table.
    public func listManagedCards(matching search: String = "",
                                 offset: Int = 0,
                                 limit: Int = 100) throws -> [WCDBV3ManagedCard] {
        guard offset >= 0, (1...200).contains(limit) else {
            throw ReviewWCDBError.invalidSchedulerOutput
        }
        let selected = [
            WCDBV3CardRow.Properties.cardID,
            WCDBV3CardRow.Properties.question,
            WCDBV3CardRow.Properties.answerText,
            WCDBV3CardRow.Properties.cardType,
            WCDBV3CardRow.Properties.sourceNotePath,
            WCDBV3CardRow.Properties.isSuspended,
            WCDBV3CardRow.Properties.revision,
            WCDBV3CardRow.Properties.updatedAt
        ]
        // The secondary key makes pagination deterministic for equal timestamps.
        let ordering = [
            WCDBV3CardRow.Properties.updatedAt.asOrder(by: .descending),
            WCDBV3CardRow.Properties.cardID.asOrder(by: .ascending)
        ]
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows: [WCDBV3CardRow]
        if query.isEmpty {
            rows = try database.getObjects(on: selected, fromTable: Self.cardsTable,
                orderBy: ordering, limit: limit, offset: offset)
        } else if !query.contains("%") && !query.contains("_") {
            // WCDB escapes SQL parameters: never interpolate into raw SQL.
            // Common searches use SQLite filtering *before* LIMIT/OFFSET.
            let pattern = "%" + query + "%"
            let matching = WCDBV3CardRow.Properties.question.like(pattern)
                || WCDBV3CardRow.Properties.answerText.like(pattern)
                || WCDBV3CardRow.Properties.sourceNotePath.like(pattern)
            rows = try database.getObjects(on: selected, fromTable: Self.cardsTable,
                where: matching, orderBy: ordering, limit: limit, offset: offset)
        } else {
            // SQLite LIKE treats _ and % as wildcards. Use bounded chunks
            // and a literal comparison to avoid false-positive search results.
            var collected = [WCDBV3CardRow]()
            var scanned = 0
            var matched = 0
            while collected.count < limit {
                let block: [WCDBV3CardRow] = try database.getObjects(
                    on: selected, fromTable: Self.cardsTable, orderBy: ordering,
                    limit: 200, offset: scanned)
                if block.isEmpty { break }
                for row in block where [row.question, row.answerText, row.sourceNotePath]
                    .compactMap({ $0 }).contains(where: { $0.localizedStandardContains(query) }) {
                    if matched >= offset && collected.count < limit {
                        collected.append(row)
                    }
                    matched += 1
                }
                scanned += block.count
            }
            rows = collected
        }
        return try rows.map { row in
            guard let rawID = row.cardID, let id = UUID(uuidString: rawID),
                  let question = row.question, let type = row.cardType,
                  let suspended = row.isSuspended, let revision = row.revision else {
                throw ReviewWCDBError.corruptRecord
            }
            return WCDBV3ManagedCard(cardID: id, question: question,
                answerText: row.answerText, cardType: type,
                sourceNotePath: row.sourceNotePath,
                isSuspended: suspended != 0, revision: revision,
                updatedAt: row.updatedAt ?? .distantPast)
        }
    }

    /// Exact Vault ID + full relative path. An unrelated or same-title file
    /// cannot enter this result; legacy path-only cards are deliberately excluded.
    /// Searches are literal, not SQL LIKE patterns, and do not touch FSRS.
    public func listRelatedCards(for source: ImVaultFileIdentity,
                                 matching search: String = "",
                                 offset: Int = 0, limit: Int = 100) throws -> [WCDBV3ManagedCard] {
        guard offset >= 0, (1...200).contains(limit) else {
            throw ReviewWCDBError.invalidSchedulerOutput
        }
        // Historic v1 keys were serialized by JSONEncoder without sortedKeys,
        // so identical (vaultID, relativePath) can have different base64 bytes.
        // Never compare an encoded key to a freshly re-encoded identity in SQL.
        // Prefilter only the key family; ALWAYS decode and compare full identity
        // before returning a card. This supports legacy v1 and versioned v2,
        // including old keys with either JSON property order.
        let selected = [
            WCDBV3CardRow.Properties.cardID,
            WCDBV3CardRow.Properties.question,
            WCDBV3CardRow.Properties.answerText,
            WCDBV3CardRow.Properties.cardType,
            WCDBV3CardRow.Properties.sourceNotePath,
            WCDBV3CardRow.Properties.isSuspended,
            WCDBV3CardRow.Properties.revision,
            WCDBV3CardRow.Properties.updatedAt
        ]
        let ordering = [
            WCDBV3CardRow.Properties.updatedAt.asOrder(by: .descending),
            WCDBV3CardRow.Properties.cardID.asOrder(by: .ascending)
        ]
        let sourceFilter = WCDBV3CardRow.Properties.sourceNotePath.like("obsidian+v%")
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        var rows: [WCDBV3CardRow] = []
        var scanned = 0
        var skipped = 0
        while rows.count < limit {
            let block: [WCDBV3CardRow] = try database.getObjects(
                on: selected, fromTable: Self.cardsTable, where: sourceFilter,
                orderBy: ordering, limit: 200, offset: scanned)
            guard !block.isEmpty else { break }
            scanned += block.count
            for row in block {
                guard let key = row.sourceNotePath,
                      let decoded = try? ImpressBatchSourceKey.decode(key),
                      decoded == source else { continue }
                let matches = query.isEmpty || [row.question, row.answerText]
                    .compactMap({ $0 }).contains(where: { $0.localizedStandardContains(query) })
                guard matches else { continue }
                if skipped < offset { skipped += 1 }
                else if rows.count < limit { rows.append(row) }
            }
            if block.count < 200 { break }
        }
        return try rows.map { row in
            guard let rawID = row.cardID, let id = UUID(uuidString: rawID),
                  let question = row.question, let type = row.cardType,
                  let suspended = row.isSuspended, let revision = row.revision else {
                throw ReviewWCDBError.corruptRecord
            }
            return WCDBV3ManagedCard(cardID: id, question: question,
                answerText: row.answerText, cardType: type,
                sourceNotePath: row.sourceNotePath,
                isSuspended: suspended != 0, revision: revision,
                updatedAt: row.updatedAt ?? .distantPast)
        }
    }

    /// Update only content fields. Card identity, FSRS revision/schedule and
    /// immutable review events remain intact. Two independent CAS tokens stop
    /// a stale editor after either an FSRS commit or another content edit.
    public func updateManagedCard(_ input: WCDBV3CardInput,
                                  expectedRevision: Int,
                                  expectedContentRevision: Int,
                                  now: Date = Date(),
                                  origin: WCDBV3ContentVersionOrigin = .manual,
                                  videoMutation: WCDBV3CardVideoMutation = .automatic) throws {
        // Content CAS and FSRS revisions must have a representable successor.
        // A forged/corrupt Int.max token must not overflow in the transaction,
        // and a negative token can never acknowledge a valid old row.
        guard expectedRevision >= 0, expectedRevision < Int.max else {
            throw ReviewWCDBError.revisionConflict
        }
        guard expectedContentRevision >= 0, expectedContentRevision < Int.max else {
            throw ReviewWCDBError.contentConflict
        }
        guard !input.question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              [0, 2, 3].contains(input.cardType),
              (input.cardType != 0 || !(input.answerText ?? "").isEmpty),
              (input.cardType != 2 ||
                 (!(input.choices ?? "").isEmpty &&
                  !(input.correctIndices ?? "").isEmpty)),
              (input.cardType != 3 || input.imageData != nil) else {
            throw ReviewWCDBError.invalidSchedulerOutput
        }
        let key = input.cardID.uuidString
        let tx = try database.getTransaction()
        var didChange = false
        try tx.run(transaction: {
            guard let old: WCDBV3CardRow = try tx.getObject(
                fromTable: Self.cardsTable,
                where: WCDBV3CardRow.Properties.cardID == key)
            else { throw ReviewWCDBError.missingCard }
            guard old.revision == expectedRevision else {
                throw ReviewWCDBError.revisionConflict
            }
            guard (old.contentRevision ?? 0) == expectedContentRevision else {
                throw ReviewWCDBError.contentConflict
            }
            let priorVideo = try Self.decodeCardVideo(old.videoReferenceJSON,
                cardID: input.cardID, revision: expectedContentRevision)
            let nextRevision = expectedContentRevision + 1
            let revisedVideo: ImpressCardVideoReference?
            switch videoMutation {
            case .automatic:
                // Changing only text keeps the immutable video. A replacement
                // cover or switch away from image explicitly clears it.
                revisedVideo = input.cardType == 3 && old.imageData == input.imageData
                    ? try priorVideo?.rebound(to: nextRevision) : nil
            case .remove:
                revisedVideo = nil
            case .replace(let next):
                guard input.cardType == 3, input.imageData != nil,
                      next.belongs(to: input.cardID, revision: nextRevision) else {
                    throw ReviewWCDBError.contentConflict
                }
                revisedVideo = next
            }
            // A no-op must never allocate a new content version or dirty ZIP.
            guard !Self.sameContent(old, input) ||
                  priorVideo?.mediaID != revisedVideo?.mediaID else { return }
            let all: [WCDBV3CardRow] = try tx.getObjects(
                on: [WCDBV3CardRow.Properties.cardID,
                     WCDBV3CardRow.Properties.question,
                     WCDBV3CardRow.Properties.sourceNotePath],
                fromTable: Self.cardsTable)
            var edited = old
            edited.question = input.question
            edited.answerText = input.answerText
            edited.choices = input.choices
            edited.correctIndices = input.correctIndices
            edited.cardType = input.cardType
            edited.imageData = input.imageData
            edited.videoReferenceJSON = try Self.encodeCardVideo(revisedVideo,
                cardID: input.cardID, revision: nextRevision)
            edited.sourceNotePath = input.sourceNotePath
            edited.updatedAt = now
            edited.contentRevision = nextRevision
            guard !all.contains(where: {
                $0.cardID != key && Self.duplicateKey($0) == Self.duplicateKey(edited)
            }) else { throw ReviewWCDBError.duplicateContent }
            // Pre-upgrade cards did not have recorded history. Snapshot the
            // currently observed content (never invent revisions -1, -2...).
            let existing: WCDBV3ContentVersionRow? = try tx.getObject(
                fromTable: Self.contentVersionsTable,
                where: WCDBV3ContentVersionRow.Properties.versionID ==
                    Self.contentVersionID(cardID: key, revision: expectedContentRevision))
            if existing == nil {
                try tx.insert(objects: [Self.makeContentVersionRow(
                    old, origin: .observedBaseline, recordedAt: now)],
                    intoTable: Self.contentVersionsTable)
            }
            try tx.update(table: Self.cardsTable, on: [
                WCDBV3CardRow.Properties.question,
                WCDBV3CardRow.Properties.answerText,
                WCDBV3CardRow.Properties.choices,
                WCDBV3CardRow.Properties.correctIndices,
                WCDBV3CardRow.Properties.cardType,
                WCDBV3CardRow.Properties.imageData,
                WCDBV3CardRow.Properties.videoReferenceJSON,
                WCDBV3CardRow.Properties.sourceNotePath,
                WCDBV3CardRow.Properties.updatedAt,
                WCDBV3CardRow.Properties.contentRevision
            ], with: edited,
               where: WCDBV3CardRow.Properties.cardID == key &&
                      WCDBV3CardRow.Properties.revision == expectedRevision)
            guard tx.changes == 1 else { throw ReviewWCDBError.revisionConflict }
            // This insert and the current-content CAS are inseparable.
            try tx.insert(objects: [Self.makeContentVersionRow(
                edited, origin: origin, recordedAt: now)],
                intoTable: Self.contentVersionsTable)
            didChange = true
        })
        if didChange { ImpressV3BackupCoordinator.markDataChanged() }
    }

    public func setManagedCardSuspended(_ suspended: Bool,
                                        id: UUID,
                                        expectedRevision: Int) throws {
        let tx = try database.getTransaction()
        try tx.run(transaction: {
            guard let old: WCDBV3CardRow = try tx.getObject(
                fromTable: Self.cardsTable,
                where: WCDBV3CardRow.Properties.cardID == id.uuidString)
            else { throw ReviewWCDBError.missingCard }
            guard old.revision == expectedRevision else {
                throw ReviewWCDBError.revisionConflict
            }
            var updated = old
            updated.isSuspended = suspended ? 1 : 0
            updated.updatedAt = Date()
            try tx.update(table: Self.cardsTable,
                on: [WCDBV3CardRow.Properties.isSuspended,
                     WCDBV3CardRow.Properties.updatedAt],
                with: updated,
                where: WCDBV3CardRow.Properties.cardID == id.uuidString &&
                       WCDBV3CardRow.Properties.revision == expectedRevision)
            guard tx.changes == 1 else { throw ReviewWCDBError.revisionConflict }
        })
        ImpressV3BackupCoordinator.markDataChanged()
    }

    /// Explicit destructive action only. Removes the card and its review-event
    /// rows atomically; never affects source notes or independent learning logs.
    public func deleteManagedCard(id: UUID,
                                  expectedRevision: Int) throws {
        let tx = try database.getTransaction()
        try tx.run(transaction: {
            guard let old: WCDBV3CardRow = try tx.getObject(
                fromTable: Self.cardsTable,
                where: WCDBV3CardRow.Properties.cardID == id.uuidString)
            else { throw ReviewWCDBError.missingCard }
            guard old.revision == expectedRevision else {
                throw ReviewWCDBError.revisionConflict
            }
            try tx.delete(fromTable: Self.eventsTable,
                where: WCDBV3EventRow.Properties.cardID == id.uuidString)
            try tx.delete(fromTable: Self.cardsTable,
                where: WCDBV3CardRow.Properties.cardID == id.uuidString &&
                       WCDBV3CardRow.Properties.revision == expectedRevision)
            guard tx.changes == 1 else { throw ReviewWCDBError.revisionConflict }
        })
        ImpressV3BackupCoordinator.markDataChanged()
    }

    /// One transaction: event replay check, optimistic revision check, state
    /// update, row-count verification, immutable event insert.
    public func commit(_ submission: ReviewSubmission) async throws -> ReviewEvent {
        let eventKey = submission.eventID.uuidString
        let cardKey = submission.cardID.uuidString
        let transaction = try database.getTransaction()
        var outcome: ReviewEvent?

        do {
            try transaction.run(transaction: {
                let previousEvent: WCDBV3EventRow? = try transaction.getObject(
                    fromTable: Self.eventsTable,
                    where: WCDBV3EventRow.Properties.eventID == eventKey)
                if let previousEvent = previousEvent {
                    let event = try Self.decodeEvent(previousEvent)
                    try Self.assertSameRequest(event, submission)
                    outcome = event
                    return
                }

                guard let row: WCDBV3CardRow = try transaction.getObject(
                    fromTable: Self.cardsTable,
                    where: WCDBV3CardRow.Properties.cardID == cardKey)
                else { throw ReviewWCDBError.missingCard }
                guard let suspension = row.isSuspended else { throw ReviewWCDBError.corruptRecord }
                guard suspension == 0 else { throw ReviewWCDBError.suspendedCard }
                guard row.revision == submission.expectedRevision else {
                    throw ReviewWCDBError.revisionConflict
                }

                let before = try Self.decodeSnapshot(row, id: submission.cardID)
                guard let currentStatus = ReviewCardStatus(rawValue: row.state ?? -1),
                      currentStatus != .new || row.lastReviewedAt == nil else {
                    throw ReviewWCDBError.corruptRecord
                }

                let calculated = try calculator.next(
                    before: before, status: currentStatus, submission: submission)
                let after = calculated.snapshot
                guard after.cardID == submission.cardID,
                      after.revision == before.revision + 1,
                      after.lastReviewedAt == submission.reviewedAt,
                      after.dueAt.timeIntervalSince1970.isFinite,
                      !after.schedulerPayload.isEmpty else {
                    throw ReviewWCDBError.invalidSchedulerOutput
                }

                var nextRow = row
                nextRow.revision = after.revision
                nextRow.state = calculated.status.rawValue
                nextRow.dueAt = after.dueAt
                nextRow.lastReviewedAt = after.lastReviewedAt
                nextRow.schedulerPayload = after.schedulerPayload
                nextRow.updatedAt = submission.reviewedAt

                try transaction.update(
                    table: Self.cardsTable,
                    on: [
                        WCDBV3CardRow.Properties.revision,
                        WCDBV3CardRow.Properties.state,
                        WCDBV3CardRow.Properties.dueAt,
                        WCDBV3CardRow.Properties.lastReviewedAt,
                        WCDBV3CardRow.Properties.schedulerPayload,
                        WCDBV3CardRow.Properties.updatedAt
                    ],
                    with: nextRow,
                    where: WCDBV3CardRow.Properties.cardID == cardKey
                        && WCDBV3CardRow.Properties.revision == submission.expectedRevision
                )
                guard transaction.changes == 1 else {
                    throw ReviewWCDBError.revisionConflict
                }

                let event = ReviewEvent(
                    eventID: submission.eventID, cardID: submission.cardID,
                    rating: submission.rating, reviewedAt: submission.reviewedAt,
                    before: before, after: after,
                    algorithmIdentifier: algorithmIdentifier
                )
                var eventRow = WCDBV3EventRow()
                eventRow.eventID = eventKey
                eventRow.cardID = cardKey
                eventRow.reviewedAt = submission.reviewedAt
                eventRow.eventPayload = try JSONEncoder().encode(event)
                eventRow.schemaVersion = Self.schema
                try transaction.insert(objects: [eventRow], intoTable: Self.eventsTable)
                outcome = event
            })
        } catch {
            #if DEBUG
            NSLog("Impress V3 review transaction rejected: %@", String(describing: error))
            #endif
            // Commit acknowledgements can be ambiguous. If the event exists,
            // it and its card state were committed in the same transaction.
            if let persisted: WCDBV3EventRow = try? database.getObject(
                fromTable: Self.eventsTable,
                where: WCDBV3EventRow.Properties.eventID == eventKey) {
                let event = try Self.decodeEvent(persisted)
                try Self.assertSameRequest(event, submission)
                return event
            }
            throw error
        }
        guard let result = outcome else { throw ReviewWCDBError.corruptRecord }
        ImpressV3BackupCoordinator.markDataChanged()
        return result
    }

    /// Projection excludes question, answer, picture BLOB, and scheduler payload.
    public func fetchQueueCandidates() throws -> [ReviewQueueCandidate] {
        let projected: [WCDBV3CardRow] = try database.getObjects(
            on: [
                WCDBV3CardRow.Properties.cardID,
                WCDBV3CardRow.Properties.revision,
                WCDBV3CardRow.Properties.state,
                WCDBV3CardRow.Properties.dueAt,
                WCDBV3CardRow.Properties.createdAt,
                WCDBV3CardRow.Properties.isSuspended
            ],
            fromTable: Self.cardsTable
        )
        return try projected.map { row in
            guard let idText = row.cardID,
                  let id = UUID(uuidString: idText),
                  let version = row.revision,
                  let stateCode = row.state,
                  let status = ReviewCardStatus(rawValue: stateCode),
                  let due = row.dueAt,
                  let created = row.createdAt,
                  let suspension = row.isSuspended
            else { throw ReviewWCDBError.corruptRecord }
            return ReviewQueueCandidate(
                cardID: id, revision: version, status: status,
                dueAt: due, createdAt: created, isSuspended: suspension != 0
            )
        }
    }

    public func dueCount(at now: Date) throws -> Int {
        let condition = WCDBV3CardRow.Properties.isSuspended == 0
            && WCDBV3CardRow.Properties.state != ReviewCardStatus.new.rawValue
            && WCDBV3CardRow.Properties.dueAt <= now
        let result = try database.getRow(
            on: Column.all.count(), fromTable: Self.cardsTable, where: condition)
        return Int(result.first?.int64Value ?? 0)
    }

    /// Copy only a quiescent WCDB database. Closing all WCDB handles flushes
    /// the WAL to the main database before copying. The repository actor has no
    /// reentrant awaits inside this operation, so no new V3 write can race.
    /// This is deliberately separate from the legacy folder ZIP backup.
    /// The destination MUST be a fresh path; existing backups are not replaced.
    public func createConsistentBackup(to destination: URL) throws {
        let fileManager = FileManager.default
        let source = URL(fileURLWithPath: database.path)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ReviewWCDBError.invalidSchedulerOutput
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: nil
        )
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".impress-snapshot-" + UUID().uuidString)
        do {
            try database.close(onClosed: {
                try fileManager.copyItem(at: source, to: staging)
            })
            try fileManager.moveItem(at: staging, to: destination)
        } catch {
            try? fileManager.removeItem(at: staging)
            throw error
        }
    }

    /// Preserve complete local transcripts and resumable drafts/proposals.
    /// A model's request context window must be derived from this history
    /// without deleting earlier stored turns. No raw credentials belong here.
    private func decodeChatRow(_ row: WCDBV3ChatSessionRow) throws -> WCDBV3ChatSession {
        guard let bytes = row.record,
              let id = row.sessionID,
              let sessionID = UUID(uuidString: id) else {
            throw WCDBV3ChatStorageError.invalidRecord
        }
        let session = try JSONDecoder().decode(WCDBV3ChatSession.self, from: bytes)
        guard let storedUpdatedAt = row.updatedAt,
              session.sessionID == sessionID,
              session.sourceIdentity == row.sourceIdentity,
              abs(session.updatedAt.timeIntervalSince(storedUpdatedAt)) < 0.002 else {
            throw WCDBV3ChatStorageError.invalidRecord
        }
        return session
    }

    public func allChatSessions(includeDeleted: Bool = false) throws -> [WCDBV3ChatSession] {
        let rows: [WCDBV3ChatSessionRow] = try database.getObjects(
            fromTable: Self.chatSessionsTable,
            orderBy: [WCDBV3ChatSessionRow.Properties.updatedAt.asOrder(by: .descending)])
        return try rows.map(decodeChatRow).filter {
            includeDeleted || $0.isDeleted != true
        }
    }

    public func chatSessions(for sourceIdentity: String) throws -> [WCDBV3ChatSession] {
        guard !sourceIdentity.isEmpty else { throw WCDBV3ChatStorageError.invalidRecord }
        let rows: [WCDBV3ChatSessionRow] = try database.getObjects(
            fromTable: Self.chatSessionsTable,
            where: WCDBV3ChatSessionRow.Properties.sourceIdentity == sourceIdentity,
            orderBy: [WCDBV3ChatSessionRow.Properties.updatedAt.asOrder(by: .descending)])
        return try rows.map(decodeChatRow).filter { $0.isDeleted != true }
    }

    /// Read applied knowledge receipts even after a discussion has been
    /// deleted. Do not make a tombstone visible as a normal conversation.
    public func retainedChatReceipts() throws -> [WCDBV3ChatSession] {
        try allChatSessions(includeDeleted: true).filter { session in
            session.isDeleted == true && (
                session.pendingDuplex != nil || !(session.duplexHistory ?? []).isEmpty)
        }
    }

    /// Only a verified completed target is an executed audit fact.
    /// A failure/conflict message is NOT a write receipt and must never
    /// retain an unapproved card or note proposal in a deletion tombstone.
    private static func hasAppliedFact(_ proposal: WCDBV3DuplexProposal) -> Bool {
        let statuses = [proposal.state.noteStatus, proposal.state.cardStatus]
        return statuses.contains(where: { [.applied, .undoing, .reverted].contains($0) })
    }

    /// F13: keep executed target facts, not the rejected other target's private
    /// draft, failed receipts, or a deleted conversation message identifier.
    /// In-flight operations are rejected by deleteChatSession before this runs.
    private static func retainedAuditProposal(
        _ proposal: WCDBV3DuplexProposal) -> WCDBV3DuplexProposal? {
        let note = [.applied, .reverted].contains(proposal.state.noteStatus)
        let card = [.applied, .reverted].contains(proposal.state.cardStatus)
        guard note || card else { return nil }
        var retained = WCDBV3DuplexProposal(
            proposalID: proposal.proposalID,
            sourceMessageID: nil,
            noteIdentity: note ? proposal.noteIdentity : nil,
            noteBaseDigest: note ? proposal.noteBaseDigest : nil,
            noteEditedDigest: note ? proposal.noteEditedDigest : nil,
            cardID: card ? proposal.cardID : nil,
            cardReviewRevision: card ? proposal.cardReviewRevision : nil,
            cardContentRevision: card ? proposal.cardContentRevision : nil,
            cardBaseQuestion: card ? proposal.cardBaseQuestion : nil,
            cardBaseAnswer: card ? proposal.cardBaseAnswer : nil,
            cardEditedQuestion: card ? proposal.cardEditedQuestion : nil,
            cardEditedAnswer: card ? proposal.cardEditedAnswer : nil,
            state: ImDuplexApprovalState(
                noteSelected: note, cardSelected: card,
                noteStatus: note ? proposal.state.noteStatus : .pending,
                cardStatus: card ? proposal.state.cardStatus : .pending))
        retained.noteReceipt = note ? proposal.noteReceipt : nil
        retained.cardReceipt = card ? proposal.cardReceipt : nil
        return retained
    }

    public func deleteChatSession(_ sessionID: UUID, expectedRevision: Int) throws {
        let tx = try database.getTransaction()
        try tx.run(transaction: {
            guard let row: WCDBV3ChatSessionRow = try tx.getObject(
                fromTable: Self.chatSessionsTable,
                where: WCDBV3ChatSessionRow.Properties.sessionID == sessionID.uuidString),
                  let bytes = row.record else { throw WCDBV3ChatStorageError.invalidRecord }
            let old = try JSONDecoder().decode(WCDBV3ChatSession.self, from: bytes)
            guard old.sessionID == sessionID, old.isDeleted != true,
                  old.revision == expectedRevision else {
                throw WCDBV3ChatStorageError.conflict
            }
            let proposals = (old.pendingDuplex.map { [$0] } ?? []) +
                (old.duplexHistory ?? [])
            // A crashed/in-flight write has unknown side effects and must be
            // reconciled before a destructive action can conceal its state.
            for proposal in proposals {
                let note = proposal.state.noteStatus
                let card = proposal.state.cardStatus
                if [.applying, .undoing].contains(note) ||
                   [.applying, .undoing].contains(card) {
                    throw WCDBV3ChatStorageError.unsafeDeletion
                }
                let pendingNote = proposal.state.noteSelected &&
                    [.pending, .failed, .conflict].contains(note)
                let pendingCard = proposal.state.cardSelected &&
                    [.pending, .failed, .conflict].contains(card)
                if Self.hasAppliedFact(proposal) && (pendingNote || pendingCard) {
                    throw WCDBV3ChatStorageError.unsafeDeletion
                }
            }
            // F13: the source identity often embeds a private Vault path.
            // A deletion tombstone requires only its stable session ID, the
            // revision and the independently executed audit receipts. Build a
            // minimal record rather than copying confidential discussion fields
            // (including future optional fields) into the next backup ZIP.
            var erased = WCDBV3ChatSession(
                sessionID: old.sessionID,
                sourceIdentity: "deleted:" + old.sessionID.uuidString,
                createdAt: old.createdAt)
            erased.isDeleted = true
            var durable = (old.duplexHistory ?? []).compactMap(Self.retainedAuditProposal)
            if let pending = old.pendingDuplex,
               let retained = Self.retainedAuditProposal(pending),
               !durable.contains(where: { $0.proposalID == retained.proposalID }) {
                durable.append(retained)
            }
            erased.duplexHistory = durable
            erased.revision = old.revision + 1
            erased.updatedAt = max(Date(), old.updatedAt.addingTimeInterval(0.001))
            var changed = row
            changed.sourceIdentity = erased.sourceIdentity
            changed.updatedAt = erased.updatedAt
            changed.record = try JSONEncoder().encode(erased)
            try tx.update(table: Self.chatSessionsTable,
                on: [WCDBV3ChatSessionRow.Properties.sourceIdentity,
                     WCDBV3ChatSessionRow.Properties.updatedAt,
                     WCDBV3ChatSessionRow.Properties.record],
                with: changed,
                where: WCDBV3ChatSessionRow.Properties.sessionID == sessionID.uuidString)
            guard tx.changes == 1 else { throw WCDBV3ChatStorageError.conflict }
        })
        ImpressV3BackupCoordinator.markDataChanged()
    }

    public func saveChatSession(_ session: WCDBV3ChatSession,
                                expectedRevision: Int?) throws {
        guard !session.sourceIdentity.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              session.revision >= 0,
              session.messages.count <= 10_000,
              Set((session.duplexHistory ?? []).map(\.proposalID)).count ==
                  (session.duplexHistory ?? []).count,
              session.pendingDuplex.map { active in
                  !(session.duplexHistory ?? []).contains(where: {
                      $0.proposalID == active.proposalID
                  })
              } ?? true,
              Set(session.messages.map(\.messageID)).count == session.messages.count,
              session.messages.allSatisfy({ !$0.text.isEmpty || $0.status != .completed }),
              session.messages.allSatisfy({ message in
                  let photos = message.approvedImages ?? []
                  return (message.role == .user || photos.isEmpty) &&
                      photos.count <= 3 &&
                      photos.allSatisfy {
                          !$0.name.isEmpty && $0.name.utf8.count <= 100 &&
                          $0.jpegBytes > 0 && $0.jpegBytes <= 400_000
                      }
              })
        else { throw WCDBV3ChatStorageError.invalidRecord }
        let bytes = try JSONEncoder().encode(session)
        // A clear error avoids runaway SQLite/image-sized context archives.
        guard bytes.count <= 8 * 1_024 * 1_024 else {
            throw WCDBV3ChatStorageError.tooLarge
        }
        var row = WCDBV3ChatSessionRow()
        row.sessionID = session.sessionID.uuidString
        row.sourceIdentity = session.sourceIdentity
        row.updatedAt = session.updatedAt
        row.record = bytes
        let tx = try database.getTransaction()
        var didChange = false
        try tx.run(transaction: {
            let prior: WCDBV3ChatSessionRow? = try tx.getObject(
                fromTable: Self.chatSessionsTable,
                where: WCDBV3ChatSessionRow.Properties.sessionID == session.sessionID.uuidString)
            if let prior {
                guard let old = prior.record,
                      let decoded = try? JSONDecoder().decode(WCDBV3ChatSession.self, from: old) else {
                    throw WCDBV3ChatStorageError.invalidRecord
                }
                // A late callback must still fail as a deletion conflict after
                // the tombstone's source identity has been anonymized.
                guard decoded.isDeleted != true, session.isDeleted != true else {
                    throw WCDBV3ChatStorageError.conflict
                }
                guard decoded.sourceIdentity == session.sourceIdentity else {
                    throw WCDBV3ChatStorageError.invalidRecord
                }
                if decoded == session { return } // idempotent same snapshot
                guard let expectedRevision, decoded.revision == expectedRevision,
                      session.revision == expectedRevision + 1,
                      session.updatedAt >= decoded.updatedAt else {
                    throw WCDBV3ChatStorageError.conflict
                }
                try tx.update(table: Self.chatSessionsTable,
                    on: [WCDBV3ChatSessionRow.Properties.updatedAt,
                         WCDBV3ChatSessionRow.Properties.record],
                    with: row,
                    where: WCDBV3ChatSessionRow.Properties.sessionID == session.sessionID.uuidString)
                guard tx.changes == 1 else { throw WCDBV3ChatStorageError.conflict }
                didChange = true
            } else {
                guard expectedRevision == nil, session.revision == 0,
                      session.isDeleted != true else {
                    throw WCDBV3ChatStorageError.conflict
                }
                try tx.insert(objects: [row], intoTable: Self.chatSessionsTable)
                didChange = true
            }
        })
        if didChange { ImpressV3BackupCoordinator.markDataChanged() }
    }

    /// The content history is not the FSRS ReviewEvent history.
    /// Deleted card IDs retain snapshots for explicit archival/recovery;
    /// no title-based guessing is performed.
    public func contentHistory(for cardID: UUID) throws -> [WCDBV3ContentVersion] {
        let rows: [WCDBV3ContentVersionRow] = try database.getObjects(
            fromTable: Self.contentVersionsTable,
            where: WCDBV3ContentVersionRow.Properties.cardID == cardID.uuidString,
            orderBy: [WCDBV3ContentVersionRow.Properties.contentRevision.asOrder(by: .ascending)])
        return try rows.map { row in
            guard let blob = row.snapshot else { throw ReviewWCDBError.corruptRecord }
            let decoded = try JSONDecoder().decode(WCDBV3ContentVersion.self, from: blob)
            guard decoded.cardID == cardID,
                  decoded.contentRevision == row.contentRevision,
                  row.versionID == Self.contentVersionID(
                      cardID: cardID.uuidString, revision: decoded.contentRevision)
            else { throw ReviewWCDBError.corruptRecord }
            return decoded
        }
    }

    /// Restore creates a NEW effective version. Intermediate content revisions,
    /// their media BLOBs, and every FSRS event remain immutable.
    public func restoreContentVersion(cardID: UUID, savedRevision: Int,
                                      expectedContentRevision: Int,
                                      expectedReviewRevision: Int,
                                      now: Date = Date()) throws {
        guard let version = try contentHistory(for: cardID)
            .first(where: { $0.contentRevision == savedRevision }) else {
            throw ReviewWCDBError.missingCard
        }
        guard expectedContentRevision >= 0, expectedContentRevision < Int.max else {
            throw ReviewWCDBError.contentConflict
        }
        // Restoring a historical movie retains its immutable files but binds
        // the metadata to a NEW effective CAS revision; FSRS is unchanged.
        let mutation: WCDBV3CardVideoMutation = try version.videoReference.map {
            .replace(try $0.rebound(to: expectedContentRevision + 1))
        } ?? .remove
        try updateManagedCard(
            WCDBV3CardInput(cardID: cardID, question: version.question,
                            answerText: version.answerText, choices: version.choices,
                            correctIndices: version.correctIndices,
                            cardType: version.cardType, imageData: version.imageData,
                            sourceNotePath: version.sourceNotePath),
            expectedRevision: expectedReviewRevision,
            expectedContentRevision: expectedContentRevision,
            now: now, origin: .restored, videoMutation: mutation)
    }

    private static func contentVersionID(cardID: String, revision: Int) -> String {
        cardID + ":" + String(revision)
    }

    private static func decodeCardVideo(_ data: Data?, cardID: UUID,
                                        revision: Int) throws -> ImpressCardVideoReference? {
        guard let data else { return nil }
        guard data.count > 0, data.count <= 4096,
              let reference = try? JSONDecoder().decode(ImpressCardVideoReference.self, from: data),
              reference.belongs(to: cardID, revision: revision) else {
            throw ReviewWCDBError.corruptRecord
        }
        return reference
    }

    private static func encodeCardVideo(_ reference: ImpressCardVideoReference?,
                                        cardID: UUID, revision: Int) throws -> Data? {
        guard let reference else { return nil }
        guard reference.belongs(to: cardID, revision: revision) else {
            throw ReviewWCDBError.contentConflict
        }
        let bytes = try JSONEncoder().encode(reference)
        guard bytes.count <= 4096 else { throw ReviewWCDBError.contentConflict }
        return bytes
    }

    private static func sameContent(_ old: WCDBV3CardRow,
                                    _ input: WCDBV3CardInput) -> Bool {
        old.question == input.question &&
        old.answerText == input.answerText &&
        old.choices == input.choices &&
        old.correctIndices == input.correctIndices &&
        old.cardType == input.cardType &&
        old.imageData == input.imageData &&
        old.sourceNotePath == input.sourceNotePath
    }

    private static func makeContentVersionRow(_ card: WCDBV3CardRow,
                                              origin: WCDBV3ContentVersionOrigin,
                                              recordedAt: Date) throws -> WCDBV3ContentVersionRow {
        guard let rawID = card.cardID, let cardID = UUID(uuidString: rawID),
              let revision = card.contentRevision, revision >= 0,
              let question = card.question, let cardType = card.cardType else {
            throw ReviewWCDBError.corruptRecord
        }
        let media = try decodeCardVideo(card.videoReferenceJSON,
            cardID: cardID, revision: revision)
        let snapshot = WCDBV3ContentVersion(
            cardID: cardID, contentRevision: revision,
            recordedAt: recordedAt, origin: origin, question: question,
            answerText: card.answerText, choices: card.choices,
            correctIndices: card.correctIndices, cardType: cardType,
            imageData: card.imageData, videoReference: media,
            sourceNotePath: card.sourceNotePath)
        var row = WCDBV3ContentVersionRow()
        row.versionID = contentVersionID(cardID: rawID, revision: revision)
        row.cardID = rawID
        row.contentRevision = revision
        row.recordedAt = recordedAt
        row.snapshot = try JSONEncoder().encode(snapshot)
        return row
    }

    /// Fetch the heavy image only when this card is about to be presented.
    public func content(for cardID: UUID) throws -> WCDBV3CardContent? {
        guard let row: WCDBV3CardRow = try database.getObject(
            fromTable: Self.cardsTable,
            where: WCDBV3CardRow.Properties.cardID == cardID.uuidString)
        else { return nil }
        guard let question = row.question, let cardType = row.cardType else {
            throw ReviewWCDBError.corruptRecord
        }
        return WCDBV3CardContent(
            cardID: cardID, question: question, answerText: row.answerText,
            choices: row.choices, correctIndices: row.correctIndices,
            cardType: cardType, imageData: row.imageData,
            videoReference: try Self.decodeCardVideo(row.videoReferenceJSON,
                cardID: cardID, revision: row.contentRevision ?? 0),
            sourceNotePath: row.sourceNotePath,
            contentRevision: row.contentRevision ?? 0
        )
    }

    /// Current-card lookup for the after-reveal AVKit resolver. No image BLOB
    /// or movie bytes are fetched; stale content revisions fail closed.
    public func videoReference(for cardID: UUID,
                               contentRevision: Int) throws -> ImpressCardVideoReference? {
        guard let row: WCDBV3CardRow = try database.getObject(
            on: [WCDBV3CardRow.Properties.cardID,
                 WCDBV3CardRow.Properties.contentRevision,
                 WCDBV3CardRow.Properties.videoReferenceJSON],
            fromTable: Self.cardsTable,
            where: WCDBV3CardRow.Properties.cardID == cardID.uuidString)
        else { throw ReviewWCDBError.missingCard }
        guard row.contentRevision == contentRevision else {
            throw ReviewWCDBError.contentConflict
        }
        return try Self.decodeCardVideo(row.videoReferenceJSON,
            cardID: cardID, revision: contentRevision)
    }

    /// Audit BOTH effective and historical references before cleanup: undo
    /// history remains accessible even after a card is deleted.
    public func retainedMediaIDs() throws -> Set<UUID> {
        let current: [WCDBV3CardRow] = try database.getObjects(
            on: [WCDBV3CardRow.Properties.cardID,
                 WCDBV3CardRow.Properties.contentRevision,
                 WCDBV3CardRow.Properties.videoReferenceJSON],
            fromTable: Self.cardsTable)
        var ids = Set<UUID>()
        for row in current {
            guard let rawID = row.cardID, let cardID = UUID(uuidString: rawID),
                  let revision = row.contentRevision else {
                throw ReviewWCDBError.corruptRecord
            }
            if let reference = try Self.decodeCardVideo(row.videoReferenceJSON,
                cardID: cardID, revision: revision) {
                ids.insert(reference.mediaID)
            }
        }
        let history: [WCDBV3ContentVersionRow] = try database.getObjects(
            on: [WCDBV3ContentVersionRow.Properties.cardID,
                 WCDBV3ContentVersionRow.Properties.contentRevision,
                 WCDBV3ContentVersionRow.Properties.snapshot],
            fromTable: Self.contentVersionsTable)
        for row in history {
            guard let data = row.snapshot, let rawID = row.cardID,
                  let cardID = UUID(uuidString: rawID),
                  let revision = row.contentRevision else {
                throw ReviewWCDBError.corruptRecord
            }
            let version = try JSONDecoder().decode(WCDBV3ContentVersion.self, from: data)
            guard version.cardID == cardID, version.contentRevision == revision else {
                throw ReviewWCDBError.corruptRecord
            }
            if let reference = version.videoReference {
                guard reference.belongs(to: cardID, revision: revision) else {
                    throw ReviewWCDBError.corruptRecord
                }
                ids.insert(reference.mediaID)
            }
        }
        return ids
    }

    public func reviewHistory(for cardID: UUID) throws -> [ReviewEvent] {
        let rows: [WCDBV3EventRow] = try database.getObjects(
            fromTable: Self.eventsTable,
            where: WCDBV3EventRow.Properties.cardID == cardID.uuidString,
            orderBy: [WCDBV3EventRow.Properties.reviewedAt.asOrder(by: .ascending)]
        )
        return try rows.map { try Self.decodeEvent($0) }
    }

    private static func decodeSnapshot(
        _ row: WCDBV3CardRow, id: UUID) throws -> ReviewScheduleSnapshot {
        guard let revision = row.revision,
              let due = row.dueAt,
              let payload = row.schedulerPayload,
              !payload.isEmpty,
              due.timeIntervalSince1970.isFinite else {
            throw ReviewWCDBError.corruptRecord
        }
        return ReviewScheduleSnapshot(
            cardID: id, revision: revision, dueAt: due,
            lastReviewedAt: row.lastReviewedAt, schedulerPayload: payload
        )
    }

    private static func decodeEvent(_ row: WCDBV3EventRow) throws -> ReviewEvent {
        guard let data = row.eventPayload else { throw ReviewWCDBError.corruptRecord }
        return try JSONDecoder().decode(ReviewEvent.self, from: data)
    }

    private static func assertSameRequest(
        _ event: ReviewEvent, _ request: ReviewSubmission) throws {
        guard event.eventID == request.eventID,
              event.cardID == request.cardID,
              event.rating == request.rating,
              event.reviewedAt == request.reviewedAt,
              event.before.revision == request.expectedRevision else {
            throw ReviewWCDBError.eventIdentifierCollision
        }
    }
}
