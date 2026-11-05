import Foundation

/// Portable, no-I/O contracts for the V3.1 Obsidian synchronization gate.
/// No scheduler, WCDB, UIKit, Vault root or iCloud dependency.
public enum ImVaultCoreError: Error, Equatable {
    case invalidVaultIdentity
    case invalidRelativePath
    case modifiedSource
    case invalidDraft
    case oversizedFile
}

public enum ImVaultDocumentFormat: String, Codable, Sendable {
    case markdown, excalidrawMarkdown, excalidrawJSON, jsonCanvas, unsupported

    public static func detect(relativePath: String) -> Self? {
        let lower = relativePath.lowercased()
        if lower.hasSuffix(".excalidraw.md") { return .excalidrawMarkdown }
        if lower.hasSuffix(".md") { return .markdown }
        if lower.hasSuffix(".excalidraw") { return .excalidrawJSON }
        if lower.hasSuffix(".canvas") { return .jsonCanvas }
        return nil
    }

    public var allowsGenericMarkdownDraft: Bool { self == .markdown }
}

public struct ImVaultFileIdentity: Codable, Hashable, Sendable {
    public let vaultID: String
    public let relativePath: String

    public init(vaultID: String, relativePath: String) throws {
        let key = vaultID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains("/"), !key.contains("\\"),
              !key.contains("\0") else { throw ImVaultCoreError.invalidVaultIdentity }
        let raw = relativePath.precomposedStringWithCanonicalMapping
        guard !raw.isEmpty, !raw.hasPrefix("/"), !raw.contains("\\"),
              !raw.contains("\0"), !raw.contains(":") else {
            throw ImVaultCoreError.invalidRelativePath
        }
        let segments = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.isEmpty, segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              segments[0] != ".obsidian",
              ImVaultDocumentFormat.detect(relativePath: raw) != nil else {
            throw ImVaultCoreError.invalidRelativePath
        }
        self.vaultID = key
        self.relativePath = raw
    }

    public var documentFormat: ImVaultDocumentFormat {
        // Identity initialization/decoding remains validated on every file
        // access; malformed persisted paths must never grant write authority.
        ImVaultDocumentFormat.detect(relativePath: relativePath) ?? .unsupported
    }
}

public enum ImVaultWriteDecision: Equatable {
    case unchanged
    case safeToWrite
    case alreadyApplied
    case conflict
}

public enum ImVaultVersionGate {
    /// Re-hash the ACTUAL file bytes inside a coordinated write block, not the
    /// metadata timestamp. Neither two competing editors nor offline iCloud
    /// versions may silently replace a different local source revision.
    public static func decide(baseDigest: String, currentDigest: String,
                              proposedDigest: String) -> ImVaultWriteDecision {
        if proposedDigest == baseDigest { return .unchanged }
        if proposedDigest == currentDigest { return .alreadyApplied }
        if currentDigest != baseDigest { return .conflict }
        return .safeToWrite
    }
}

public struct ImVaultDraft: Codable, Equatable, Sendable {
    public let identity: ImVaultFileIdentity
    public let baseText: String
    /// Exact pre-edit file bytes, including any UTF-8 BOM/newline convention.
    public let baseRawData: Data
    public let baseDigest: String
    public var editedText: String
    public let createdAt: Date
    public var updatedAt: Date

    public init(identity: ImVaultFileIdentity, baseText: String,
                baseRawData: Data? = nil, editedText: String? = nil,
                createdAt: Date = Date()) throws {
        guard identity.documentFormat.allowsGenericMarkdownDraft else {
            throw ImVaultCoreError.invalidDraft
        }
        guard baseText.utf8.count <= 8 * 1024 * 1024 else {
            throw ImVaultCoreError.oversizedFile
        }
        let originalBytes = baseRawData ?? Data(baseText.utf8)
        guard originalBytes.count <= 8 * 1024 * 1024,
              String(data: originalBytes, encoding: .utf8) == baseText else {
            throw ImVaultCoreError.invalidDraft
        }
        guard !ImpressObsidianDrawingEnvelope.isSupportedDrawing(originalBytes)
        else { throw ImVaultCoreError.invalidDraft }
        self.identity = identity
        self.baseText = baseText
        self.baseRawData = originalBytes
        self.baseDigest = ImVaultDigest.sha256(originalBytes)
        self.editedText = editedText ?? baseText
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }

