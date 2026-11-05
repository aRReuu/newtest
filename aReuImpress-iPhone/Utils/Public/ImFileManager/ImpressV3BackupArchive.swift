import Foundation
import CryptoKit
import ImpressReviewCore

enum ImpressV3BackupFailure: LocalizedError {
    case invalidArchive, invalidManifest, unsupportedArchive
    case invalidChecksum, duplicateEntry, missingData
    case unsafeSize, notAuthorized, cloudUnavailable, restoreAlreadyPending
    case concurrentChanges, restoreInterrupted

    var errorDescription: String? {
        switch self {
        case .invalidArchive: return "备份归档不完整或结构损坏。"
        case .invalidManifest: return "备份清单格式不正确。"
        case .unsupportedArchive: return "备份格式版本不受支持。"
        case .invalidChecksum: return "备份文件校验失败，请勿恢复。"
        case .duplicateEntry: return "备份存在重复文件名。"
        case .missingData: return "备份缺少必要的 V3 数据。"
        case .unsafeSize: return "备份文件超出支持的大小限制。"
        case .notAuthorized: return "文件夹授权已失效，请重新选择备份位置。"
        case .cloudUnavailable: return "云端目录暂时不可用，本地备份已保留。"
        case .restoreAlreadyPending: return "已有待恢复的数据，请先重新启动应用完成恢复。"
        case .concurrentChanges: return "创建备份期间数据仍在变化，已保留上一个有效快照并等待下一次一致性备份。"
        case .restoreInterrupted: return "检测到上次恢复被系统中断，已回滚至恢复前的数据；请再次冷启动应用以重试已经确认的恢复。"
        }
    }
}

struct ImpressV3BackupFileRecord: Codable {
    let name: String
    let size: UInt64
    let sha256: String
}

struct ImpressV3BackupManifest: Codable {
    let formatVersion: Int
    let appData: String
    let createdAt: Date
    let files: [ImpressV3BackupFileRecord]
    // Vault source files, credentials and provider bookmarks never enter this archive.
    let includesExternalVault: Bool
    let includesCredentials: Bool

    static func make(_ records: [ImpressV3BackupFileRecord]) -> Self {
        .init(formatVersion: records.contains(where: { $0.name == "media-index.json" })
                ? 3 : (records.contains(where: { $0.name == "checkins-v1.json" }) ? 2 : 1),
              appData: "ImpressV3",
              createdAt: Date(), files: records,
              includesExternalVault: false, includesCredentials: false)
    }

    func validate(_ actual: [ImpressV3BackupFileRecord]) throws {
        let legacy = Set(["ReviewV3.sqlite", "LearningEntry-v1.json", "prompts.json"])
        let v2 = legacy.union(["checkins-v1.json"])
        let listed = Set(files.map(\.name))
        let extracted = Set(actual.map(\.name))
        let isV3 = formatVersion == 3
        let staticNames = isV3 ? v2.union(["media-index.json"]) :
            (formatVersion == 2 ? v2 : legacy)
        let mediaNames = listed.subtracting(staticNames)
        guard (1...3).contains(formatVersion),
              appData == "ImpressV3",
              !includesExternalVault, !includesCredentials,
              (isV3 ? (!mediaNames.isEmpty &&
                         mediaNames.count <= 256 &&
                         mediaNames.allSatisfy(ImpressV3BackupArchive.isSafeMediaName))
                    : mediaNames.isEmpty),
              staticNames.isSubset(of: listed),
              listed == extracted,
              files.count == listed.count,
              actual.count == extracted.count else {
            throw ImpressV3BackupFailure.invalidManifest
        }
        for expected in files {
            guard let match = actual.first(where: { $0.name == expected.name }),
                  match.size == expected.size,
                  match.sha256 == expected.sha256 else {
                throw ImpressV3BackupFailure.invalidChecksum
            }
        }
    }
}