    public mutating func update(_ newValue: String, at date: Date = Date()) throws {
        guard newValue.utf8.count <= 8 * 1024 * 1024 else {
            throw ImVaultCoreError.oversizedFile
        }
        // Allow at most 8MB of the *actual* bytes written (BOM included).
        // Keep the old draft intact if this edit would exceed the limit.
        let previous = editedText
        editedText = newValue
        guard proposedBytes.count <= 8 * 1024 * 1024 else {
            editedText = previous
            throw ImVaultCoreError.oversizedFile
        }
        updatedAt = date
    }

    /// Preserve the original UTF-8 BOM and uniform line-ending convention.
    /// UIKit's UITextView may normalize CRLF to LF while editing. A harmless
    /// normalization must not rewrite every line or silently strip a BOM.
    /// Mixed-line-ending sources remain byte-sensitive; never claim they have
    /// been normalized without an observable modification.
    public var proposedBytes: Data {
        var rendered = editedText
        let withoutCRLF = baseText.replacingOccurrences(of: "\r\n", with: "")
        if baseText.contains("\r\n") &&
           !withoutCRLF.contains("\r") && !withoutCRLF.contains("\n") {
            rendered = rendered.replacingOccurrences(of: "\r\n", with: "\n")
                               .replacingOccurrences(of: "\n", with: "\r\n")
        } else if baseText.contains("\r") && !baseText.contains("\n") {
            rendered = rendered.replacingOccurrences(of: "\r\n", with: "\n")
                               .replacingOccurrences(of: "\n", with: "\r")
        }
        let prefix: [UInt8] = [0xEF, 0xBB, 0xBF]
        if baseRawData.starts(with: prefix) {
            var result = Data(prefix)
            result.append(contentsOf: rendered.utf8)
            return result
        }
        return Data(rendered.utf8)
    }

    public func validate() throws {
        guard identity.documentFormat.allowsGenericMarkdownDraft,
              ImVaultDigest.sha256(baseRawData) == baseDigest,
              String(data: baseRawData, encoding: .utf8) == baseText,
              proposedBytes.count <= 8 * 1024 * 1024,
              !ImpressObsidianDrawingEnvelope.isSupportedDrawing(baseRawData),
              !ImpressObsidianDrawingEnvelope.isSupportedDrawing(proposedBytes) else {
            throw ImVaultCoreError.invalidDraft
        }
    }

    public func decision(against source: Data) -> ImVaultWriteDecision {
        ImVaultVersionGate.decide(baseDigest: baseDigest,
            currentDigest: ImVaultDigest.sha256(source),
            proposedDigest: ImVaultDigest.sha256(proposedBytes))
    }

    public var hasChanges: Bool { proposedBytes != baseRawData }

    /// Exact UTF-8 content that would be committed after BOM/newline handling.
    /// The editor's raw text can differ from these bytes even when they look
    /// visually identical. Approval and verification diffs MUST use this.
    public var byteFaithfulBaseText: String {
        // Foundation's String(data:encoding:) strips UTF-8 BOM. Preserve
        // all original bytes in the readable full-diff projection instead.
        String(decoding: baseRawData, as: UTF8.self)
    }

    public var byteFaithfulEditedText: String {
        String(decoding: proposedBytes, as: UTF8.self)
    }
}

public enum ImVaultDiff {
    /// Bounded, lossless-text comparison for a user approval surface.
    /// Displays ALL differing middle lines up to the preview cap. When the
    /// preview is truncated, approval must remain disabled by the caller.
    public static func summary(base: String, edited: String, maximumLines: Int = 200) -> (text: String, complete: Bool) {
        // Editing a uniform CRLF/classic-Mac file in UITextView may yield LF
        // even when the write path restores the original separators. Compare
        // logical lines in that case, or the preview would claim every line
        // changed and arbitrarily block a one-line edit in a long note.
        // A mixed-newline source is NOT normalized here: a newline-only
        // rewrite in that file must remain visible and approvable explicitly.
        let stripped = base.replacingOccurrences(of: "\r\n", with: "")
        let uniformCRLF = base.contains("\r\n") &&
            !stripped.contains("\r") && !stripped.contains("\n")
        let classicMac = base.contains("\r") && !base.contains("\n")
        func logicalLines(_ text: String) -> [String] {
            if uniformCRLF {
                return text.replacingOccurrences(of: "\r\n", with: "\n")
                    .components(separatedBy: "\n")
            }
            if classicMac {
                return text.replacingOccurrences(of: "\r\n", with: "\n")
                    .replacingOccurrences(of: "\r", with: "\n")
                    .components(separatedBy: "\n")
            }
            return text.components(separatedBy: "\n")
        }
        let before = logicalLines(base)
        let after = logicalLines(edited)
        var prefix = 0
        while prefix < min(before.count, after.count) && before[prefix] == after[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(before.count, after.count) - prefix &&
                before[before.count - suffix - 1] == after[after.count - suffix - 1] {
            suffix += 1
        }
        let oldEnd = before.count - suffix, newEnd = after.count - suffix
        let middleBefore = Array(before[prefix..<oldEnd])
        let middleAfter = Array(after[prefix..<newEnd])
        guard middleBefore != middleAfter else { return ("没有变更", true) }
        let cap = max(1, maximumLines)

        // An ordinary first/last-line trim incorrectly marks ALL unchanged
        // middle paragraphs as modified when two distant sentences change.
        // Use the Swift standard-library diff for bounded middle regions to
        // show only real changed hunks. Very large/adversarial inputs retain
        // the conservative (possibly incomplete) legacy preview; never omit
        // a modification and then enable the write button.
        if middleBefore.count + middleAfter.count <= 4_000 {
            let changes = middleAfter.difference(from: middleBefore)
            var removedIndices = Set<Int>()
            var insertedIndices = Set<Int>()
            for change in changes {
                switch change {
                case .remove(let index, _, _): removedIndices.insert(index)
                case .insert(let index, _, _): insertedIndices.insert(index)
                }
            }
            let oldMatches = middleBefore.indices.filter { !removedIndices.contains($0) }
            let newMatches = middleAfter.indices.filter { !insertedIndices.contains($0) }
            var oldCursor = 0, newCursor = 0
            var emitted = 0, changed = 0
            var sections: [String] = []

            func appendHunk(oldEnd: Int, newEnd: Int) {
                guard oldEnd > oldCursor || newEnd > newCursor else { return }
                let minus = Array(middleBefore[oldCursor..<oldEnd]).map { "- " + $0 }
                let plus = Array(middleAfter[newCursor..<newEnd]).map { "+ " + $0 }
                let modified = minus + plus
                changed += modified.count
                var display = ["变更区域从第 \(prefix + oldCursor + 1) 行开始。删除 \(minus.count) 行，新增 \(plus.count) 行。"]
                let remaining = max(0, cap - emitted)
                if remaining > 0 {
                    display.append(contentsOf: modified.prefix(remaining))
                    emitted += min(modified.count, remaining)
                }
                sections.append(display.joined(separator: "\n"))
            }

            for (oldMatch, newMatch) in zip(oldMatches, newMatches) {
                appendHunk(oldEnd: oldMatch, newEnd: newMatch)
                oldCursor = oldMatch + 1
                newCursor = newMatch + 1
            }
            appendHunk(oldEnd: middleBefore.count, newEnd: middleAfter.count)
            if changed == 0 { return ("没有变更", true) }
            let complete = changed <= cap
            return (sections.joined(separator: "\n\n") +
                (complete ? "" : "\n⚠ 变更预览已截断，禁止提交"), complete)
        }

        // CPU-bounded conservative fallback for unusually large diffs.
        let removed = middleBefore.map { "- " + $0 }
        let added = middleAfter.map { "+ " + $0 }
        let all = removed + added
        let header = "变更区域从第 \(prefix + 1) 行开始。删除 \(removed.count) 行，新增 \(added.count) 行。\n"
        let complete = all.count <= cap
        return (header + all.prefix(cap).joined(separator: "\n") +
            (complete ? "" : "\n⚠ 变更预览已截断，禁止提交"), complete)
    }
}

/// One review can approve two independently selected objects, but never pretends
/// an external File Provider write and a WCDB transaction are atomic.
public enum ImDuplexTargetStatus: String, Codable, Equatable, Sendable {
    case pending, applying, applied, conflict, failed
    /// A user-confirmed inverse edit is in progress. Must NOT be mistaken
    /// for a forward retry after process death.
    case undoing, reverted
}
public struct ImDuplexApprovalState: Codable, Equatable, Sendable {
    public var noteSelected: Bool
    public var cardSelected: Bool
    public var noteStatus: ImDuplexTargetStatus
    public var cardStatus: ImDuplexTargetStatus
    public init(noteSelected: Bool, cardSelected: Bool,
                noteStatus: ImDuplexTargetStatus = .pending,
                cardStatus: ImDuplexTargetStatus = .pending) {
        self.noteSelected = noteSelected
        self.cardSelected = cardSelected
        self.noteStatus = noteStatus
        self.cardStatus = cardStatus
    }
    /// NEVER auto-run in-flight work after app restart. A later explicit
    /// confirmation may retry only the targets that were not applied.
    private static func needsForwardAction(_ status: ImDuplexTargetStatus) -> Bool {
        switch status {
        case .pending, .applying, .conflict, .failed: return true
        case .applied, .undoing, .reverted: return false
        }
    }
    public var needsNoteAction: Bool {
        noteSelected && Self.needsForwardAction(noteStatus)
    }
    public var needsCardAction: Bool {
        cardSelected && Self.needsForwardAction(cardStatus)
    }
    // Undo intent remains durable even if a legacy or faulty UI snapshot
    // deselected the target. It must never become "completed" by deselection.
    public var needsNoteUndo: Bool { noteStatus == .undoing }
    public var needsCardUndo: Bool { cardStatus == .undoing }
    public var completed: Bool {
        // A crash between the reverse write and its receipt is never
        // mistaken for an already-finished operation. Recover manually.
        noteStatus != .applying && cardStatus != .applying &&
        !needsNoteAction && !needsCardAction && !needsNoteUndo && !needsCardUndo
    }
}



/// Classify a previously interrupted *forward* write by reading authoritative
/// storage; never attempt a second write while its outcome is unknown.
/// A verified changed source is a conflict requiring fresh review, not an
/// invitation to replay a stale ApprovedDraft.
public enum ImDuplexInterruptedRecovery {
    /// Read-only adjudication of an interrupted inverse source write. Only
    /// matching the *original* bytes can confirm the desired restored state.
    /// An approved or third-party digest is inconclusive and MUST NOT cause a
    /// retry, status reset or a fabricated completion receipt.
    public static func noteUndoStatus(currentDigest: String?,
                                      approvedDigest: String,
                                      originalDigest: String) -> ImDuplexTargetStatus? {
        guard let currentDigest, !currentDigest.isEmpty,
              !approvedDigest.isEmpty, !originalDigest.isEmpty,
              approvedDigest != originalDigest else { return nil }
        return currentDigest == originalDigest ? .reverted : nil
    }