/// Minimal, standards-compliant ZIP with stored (method 0) entries.
/// No third-party SDK, unzip command, shell invocation or remote HTTP.
enum ImpressV3BackupArchive {
    private static let legacyNames: Set<String> = [
        "ReviewV3.sqlite", "LearningEntry-v1.json", "prompts.json", "manifest.json"
    ]
    private static let allowedNames: Set<String> = legacyNames.union(["checkins-v1.json"])
    private static let mediaIndexName = "media-index.json"
    static func isSafeMediaName(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "CardVideo",
              let card = UUID(uuidString: String(parts[1])),
              let media = UUID(uuidString: String(parts[2])),
              String(parts[1]) == card.uuidString.lowercased(),
              String(parts[2]) == media.uuidString.lowercased() else { return false }
        return parts[3] == "video.mp4" || parts[3] == "cover.jpg"
    }
    private static func isAllowedName(_ name: String) -> Bool {
        allowedNames.contains(name) || name == mediaIndexName || isSafeMediaName(name)
    }

    /// SQLite is the source of truth for current AND historical/undo references.
    /// Read only fixed tables/columns and bounded JSON metadata, never movie BLOBs.
    static func mediaIndex(forSQLite file: URL) throws -> ImpressCardVideoArchiveIndex {
        var connection: OpaquePointer?
        let status = file.path.withCString {
            sqlite3_open_v2($0, &connection, SQLITE_OPEN_READONLY, nil)
        }
        guard status == SQLITE_OK, let db = connection else {
            if let connection { sqlite3_close(connection) }
            throw ImpressV3BackupFailure.invalidArchive
        }
        defer { sqlite3_close(db) }
        func scan(_ sql: String, _ row: (OpaquePointer) throws -> Void) throws {
            var pointer: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &pointer, nil) == SQLITE_OK,
                  let stmt = pointer else {
                if let pointer { sqlite3_finalize(pointer) }
                throw ImpressV3BackupFailure.invalidArchive
            }
            defer { sqlite3_finalize(stmt) }
            var code = sqlite3_step(stmt)
            while code == SQLITE_ROW {
                try row(stmt)
                code = sqlite3_step(stmt)
            }
            guard code == SQLITE_DONE else { throw ImpressV3BackupFailure.invalidArchive }
        }
        func string(_ statement: OpaquePointer, _ index: Int32) throws -> String {
            guard let raw = sqlite3_column_text(statement, index) else {
                throw ImpressV3BackupFailure.invalidArchive
            }
            return String(cString: UnsafeRawPointer(raw).assumingMemoryBound(to: CChar.self))
        }
        func data(_ statement: OpaquePointer, _ index: Int32,
                  maxBytes: Int) throws -> Data? {
            if sqlite3_column_type(statement, index) == SQLITE_NULL { return nil }
            let size = Int(sqlite3_column_bytes(statement, index))
            guard size > 0, size <= maxBytes,
                  let raw = sqlite3_column_blob(statement, index) else {
                throw ImpressV3BackupFailure.invalidArchive
            }
            return Data(bytes: raw, count: size)
        }
        var columns = Set<String>()
        try scan("PRAGMA table_info(impress_v3_memory_card);") { statement in
            columns.insert(try string(statement, 1))
        }
        var refs = [String: ImpressCardVideoReference]()
        func append(_ ref: ImpressCardVideoReference, cardID: UUID,
                    revision: Int) throws {
            guard ref.belongs(to: cardID, revision: revision) else {
                throw ImpressV3BackupFailure.invalidArchive
            }
            let key = cardID.uuidString + ":" + String(revision)
            if let existing = refs[key], existing != ref {
                throw ImpressV3BackupFailure.invalidArchive
            }
            refs[key] = ref
        }
        if columns.contains("video_reference") {
            try scan("SELECT card_id, content_revision, video_reference " +
                     "FROM impress_v3_memory_card WHERE video_reference IS NOT NULL;") { row in
                let card = try string(row, 0)
                guard let id = UUID(uuidString: card),
                      sqlite3_column_type(row, 1) != SQLITE_NULL,
                      let metadata = try data(row, 2, maxBytes: 4096) else {
                    throw ImpressV3BackupFailure.invalidArchive
                }
                let ref = try JSONDecoder().decode(ImpressCardVideoReference.self,
                                                    from: metadata)
                try append(ref, cardID: id,
                    revision: Int(sqlite3_column_int64(row, 1)))
            }
        }
        var hasHistory = false
        try scan("SELECT name FROM sqlite_master WHERE type='table' " +
                 "AND name='impress_v3_content_version';") { _ in
            hasHistory = true
        }
        if hasHistory {
            struct Envelope: Decodable {
                let cardID: UUID
                let contentRevision: Int
                let videoReference: ImpressCardVideoReference?
            }
            try scan("SELECT card_id, content_revision, snapshot " +
                     "FROM impress_v3_content_version;") { row in
                let card = try string(row, 0)
                guard let id = UUID(uuidString: card),
                      sqlite3_column_type(row, 1) != SQLITE_NULL,
                      let snapshot = try data(row, 2, maxBytes: 48 * 1_048_576) else {
                    throw ImpressV3BackupFailure.invalidArchive
                }
                let version = try JSONDecoder().decode(Envelope.self, from: snapshot)
                guard version.cardID == id,
                      version.contentRevision == Int(sqlite3_column_int64(row, 1)) else {
                    throw ImpressV3BackupFailure.invalidArchive
                }
                if let ref = version.videoReference {
                    try append(ref, cardID: id, revision: version.contentRevision)
                }
            }
        }
        return try ImpressCardVideoArchiveIndex(references: Array(refs.values))
    }

    /// Validate the ZIP reference graph before anyone swaps a live database.
    static func validateMediaBackup(database: URL, folder: URL,
                                    manifest: ImpressV3BackupManifest,
                                    records: [ImpressV3BackupFileRecord]) throws {
        let fromDatabase = try mediaIndex(forSQLite: database)
        if manifest.formatVersion != 3 {
            guard fromDatabase.references.isEmpty else {
                throw ImpressV3BackupFailure.missingData
            }
            return
        }
        let indexFile = folder.appendingPathComponent(mediaIndexName)
        let bytes = try Data(contentsOf: indexFile)
        guard bytes.count <= 64 * 1024 else {
            throw ImpressV3BackupFailure.unsafeSize
        }
        let index = try JSONDecoder().decode(ImpressCardVideoArchiveIndex.self,
                                              from: bytes)
        guard !index.references.isEmpty,
              index.references.count == fromDatabase.references.count,
              index.references.allSatisfy({ candidate in
                  fromDatabase.references.contains(candidate)
              }) else {
            throw ImpressV3BackupFailure.invalidManifest
        }
        let actual = records.filter { isSafeMediaName($0.name) }.map {
            ImpressCardVideoArchiveIndex.File(name: $0.name, bytes: $0.size,
                                              sha256: $0.sha256)
        }
        try index.validateExtractedFiles(actual)
    }

    private struct ZIPMember {
        let name: String
        let bytes: UInt32
        let crc: UInt32
        let offset: UInt32
    }

    /// Never trust a local-header-only prefix as an installable ZIP. The
    /// generated archive has a matching central directory and EOCD, with no
    /// comments, extra members or trailing overlay. Restore must reject a
    /// truncated/repacked archive even when each local CRC/manifest SHA matches.
    private static func verifyCentralDirectory(
        from input: FileHandle, startingAt start: UInt64,
        members: [ZIPMember]
    ) throws {
        guard !members.isEmpty, members.count <= 262,
              start <= UInt64(UInt32.max) else {
            throw ImpressV3BackupFailure.invalidArchive
        }
        for (index, local) in members.enumerated() {
            if index > 0 {
                let signature = try read(input, length: 4)
                guard try number(signature, at: 0, count: 4) == 0x02014b50 else {
                    throw ImpressV3BackupFailure.invalidArchive
                }
            }
            let record = try read(input, length: 42)
            let versionNeeded = try number(record, at: 2, count: 2)
            let flags = try number(record, at: 4, count: 2)
            let method = try number(record, at: 6, count: 2)
            let crc = try number(record, at: 12, count: 4)
            let compressed = try number(record, at: 16, count: 4)
            let uncompressed = try number(record, at: 20, count: 4)
            let nameCount = Int(try number(record, at: 24, count: 2))
            let extraCount = try number(record, at: 26, count: 2)
            let commentCount = try number(record, at: 28, count: 2)
            let diskStart = try number(record, at: 30, count: 2)
            let relativeOffset = try number(record, at: 38, count: 4)
            guard versionNeeded == 20, flags == 0, method == 0,
                  extraCount == 0, commentCount == 0, diskStart == 0,
                  crc == local.crc, compressed == local.bytes,
                  uncompressed == local.bytes, relativeOffset == local.offset,
                  nameCount == local.name.utf8.count,
                  String(data: try read(input, length: nameCount),
                         encoding: .utf8) == local.name else {
                throw ImpressV3BackupFailure.invalidArchive
            }
        }
        let end = input.offsetInFile
        guard end >= start, end - start <= UInt64(UInt32.max) else {
            throw ImpressV3BackupFailure.invalidArchive
        }
        let endRecord = try read(input, length: 22)
        guard try number(endRecord, at: 0, count: 4) == 0x06054b50,
              try number(endRecord, at: 4, count: 2) == 0,
              try number(endRecord, at: 6, count: 2) == 0,
              try number(endRecord, at: 8, count: 2) == UInt32(members.count),
              try number(endRecord, at: 10, count: 2) == UInt32(members.count),
              try number(endRecord, at: 12, count: 4) == UInt32(end - start),
              try number(endRecord, at: 16, count: 4) == UInt32(start),
              try number(endRecord, at: 20, count: 2) == 0,
              input.readData(ofLength: 1).isEmpty else {
            throw ImpressV3BackupFailure.invalidArchive
        }
    }

    private static let crcTable: [UInt32] = (0..<256).map { value in
        var number = UInt32(value)
        for _ in 0..<8 {
            number = number & 1 == 1
                ? (number >> 1) ^ 0xEDB88320
                : number >> 1
        }
        return number
    }

    private static func checksum(_ data: Data, initial: UInt32) -> UInt32 {
        data.reduce(initial) {
            crcTable[Int(($0 ^ UInt32($1)) & 0xff)] ^ ($0 >> 8)
        }
    }

    private static func u16(_ v: UInt16) -> Data {
        Data([UInt8(truncatingIfNeeded: v), UInt8(truncatingIfNeeded: v >> 8)])
    }
    private static func u32(_ v: UInt32) -> Data {
        u16(UInt16(truncatingIfNeeded: v)) + u16(UInt16(truncatingIfNeeded: v >> 16))
    }
    private static func number(_ bytes: Data, at index: Int, count: Int) throws -> UInt32 {
        guard count > 0, count <= 4, index >= 0, index + count <= bytes.count else {
            throw ImpressV3BackupFailure.invalidArchive
        }
        var result: UInt32 = 0
        for i in 0..<count { result |= UInt32(bytes[bytes.startIndex + index + i]) << UInt32(8 * i) }
        return result
    }
    private static func read(_ input: FileHandle, length: Int) throws -> Data {
        guard length >= 0, length <= 65536 else { throw ImpressV3BackupFailure.unsafeSize }
        let data = input.readData(ofLength: length)
        guard data.count == length else { throw ImpressV3BackupFailure.invalidArchive }
        return data
    }

    /// Open read-only; never create or repair the restored file implicitly.
    /// This is required in addition to ZIP CRC and manifest SHA checks.
    static func verifySQLite(_ file: URL) throws {
        var connection: OpaquePointer?
        let rc = file.path.withCString {
            sqlite3_open_v2($0, &connection, SQLITE_OPEN_READONLY, nil)
        }
        guard rc == SQLITE_OK, let db = connection else {
            if let connection { sqlite3_close(connection) }
            throw ImpressV3BackupFailure.invalidArchive
        }
        defer { sqlite3_close(db) }

        func integerQuery(_ sql: String) throws -> Int32 {
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw ImpressV3BackupFailure.invalidArchive }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw ImpressV3BackupFailure.invalidArchive
            }
            return sqlite3_column_int(statement, 0)
        }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA integrity_check;", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw ImpressV3BackupFailure.invalidArchive }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
              let raw = sqlite3_column_text(statement, 0),
              String(cString: UnsafeRawPointer(raw).assumingMemoryBound(to: CChar.self)) == "ok",
              sqlite3_step(statement) == SQLITE_DONE else {
            throw ImpressV3BackupFailure.invalidArchive
        }
        let tables = try integerQuery(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table' AND " +
            "name IN ('impress_v3_memory_card','impress_v3_review_event');")
        guard tables == 2 else { throw ImpressV3BackupFailure.invalidArchive }
    }

    /// Read counts from the verified backup instead of the current live DB.
    static func recordCounts(_ file: URL) throws -> (cards: Int, reviews: Int) {
        var connection: OpaquePointer?
        let rc = file.path.withCString {
            sqlite3_open_v2($0, &connection, SQLITE_OPEN_READONLY, nil)
        }
        guard rc == SQLITE_OK, let db = connection else {
            if let connection { sqlite3_close(connection) }
            throw ImpressV3BackupFailure.invalidArchive
        }
        defer { sqlite3_close(db) }
        func count(_ table: String) throws -> Int {
            var statement: OpaquePointer?
            let sql = "SELECT COUNT(*) FROM " + table + ";"
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else { throw ImpressV3BackupFailure.invalidArchive }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw ImpressV3BackupFailure.invalidArchive
            }
            let value = sqlite3_column_int64(statement, 0)
            guard value >= 0, sqlite3_step(statement) == SQLITE_DONE else {
                throw ImpressV3BackupFailure.invalidArchive
            }
            return Int(value)
        }
        return (try count("impress_v3_memory_card"),
                try count("impress_v3_review_event"))
    }

    static func inspectFile(_ url: URL, name: String) throws -> (ImpressV3BackupFileRecord, UInt32) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var total: UInt64 = 0
        var crc: UInt32 = 0xFFFFFFFF
        var sha = SHA256()
        while true {
            let bytes = handle.readData(ofLength: 64 * 1024)
            if bytes.isEmpty { break }
            total += UInt64(bytes.count)
            guard total <= UInt64(UInt32.max) else { throw ImpressV3BackupFailure.unsafeSize }
            sha.update(data: bytes)
            crc = checksum(bytes, initial: crc)
        }
        let digest = sha.finalize().map { String(format: "%02x", $0) }.joined()
        return (.init(name: name, size: total, sha256: digest), crc ^ 0xFFFFFFFF)
    }

    static func write(files: [(name: String, url: URL)], destination: URL) throws {
        let actual = Set(files.map(\.name))
        let mediaFiles = actual.filter(isSafeMediaName)
        let isV3 = actual.contains(mediaIndexName)
        let staticV3 = allowedNames.union([mediaIndexName])
        guard (actual == allowedNames || actual == legacyNames ||
              (isV3 && staticV3.isSubset(of: actual) &&
               !mediaFiles.isEmpty && mediaFiles.count <= 256 &&
               actual.subtracting(staticV3) == mediaFiles)),
              files.count == actual.count, files.count <= 262 else {
            throw ImpressV3BackupFailure.invalidManifest
        }
        let manager = FileManager.default
        guard !manager.fileExists(atPath: destination.path) else {
            throw ImpressV3BackupFailure.duplicateEntry
        }
        manager.createFile(atPath: destination.path, contents: nil)
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        do {
            var position: UInt64 = 0
            var members = [ZIPMember]()
            func append(_ part: Data) throws {
                try output.write(contentsOf: part)
                position += UInt64(part.count)
                guard position <= UInt64(UInt32.max) else {
                    throw ImpressV3BackupFailure.unsafeSize
                }
            }
            for (name, url) in files {
                let (record, crc) = try inspectFile(url, name: name)
                guard let size = UInt32(exactly: record.size) else {
                    throw ImpressV3BackupFailure.unsafeSize
                }
                let label = Data(name.utf8)
                guard let nameLength = UInt16(exactly: label.count),
                      let offset = UInt32(exactly: position) else {
                    throw ImpressV3BackupFailure.unsafeSize
                }
                let localParts: [Data] = [
                    u32(0x04034b50), u16(20), u16(0), u16(0),
                    u16(0), u16(0), u32(crc), u32(size),
                    u32(size), u16(nameLength), u16(0), label
                ]
                let localHeader = localParts.reduce(into: Data()) {
                    $0.append(contentsOf: $1)
                }
                try append(localHeader)
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                while true {
                    let chunk = input.readData(ofLength: 64 * 1024)
                    if chunk.isEmpty { break }
                    try append(chunk)
                }
                members.append(ZIPMember(name: name, bytes: size, crc: crc, offset: offset))
            }
            let directoryStart = position
            for member in members {
                let name = Data(member.name.utf8)
                let centralParts: [Data] = [
                    u32(0x02014b50), u16(20), u16(20),
                    u16(0), u16(0), u16(0), u16(0),
                    u32(member.crc), u32(member.bytes), u32(member.bytes),
                    u16(UInt16(name.count)), u16(0), u16(0),
                    u16(0), u16(0), u32(0), u32(member.offset), name
                ]
                let centralHeader = centralParts.reduce(into: Data()) {
                    $0.append(contentsOf: $1)
                }
                try append(centralHeader)
            }
            guard let start = UInt32(exactly: directoryStart),
                  let size = UInt32(exactly: position - directoryStart) else {
                throw ImpressV3BackupFailure.unsafeSize
            }
            let count = UInt16(members.count)
            try append(u32(0x06054b50) + u16(0) + u16(0) +
                       u16(count) + u16(count) + u32(size) + u32(start) + u16(0))
        } catch {
            try? output.close()
            try? manager.removeItem(at: destination)
            throw error
        }
    }

    /// Fail closed: reject traversal, duplicate entries, compression/encryption,
    /// unknown files, CRC mismatch, missing manifest and oversized archives.
    /// Data is extracted to a new caller-owned staging folder, never to a live DB.
    static func extract(source: URL, destination: URL) throws -> [ImpressV3BackupFileRecord] {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw ImpressV3BackupFailure.duplicateEntry
        }
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        do {
            let handle = try FileHandle(forReadingFrom: source)
            defer { try? handle.close() }
            var found = [ImpressV3BackupFileRecord]()
            var members = [ZIPMember]()
            var names = Set<String>()
            var cumulativeBytes: UInt64 = 0
            while true {
                let localOffset = handle.offsetInFile
                let rawSignature = handle.readData(ofLength: 4)
                guard rawSignature.count == 4 else { throw ImpressV3BackupFailure.invalidArchive }
                let signature = try number(rawSignature, at: 0, count: 4)
                if signature == 0x02014b50 {
                    try verifyCentralDirectory(from: handle, startingAt: localOffset,
                                               members: members)
                    break
                }
                guard signature == 0x04034b50 else {
                    throw ImpressV3BackupFailure.invalidArchive
                }
                let header = try read(handle, length: 26)
                let flags = try number(header, at: 2, count: 2)
                let method = try number(header, at: 4, count: 2)
                let expectedCRC = try number(header, at: 10, count: 4)
                let compressed = try number(header, at: 14, count: 4)
                let uncompressed = try number(header, at: 18, count: 4)
                let nameCount = Int(try number(header, at: 22, count: 2))
                let extraCount = Int(try number(header, at: 24, count: 2))
                guard flags == 0, method == 0, compressed == uncompressed,
                      uncompressed <= 1_073_741_824 else {
                    throw ImpressV3BackupFailure.unsupportedArchive
                }
                let bytes = try read(handle, length: nameCount)
                guard let name = String(data: bytes, encoding: .utf8),
                      isAllowedName(name), !names.contains(name),
                      names.count < 262 else {
                    throw ImpressV3BackupFailure.invalidArchive
                }
                if isSafeMediaName(name) {
                    guard UInt64(uncompressed) <=
                            (name.hasSuffix("/cover.jpg")
                             ? ImpressCardVideoReference.maximumCoverBytes
                             : ImpressCardVideoReference.maximumBytes) else {
                        throw ImpressV3BackupFailure.unsafeSize
                    }
                } else if name == mediaIndexName {
                    guard uncompressed <= 64 * 1024 else {
                        throw ImpressV3BackupFailure.unsafeSize
                    }
                }
                let (total, overflow) = cumulativeBytes.addingReportingOverflow(UInt64(uncompressed))
                guard !overflow, total <= UInt64(UInt32.max) else {
                    throw ImpressV3BackupFailure.unsafeSize
                }
                cumulativeBytes = total
                names.insert(name)
                _ = try read(handle, length: extraCount)
                let target = destination.appendingPathComponent(name)
                try fileManager.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
                fileManager.createFile(atPath: target.path, contents: nil)
                let output = try FileHandle(forWritingTo: target)
                defer { try? output.close() }
                var remaining = Int(uncompressed)
                var actualCRC: UInt32 = 0xFFFFFFFF
                var sha = SHA256()
                while remaining > 0 {
                    let chunk = try read(handle, length: min(remaining, 64 * 1024))
                    actualCRC = checksum(chunk, initial: actualCRC)
                    sha.update(data: chunk)
                    try output.write(contentsOf: chunk)
                    remaining -= chunk.count
                }
                guard (actualCRC ^ 0xFFFFFFFF) == expectedCRC else {
                    throw ImpressV3BackupFailure.invalidChecksum
                }
                found.append(.init(name: name, size: UInt64(uncompressed),
                    sha256: sha.finalize().map { String(format: "%02x", $0) }.joined()))
                guard let offset = UInt32(exactly: localOffset) else {
                    throw ImpressV3BackupFailure.unsafeSize
                }
                members.append(ZIPMember(name: name, bytes: uncompressed,
                                         crc: expectedCRC, offset: offset))
            }
            let isV3 = names.contains(mediaIndexName)
            let staticV3 = allowedNames.union([mediaIndexName])
            let media = names.filter(isSafeMediaName)
            guard names == allowedNames || names == legacyNames ||
                  (isV3 && staticV3.isSubset(of: names) && !media.isEmpty &&
                   media.count <= 256 && names.subtracting(staticV3) == media) else {
                throw ImpressV3BackupFailure.missingData
            }
            let manifest = try JSONDecoder().decode(ImpressV3BackupManifest.self,
                from: Data(contentsOf: destination.appendingPathComponent("manifest.json")))
            try manifest.validate(found.filter { $0.name != "manifest.json" })
            try validateMediaBackup(
                database: destination.appendingPathComponent("ReviewV3.sqlite"),
                folder: destination, manifest: manifest, records: found)
            return found
        } catch {
            try? fileManager.removeItem(at: destination)
            throw error
        }
    }
}