    /// Content revision, not the independent FSRS scheduling revision, is the
    /// proof for a completed inverse card write. Approval created revision +1;
    /// a verified undo creates +2. Intervening edits never infer success.
    public static func cardUndoStatus(currentContentRevision: Int?,
                                      expectedBaseContentRevision: Int,
                                      originalQuestion: String, originalAnswer: String?,
                                      approvedQuestion: String, approvedAnswer: String?,
                                      currentQuestion: String?, currentAnswer: String?)
        -> ImDuplexTargetStatus? {
        guard let currentContentRevision, let currentQuestion,
              expectedBaseContentRevision >= 0,
              expectedBaseContentRevision <= Int.max - 2,
              originalQuestion != approvedQuestion ||
                  originalAnswer != approvedAnswer else { return nil }
        if currentContentRevision == expectedBaseContentRevision + 2 &&
            currentQuestion == originalQuestion && currentAnswer == originalAnswer {
            return .reverted
        }
        return nil
    }

    public static func noteStatus(currentDigest: String?,
                                  baseDigest: String, proposedDigest: String)
        -> ImDuplexTargetStatus? {
        guard let currentDigest, !currentDigest.isEmpty,
              !baseDigest.isEmpty, !proposedDigest.isEmpty else { return nil }
        if currentDigest == proposedDigest { return .applied }
        return .conflict
    }

    public static func cardStatus(currentContentRevision: Int?,
                                  expectedContentRevision: Int,
                                  baseQuestion: String, baseAnswer: String?,
                                  proposedQuestion: String, proposedAnswer: String?,
                                  currentQuestion: String?, currentAnswer: String?)
        -> ImDuplexTargetStatus? {
        guard let currentContentRevision, let currentQuestion,
              expectedContentRevision >= 0, expectedContentRevision < Int.max
              else { return nil }
        let unchangedProposal = baseQuestion == proposedQuestion &&
            baseAnswer == proposedAnswer
        if unchangedProposal && currentContentRevision == expectedContentRevision &&
           currentQuestion == baseQuestion && currentAnswer == baseAnswer {
            return .applied
        }
        if !unchangedProposal && currentContentRevision == expectedContentRevision + 1 &&
           currentQuestion == proposedQuestion && currentAnswer == proposedAnswer {
            return .applied
        }
        return .conflict
    }
}

public enum ImDuplexCardVersionDecision: Equatable, Sendable {
    case unchanged, safeToWrite, alreadyApplied, conflict
}
public enum ImDuplexCardVersionGate {
    /// This gate checks *content* revision independently of FSRS review
    /// revision, and rejects an unrelated edit even when text coincidentally
    /// shares a title. Equal proposed bytes at revision + 1 are idempotent.
    public static func decide(expectedContentRevision: Int, currentContentRevision: Int,
                              baseQuestion: String, baseAnswer: String?,
                              proposedQuestion: String, proposedAnswer: String?,
                              currentQuestion: String, currentAnswer: String?)
        -> ImDuplexCardVersionDecision {
        // A missing or overflowed content revision cannot authorize a CAS,
        // including an apparently harmless no-op. Int.max has no successor.
        guard expectedContentRevision >= 0, expectedContentRevision < Int.max,
              currentContentRevision >= 0 else { return .conflict }
        let sameAsBase = currentQuestion == baseQuestion && currentAnswer == baseAnswer
        let sameAsProposal = currentQuestion == proposedQuestion &&
            currentAnswer == proposedAnswer
        if proposedQuestion == baseQuestion && proposedAnswer == baseAnswer {
            // A no-op cannot acknowledge a stale card after a human edit:
            // unchanged text at a newer content revision is not the same CAS.
            guard currentContentRevision == expectedContentRevision && sameAsBase else {
                return .conflict
            }
            return .unchanged
        }
        if currentContentRevision == expectedContentRevision && sameAsBase {
            return .safeToWrite
        }
        if expectedContentRevision >= 0 && expectedContentRevision < Int.max &&
           currentContentRevision == expectedContentRevision + 1 && sameAsProposal {
            return .alreadyApplied
        }
        return .conflict
    }
}

/// Cryptographic content version: Apple CryptoKit on iOS and a portable
/// FIPS-180 SHA-256 implementation on Linux test runners.
public enum ImVaultDigest {
    public static func sha256(_ data: Data) -> String {
        #if canImport(CryptoKit)
        return CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        #else
        return portableSHA256(Array(data)).map { String(format: "%02x", $0) }.joined()
        #endif
    }

    #if !canImport(CryptoKit)
    private static let roundConstants: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
    ]
    private static func ror(_ v: UInt32, _ n: UInt32) -> UInt32 {
        (v >> n) | (v << (32 - n))
    }
    private static func portableSHA256(_ input: [UInt8]) -> [UInt8] {
        var bytes = input
        let bitLength = UInt64(bytes.count) &* 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) {
            bytes.append(UInt8(truncatingIfNeeded: bitLength >> UInt64(shift)))
        }
        var hash: [UInt32] = [
            0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
            0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19
        ]
        for offset in stride(from: 0, to: bytes.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 64)
            for i in 0..<16 {
                let p = offset + i * 4
                w[i] = UInt32(bytes[p]) << 24 | UInt32(bytes[p + 1]) << 16 |
                       UInt32(bytes[p + 2]) << 8 | UInt32(bytes[p + 3])
            }
            for i in 16..<64 {
                let s0 = ror(w[i-15], 7) ^ ror(w[i-15], 18) ^ (w[i-15] >> 3)
                let s1 = ror(w[i-2], 17) ^ ror(w[i-2], 19) ^ (w[i-2] >> 10)
                w[i] = w[i-16] &+ s0 &+ w[i-7] &+ s1
            }
            var a=hash[0], b=hash[1], c=hash[2], d=hash[3]
            var e=hash[4], f=hash[5], g=hash[6], h=hash[7]
            for i in 0..<64 {
                let s1 = ror(e,6) ^ ror(e,11) ^ ror(e,25)
                let ch = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ ch &+ roundConstants[i] &+ w[i]
                let s0 = ror(a,2) ^ ror(a,13) ^ ror(a,22)
                let maj = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ maj
                h=g; g=f; f=e; e=d &+ temp1
                d=c; c=b; b=a; a=temp1 &+ temp2
            }
            hash[0] = hash[0] &+ a; hash[1] = hash[1] &+ b
            hash[2] = hash[2] &+ c; hash[3] = hash[3] &+ d
            hash[4] = hash[4] &+ e; hash[5] = hash[5] &+ f
            hash[6] = hash[6] &+ g; hash[7] = hash[7] &+ h
        }
        return hash.flatMap { word in
            [UInt8(truncatingIfNeeded: word >> 24),UInt8(truncatingIfNeeded: word >> 16),
             UInt8(truncatingIfNeeded: word >> 8),UInt8(truncatingIfNeeded: word)]
        }
    }
    #endif
}
#if canImport(CryptoKit)
import CryptoKit
#endif


/// P0 privacy boundary for presenting an external Markdown document inside a
/// WebKit renderer. Preserves Obsidian wiki-image syntax for the separate
/// security-scoped local embed resolver, but removes all normal Markdown image
/// constructs including reference-style, shortcut and inline variants.
/// This does NOT mutate the original Markdown bytes.
public enum ImVaultSafetyProjection {
    /// Maps Obsidian [[note|alias]] to an inert, interceptable internal HTTPS
    /// URI. This special host is never allowed to navigate in the web view;
    /// the native router resolves links against the *authorized Vault index*.
    /// Untrusted/external-looking targets remain plain text.
    public static func withWikiLinks(_ source: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?<!!)\[\[([^\]\r\n]{1,200})\]\]"#) else { return source }
        var output = source
        let matches = regex.matches(in: source, range: NSRange(source.startIndex..., in: source))
        for match in matches.reversed() {
            guard let range = Range(match.range, in: output),
                  let inner = Range(match.range(at: 1), in: output) else { continue }
            let parts = String(output[inner]).split(separator: "|", maxSplits: 1,
                                                    omittingEmptySubsequences: false)
            let target = String(parts[0]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !target.isEmpty, !target.hasPrefix("/"),
                  !target.contains(":"), !target.contains("\\"),
                  !target.contains("[") && !target.contains("]"),
                  !target.split(separator: "/").contains("..") else { continue }
            let alias = parts.count > 1 ? String(parts[1]) : target
            let label = alias.replacingOccurrences(of: "[", with: "\\[")
                             .replacingOccurrences(of: "]", with: "\\]")
                             .replacingOccurrences(of: "(", with: "\\(")
                             .replacingOccurrences(of: ")", with: "\\)")
            var allowed = CharacterSet.urlQueryAllowed
            allowed.remove(charactersIn: "&=+#")
            guard let encoded = target.addingPercentEncoding(withAllowedCharacters: allowed) else { continue }
            output.replaceSubrange(range, with:
                "[\(label)](https://impress.invalid/wiki?target=\(encoded))")
        }
        return output
    }

    /// Obsidian > [!NOTE] and > [!WARNING] become readable native Markdown
    /// blockquotes. Full Obsidian plugin and foldable callout semantics are
    /// intentionally not claimed.
    public static func withCalloutHeadings(_ source: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"(?m)^([ \t]*>[ \t]*)\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION|QUOTE|TODO)\](?:[ \t]+([^\r\n]*))?"#,
            options: [.caseInsensitive]) else { return source }
        var result = source
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            guard let full = Range(match.range, in: result),
                  let first = Range(match.range(at: 1), in: result),
                  let kind = Range(match.range(at: 2), in: result) else { continue }
            let title = match.range(at: 3).location == NSNotFound ? "" :
                (Range(match.range(at: 3), in: result).map { String(result[$0]) } ?? "")
            let type = String(result[kind]).uppercased()
            let heading = title.isEmpty ? type : type + " · " + title
            result.replaceSubrange(full, with: String(result[first]) + "**" + heading + "**")
        }
        return result
    }

    public static func withoutUntrustedImages(_ source: String) -> String {
        var projected = source
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
        let markers: [(String, String)] = [
            // Direct image URLs, including whitespace and angle-bracket form.
            (#"(?s)!\[[^\]\n]*\]\s*\([^)]*\)"#, "（外部图片已屏蔽）"),
            // Reference image: ![desc][asset] or ![desc][].
            (#"!\[[^\]\n]*\]\s*\[[^\]\n]*\]"#, "（外部图片已屏蔽）"),
            // Shortcut reference ![desc]. Don't eat Obsidian ![[image.png]].
            (#"!\[[^\]\n]*\](?!\])"#, "（外部图片已屏蔽）")
        ]
        for (pattern, replacement) in markers {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(projected.startIndex..., in: projected)
            projected = regex.stringByReplacingMatches(in: projected,
                options: [], range: range, withTemplate: replacement)
        }
        return projected
    }
}


/// A main-thread scoped generation token for asynchronous directory scans.
/// Changing or disconnecting the Vault invalidates ALL responses from the old
/// source, even if a callback completes successfully after authorization
/// changes. Does not access files or acquire additional provider privileges.
public struct ImVaultAsyncReadToken: Equatable, Sendable {
    public let vaultID: String
    public let generation: UInt64
}

public struct ImVaultAsyncReadGate {
    public private(set) var activeVaultID: String?
    private var generation: UInt64 = 0

    public init() {}

    @discardableResult
    public mutating func changeSource(to vaultID: String?) -> Bool {
        guard activeVaultID != vaultID else { return false }
        activeVaultID = vaultID
        generation &+= 1
        return true
    }

    public mutating func begin(for vaultID: String) -> ImVaultAsyncReadToken {
        changeSource(to: vaultID)
        generation &+= 1
        return ImVaultAsyncReadToken(vaultID: vaultID, generation: generation)
    }

    /// Caller must also check the current authorized Bookmark identity, since
    /// a revoked permission may change in a different control flow.
    public func accepts(_ token: ImVaultAsyncReadToken) -> Bool {
        activeVaultID == token.vaultID && generation == token.generation
    }
}
